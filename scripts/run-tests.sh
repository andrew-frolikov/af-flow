#!/bin/bash
# Run the test suite WITHOUT destroying Andrew's live app settings.
#
# Written 2026-07-20 after the test suite broke his dictation.
#
# WHAT WENT WRONG, because the mechanism is not obvious. The tests run inside
# the GhostPepper app host, so they share its bundle identifier, its sandbox
# container, and therefore its UserDefaults domain. Many of them write real
# settings: `appState.preferredLanguage = "fr"` appears eight times in
# GhostPepperTests.swift alone, and several write `speechModel` directly.
#
# Most of those tests save the previous value and restore it in a defer. That
# is correct and it is not enough, because **a test that fails partway through
# can leave the value behind**, and on 2026-07-20 fourteen tests were failing.
#
# The result was not theoretical. After two full-suite runs his live app was
# left on `speechModel = openai_whisper-small.en`, an English-only model, with
# `preferredLanguage = fr`. He dictated Russian and got English back. The app
# was behaving exactly as configured; the configuration had been overwritten by
# a test run.
#
# THE FIX. Snapshot the whole defaults domain before the run and restore it
# afterwards, unconditionally, via a trap so it survives a failing suite, a
# crash, or a Ctrl-C. Per-test cleanup is the tests' job; this is the seatbelt
# for when that cleanup does not run.
#
# It also refuses to run while the app is open, because `xcodebuild test`
# launches its own copy of the app as the test host. Two instances of a
# dictation app compete for one microphone, which is very likely part of the
# "No sound detected" overlay recorded in PROGRESS.md.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

DOMAIN="com.frolikov.afflow"
TEAM="Q4HNX2JLKT"
DERIVED="${AF_FLOW_DERIVED:-build/run-derived}"
BACKUP="$(mktemp -t afflow-defaults).plist"

# The marker that makes a directory deletable by this script. Written on every
# output directory this script creates, and required before any `rm -rf`.
OUTPUT_SENTINEL=".af-flow-scratch"

