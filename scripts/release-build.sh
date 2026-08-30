#!/bin/bash
# Build the notarized DMG Andrew hands to his friends, and refuse to claim any
# step it did not verify.
#
# Written 2026-08-30 for Phase 1 of docs/launch-v1-plan.md.
#
# WHAT THIS IS FOR. Until now every artefact this repo produced was for one Mac:
# `AF_FLOW_APP_BUILD=1 ./scripts/run-tests.sh` builds a Debug app that Andrew
# rsyncs over the one he launches, and it works because his machine already
# trusts his own development certificate. Nobody else's does. A friend who
# downloads that build gets "AF Flow is damaged and can't be opened", which is
# Gatekeeper refusing a bundle that is neither Developer ID signed nor
# notarized. Everything below exists to turn a build into an app a stranger's
# Mac will open.
#
# THE SHAPE OF THE FAILURE THIS GUARDS AGAINST. A release script is a sequence
# of eight things that each look like they worked. `hdiutil` returns 0 for a DMG
# nobody can mount; `codesign` returns 0 having signed nothing when the identity
# name matched no certificate; `notarytool submit` returns 0 with status
# "Invalid"; `stapler` staples an app and leaves the DMG around it unstapled.
# So every step here states its postcondition and checks it, and the script
# exits non-zero the moment one is not met. There is no summary line at the end
# that is not backed by a verification above it.
#
# WHAT IT NEEDS THAT DOES NOT EXIST YET (2026-08-30):
#   - Apple Developer Program membership, USD 99/yr, about CAD 135/yr. Andrew's
#     purchase, not made. Without it there is no "Developer ID Application"
#     certificate and steps 3 onward cannot run. This script stops there and
#     says so; it does not fall back to an ad-hoc or development signature,
#     because both produce a DMG that opens on his Mac and fails on everyone
#     else's, which is the worst possible outcome: a release that tests clean.
#   - A notarytool credential profile in the keychain. Create once with:
#       xcrun notarytool store-credentials AF_FLOW_NOTARY \
#           --apple-id andriy.frolikov@gmail.com --team-id Q4HNX2JLKT
#     and an app-specific password from appleid.apple.com. THE PASSWORD IS
#     ANDREW'S TO TYPE. No agent session enters it.
#
# Usage:
#   scripts/release-build.sh --version X.Y.Z [--starter-models DIR | --without-models]
#          --version must equal CFBundleShortVersionString in AFFlow/Info.plist,
#          which is 2.4.2 today, inherited from the fork. 1.0.0 is Phase 9.
#                            [--stop-after preflight|archive|export|sign|notarize|staple|dmg]
#
# Exit codes are distinct on purpose, so a caller can tell "not bought yet"
# from "the boundary broke":
#   0  every step run was verified
#   1  a step failed its own postcondition
#   2  a precondition could not be checked at all
#   3  blocked on the Apple Developer Program membership
#   4  bad arguments

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
REPO_ROOT="$(pwd -P)"

TEAM="Q4HNX2JLKT"
IDENTITY_PREFIX="Developer ID Application"
NOTARY_PROFILE="${AF_FLOW_NOTARY_PROFILE:-AF_FLOW_NOTARY}"

OUT="$REPO_ROOT/build/release"
DERIVED="$REPO_ROOT/build/release-derived"
ARCHIVE="$OUT/AF Flow.xcarchive"
EXPORTED="$OUT/export"
APP="$EXPORTED/AF Flow.app"

VERSION=""
STARTER_MODELS=""
WITHOUT_MODELS=0
STOP_AFTER=""

STOP_AFTER_STEPS="preflight archive export sign notarize staple dmg"

# `shift 2` on a trailing flag fails, and this script has no `set -e`, so the
# argument list would be unchanged and the loop would spin forever. Found by
# Codex review, 2026-08-30, along with the sibling bug: a trailing flag would
# otherwise swallow the NEXT flag as its value.
needs_value() {
    if [ "$#" -lt 2 ] || case "${2:-}" in --*) true ;; *) false ;; esac; then
        echo "$1 needs a value." >&2
        exit 4
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)         needs_value "$@"; VERSION="$2"; shift 2 ;;
        --starter-models)  needs_value "$@"; STARTER_MODELS="$2"; shift 2 ;;
        --without-models)  WITHOUT_MODELS=1; shift ;;
        --stop-after)      needs_value "$@"; STOP_AFTER="$2"; shift 2 ;;
        -h|--help)         sed -n '1,60p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 4 ;;
    esac
