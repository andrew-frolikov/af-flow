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

if pgrep -x GhostPepper >/dev/null 2>&1; then
    cat >&2 <<'RUNNING'
REFUSING TO RUN: AF Flow is currently open.

`xcodebuild test` launches its own copy of the app as the test host, so running
now would leave two instances competing for the microphone, and Andrew uses
this app for all of his dictation.

Quit AF Flow, run this again, and relaunch it afterwards.
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
    AF_FLOW_OUTPUT="$HOME/Library/Containers/$DOMAIN/Data/tmp/af-flow-scoring"
    export AF_FLOW_OUTPUT
fi
[ -n "${AF_FLOW_OUTPUT:-}" ] && mkdir -p "$AF_FLOW_OUTPUT"

RUNNER_ENV=()
for name in AF_FLOW_FIXTURES AF_FLOW_OUTPUT AF_FLOW_MODELS AF_FLOW_ALLOW_MODEL_DOWNLOAD AF_FLOW_PREFETCH_MODEL; do
    value="${!name:-}"
    [ -n "$value" ] && RUNNER_ENV+=("TEST_RUNNER_$name=$value")
done

echo
echo "building for testing"
[ ${#RUNNER_ENV[@]} -gt 0 ] && printf 'forwarding to the test process: %s\n' "${RUNNER_ENV[*]}"
xcodebuild build-for-testing \
    -project GhostPepper.xcodeproj \
    -scheme GhostPepper \
    -configuration Debug \
    -derivedDataPath "$DERIVED" \
    -skipMacroValidation \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_IDENTITY="Apple Development" \
    CODE_SIGN_STYLE=Automatic \
    "${RUNNER_ENV[@]}" \
    2>&1 | grep -E "error:|warning: .*never be executed|TEST BUILD SUCCEEDED|BUILD FAILED"

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
    # Read it back. Writing a setting and trusting it took is the exact habit
    # that cost two runs today.
    echo "  xctestrun $name = $(/usr/libexec/PlistBuddy -c "Print $TARGET:EnvironmentVariables:$name" "$XCTESTRUN" 2>&1)"
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
xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "platform=macOS,arch=arm64" \
    "${SKIPS[@]}" \
    "$@" \
    2>&1 | grep -E "Test Case.*(failed|skipped)|Executed [0-9]+ tests|Test skipped|\*\* TEST|fixtures directory|clips awaiting|captured |wrote |not captured|^xcodebuild: error|error: .*flag|BUILD FAILED"
# The alternation above must cover the failure shapes, not just the happy path.
# Twice on 2026-07-21 this filter hid the answer: once a silent skip, once a
# usage error that exited 64 with no line surviving the grep. A filter that
# only matches success turns every failure into silence.

STATUS=${PIPESTATUS[0]}

# Copy results out of the container. Reported by name and count rather than
# assumed, because "the run finished" and "the results exist" are different
# claims and this project has confused them before.
if [ -n "${AF_FLOW_OUTPUT:-}" ] && [ -n "${AF_FLOW_FIXTURES:-}" ] && [ "$AF_FLOW_OUTPUT" != "$AF_FLOW_FIXTURES" ]; then
    echo
    produced=$(find "$AF_FLOW_OUTPUT" -type f \( -name "*.hypotheses.json" -o -name "*.draft-reference.txt" -o -name "scores.md" \) 2>/dev/null | wc -l | tr -d ' ')
    if [ "$produced" -gt 0 ]; then
        find "$AF_FLOW_OUTPUT" -type f \( -name "*.hypotheses.json" -o -name "*.draft-reference.txt" -o -name "scores.md" \) \
            -exec cp {} "$AF_FLOW_FIXTURES/" \;
        echo "copied $produced result file(s) out of the container into $AF_FLOW_FIXTURES"
    else
        echo "NO RESULT FILES were produced in $AF_FLOW_OUTPUT" >&2
        echo "The run finishing is not the same as the run producing something." >&2
    fi
fi

exit $STATUS
