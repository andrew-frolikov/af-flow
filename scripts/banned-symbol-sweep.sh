#!/usr/bin/env bash
# AF Flow banned-symbol sweep. Tier B verifier from LOOP.md.
#
# Checks that capabilities forbidden by CLAUDE.md hard rule 1 are absent from
# CODE and CONFIG. It deliberately does NOT scan documentation: CLAUDE.md's own
# de-risk checklist, PROGRESS.md's review record, and LOOP.md all legitimately
# name these symbols, so a repo-wide sweep can never return zero and would force
# the operator to invent exclusions in the moment.
#
# Exit 0 = clean. Exit 1 = at least one banned symbol found in code or config.
# Output is shaped for direct paste into a commit VERIFY block.
#
# Usage: ./scripts/banned-symbol-sweep.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SWIFT_PATHS=(GhostPepper CleanupModelProbe CleanupModelProbeSupport GhostPepperTests)
CONFIG_PATHS=(project.yml GhostPepper/Info.plist GhostPepper/GhostPepper.entitlements GhostPepper.xcodeproj/project.pbxproj)

# Inert-by-decision allowlist. These files still contain upstream credential
# plumbing. Andrew decided on 2026-07-18 (see PROGRESS.md decision log and
# LOOP.md section 5) to leave the cloud integration sources inert rather than
# delete them now, per de-risk checklist item 3, and to revisit at C6 once the
# build is proven stable. Their key-entry UI is gone and no key can be entered
# or loaded, so they are unreachable in practice.
#
# This list is a committed, reviewable decision, NOT an exclusion invented at
# run time. Removing an entry here is how C6 closes the deferral. Adding one
# requires Andrew's approval.
INERT_BY_DECISION='GhostPepper/(Calendar/GoogleCalendarService|Meeting/AirtableImporter|Meeting/GranolaImporter)\.swift'
# The keychain helper defines the migration function and names the upstream
# service in a comment explaining why AF Flow does not use it. Test fixtures and
# the dev-only probe tool carry the upstream bundle id as literal strings.
DEFINITION_AND_FIXTURES='GhostPepper/QA/KeychainHelper\.swift|GhostPepperTests/|CleanupModelProbe/main\.swift|GhostPepper/Meeting/MeetingTranscriptSettings\.swift'

fail=0

# $1 = human label, $2 = extended regex, $3 = "swift" | "config",
# $4 = optional path regex to exclude (allowlisted, see decisions above)
check() {
  local label="$1" pattern="$2" scope="$3" allow="${4:-}" hits
  if [ "$scope" = "swift" ]; then
    hits=$(grep -rnE "$pattern" "${SWIFT_PATHS[@]}" --include="*.swift" 2>/dev/null || true)
  else
    hits=$(grep -rnE "$pattern" "${CONFIG_PATHS[@]}" 2>/dev/null || true)
  fi
  if [ -n "$allow" ] && [ -n "$hits" ]; then
    hits=$(printf '%s\n' "$hits" | grep -vE "$allow" || true)
  fi

  if [ -n "$hits" ]; then
    echo "FAIL  $label"
    echo "$hits" | sed 's/^/        /'
    fail=1
  else
    echo "ok    $label"
  fi
}

echo "AF Flow banned-symbol sweep"
echo "scope: code and config only, docs excluded by design (see header)"
echo ""

# Layer 1 and 2: screen capture. Hard rule 1 forbids requesting Screen Recording.
# "Removed" means: no import, no call site reachable or unreachable, framework
# not linked. See LOOP.md section 3.
check "no ScreenCaptureKit import or call sites" \
  'ScreenCaptureKit|SCShareableContent|SCScreenshotManager|SCStream|SCContentFilter' swift
check "no Screen Recording permission request" \
  'CGRequestScreenCaptureAccess|CGPreflightScreenCaptureAccess|requestScreenRecordingPermission|hasScreenRecordingPermission' swift