done

# A TYPO IN --stop-after USED TO MEAN "RUN EVERYTHING". No `stop_here` call
# matched, so a run meant to stop at the archive went on to notarize and build
# a DMG. Codex review, 2026-08-30. The whole point of the flag is to bound what
# happens, so an unrecognised value is refused rather than ignored.
if [ -n "$STOP_AFTER" ]; then
    case " $STOP_AFTER_STEPS " in
        *" $STOP_AFTER "*) : ;;
        *) echo "unknown --stop-after '$STOP_AFTER'." >&2
           echo "Expected one of: $STOP_AFTER_STEPS" >&2
           echo "An unrecognised value would have meant 'run every step'." >&2
           exit 4 ;;
    esac
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# EVERY BUILD OF THIS APP REGISTERS A SECOND CLAIMANT ON ITS BUNDLE ID, and
# this script builds two: the archive's copy and the exported one. Both carry
# `com.frolikov.afflow`, the identifier Andrew's Microphone and Input
# Monitoring grants are attached to. On 2026-07-26 a claimant exactly like
# these took his Input Monitoring grant and his dictation was dead for five
# hours with the app reporting itself ready; on 2026-08-26 the opposite
# mistake, deleting a build without unregistering it, left a live record
# pointing at a bundle that was gone.
#
# So the copies are unregistered on the way out, whatever the exit path, and
# his installed app is re-registered so it is the one claimant left. This is a
# trap rather than a final step because most of this script's exits are
# refusals, and a refusal that skips the cleanup is how the hazard survives.
#
# The dump is parsed by importing `system-list-check.py`'s own parser rather
# than by a second reader here. The field that holds the identifier is
# `identifier:`; the field called `bundle id:` holds the DISPLAY NAME, which
# is how the first version of this function found nothing at all and reported
# it as "no installed app" instead of as a parse failure.
#
# THREE ANSWERS, NOT TWO. "one live bundle", "none", and "the registry could
# not be read" are different states, and the first version of this collapsed
# the third into the second: an unreadable dump printed nothing and was
# reported as "no installed app", so a release would have run without knowing
# what it had to restore. Codex review, 2026-08-30, and it is the same defect
# as the codesign|grep line this phase replaced.
#
# It also took the FIRST matching record. If two live bundles claim
# `com.frolikov.afflow`, re-registering the wrong one is precisely the
# duplicate-claimant failure that killed his dictation for five hours on
# 2026-07-26. Ambiguity is now refused rather than guessed. Paths inside this
# repo's build directory are not candidates: those are this script's own
# output, or a previous run's.
INSTALLED_APP=""
INSTALLED_APP_STATE=""
AMBIGUOUS_PATHS=""
remember_installed_app() {
    local answer
    answer=$(python3 "$REPO_ROOT/scripts/af_installed_app.py" --repo "$REPO_ROOT" 2>/dev/null)
    INSTALLED_APP_STATE="${answer%%$'\t'*}"
    case "$INSTALLED_APP_STATE" in
        ONE) INSTALLED_APP="${answer#*$'\t'}" ;;
        AMBIGUOUS) INSTALLED_APP=""; AMBIGUOUS_PATHS="${answer#*$'\t'}" ;;
        *) INSTALLED_APP="" ;;
    esac
}

