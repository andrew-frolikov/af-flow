#!/bin/bash
# Run the test suite WITHOUT destroying Andrew's live app settings.
#
# Written 2026-07-20 after the test suite broke his dictation.
#
# WHAT WENT WRONG, because the mechanism is not obvious. The tests run inside
# the AFFlow app host, so they share its bundle identifier, its sandbox
# container, and therefore its UserDefaults domain. Many of them write real
# settings: `appState.preferredLanguage = "fr"` appears eight times in
# AFFlowTests.swift alone, and several write `speechModel` directly.
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

# THE TEST HOST GETS ITS OWN IDENTITY. Andrew's decision, 2026-07-26, taken at
# the Codex round cap over the alternative of accepting the residual risk.
#
# `xcodebuild test` launches its own copy of AF Flow.app as the test host.
# Until now that copy carried Andrew's bundle identifier, so every suite run
# registered a second and third claimant on `com.frolikov.afflow` with
# LaunchServices, and his Input Monitoring permission could attach to one of
# them. On this date it did, and his dictation was dead from 06:59 to 12:10
# with the app cheerfully reporting itself ready.
#
# Everything built before this line was a GUARD: delete the impostor, audit the
# claimants, fail the run if one survives. Three Codex rounds found holes in
# that guard and the cap fired with findings still open, which is the loudest
# possible signal that the guard was the wrong artefact. **An impostor that
# cannot exist needs no guard.**
#
# The identifier is routed through a variable that ONLY the app target reads,
# because a build setting passed on the xcodebuild command line applies to
# every target in the scheme, and giving the app and the xctest bundle the same
# identifier is a different bug. The default in the project keeps Andrew's own
# builds on `com.frolikov.afflow`; only this script overrides it.
#
# The side effect is the point, not an accident: a differently-identified host
# gets a different sandbox container and therefore a different UserDefaults
# domain, so the suite can no longer reach the settings it corrupted on
# 2026-07-20, on 2026-07-21, and again later that day. The snapshot and restore
# below stay anyway. Two independent protections against the defect that has
# bitten him more times than any other is not excessive.
TEST_HOST_DOMAIN="com.frolikov.afflow.testhost"

# The test host's VISIBLE name, passed on the same command line as its
# identifier so the two cannot drift apart again.
#
# On 2026-08-25 Andrew opened Privacy and Security > Input Monitoring and found
# "AF Flow" listed TWICE, both allowed, with nothing on screen to tell them
# apart. The second row was this test host. It had been given its own identifier
# above in 2026-07-26 and never its own NAME: `AFFlow/Info.plist` hardcoded
# `CFBundleName` and `CFBundleDisplayName` as the literal "AF Flow", and macOS
# labels a privacy row with the bundle's display name.
#
# `AF_FLOW_DISPLAY_NAME` defaults to `$(PRODUCT_NAME)` on the app target, so
# Andrew's own builds are untouched and only this script overrides it. Setting
# it here rather than in the project is the same reasoning as the identifier
# above: a build setting on the xcodebuild command line reaches every target in
# the scheme, and only the app target reads this one.
#
# The IDENTIFIER deliberately does not change. TCC keys on the identifier, so
# renaming it would forfeit the Input Monitoring grant Andrew gave this host by
# hand. Display names are free; grants do not move with them.
#
# Both name keys take this one value. Different macOS surfaces read different
# keys, and letting them disagree invites ONE bundle to appear under TWO names,
# which is a smaller copy of the bug this fixes.
TEST_HOST_DISPLAY_NAME="AF Flow Tests"

TEAM="Q4HNX2JLKT"
DERIVED="${AF_FLOW_DERIVED:-build/run-derived}"