# Layer 1: the auto-updater. Never re-enable.
check "no Sparkle symbols" 'import Sparkle|SPUUpdater|SPUStandardUpdater|UpdaterController' swift
check "no Sparkle feed keys in config" 'SUFeedURL|SUPublicEDKey|sparkle-project' config

# Layer 2 and 4: secrets. Keys and secrets do not exist in this project.
check "no Secrets.swift references" 'Secrets\.(google|anthropic|api)|import Secrets' swift
check "no upstream keychain namespace in live code" 'com\.github\.matthartman\.ghostpepper' swift \
  "$INERT_BY_DECISION|$DEFINITION_AND_FIXTURES"
check "no credential migration in live code" 'migrateUserDefaultsString' swift \
  "$INERT_BY_DECISION|$DEFINITION_AND_FIXTURES"

# Layer 3: UI that invites a pasted secret, or tells the user to go set one up.
# Both matter: a text field is an invitation, and instructional copy is worse
# because it sends Andrew hunting for a field that no longer exists.
check "no key or token entry fields" \
  'SecureField\(.*([Aa]pi[ _]?[Kk]ey|[Tt]oken|sk-ant|zo_sk)' swift
check "no user-facing text instructing key setup" \
  '"[^"]*([Aa]dd your .*[Kk]ey|API key .*(required|in Settings)|[Kk]ey in Settings)' swift

# Layer 4: any live path that loads a credential and builds a cloud client.
# This is the check whose absence let a live Anthropic key path pass on
# 2026-07-18 while the sweep reported clean.
check "no live credential reads outside deferred files" \
  'KeychainHelper\.get\(' swift "$INERT_BY_DECISION|$DEFINITION_AND_FIXTURES"

# Layer 1: entitlement dropped with the Calendar loopback server.
check "no network.server entitlement" 'network\.server' config
# Layer 1 and 2: screen capture must also be absent from config, and the built
# binary must not link the framework. A Swift-only grep cannot prove either.
check "no ScreenCaptureKit in config" 'ScreenCaptureKit' config

BIN="build/run-derived/Build/Products/Debug/GhostPepper.app/Contents/MacOS"
if [ -d "$BIN" ]; then
  linked=$( { otool -L "$BIN/GhostPepper" 2>/dev/null; otool -L "$BIN/GhostPepper.debug.dylib" 2>/dev/null; } | grep -i "screencapture" || true)
  if [ -n "$linked" ]; then
    echo "FAIL  built binary does not link ScreenCaptureKit"
    echo "$linked" | sed 's/^/        /'
    fail=1
  else
    echo "ok    built binary does not link ScreenCaptureKit"
  fi
else
  echo "skip  binary link check (no Debug build present, run xcodebuild first)"
fi

# Layer 5: product docs must not advertise removed capabilities or tell anyone
# to run the prebuilt DMG (de-risk item 6 is build from source only). The
# contract and log documents are excluded: CLAUDE.md, PROGRESS.md and LOOP.md
# necessarily name what is banned in order to ban it.
#
# Known limitation, recorded rather than worked around: this is a substring
# match, so it cannot tell "we removed X" from "we use X". Product docs
# therefore describe absences without naming the removed thing. That is a
# wording constraint, not a safety gap. Do not relax the check to allow
# negation phrasing; the wording constraint is the cheaper price to pay.
PRODUCT_DOCS=(README.md PRIVACY_AUDIT.md docs/index.html docs/pre-deploy-privacy-security.md)
doc_hits=$(grep -rnE 'ScreenCaptureKit|[Ss]parkle|API key|\.dmg' "${PRODUCT_DOCS[@]}" 2>/dev/null || true)
if [ -n "$doc_hits" ]; then
  echo "FAIL  product docs describe removed capabilities"
  echo "$doc_hits" | sed 's/^/        /'
  fail=1
else
  echo "ok    product docs describe removed capabilities"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "RESULT: clean"
else
  echo "RESULT: banned symbols present, see FAIL lines above"
fi
exit "$fail"