release_build_cleanup() {
    local status=$?
    local built failed=0
    # THREE bundles, not two. Step 6 copies the signed app into the DMG
    # staging directory, and the first version of this loop listed only the
    # archive's copy and the export. The next run's `rm -rf "$OUT"` then
    # deleted a registered bundle, which is literally the 2026-08-26 failure
    # this trap's header describes, and `af_installed_app.py` skips everything
    # under build/ so the ambiguity check could never have noticed. Found by
    # review, 2026-08-30.
    for built in "$ARCHIVE/Products/Applications/AF Flow.app" "$APP" \
                 "$OUT/dmg-stage/AF Flow.app"; do
        if [ -d "$built" ]; then
            if ! "$LSREGISTER" -u "$built" >/dev/null 2>&1; then
                echo "CLEANUP FAILED: could not unregister $built" >&2
                failed=1
            fi
        fi
    done
    if [ -n "$INSTALLED_APP" ] && [ -d "$INSTALLED_APP" ]; then
        if ! "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1; then
            echo "CLEANUP FAILED: could not re-register $INSTALLED_APP" >&2
            failed=1
        fi
    fi
    if [ "$failed" = "1" ]; then
        cat >&2 <<'CLEANUP'

LaunchServices was left in a state this script could not fix. Run
  python3 scripts/system-list-check.py
and do not install anything until it is clean. A second live claimant on
com.frolikov.afflow is what took his Input Monitoring grant on 2026-07-26.
CLEANUP
        [ "$status" -eq 0 ] && exit 1
    fi
    exit "$status"
}
trap release_build_cleanup EXIT

step_number=0
say() { printf '\n== %s\n' "$1"; }
fail() { printf '\nREFUSING TO REPORT SUCCESS: %s\n' "$1" >&2; exit "${2:-1}"; }

# Returns 0 when the caller should stop after the step just finished.
stop_here() {
    [ "$STOP_AFTER" = "$1" ] || return 1
    printf '\nSTOPPED after "%s" as asked. Nothing beyond this point was run,\n' "$1"
    printf 'and nothing beyond this point is claimed.\n'
    return 0
}

# ---------------------------------------------------------------------------
say "step 0: preflight"

remember_installed_app
case "$INSTALLED_APP_STATE" in
    ONE)
        echo "ok    his installed app, to be re-registered on exit: $INSTALLED_APP" ;;
    NONE)
        echo "note  LaunchServices names no installed AF Flow outside this repo's"
        echo "      build directory, so there is nothing to re-register. The"
        echo "      builds below are still unregistered on exit." ;;
    AMBIGUOUS)
        echo "Two or more live bundles claim com.frolikov.afflow:" >&2
        # Tab-separated and printed one per line. The first version split on
        # spaces, and EVERY path here contains one: "/Applications/AF Flow.app"
        # printed as two broken lines. This is the diagnostic Andrew would act
        # on. Found by review, 2026-08-30.
        printf '%s' "$AMBIGUOUS_PATHS" | tr '\t' '\n' | sed 's/^/  /' >&2
        fail "this script cannot tell which one is the app Andrew launches, and
re-registering the wrong one is the duplicate-claimant failure that killed his
dictation for five hours on 2026-07-26. Run
  python3 scripts/system-list-check.py
  ./scripts/tcc-orphan-cleanup.sh
until exactly one live bundle claims that identifier." 1 ;;
    *)
        fail "LaunchServices could not be read, so this run does not know which
app it would have to restore afterwards. An unreadable registry is not an empty
one. Try again, or run scripts/system-list-check.py to see why it failed." 2 ;;
esac

if [ -z "$VERSION" ]; then
    fail "no --version given. The version is not read from the project on
purpose: Info.plist still carries 2.4.2, inherited from the fork this app grew
out of, and a release that silently ships the fork's version number is a claim
about a history AF Flow does not have. Pass the version you mean." 4
fi

if [ -n "$STARTER_MODELS" ] && [ "$WITHOUT_MODELS" = "1" ]; then
    fail "--starter-models and --without-models contradict each other." 4
fi
if [ -z "$STARTER_MODELS" ] && [ "$WITHOUT_MODELS" != "1" ]; then
    fail "no --starter-models DIR. The settled decision of 2026-08-29 is that
the DMG bundles the Starter tier so dictation works the moment the app first
opens, offline. The tier itself is defined in Phase 3 of
docs/launch-v1-plan.md, which has not run yet. Pass --without-models to build
a DMG deliberately without them; it will not be the DMG that ships." 4
fi