# The derived-data root must stay inside the repo, and this is a safety
# constraint rather than a tidiness one. Codex round 1 of 2026-07-26, finding 2:
# `AF_FLOW_DERIVED` could put the test-host app bundle anywhere on the disk
# while the cleanup that deletes it only ever looked under the repo. The result
# would be a second bundle claiming com.frolikov.afflow that nothing removes,
# which is exactly the defect the cleanup exists to prevent, reintroduced by the
# knob. Refused outright rather than papered over, the same way a relative
# AF_FLOW_OUTPUT is refused: there is no legitimate reason to build this
# project's test host outside its own build directory.
CLEANUP_FAILED=0
REPO_ROOT="$(pwd -P)"
mkdir -p "$DERIVED" 2>/dev/null
DERIVED_REAL="$( ( cd -P "$DERIVED" 2>/dev/null && pwd -P ) || printf '%s' "$DERIVED" )"
case "$DERIVED_REAL" in
    "$REPO_ROOT"/*) : ;;
    *)
        echo "REFUSING TO RUN: AF_FLOW_DERIVED resolves outside the repository." >&2
        echo "  given:    $DERIVED" >&2
        echo "  resolves: $DERIVED_REAL" >&2
        echo "  repo:     $REPO_ROOT" >&2
        echo >&2
        echo "The test host is a second app bundle carrying $DOMAIN. Cleanup can" >&2
        echo "only delete it if it is somewhere this script owns, and a bundle" >&2
        echo "that survives will compete with Andrew's app for its Input" >&2
        echo "Monitoring permission and silently break his dictation." >&2
        exit 8
        ;;
esac

# And being inside the repo is not enough to make it deletable. Codex round 2,
# finding 4: `AF_FLOW_DERIVED` can point at an existing in-repo directory this
# script never created, and the trap would then delete matching app bundles out
# of it. Same answer as the output directory got in session 5, for the same
# reason: **only delete what you created and marked.** The marker has a ground
# truth behind it; "this looks like a build directory" is a guess.
#
# A directory that is empty or absent is adopted and marked. A non-empty one
# without the marker is refused, because this script cannot show it made it.
DERIVED_SENTINEL="$DERIVED_REAL/.af-flow-derived"
if [ ! -e "$DERIVED_SENTINEL" ]; then
    if [ -z "$(ls -A "$DERIVED_REAL" 2>/dev/null)" ]; then
        cat > "$DERIVED_SENTINEL" <<'SENTINEL'
Created by scripts/run-tests.sh. This marks the directory as a scratch
derived-data root that the script is allowed to delete build products from,
specifically the AF Flow.app test host, which otherwise competes with
Andrew's real app for its Input Monitoring permission.

Delete this file and the script will refuse to clean the directory.
SENTINEL
    else
        echo "REFUSING TO RUN: the derived-data root is not one this script created." >&2
        echo "  $DERIVED_REAL" >&2
        echo >&2
        echo "It has contents but no $DERIVED_SENTINEL marker, so the cleanup that" >&2
        echo "deletes the test-host app bundle cannot prove the directory is its" >&2
        echo "own. Point AF_FLOW_DERIVED at a new or previously-used scratch path," >&2
        echo "or leave it unset to use build/run-derived." >&2
        exit 8
    fi
fi
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
        -project AFFlow.xcodeproj \
        -scheme AFFlow \
        -configuration Debug \
        -derivedDataPath "$DERIVED" \
        -skipMacroValidation \
        DEVELOPMENT_TEAM="$TEAM" \
        CODE_SIGN_IDENTITY="Apple Development" \
        CODE_SIGN_STYLE=Automatic \
        AF_FLOW_BUNDLE_ID="$TEST_HOST_DOMAIN" \
        AF_FLOW_DISPLAY_NAME="$TEST_HOST_DISPLAY_NAME" \
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
# AF_FLOW_APP_BUILD builds the app Andrew actually launches, and prints where it
# put it. It runs no tests and installs nothing.
#
# **The fifth capability added to this wrapper rather than worked around, and it
# was created by another capability.** Since the test host was given its own
# bundle identifier on 2026-07-26, every build this script produces is
# `com.frolikov.afflow.testhost`, which is deliberately NOT installable: it would
# not carry his Input Monitoring grant and it is not the app he runs. That left
# no sanctioned way to produce an installable build at all, and the only route
# was a bare `xcodebuild`, which is exactly the bypass that corrupted his
# settings three times on 2026-07-21.
#
# Every time this wrapper has been bypassed, the bypass existed because the
# wrapper was missing something. That has now produced raw output, repeat runs,
# build-only, and this. The rule holds: add the capability people are going
# around it for.
#
# It touches no defaults, launches nothing, and uses its own derived-data
# directory so it can never be confused with the test host next to it.
if [ "${AF_FLOW_APP_BUILD:-}" = "1" ]; then
    APP_DERIVED="$REPO_ROOT/build/app-derived"
    echo "APP BUILD: producing the app Andrew launches, running nothing."
    echo "Bundle identifier: $DOMAIN (NOT the test host)."
    echo
    xcodebuild build \
        -project AFFlow.xcodeproj \
        -scheme AFFlow \
        -configuration Debug \
        -derivedDataPath "$APP_DERIVED" \
        -skipMacroValidation \
        DEVELOPMENT_TEAM="$TEAM" \
        CODE_SIGN_IDENTITY="Apple Development" \
        CODE_SIGN_STYLE=Automatic \
        "$@" \
        2>&1 | grep -E "error:|warning: .*never be executed|BUILD SUCCEEDED|BUILD FAILED"
    APP_BUILD_STATUS=${PIPESTATUS[0]}
    APP_PATH="$APP_DERIVED/Build/Products/Debug/AF Flow.app"
    if [ "$APP_BUILD_STATUS" -ne 0 ] || [ ! -d "$APP_PATH" ]; then
        echo "APP BUILD FAILED (exit $APP_BUILD_STATUS)." >&2
        exit "${APP_BUILD_STATUS:-1}"
    fi
    # Building a bundle REGISTERS it with LaunchServices, and this one is thrown
    # away: the workflow is copy it over the app he launches, then delete
    # `build/app-derived`. That left LaunchServices holding a record naming
    # `com.frolikov.afflow` as "AF Flow" at a path that no longer exists, every
    # single time. Found on 2026-08-25 by scripts/system-list-check.py on the
    # very first app build after that check was wired in, which is the check
    # doing its job: the routine workflow was the leak.
    #
    # BEFORE the verifications below, not after, because each of them exits.
    # A refused build is exactly when a stale record is least likely to be
    # noticed. Unregistering does not touch the bundle on disk, so the copy
    # still works. Best effort: a failure here is a stale row in a settings
    # list, not a broken build, and the checker reports it either way.
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" \
        -u "$APP_PATH" >/dev/null 2>&1

    # Verified rather than assumed. Shipping a build carrying the test host's
    # identity to the path his permissions are attached to would silently break
    # his dictation, which is the failure this whole line of work started from.
    BUILT_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null)
    if [ "$BUILT_ID" != "$DOMAIN" ]; then
        echo "REFUSING TO REPORT SUCCESS: built bundle id is '$BUILT_ID', expected '$DOMAIN'." >&2
        echo "Installing this would break his Input Monitoring grant." >&2
        exit 10
    fi

    # The NAME, checked here for the same reason the identifier is: this is the
    # only branch that produces the artefact Andrew installs, and since
    # 2026-08-25 both name keys are a build setting rather than a literal.
    #
    # There is no other layer that can see this. `BundleIdentityNameTests` runs
    # inside the test host, and the test host's identifier is set unconditionally
    # by this same script, so the arm of that test covering the APP can never
    # execute. Found by review on 2026-08-25: without these four lines an app
    # built with an empty or wrong AF_FLOW_DISPLAY_NAME would be reported as
    # "bundle id verified" and success, and macOS would quietly fall back to the
    # bundle filename in the menu bar and the About box.
    for name_key in CFBundleName CFBundleDisplayName; do
        BUILT_NAME=$(/usr/libexec/PlistBuddy -c "Print :$name_key" "$APP_PATH/Contents/Info.plist" 2>/dev/null)
        if [ "$BUILT_NAME" != "AF Flow" ]; then
            echo "REFUSING TO REPORT SUCCESS: built $name_key is '$BUILT_NAME', expected 'AF Flow'." >&2
            echo "The bare product name belongs to the app alone; see" >&2
            echo "docs/design/af-flow-system-list-names.md." >&2
            exit 11
        fi
    done

    # The app must be INCAPABLE of egress at the OS layer, not merely watched.
    # 2026-08-29, his decision after the LuLu episode: Allow-any firewall rules
    # for this app came back months after he deleted them, LuLu ignores
    # synthetic clicks by design so nothing can clean them up for him, and a
    # firewall's view of an app is only as good as its rule matching, which
    # stale post-rename paths had already broken. The sandbox needs no
    # matching: without com.apple.security.network.client every outbound call
    # dies at the kernel. Fetching a NEW model is a deliberate act, run from
    # scripts/download-model.sh and never by this app.
    #
    # THIS USED TO BE ONE LINE, AND THAT LINE COULD ONLY REFUSE A BUNDLE IT HAD
    # ALREADY SUCCESSFULLY READ:
    #
    #   codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q network.client
    #
    # When codesign fails, it prints nothing, grep finds nothing, and the build
    # is reported boundary-clean. An unsigned bundle, an empty
    # CODE_SIGN_IDENTITY, or a path codesign cannot read all read as verified.
    # Staged and watched on 2026-08-30: an unsigned copy of a bundle that
    # really did carry the entitlement was reported CLEAN. Unreadable must
    # fail, which is the `lulu-rule-check.py` rule in a second system.
    #
    # It is now a script so that `scripts/release-build.sh` runs the SAME
    # guarantee against the notarized artefact, plus the ones only a
    # distribution build can break: hardened runtime on, get-task-allow absent,
    # and a signature that is not ad-hoc. Every state it distinguishes is
    # staged in scripts/bundle-boundary-check-selftest.py.
    if ! python3 "$REPO_ROOT/scripts/bundle-boundary-check.py" \
            "$APP_PATH" --configuration debug; then
        echo "REFUSING TO REPORT SUCCESS: the built app is outside its boundary." >&2
        exit 12
    fi
    echo
    echo "built: $APP_PATH"
    echo "bundle id verified: $BUILT_ID"
    echo
    echo "NOT INSTALLED. Copy it over the app he launches only when he can relaunch it."
    exit 0
fi

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


# WHAT PROCESS NAME IS HIS APP, ACTUALLY.
#
# The two guards below refuse to launch a test host while Andrew's app is open,
# because two instances compete for one microphone and he dictates all day.
# From 2026-08-25 until 2026-08-30 NEITHER OF THEM COULD FIRE.
#
# The rename commit rewrote `pgrep -x GhostPepper` into a pgrep for the MODULE
# name, AFFlow. The executable is PRODUCT_NAME, which that same commit set to
# "AF Flow", with a space. So both guards looked for a process that has never
# existed under either name, and the protection had been silently off for five
# days when this was found. Verified rather than reasoned: his app was running,
# the old pattern matched nothing, and a pgrep for "AF Flow" returned its pid.
#
# This is the 2026-08-25 rename's other victim, and it is the same shape as the
# one that cost 24 days: a find-and-replace rewrote a literal that had to agree
# with something outside the file. The cure is the same one `af_paths.py` uses
# for the data folder. The name is not repeated here; it is READ from the
# project that builds the app, through the parser `build-config-check.py`
# already owns.
#
# Unreadable is not a pass. If the name cannot be resolved this refuses rather
# than guessing, because a guard that cannot name its target is exactly the
# state that just went unnoticed for five days.
resolve_app_process_name() {
    python3 - "$REPO_ROOT" <<'PY'
import importlib.util, os, sys
repo = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "build_config_check", os.path.join(repo, "scripts", "build-config-check.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    settings = module.pbxproj_settings(
        os.path.join(repo, "AFFlow.xcodeproj", "project.pbxproj"))
except Exception:
    sys.exit(1)
name = (settings.get("Debug") or {}).get("PRODUCT_NAME")
if not name or name.startswith("$("):
    sys.exit(1)
print(name)
PY
}

APP_PROCESS_NAME=$(resolve_app_process_name)
if [ -z "$APP_PROCESS_NAME" ]; then
    echo "REFUSING TO RUN: could not read PRODUCT_NAME out of the project, so" >&2
    echo "this script cannot tell whether Andrew's app is open. A guard that" >&2
    echo "cannot name its target was off for five days in August 2026." >&2
    exit 2
fi

# One place asks the question. Both guards below call this.
#
# IT MUST NOT MATCH THIS SCRIPT'S OWN TEST HOST, and the first version did.
# The test host is built with the SAME `PRODUCT_NAME`, so its executable is
# also named "AF Flow"; only its bundle id and display name differ. Review,
# 2026-08-30, found the deadlock that buys: `remove_test_hosts` is only ever
# called from the `restore` trap, which is installed AFTER the first guard, so
# a test host left running by a killed run, or resurrected by macOS Resume,
# would make every future run refuse at that guard and tell Andrew to quit an
# app he had already closed. The one automated thing that kills the leftover
# sits downstream of the refusal that the leftover causes.
#
# That is worse than the dead guard it replaced, because a dead guard fails
# open on a rare hazard and this failed closed on a documented one: a test host
# surviving a reboot is exactly the 2026-08-29 incident.
#
# So the question is not "is a process called AF Flow running" but "is the
# process Andrew launched running", and the answer is a path test. Anything
# under this repository's build directory is this script's own output.
#
# `ps -o comm=` REPORTS THE PATH AS THE PROCESS WAS INVOKED, which is relative
# when it was launched with a relative path. Staged on 2026-08-30: a stub under
# the derived root reported `build/run-derived/.../AF Flow`, with no leading
# slash, and an exclusion written only against "$REPO_ROOT"/build/* let it
# through and refused the run. So a relative path is resolved against the
# repository root before it is compared, and the derived root is matched
# separately in case it was pointed somewhere else by AF_FLOW_DERIVED.
af_flow_is_running() {
    local pid path
    for pid in $(pgrep -x "$APP_PROCESS_NAME" 2>/dev/null); do
        path=$(ps -o comm= -p "$pid" 2>/dev/null)
        [ -n "$path" ] || continue
        case "$path" in
            /*) : ;;
            *) path="$REPO_ROOT/$path" ;;
        esac
        case "$path" in
            "$REPO_ROOT"/build/*) continue ;;
            "$DERIVED_REAL"/*) continue ;;
        esac
        return 0
    done
    return 1
}

if af_flow_is_running; then
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
    remove_test_hosts
    # A cleanup failure fails the run. Codex round 1 of 2026-07-26, finding 3
    # and finding 4: a warning nobody has to act on is how a leftover bundle
    # survives to break his dictation days later. Exiting from inside an EXIT
    # trap sets the status without re-entering the trap.
    if [ "${CLEANUP_FAILED:-0}" -ne 0 ]; then
        echo
        echo "EXITING NON-ZERO: the suite ran, but cleanup left the system in a" >&2
        echo "state that can break Andrew's dictation. Read the lines above." >&2
        exit 9
    fi
}

# `xcodebuild test` launches its own copy of AF Flow.app as the test host,
# and launching an app REGISTERS it with LaunchServices as a claimant on its
# bundle identifier. So every suite run quietly adds a second and third app
# claiming to be com.frolikov.afflow, from inside the repo build tree.
#
# That is not cosmetic. On 2026-07-26 Andrew's push-to-talk stopped working
# with no error on screen, and `tccutil reset ListenEvent com.frolikov.afflow`
# reported resetting the grant THREE times: one identity, three claimants, and
# his Input Monitoring permission attached to the wrong one. He held the keys
# and nothing happened.
#
# This is the same defect as the defaults domain and it gets the same
# treatment. The suite reaches into state shared with his live app, so the
# wrapper undoes it in the trap, unconditionally, whether the run passed,
# failed or was interrupted. Per-run tidiness is never enough, because the
# failing run is exactly the one that would skip it.
#
# Unregistering alone is NOT enough, and believing it was is the mistake this
# comment exists to stop the next person repeating. `lsregister -u` was tried
# first on 2026-07-26 and both copies re-registered themselves within minutes
# with no suite run in between: LaunchServices rescans app bundles that exist
# on disk and re-adopts them. A bundle that exists is a bundle that claims the
# identity. So the test host is DELETED, not merely deregistered.
#
# The cost is one relink on the next run, and it is worth it. The alternative
# is his dictation silently breaking again on a schedule nobody controls.
#
# Anchored to what this script OWNS rather than to a list of paths someone
# imagined, and confirmed rather than assumed before anything is removed: the
# search is confined to the repo's own build directory, and each candidate
# must actually BE our app bundle, carrying `com.frolikov.afflow` in its
# Info.plist and an executable at the expected path. Anything else under
# build/ is reported and left alone. The app Andrew launches lives in
# DerivedData, outside this directory, and is never a candidate.
remove_test_hosts() {
    local lsregister id left claimant
    lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    if [ ! -x "$lsregister" ]; then
        echo "  CLEANUP FAILED: lsregister missing, cannot audit bundle claimants." >&2
        CLEANUP_FAILED=1
        return
    fi

    # Refuse to delete anything from a derived root this script cannot prove it
    # created. The marker is written at startup, so if it is missing by now,
    # something is wrong enough to stop rather than to guess.
    if [ ! -e "${DERIVED_SENTINEL:-/nonexistent}" ]; then
        echo "  CLEANUP SKIPPED: $DERIVED_REAL carries no scratch marker, so the" >&2
        echo "  test host was left in place. Remove it before he next dictates." >&2
        CLEANUP_FAILED=1
        return
    fi

    # Kill anything still RUNNING from this scratch root before touching its
    # bundles. 2026-08-29: the suite's app product survived a reboot through
    # macOS Resume, ran for a whole day beside his real app with the test
    # host's permanent grants, transcribed his dictation with whisper-tiny.en,
    # and raced his real app for the clipboard. Deleting the bundle is not
    # enough while the process it spawned is alive, and a process the run left
    # behind is this run's to kill: the sentinel above just proved ownership.
    local scratch_pids
    scratch_pids=$(pgrep -f "$DERIVED_REAL/.*/Contents/MacOS/" 2>/dev/null || true)
    if [ -n "$scratch_pids" ]; then
        echo "  terminating process(es) still running from the scratch root:" $scratch_pids
        kill $scratch_pids 2>/dev/null
        for _ in 1 2 3 4 5; do
            pgrep -f "$DERIVED_REAL/.*/Contents/MacOS/" >/dev/null 2>&1 || break
            sleep 1
        done
        if pgrep -f "$DERIVED_REAL/.*/Contents/MacOS/" >/dev/null 2>&1; then
            kill -9 $scratch_pids 2>/dev/null
            sleep 1
        fi
        if pgrep -f "$DERIVED_REAL/.*/Contents/MacOS/" >/dev/null 2>&1; then
            echo "  CLEANUP FAILED: a process from $DERIVED_REAL is still running." >&2
            CLEANUP_FAILED=1
        fi
    fi

    # Scoped to THIS invocation's derived-data root, not to the whole build
    # directory. Codex round 1 of 2026-07-26, finding 1: scanning `build/**`
    # deleted any bundle carrying the live identity, including ones this run
    # never created. `$DERIVED_REAL` is where xcodebuild was told to put the
    # test host minutes earlier and is constrained to the repo at the top of
    # this script, so it is the one path this invocation can prove it owns.
    while IFS= read -r bundle; do
        id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$bundle/Contents/Info.plist" 2>/dev/null)
        # Ours means the FAMILY, not only his app id. 2026-08-29: the identity
        # isolation gives the suite's own product the test host id, and this
        # filter, written to protect bundles the run did not create, read its
        # OWN product as foreign, printed "left alone", and left it for Resume
        # to launch at his next login. Ownership inside $DERIVED_REAL is proven
        # by the sentinel; the id only decides whether it is ours to delete or
        # genuinely foreign.
        if { [ "$id" != "$DOMAIN" ] && [ "$id" != "$TEST_HOST_DOMAIN" ]; } || [ ! -x "$bundle/Contents/MacOS/AF Flow" ]; then
            echo "  left alone, not our app bundle: $bundle" >&2
            continue
        fi
        # Both commands are checked. Codex round 2 finding 1: an unregister that
        # failed while the delete succeeded printed "removed" and left a stale
        # LaunchServices record pointing at a path that no longer exists, which
        # the identity audit below cannot see because it reads the Info.plist of
        # a bundle this loop just deleted.
        if ! "$lsregister" -u "$bundle" 2>/dev/null; then
            echo "  CLEANUP FAILED: could not deregister $bundle" >&2
            CLEANUP_FAILED=1
        fi
        rm -rf "$bundle"
        # Verify the removal instead of announcing it. Codex round 1 finding 3:
        # both commands could fail and the script still printed "removed", which
        # is the same false-pass shape as a gate that cannot fail.
        if [ -e "$bundle" ]; then
            echo "  CLEANUP FAILED: could not remove test host $bundle" >&2
            CLEANUP_FAILED=1
        else
            echo "  removed test host $bundle"
        fi
    done < <(find "$DERIVED_REAL" -maxdepth 4 -name "AF Flow.app" -type d 2>/dev/null)

    # The dump is captured and CHECKED before it is parsed. Codex round 2
    # finding 2: inside a process substitution a failing `lsregister -dump` is
    # invisible, the loop reads nothing, and "no claimants found" is reported as
    # a clean result. An audit that reports perfect when it could not run is the
    # zero-denominator bug of session 5 wearing different clothes.
    local dump
    dump="$(mktemp -t afflow-lsdump)"
    if ! "$lsregister" -dump > "$dump" 2>/dev/null || [ ! -s "$dump" ]; then
        echo "  CLEANUP FAILED: could not read the LaunchServices database, so" >&2
        echo "  the claimant audit did not run. Treating that as a failure rather" >&2
        echo "  than as a clean result." >&2
        CLEANUP_FAILED=1
        rm -f "$dump"
        return
    fi

    # Audit the survivors by IDENTITY, not by filename. Codex round 1 finding 4:
    # counting paths ending in AF Flow.app answers a different question from
    # "how many bundles claim com.frolikov.afflow", and the second is the one
    # that decides whether his hotkey permission lands on the right app.
    #
    # And WHICH one survives matters, not just how many. Codex round 2 finding
    # 3: a lone surviving test host passes a "one claimant" test whenever his
    # real app happens to be unregistered, and then becomes the second claimant
    # the moment he launches it. So the rule is stated as ground truth about
    # this repository rather than as a count: no bundle inside this repo may
    # claim his identity, ever. The app he launches lives in DerivedData and
    # cannot trip it.
    left=0
    while IFS= read -r claimant; do
        [ -z "$claimant" ] && continue
        id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$claimant/Contents/Info.plist" 2>/dev/null)
        [ "$id" = "$DOMAIN" ] || continue
        left=$((left + 1))
        echo "  claimant: $claimant"
        case "$claimant" in
            "$REPO_ROOT"/*)
                echo "  CLEANUP FAILED: a bundle inside this repository claims $DOMAIN." >&2
                echo "  $claimant" >&2
                echo "  It will compete with his app for Input Monitoring and his" >&2
                echo "  dictation will stop working with no error on screen." >&2
                CLEANUP_FAILED=1
                ;;
        esac
    done < <(sed -n 's/^[[:space:]]*path:[[:space:]]*\(.*\.app\)\( ([^)]*)\)\{0,1\}$/\1/p' "$dump" | sort -u)
    rm -f "$dump"

    if [ "$left" -gt 1 ]; then
        echo "  CLEANUP FAILED: $left bundles claim $DOMAIN. His Input Monitoring" >&2
        echo "  permission can attach to the wrong one and his dictation will stop" >&2
        echo "  working with no error on screen. Delete the extras above." >&2
        CLEANUP_FAILED=1
    else
        echo "  bundles claiming $DOMAIN: $left"
    fi
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
for name in AF_FLOW_LAB_ARCHIVE AF_FLOW_FIXTURES AF_FLOW_OUTPUT AF_FLOW_MODELS AF_FLOW_ALLOW_MODEL_DOWNLOAD AF_FLOW_PREFETCH_MODEL AF_FLOW_MEETING_BAKEOFF AF_FLOW_SUMMARY_EVALS AF_FLOW_MEETING_NOTES AF_FLOW_SUMMARY_EVAL_MODEL AF_FLOW_SUMMARY_EVAL_PROMPT AF_FLOW_SUMMARY_EVAL_MAX_CHARS; do
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
    -skip-testing:AFFlowTests/CleanupPromptEvalTests
)
if [ "${AF_FLOW_SCORING:-}" != "1" ]; then
    SKIPS+=(
        -skip-testing:AFFlowTests/TranscriptionScoringTests/testScoreCandidateModelsOnFixtures
        -skip-testing:AFFlowTests/TranscriptionScoringTests/testPrefetchNamedModel
        -skip-testing:AFFlowTests/TranscriptionScoringTests/testGenerateDraftReferencesForUnreferencedAudio
        -skip-testing:AFFlowTests/TranscriptionScoringTests/testCaptureAllCandidateTranscriptsForUnreferencedAudio
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
for name in AF_FLOW_LAB_ARCHIVE AF_FLOW_FIXTURES AF_FLOW_OUTPUT AF_FLOW_MODELS AF_FLOW_ALLOW_MODEL_DOWNLOAD AF_FLOW_PREFETCH_MODEL AF_FLOW_MEETING_BAKEOFF AF_FLOW_SUMMARY_EVALS AF_FLOW_MEETING_NOTES AF_FLOW_SUMMARY_EVAL_MODEL AF_FLOW_SUMMARY_EVAL_PROMPT AF_FLOW_SUMMARY_EVAL_MAX_CHARS; do
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

# RE-CHECK, because the first check is stale by the time it matters.
#
# The refuse-while-running guard runs near the top of this script, but the test
# host does not launch until the line below, a whole build later. On 2026-08-24
# the margin was 95 SECONDS: Andrew's last dictation landed at 18:04:14 and the
# test host started at 18:05:49. Had he dictated two minutes later, two copies of
# the app would have been competing for his microphone, which is the exact thing
# the first check exists to prevent.
#
# Deliberately placed AFTER the defaults trap on line 568, so refusing here still
# restores his settings on the way out.
if af_flow_is_running; then
    cat >&2 <<'RUNNING_NOW'
REFUSING TO RUN: AF Flow was opened while this script was building.

The check at the start of this run passed, then the build took long enough for
the app to come back up. Launching the test host now would leave two instances
competing for the microphone, and Andrew uses this app for all of his dictation.

Nothing was run and his defaults have been restored. Quit AF Flow and try again.
RUNNING_NOW
    exit 2
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
        grep -E "Test Case.*(failed|skipped)|Executed [0-9]+ tests|Test skipped|\*\* TEST|fixtures directory|clips awaiting|captured |wrote |not captured|^xcodebuild: error|error: .*flag|BUILD FAILED|^\s*(MEETING-BAKEOFF|SUMMARY-EVAL|SWEEP) "
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