# Validate a caller-supplied AF_FLOW_OUTPUT before anything else happens.
#
# **Placed first on purpose, and the reason is a testing one as much as a
# safety one.** It used to sit next to the `rm -rf` it protects, which put it
# behind both the build-only branch and the refuse-while-running guard. That
# made it unreachable, and therefore uncanaryable, whenever Andrew's app was
# open, which is most of the time. A guard nobody can exercise is a guard
# nobody has checked.
#
# It is pure validation with no side effects, so running it always costs
# nothing and it now applies on every path. The `rm -rf` itself stays where it
# was; only the decision moved.
validate_output_directory() {
    [ -z "${AF_FLOW_OUTPUT:-}" ] && return 0

    # RELATIVE PATHS ARE REFUSED, and this one was found by canarying the fix
    # rather than by reasoning about it, which is the third time on this project
    # that a guard's own canary has caught the guard.
    #
    # Line 34 does `cd "$(dirname "$0")/.."`, so by the time anything here runs
    # the working directory is the REPO ROOT, not wherever the caller was
    # standing. A relative `AF_FLOW_OUTPUT` therefore silently means something
    # different from what the person typing it meant, and the canonicalisation
    # above cannot help: `cd -P` on a path that does not exist under the repo
    # root fails, the fallback returns the literal string, no comparison
    # matches, and the whole guard falls through to `rm -rf` on a path resolved
    # against a directory the caller never mentioned.
    #
    # There is no legitimate reason to pass a relative output directory here,
    # so the ambiguity is removed rather than resolved.
    for var in AF_FLOW_OUTPUT AF_FLOW_FIXTURES; do
        value="${!var:-}"
        [ -z "$value" ] && continue
        case "$value" in
            /*) ;;
            *)
                echo "REFUSING TO RUN: $var must be an absolute path." >&2
                echo "  $var=$value" >&2
                echo "This script changes directory to the repo root before doing anything," >&2
                echo "so a relative path here resolves against the repo, not against you." >&2
                exit 7
                ;;
        esac
    done

    # CANONICALISE BOTH SIDES BEFORE COMPARING. String equality was the first
    # version and Codex was right that it is not a guard at all: a trailing
    # slash, a relative path, a `..`, or a symlink all spell the same directory
    # differently and every one of them walked straight past it into `rm -rf`.
    canonical() {
        ( cd -P "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"
    }
    local out_real fix_real
    out_real="$(canonical "$AF_FLOW_OUTPUT")"

    if [ -n "${AF_FLOW_FIXTURES:-}" ]; then
        fix_real="$(canonical "$AF_FLOW_FIXTURES")"
        # Equal, OR the output is an ANCESTOR of the fixtures, which is worse:
        # `rm -rf` on a parent takes the fixtures with it and an equality test
        # would have said nothing at all.
        if [ "$out_real" = "$fix_real" ] \
            || case "$fix_real/" in "$out_real"/*) true ;; *) false ;; esac; then
            echo "REFUSING TO RUN: AF_FLOW_OUTPUT is, or contains, AF_FLOW_FIXTURES." >&2
            echo "  output:   $out_real" >&2
            echo "  fixtures: $fix_real" >&2
            echo "This script wipes the output directory before every run, so that would" >&2
            echo "delete the corrected reference text and the captured transcripts." >&2
            exit 7
        fi
    fi

    # **ONLY DELETE WHAT THIS SCRIPT CREATED AND MARKED.**
    #
    # Everything before this line was a BLOCKLIST: it enumerated what looks
    # precious, reference text and worksheets and five audio extensions, and
    # deleted anything that did not match. That design has now failed here
    # three times in three review rounds, each time on a spelling nobody had
    # imagined: a trailing slash, then a symlink, then a capital `.M4A`. And it
    # would still have wiped a directory of Andrew's notes without hesitating,
    # because notes are not on the list.
    #
    # LOOP.md already says why: a check like this only catches what its author
    # already imagined, and the author is the worst-placed person to find the
    # gap. The fix is not a fourth entry on the list. It is to stop asking
    # "does this look precious" and start asking "did I make this", which is a
    # question with a ground truth rather than a guess.
    #
    # So the directory must either not exist yet, or carry a sentinel file this
    # script wrote itself. Nothing else is ever deleted, whatever it contains.
    if [ -e "$out_real" ] && [ ! -f "$out_real/$OUTPUT_SENTINEL" ]; then
        echo "REFUSING TO RUN: AF_FLOW_OUTPUT exists and this script did not create it." >&2
        echo "  $out_real" >&2
        echo "This script wipes the output directory before every run, and it only" >&2
        echo "ever wipes a directory carrying its own marker file:" >&2
        echo "  $OUTPUT_SENTINEL" >&2
        echo "Point AF_FLOW_OUTPUT at a new or previously-used scratch path, or leave" >&2
        echo "it unset and the script will choose one inside the app container." >&2
        exit 7
    fi
}
validate_output_directory

build_for_testing() {
    xcodebuild build-for-testing \
        -project GhostPepper.xcodeproj \
        -scheme GhostPepper \
        -configuration Debug \
        -derivedDataPath "$DERIVED" \
        -skipMacroValidation \
        DEVELOPMENT_TEAM="$TEAM" \
        CODE_SIGN_IDENTITY="Apple Development" \
        CODE_SIGN_STYLE=Automatic \
        "$@" \
        2>&1 | grep -E "error:|warning: .*never be executed|TEST BUILD SUCCEEDED|BUILD FAILED"
    return "${PIPESTATUS[0]}"
}

# AF_FLOW_BUILD_ONLY compiles both targets and stops, TOUCHING NOTHING ELSE.
#
# The third capability added to this wrapper rather than worked around, and the
# reason is the same every time. Typechecking a Swift change is the single most
# common thing anyone needs from this script, and it was the one thing the
# script could not do: every path ran the suite, running the suite launches a
# second copy of the app as the test host, and that requires Andrew to quit the
# dictation tool he uses all day. So "I only want to know if it compiles"
# carried the full cost of interrupting his work, and the cheap way to dodge
# that cost was a bare `xcodebuild` call, which is exactly what corrupted his
# settings three times on 2026-07-21.
#
# THIS BRANCH RETURNS BEFORE EVERYTHING ELSE, and the first version did not.
# Codex, reviewing the commit that added it, found that build-only skipped the
# refuse-while-running guard and then went on to `defaults export`, `defaults
# delete` and `defaults import` against Andrew's LIVE domain, plus `rm -rf` on
# the output directory, while his app was open. So the mode whose entire purpose
# was to avoid disturbing a running app was reaching for the exact trap door
# this wrapper exists to keep shut: a delete-and-reimport racing a live app can
# lose any setting it writes in between.
#
# The reasoning that produced the bug is worth recording, because it is subtle
# and it was mine. I checked the thing the guard's comment talks about, the test
# host, confirmed `build-for-testing` never launches one, and concluded the
# whole path was inert. The guard's comment is not the guard's blast radius.
# **When you exempt something from a check, enumerate what the check was
# protecting, not what its documentation mentions.**
if [ "${AF_FLOW_BUILD_ONLY:-}" = "1" ]; then
    echo "BUILD-ONLY MODE: compiling both targets, running nothing."
    echo "Touches no defaults, no output directory, and launches no test host,"
    echo "so the app may stay open."
    echo
    build_for_testing
    BUILD_ONLY_STATUS=$?
    echo
    if [ "$BUILD_ONLY_STATUS" -ne 0 ]; then
        echo "BUILD FAILED (exit $BUILD_ONLY_STATUS)." >&2
        exit "$BUILD_ONLY_STATUS"
    fi
    # Reported explicitly rather than by silence. A build-only run that printed
    # nothing would be indistinguishable from a suite that passed, which is the
    # failure shape this script has hit repeatedly: a filter tuned to success
    # turning a skip into no output at all.
    echo "BUILD-ONLY: both targets compiled. NO TESTS WERE RUN."
    echo "This is not a pass. Run without AF_FLOW_BUILD_ONLY, with AF Flow quit,"
    echo "to actually execute the suite."
    exit 0
fi

if pgrep -x GhostPepper >/dev/null 2>&1; then
    cat >&2 <<'RUNNING'
REFUSING TO RUN: AF Flow is currently open.

`xcodebuild test` launches its own copy of the app as the test host, so running
now would leave two instances competing for the microphone, and Andrew uses
this app for all of his dictation.

Quit AF Flow, run this again, and relaunch it afterwards.

If you only want to know whether the code COMPILES, you do not need to quit
anything: re-run with AF_FLOW_BUILD_ONLY=1.
RUNNING
    exit 2
fi

echo "backing up the $DOMAIN defaults domain"
if ! defaults export "$DOMAIN" "$BACKUP" 2>/dev/null; then
    echo "WARNING: could not export $DOMAIN. Continuing without a backup is not" >&2
    echo "         safe, because the suite writes real settings. Aborting." >&2
    exit 3
fi
echo "backup: $BACKUP"

restore() {
    echo
    echo "restoring the $DOMAIN defaults domain"
    # `defaults import` MERGES; it does not replace. That is the hole this had
    # on its first real run on 2026-07-20: the backup was taken while
    # `speechModel` and `preferredLanguage` were absent, the suite then created
    # both, and importing the backup left the suite's values in place because
    # there was nothing in the backup to overwrite them with. The wrapper
    # reported "restored" and printed the corrupted values in the same breath.
    #
    # Deleting the domain first makes the restore exact rather than additive.
    # Safe because the backup was verified non-empty before the run started,
    # and its path is printed on every failure path below.
    defaults delete "$DOMAIN" 2>/dev/null
    if defaults import "$DOMAIN" "$BACKUP" 2>/dev/null; then
        echo "restored from $BACKUP"
    else
        echo "RESTORE FAILED. The backup is still at $BACKUP" >&2
        echo "Recover with: defaults import $DOMAIN $BACKUP" >&2
        return
    fi
    # Report anything the suite changed and the restore put back, so a
    # settings-mutating test is visible rather than silently absorbed.
    for key in speechModel preferredLanguage selectedCleanupModelKind cleanupEnabled; do
        value=$(defaults read "$DOMAIN" "$key" 2>/dev/null || echo "(absent)")
        echo "  $key = $value"
    done
}
trap restore EXIT INT TERM

# xcodebuild does not hand the calling shell's environment to the test process.
# Variables prefixed TEST_RUNNER_ are forwarded with the prefix stripped, but
# they must be set HERE, on build-for-testing, because that is the step which
# writes the .xctestrun file that carries the environment. Passing them to
# `test-without-building` instead does nothing at all, silently: on 2026-07-21
# that made a capture run skip in 0.029 seconds while reporting success.
# The test host is the sandboxed app, so it can READ fixture audio from any
# folder but cannot WRITE results back into one. That surfaces as a bare
# NSPOSIXErrorDomain Code=1 after every transcription has already run, which
# reads like a permissions mistake rather than the sandbox. Results therefore
# go to a directory inside the app's own container and are copied out here.
if [ "${AF_FLOW_SCORING:-}" = "1" ] && [ -z "${AF_FLOW_OUTPUT:-}" ]; then
    # A FRESH directory per run. It used to be one reusable path, so the
    # copy-out step could pick up a previous run's files and report them as this
    # run's results, and a run that produced nothing looked identical to one
    # that worked. Codex round 2, finding 3.
    AF_FLOW_OUTPUT="$HOME/Library/Containers/$DOMAIN/Data/tmp/af-flow-scoring-$$"
    export AF_FLOW_OUTPUT
fi
if [ -n "${AF_FLOW_OUTPUT:-}" ]; then
    # REFUSE to recursively delete a directory holding irreplaceable input.
    #
    # `rm -rf "$AF_FLOW_OUTPUT"` was unconditional, and AF_FLOW_OUTPUT is a
    # caller-supplied path. The Swift side DEFAULTS its output directory to the
    # fixtures directory, so pointing the two at the same place is not an exotic
    # mistake, it is the arrangement the code documents as normal. Doing it here
    # would have deleted Andrew's hand-corrected `.reference.txt` files, the
    # captured transcripts, and the clip audio, before the run that was supposed
    # to read them.
    #
    # The audio survives elsewhere: all five fixture clips are byte-identical to
    # copies in `wispr-archive/`, verified by SHA. The reference text does not.
    # It is 20 to 30 minutes of listening that only he can redo, and it is the
    # one input in this project with no second copy anywhere.
    # The decision was made by validate_output_directory() at the top of this
    # script, before any other branch, so it is enforced on every path and can
    # be canaried without quitting the app. Re-checked here rather than trusted,
    # because between the two points the script has run a build, and a guard
    # that holds only at the moment it was evaluated is a guard with a window.
    validate_output_directory
    rm -rf "$AF_FLOW_OUTPUT"
    mkdir -p "$AF_FLOW_OUTPUT"
    # Written IMMEDIATELY after creation, so the directory is deletable by the
    # next run. A scratch path that loses its marker becomes undeletable rather
    # than dangerous, which is the correct direction for this to fail in.
    cat > "$AF_FLOW_OUTPUT/$OUTPUT_SENTINEL" <<'SENTINEL'
Created by scripts/run-tests.sh. This directory is WIPED at the start of every
run, and this file is what marks it as safe to wipe. Do not put anything here
you want to keep, and do not copy this file into a directory that holds
anything you care about.
SENTINEL
fi

RUNNER_ENV=()
for name in AF_FLOW_FIXTURES AF_FLOW_OUTPUT AF_FLOW_MODELS AF_FLOW_ALLOW_MODEL_DOWNLOAD AF_FLOW_PREFETCH_MODEL; do
    value="${!name:-}"
    [ -n "$value" ] && RUNNER_ENV+=("TEST_RUNNER_$name=$value")
done

echo
echo "building for testing"
[ ${#RUNNER_ENV[@]} -gt 0 ] && printf 'forwarding to the test process: %s\n' "${RUNNER_ENV[*]}"
build_for_testing ${RUNNER_ENV[@]+"${RUNNER_ENV[@]}"}
BUILD_STATUS=$?
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "BUILD FAILED (exit $BUILD_STATUS). Not running tests." >&2
    exit "$BUILD_STATUS"
fi

# AF_FLOW_REPEAT runs the suite N times inside ONE protected invocation.
#
# This exists because of a specific, repeated failure rather than as a
# convenience. Measuring flakiness needs the suite run several times, and on
# 2026-07-21 I hand-rolled that loop with raw `xcodebuild test-without-building`
# calls OUTSIDE this wrapper, on three separate occasions. Every one skipped the
# defaults snapshot, and twice it left Andrew's live app on an English-only
# model with the language pinned to French. He had to be told twice that his
# dictation had been broken by the tool that exists to protect it.
#
# The lesson is not "remember the rule": the rule was written and then broken
# within the hour. The wrapper lacked a capability that was actually needed, so
# the unsafe path got used, and using it is what removed the protection. Give
# the safe path the feature and the unsafe path loses its reason to exist.
REPEAT="${AF_FLOW_REPEAT:-1}"

echo
echo "running tests"

# The scoring and prefetch tests are excluded by default: they need Andrew's
# fixtures or the network, and neither belongs in a routine verification run.
#
# AF_FLOW_SCORING=1 lifts those exclusions. This is an opt-in path for a
# deliberate measurement run, NOT a way to make anything pass: it adds tests
# rather than removing checks, every other guard in this script still applies,
# and the caller still has to name the test with -only-testing. The defaults
# snapshot and the refuse-while-running check are the reason it is safe to
# offer at all.
SKIPS=(
    -skip-testing:GhostPepperTests/CleanupPromptEvalTests
)
if [ "${AF_FLOW_SCORING:-}" != "1" ]; then
    SKIPS+=(
        -skip-testing:GhostPepperTests/TranscriptionScoringTests/testScoreCandidateModelsOnFixtures
        -skip-testing:GhostPepperTests/TranscriptionScoringTests/testPrefetchNamedModel
        -skip-testing:GhostPepperTests/TranscriptionScoringTests/testGenerateDraftReferencesForUnreferencedAudio
        -skip-testing:GhostPepperTests/TranscriptionScoringTests/testCaptureAllCandidateTranscriptsForUnreferencedAudio
    )
else
    echo "SCORING MODE: the fixture tests are enabled for this run."
fi

# The .xctestrun file is what actually carries the test process's environment.
# TEST_RUNNER_ build settings do not reach an app-hosted unit test: proven on
# 2026-07-21 by setting one and watching the test still resolve the default
# path. So write the values into the file directly, then run from that file
# explicitly rather than letting xcodebuild pick one.
XCTESTRUN=$(ls "$DERIVED"/Build/Products/*.xctestrun 2>/dev/null | head -1)
if [ -z "$XCTESTRUN" ]; then
    echo "no .xctestrun found under $DERIVED. Cannot run." >&2
    exit 4
fi

TARGET=":TestConfigurations:0:TestTargets:0"
for name in AF_FLOW_FIXTURES AF_FLOW_OUTPUT AF_FLOW_MODELS AF_FLOW_ALLOW_MODEL_DOWNLOAD AF_FLOW_PREFETCH_MODEL; do
    value="${!name:-}"
    [ -z "$value" ] && continue
    /usr/libexec/PlistBuddy -c "Add $TARGET:EnvironmentVariables:$name string $value" "$XCTESTRUN" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set $TARGET:EnvironmentVariables:$name $value" "$XCTESTRUN"
    # Read back AND COMPARE, then abort on mismatch. Printing the readback was
    # not enough: a failed Add/Set would print something wrong and the run would
    # continue, recreating the "env never reached the tests, so the test skipped
    # and the skip looked like success" hole that cost three runs today. Codex
    # round 2, finding 4.
    readback=$(/usr/libexec/PlistBuddy -c "Print $TARGET:EnvironmentVariables:$name" "$XCTESTRUN" 2>&1)
    if [ "$readback" != "$value" ]; then
        echo "FAILED to inject $name into the xctestrun." >&2
        echo "  wanted: $value" >&2
        echo "  got:    $readback" >&2
        echo "Refusing to run: the tests would silently use the wrong path." >&2
        exit 5
    fi
    echo "  xctestrun $name = $readback"
done

if [ "${AF_FLOW_SCORING:-}" = "1" ]; then
    # A capture run is 40 transcriptions plus 8 model loads. The default
    # per-test allowance is 600s, which would kill it partway and look like a
    # hang rather than a timeout.
    /usr/libexec/PlistBuddy -c "Set $TARGET:DefaultTestExecutionTimeAllowance 3600" "$XCTESTRUN" 2>/dev/null
    echo "  xctestrun time allowance = $(/usr/libexec/PlistBuddy -c "Print $TARGET:DefaultTestExecutionTimeAllowance" "$XCTESTRUN" 2>&1)s"
fi

# -xctestrun requires an explicit -destination; xcodebuild cannot infer one
# from a test-run file the way it can from a scheme.
overall=0
for attempt in $(seq 1 "$REPEAT"); do
[ "$REPEAT" -gt 1 ] && echo "--- run $attempt of $REPEAT ---"
xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "platform=macOS,arch=arm64" \
    "${SKIPS[@]}" \
    "$@" \
    2>&1 | { if [ "${AF_FLOW_RAW_OUTPUT:-}" = "1" ]; then cat; else
        grep -E "Test Case.*(failed|skipped)|Executed [0-9]+ tests|Test skipped|\*\* TEST|fixtures directory|clips awaiting|captured |wrote |not captured|^xcodebuild: error|error: .*flag|BUILD FAILED"
    fi; }
# The alternation above must cover the failure shapes, not just the happy path.
# Twice on 2026-07-21 this filter hid the answer: once a silent skip, once a
# usage error that exited 64 with no line surviving the grep. A filter that
# only matches success turns every failure into silence.
#
# AF_FLOW_RAW_OUTPUT=1 bypasses the filter entirely and exists for one reason:
# on 2026-07-21 the filter hid the suite's grand total, and to see it I ran
# `xcodebuild test-without-building` directly, OUTSIDE this wrapper. That
# skipped the defaults snapshot, and the suite wrote `speechModel =
# openai_whisper-small.en` and `preferredLanguage = fr` into Andrew's live
# app: the exact regression of 2026-07-20, caused the same way, by the one
# person who had just written the rule against it.
#
# The lesson is not "be more careful". A safety wrapper that hides output
# people need CREATES the incentive to go around it, and going around it is
# what removes the safety. So the wrapper now shows everything on request. If
# you ever want raw xcodebuild output, use this flag, never the bare command.

RUN_STATUS=${PIPESTATUS[0]}
[ "$RUN_STATUS" -ne 0 ] && overall=$RUN_STATUS
done
STATUS=$overall

# Copy results out of the container. Reported by name and count rather than
# assumed, because "the run finished" and "the results exist" are different
# claims and this project has confused them before.
if [ -n "${AF_FLOW_OUTPUT:-}" ] && [ -n "${AF_FLOW_FIXTURES:-}" ] && [ "$AF_FLOW_OUTPUT" != "$AF_FLOW_FIXTURES" ]; then
    echo
    produced=$(find "$AF_FLOW_OUTPUT" -type f \( -name "*.hypotheses.json" -o -name "*.draft-reference.txt" -o -name "scores.md" -o -name "transcripts.md" \) 2>/dev/null | wc -l | tr -d ' ')
    if [ "$produced" -gt 0 ]; then
        copy_failures=0
        while IFS= read -r artefact; do
            cp "$artefact" "$AF_FLOW_FIXTURES/" || copy_failures=$((copy_failures + 1))
        done < <(find "$AF_FLOW_OUTPUT" -type f \( -name "*.hypotheses.json" -o -name "*.draft-reference.txt" -o -name "scores.md" -o -name "transcripts.md" \))
        if [ "$copy_failures" -gt 0 ]; then
            echo "$copy_failures result file(s) FAILED to copy out of the container" >&2
            STATUS=6
        else
            echo "copied $produced result file(s) out of the container into $AF_FLOW_FIXTURES"
        fi
    else
        # Non-zero exit, not a warning. A scoring run producing nothing has
        # failed however green the log looks, and exiting 0 is the same
        # silent-success shape this script exists to prevent.
        echo "NO RESULT FILES were produced in $AF_FLOW_OUTPUT" >&2
        echo "The run finishing is not the same as the run producing something." >&2
        STATUS=6
    fi
fi

exit $STATUS