# A DMG built from an uncommitted tree cannot be rebuilt from the tag it claims
# to be. This is the one release rule that is about git rather than signing.
if [ -n "$(git status --porcelain)" ]; then
    if [ "${AF_FLOW_RELEASE_ALLOW_DIRTY:-}" = "1" ]; then
        echo "warning: the tree is dirty and AF_FLOW_RELEASE_ALLOW_DIRTY=1 is set."
        echo "         This artefact cannot be reproduced from any commit."
    else
        fail "the working tree is dirty. A DMG built from uncommitted changes
cannot be rebuilt from the tag it claims to be, and this is the artefact that
goes to other people's machines. Commit, or set AF_FLOW_RELEASE_ALLOW_DIRTY=1
for a build you know is throwaway." 1
    fi
fi

PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$REPO_ROOT/AFFlow/Info.plist" 2>/dev/null)
if [ "$PLIST_VERSION" != "$VERSION" ]; then
    fail "AFFlow/Info.plist says CFBundleShortVersionString = '$PLIST_VERSION',
you asked for '$VERSION'. The DMG name, the release notes and the app's own
About box would then disagree, and the copy-to-AI prompt carries the version so
an AI can say whether a newer one exists. Fix Info.plist or fix the argument." 1
fi

# The checkers this script leans on are themselves verified first. A checker
# that has not been seen distinguishing states is not a checker, and this is
# the one run where nobody is watching the output line by line.
say "step 0a: the boundary checkers, seen distinguishing their states"
python3 scripts/bundle-boundary-check-selftest.py >/dev/null 2>&1 \
    || fail "scripts/bundle-boundary-check-selftest.py does not pass. The
entitlement guarantee below would be unverified. Run it directly to see which
state it stopped distinguishing." 2
python3 scripts/build-config-check-selftest.py >/dev/null 2>&1 \
    || fail "scripts/build-config-check-selftest.py does not pass." 2
python3 scripts/af_installed_app_selftest.py >/dev/null 2>&1 \
    || fail "scripts/af_installed_app_selftest.py does not pass. The cleanup
below decides which bundle keeps his microphone grant." 2
echo "ok    all three selftests pass"

say "step 0b: the build settings a release depends on"
python3 scripts/build-config-check.py || fail "the build configuration is not
release-ready. Nothing below would fix it." 1

