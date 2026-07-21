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

echo
echo "building for testing"
xcodebuild build-for-testing \
    -project GhostPepper.xcodeproj \
    -scheme GhostPepper \
    -configuration Debug \
    -derivedDataPath "$DERIVED" \
    -skipMacroValidation \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_IDENTITY="Apple Development" \
    CODE_SIGN_STYLE=Automatic \
    2>&1 | grep -E "error:|warning: .*never be executed|TEST BUILD SUCCEEDED|BUILD FAILED"

echo
echo "running tests"
# The scoring and prefetch tests are excluded by default: they need Andrew's
# fixtures or the network, and neither belongs in a routine verification run.
xcodebuild test-without-building \
    -project GhostPepper.xcodeproj \
    -scheme GhostPepper \
    -derivedDataPath "$DERIVED" \
    -skip-testing:GhostPepperTests/TranscriptionScoringTests/testScoreCandidateModelsOnFixtures \
    -skip-testing:GhostPepperTests/TranscriptionScoringTests/testPrefetchNamedModel \
    -skip-testing:GhostPepperTests/TranscriptionScoringTests/testGenerateDraftReferencesForUnreferencedAudio \
    -skip-testing:GhostPepperTests/CleanupPromptEvalTests \
    "$@" \
    2>&1 | grep -E "Test Case.*(failed)|Executed [0-9]+ tests|\*\* TEST"

STATUS=${PIPESTATUS[0]}
exit $STATUS