say "step 0c: is there a Developer ID Application certificate"
SHIPPABLE=1
# `head -1` WAS THE SAME DEFECT REFUSED FOR LAUNCHSERVICES TWENTY LINES UP.
# Two valid Developer ID Application certificates in this keychain, from two
# teams, and the release would sign, verify and report ok under whichever came
# first. Ambiguity is refused here for the same reason it is refused there.
# Found by review, 2026-08-30.
IDENTITY_LIST=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "$IDENTITY_PREFIX" | sed -E 's/.*"(.*)"/\1/')
IDENTITY_COUNT=$(printf '%s' "$IDENTITY_LIST" | grep -c . || true)
if [ -n "${AF_FLOW_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$AF_FLOW_SIGN_IDENTITY"
elif [ "$IDENTITY_COUNT" -gt 1 ]; then
    echo "More than one $IDENTITY_PREFIX certificate is in this keychain:" >&2
    printf '%s' "$IDENTITY_LIST" | sed 's/^/  /' >&2
    fail "this script will not guess which team ships his app. Set
AF_FLOW_SIGN_IDENTITY to the exact certificate name." 1
else
    IDENTITY=$(printf '%s' "$IDENTITY_LIST" | head -1)
fi

# Without the certificate the ARCHIVE still means something: it proves the
# Release configuration compiles, that the entitlements survive it, and that
# the settings checked above are the ones Xcode actually used. So a run that
# stops at or before the archive is allowed to continue on the development
# certificate, loudly and with SHIPPABLE=0, and every step after the archive
# refuses to run at all. Without this branch the "to see how far the build
# gets" line below would name a command the check above had already made
# unreachable, which is an instruction that reads as help and is a dead end.
if [ -z "$IDENTITY" ] && { [ "$STOP_AFTER" = "preflight" ] || [ "$STOP_AFTER" = "archive" ]; }; then
    SHIPPABLE=0
    IDENTITY="Apple Development"
    cat <<'NOTSHIPPABLE'
warning: no Developer ID Application certificate, and --stop-after is at or
         before the archive, so this run continues on the development
         certificate. WHAT IT PRODUCES CANNOT BE SHIPPED and this script will
         refuse every step past the archive. It proves the Release
         configuration builds, nothing more.
NOTSHIPPABLE
fi

if [ -z "$IDENTITY" ]; then
    cat >&2 <<'BLOCKED'

BLOCKED ON THE APPLE DEVELOPER PROGRAM MEMBERSHIP.

There is no "Developer ID Application" certificate in this keychain, so this
Mac cannot produce a signature any other Mac will trust. The membership is
USD 99/yr, about CAD 135/yr, and it is Andrew's purchase to make at
developer.apple.com/programs.

Everything above this line ran and passed. Nothing below it ran, and nothing
below it is claimed.

This script does NOT fall back to the "Apple Development" certificate that is
here, and that refusal is the point: a development-signed DMG opens on this Mac
and fails on every other one, so the fallback would produce a release that
tests clean and is broken for exactly the people it is for.

To see how far the build itself gets without the certificate:
  scripts/release-build.sh --version VERSION --without-models --stop-after archive
BLOCKED
    exit 3
fi
echo "ok    signing identity: $IDENTITY"

if [ -n "$STARTER_MODELS" ]; then
    [ -d "$STARTER_MODELS" ] || fail "--starter-models '$STARTER_MODELS' is not a directory." 4
    MODEL_BYTES=$(du -sk "$STARTER_MODELS" | cut -f1)
    echo "ok    starter models: $STARTER_MODELS ($(( MODEL_BYTES / 1024 )) MB)"
fi

stop_here preflight && exit 0

# ---------------------------------------------------------------------------
say "step 1: archive (Release configuration)"
# Its own derived-data directory, so it can never be confused with the test
# host's or with the Debug app build's, both of which live beside it under
# build/. This touches no defaults domain and launches no test host, so AF Flow
# may stay open while it runs.
# UNREGISTER BEFORE DELETING, because a previous run that was killed, or a
# machine that lost power, never reached its EXIT trap and left its bundles
# registered under com.frolikov.afflow. Deleting them first strands the record:
# the trap below then finds nothing to unregister, and `af_installed_app.py`
# deliberately ignores paths under build/, so nothing else would ever see them.
# That is the 2026-08-26 failure with the order reversed. Codex, 2026-08-30.
for leftover in "$ARCHIVE/Products/Applications/AF Flow.app" "$APP" \
                "$OUT/dmg-stage/AF Flow.app"; do
    if [ -d "$leftover" ]; then
        echo "  unregistering a bundle left by an earlier run: $leftover"
        "$LSREGISTER" -u "$leftover" >/dev/null 2>&1 \
            || echo "  WARNING: could not unregister $leftover" >&2
    fi
done
rm -rf "$OUT"
mkdir -p "$OUT"

xcodebuild archive \
    -project AFFlow.xcodeproj \
    -scheme AFFlow \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -archivePath "$ARCHIVE" \
    -skipMacroValidation \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    2>&1 | grep -E "error:|warning: .*never be executed|ARCHIVE SUCCEEDED|BUILD FAILED"
ARCHIVE_STATUS=${PIPESTATUS[0]}

ARCHIVED_APP="$ARCHIVE/Products/Applications/AF Flow.app"
[ "$ARCHIVE_STATUS" -eq 0 ] || fail "xcodebuild archive exited $ARCHIVE_STATUS." 1
[ -d "$ARCHIVED_APP" ] || fail "the archive exists but holds no 'AF Flow.app'.
xcodebuild reports success for an archive with nothing in it when the scheme's
archive action has no build target." 1
echo "ok    archived: $ARCHIVED_APP"
[ "$SHIPPABLE" = "1" ] || echo "note  NOT SHIPPABLE: development certificate."

stop_here archive && exit 0

[ "$SHIPPABLE" = "1" ] || fail "this run has no Developer ID certificate. It was
allowed as far as the archive and no further. Nothing beyond step 1 ran." 3

# ---------------------------------------------------------------------------
say "step 2: export a Developer ID copy"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM</string>
    <!-- export, never upload: notarization is step 5 below, where its result
         is read. Letting the export do it hides the verdict. -->
    <key>destination</key><string>export</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$IDENTITY_PREFIX</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORTED" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    2>&1 | grep -E "error:|EXPORT SUCCEEDED|EXPORT FAILED"
EXPORT_STATUS=${PIPESTATUS[0]}
[ "$EXPORT_STATUS" -eq 0 ] || fail "xcodebuild -exportArchive exited $EXPORT_STATUS." 1
[ -d "$APP" ] || fail "the export succeeded but produced no '$APP'." 1

# THE IDENTIFIER IS A BUILD SETTING, so it can be overridden, and
# Config/LocalSigning.xcconfig is an untracked file this repo invites Andrew to
# create. An exported bundle carrying the test host's identifier, or any other,
# would sign, notarize and pass Gatekeeper while being a different app to the
# sandbox and to TCC: his grants would not follow it and neither would his
# data. run-tests.sh checks exactly this on the Debug build it produces; the
# artefact strangers install was not checked at all. Codex review, 2026-08-30.
EXPORTED_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    "$APP/Contents/Info.plist" 2>/dev/null)
[ "$EXPORTED_ID" = "com.frolikov.afflow" ] || fail "the exported bundle's
identifier is '$EXPORTED_ID', expected 'com.frolikov.afflow'. Something
overrode AF_FLOW_BUNDLE_ID; check Config/LocalSigning.xcconfig." 1

# The visible name, for the reason recorded in docs/design/af-flow-system-list-names.md:
# the bare name "AF Flow" belongs to exactly one bundle, and macOS labels a
# privacy row with the display name, so a wrong one buys a permanent mislabelled
# row in his settings.
for name_key in CFBundleName CFBundleDisplayName; do
    EXPORTED_NAME=$(/usr/libexec/PlistBuddy -c "Print :$name_key" \
        "$APP/Contents/Info.plist" 2>/dev/null)
    [ "$EXPORTED_NAME" = "AF Flow" ] || fail "the exported bundle's $name_key is
'$EXPORTED_NAME', expected 'AF Flow'." 1
done
echo "ok    exported: $APP ($EXPORTED_ID)"

stop_here export && exit 0

# ---------------------------------------------------------------------------
say "step 3: put the starter models in, then sign"
# ORDER MATTERS AND IT IS EASY TO GET BACKWARDS. Anything added to a bundle
# after it is signed invalidates the signature, and the app then fails
# Gatekeeper on a stranger's Mac with an error that names nothing useful. The
# models go in first and the whole bundle is signed around them.
if [ -n "$STARTER_MODELS" ]; then
    DEST="$APP/Contents/Resources/StarterModels"
    mkdir -p "$DEST"
    rsync -a --delete "$STARTER_MODELS/" "$DEST/" \
        || fail "could not copy the starter models into the bundle." 1
    COPIED=$(find "$DEST" -type f | wc -l | tr -d ' ')
    [ "$COPIED" -gt 0 ] || fail "the starter models directory copied 0 files." 1
    echo "ok    $COPIED model file(s) inside the bundle, before signing"
else
    echo "note  no starter models. This DMG is not the one that ships."
fi

# NO --deep, DELIBERATELY. Apple documents `--deep` as unsuitable for
# distribution signing: it walks into the embedded WhisperKit, FluidAudio and
# LLM.swift frameworks that xcodebuild already signed correctly and re-signs
# them with the APP's entitlements, including the App Sandbox. The failure that
# buys is a notarization rejection, or Gatekeeper refusing on a friend's Mac,
# which is the outcome this whole script exists to prevent. And
# `bundle-boundary-check.py` reads only the top-level signature, so nothing
# below would have caught it. Found by review, 2026-08-30.
#
# Re-signing only the top level is also all that is needed: adding files under
# Contents/Resources breaks the app bundle's own seal and leaves every nested
# signature intact. `codesign --verify --deep --strict` below then checks the
# nested ones rather than replacing them; --deep is correct for verifying and
# wrong for signing.
#
# --force replaces the export's signature rather than appending to it,
# --timestamp because notarization refuses a signature without a secure
# timestamp, --options runtime because it refuses one without the hardened
# runtime, and the entitlements are passed explicitly so the shipped bundle
# carries the file in this repo rather than whatever the archive kept.
codesign --force --timestamp --options runtime \
    --entitlements "$REPO_ROOT/AFFlow/AFFlow.entitlements" \
    --sign "$IDENTITY" "$APP" \
    || fail "codesign failed." 1

# codesign exits 0 having signed with a certificate that is not the one asked
# for if the name matched something else, so the authority is read back rather
# than assumed.
AUTHORITY=$(codesign -dvv "$APP" 2>&1 | grep "^Authority=" | head -1 | cut -d= -f2-)
case "$AUTHORITY" in
    "$IDENTITY_PREFIX"*) : ;;
    *) fail "the bundle is signed by '$AUTHORITY', not a $IDENTITY_PREFIX
certificate. Gatekeeper would refuse it on every Mac but this one." 1 ;;
esac

# The AUTHORITY prefix says "some Developer ID certificate", not "his". TCC,
# Gatekeeper and every future update key on the TEAM, so the team is read back
# rather than inferred from the certificate's display name. Found by review,
# 2026-08-30.
SIGNED_TEAM=$(codesign -dvv "$APP" 2>&1 | grep "^TeamIdentifier=" | cut -d= -f2)
[ "$SIGNED_TEAM" = "$TEAM" ] || fail "the bundle is signed under team
'$SIGNED_TEAM', expected '$TEAM'. A different team is a different app to TCC
and to Gatekeeper." 1
echo "ok    signed by: $AUTHORITY (team $SIGNED_TEAM)"

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "codesign --verify --deep --strict rejected the bundle." 1

# The same guarantee run-tests.sh runs on the Debug build, plus the three only a
# distribution build can break. Every state it distinguishes is staged in
# scripts/bundle-boundary-check-selftest.py.
python3 scripts/bundle-boundary-check.py "$APP" --configuration release \
    || fail "the signed bundle is outside its boundary." 1

stop_here sign && exit 0

# ---------------------------------------------------------------------------
say "step 4: notarize"
ZIP="$OUT/AF Flow-$VERSION.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP" \
    || fail "could not zip the app for submission." 1

NOTARY_LOG="$OUT/notarytool-submit.txt"
xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 45m 2>&1 | tee "$NOTARY_LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "notarytool submit exited non-zero.
If it could not find the credential profile '$NOTARY_PROFILE', create it once:
  xcrun notarytool store-credentials $NOTARY_PROFILE \\
      --apple-id andriy.frolikov\@gmail.com --team-id $TEAM
It asks for an app-specific password from appleid.apple.com. That password is
Andrew's to type." 1

# notarytool exits 0 for a submission it successfully delivered and Apple
# successfully REJECTED. The verdict is a field in the output, not the exit
# code, and reading the exit code alone is how a rejected build gets stapled.
if ! grep -q "status: Accepted" "$NOTARY_LOG"; then
    SUBMISSION=$(grep -m1 "id:" "$NOTARY_LOG" | awk '{print $2}')
    echo >&2
    echo "Apple did not accept it. The full log:" >&2
    [ -n "$SUBMISSION" ] && xcrun notarytool log "$SUBMISSION" \
        --keychain-profile "$NOTARY_PROFILE" >&2
    fail "notarization status is not Accepted." 1
fi
echo "ok    notarization accepted"

stop_here notarize && exit 0

# ---------------------------------------------------------------------------
say "step 5: staple the app"
xcrun stapler staple "$APP" || fail "stapler could not staple the app." 1
xcrun stapler validate "$APP" || fail "the app does not validate after stapling." 1
echo "ok    stapled and validated"

stop_here staple && exit 0

# ---------------------------------------------------------------------------
say "step 6: build the DMG"
DMG="$OUT/AF Flow $VERSION.dmg"
STAGE="$OUT/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/" || fail "could not stage the app for the DMG." 1
ln -s /Applications "$STAGE/Applications" \
    || fail "could not create the Applications shortcut in the DMG." 1

rm -f "$DMG"
hdiutil create -volname "AF Flow" -srcfolder "$STAGE" -ov -format UDZO "$DMG" \
    >/dev/null || fail "hdiutil create failed." 1
[ -f "$DMG" ] || fail "hdiutil reported success and produced no file." 1

# hdiutil returns 0 for images that will not mount, so it is mounted here and
# the app is looked for inside it.
MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet \
    || fail "the DMG hdiutil just built cannot be mounted." 1
MOUNTED_OK=0
[ -d "$MOUNT/AF Flow.app" ] && MOUNTED_OK=1
# A detach that fails leaves "AF Flow.app" mounted at /Volumes, which is a LIVE
# claimant on com.frolikov.afflow that the EXIT trap does not know about and
# cannot unregister. Discarding its status and carrying on to "every step
# verified" is exactly the shape this script refuses everywhere else. Found by
# review, 2026-08-30.
if ! hdiutil detach "$MOUNT" -quiet; then
    hdiutil detach "$MOUNT" -force -quiet >/dev/null 2>&1 \
        || fail "the DMG is still mounted at $MOUNT and could not be detached.
It is a live claimant on com.frolikov.afflow. Eject it in Finder, then run
  python3 scripts/system-list-check.py
before installing anything." 1
fi
rmdir "$MOUNT" 2>/dev/null
[ "$MOUNTED_OK" = "1" ] || fail "the DMG mounts but holds no 'AF Flow.app'." 1
echo "ok    DMG mounts and holds the app: $DMG"

# The DMG is itself a distributed artefact, so it is signed, notarized and
# stapled in its own right. An unstapled DMG makes the first launch depend on
# the friend's Mac reaching Apple, which is the one moment they are most likely
# to be told the app is broken.
codesign --force --timestamp --sign "$IDENTITY" "$DMG" \
    || fail "could not sign the DMG." 1

DMG_LOG="$OUT/notarytool-submit-dmg.txt"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 45m 2>&1 | tee "$DMG_LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "notarytool submit for the DMG exited non-zero." 1
grep -q "status: Accepted" "$DMG_LOG" || fail "the DMG's notarization status is not Accepted." 1

xcrun stapler staple "$DMG" || fail "stapler could not staple the DMG." 1
xcrun stapler validate "$DMG" || fail "the DMG does not validate after stapling." 1
echo "ok    DMG signed, notarized and stapled"

stop_here dmg && exit 0

# ---------------------------------------------------------------------------
say "step 7: ask Gatekeeper, the way a friend's Mac will"
# spctl is the only check here that answers the actual question: not "did every
# tool return 0" but "will this open on a Mac that has never seen it".
SPCTL_APP=$(spctl -a -vv -t install "$APP" 2>&1)
echo "$SPCTL_APP"
case "$SPCTL_APP" in
    *"source=Notarized Developer ID"*) : ;;
    *) fail "Gatekeeper does not report the app as Notarized Developer ID." 1 ;;
esac

SPCTL_DMG=$(spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1)
echo "$SPCTL_DMG"
# The same sentence demanded of the app. Accepting any "accepted" here would
# pass an unnotarized Developer ID DMG, which is the artefact a friend actually
# downloads. Found by review, 2026-08-30.
case "$SPCTL_DMG" in
    *"source=Notarized Developer ID"*) : ;;
    *) fail "Gatekeeper does not report the DMG as Notarized Developer ID." 1 ;;
esac

cat <<DONE

======================================================================
 Every step above was verified, not assumed.

   app:  $APP
   DMG:  $DMG

 What is still NOT proven by this script, and what proves it:
   - that it installs and runs on a Mac that has never seen AF Flow.
     Phase 1 gate 4: a fresh macOS user account is the proxy.
   - that the Team ID change re-prompts Microphone and Input Monitoring
     once on Andrew's own Mac. Expected, documented in
     docs/launch-v1-plan.md; not a defect.
======================================================================
DONE
exit 0
