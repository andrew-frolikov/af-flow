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

# The same deferral, expressed as the full set of cloud-integration SOURCE files
# named in CLAUDE.md de-risk item 3 (Anthropic, Google Calendar, Zo, Trello,
# Granola, Airtable, Reader, qmd). These files may define cloud clients. What no
# file outside this set may do is CONSTRUCT one: that is the difference between
# dead code awaiting C6 deletion and a live capability.
#
# Added 2026-07-19 after Codex round 6 found AppState still building a
# TrelloBackend and passing live callbacks into the UI while the sweep reported
# clean. The gate had no cloud-wiring check at all. This is the widening, not an
# exclusion: it encodes a decision Andrew already made and it makes the live
# layer checkable for the first time.
INERT_CLOUD_SOURCES='GhostPepper/(Calendar/GoogleCalendarService|Meeting/AirtableImporter|Meeting/GranolaImporter|PepperChat/ZoBackend|PepperChat/TrelloBackend|PepperChat/TrelloCommandParser|QA/AnthropicProvider|Reader/[A-Za-z]+)\.swift'
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
# Checks both SecureField and TextField: a plain TextField holding a key is
# still key entry, and is the obvious way to defeat a SecureField-only check.
check "no key or token entry fields" \
  '(SecureField|TextField)\(.*([Aa]pi[ _]?[Kk]ey|[Tt]oken|sk-ant|zo_sk|[Cc]redential)' swift
check "no user-facing text instructing key setup" \
  '"[^"]*([Aa]dd your .*[Kk]ey|API key .*(required|in Settings)|[Kk]ey in Settings)' swift

# Layer 4: any live path that loads a credential and builds a cloud client.
# This is the check whose absence let a live Anthropic key path pass on
# 2026-07-18 while the sweep reported clean.
check "no live credential reads outside deferred files" \
  'KeychainHelper\.get\(' swift "$INERT_BY_DECISION|$DEFINITION_AND_FIXTURES"
# Writing a credential matters as much as reading one: storing a key is how a
# key comes to exist at all. Checking only reads let a store path pass.
check "no live credential writes outside deferred files" \
  'KeychainHelper\.set\(' swift "$INERT_BY_DECISION|$DEFINITION_AND_FIXTURES"

# Layer 2 and 3: no LIVE code may construct a cloud client or carry its wiring.
# Codex round 6 found dangling Zo/Trello callbacks threaded through the UI and a
# live TrelloBackend construction in AppState, all invisible to the old checks
# because they never touched the keychain.
check "no live code constructs a cloud client" \
  '(ZoBackend|TrelloBackend|TrelloCommandParser|AirtableImporter|GranolaImporter|GoogleCalendarService|AnthropicProvider)\(' swift \
  "$INERT_CLOUD_SOURCES"
check "no cloud callback wiring in live code" \
  'onSendToZo|onSendToTrello|isTrelloConfigured|trelloApiKey|trelloToken|trelloBoards|fetchTrelloBoards' swift \
  "$INERT_CLOUD_SOURCES"

# Layer 1: entitlement dropped with the Calendar loopback server.
check "no network.server entitlement" 'network\.server' config
# Layer 1: a registered custom URL scheme exists to receive an OAuth callback.
# Nothing in AF Flow's spec needs the app to be a URL handler, and the Google
# OAuth callback entry outlived the Calendar UI that used it.
check "no OAuth callback URL scheme" 'CFBundleURLTypes|CFBundleURLSchemes|[Oo][Aa]uth' config
# Layer 1 and 2: screen capture must also be absent from config, and the built
# binary must not link the framework. A Swift-only grep cannot prove either.
check "no ScreenCaptureKit in config" 'ScreenCaptureKit' config

# CLAUDE.md hard rule 9: no em dashes in anything user-facing, and costs in CAD
# with a label. Contract rules rather than security rules, but they were being
# enforced only by whoever happened to read the diff, which is how a new em dash
# and USD price strings both shipped past five review rounds.
#
# These run through scripts/string-literal-grep.py rather than grep, because
# they must match INSIDE Swift string literals and nowhere else. A line-oriented
# grep flags ordinary code comments that quote something before an em dash (it
# produced eight false positives on 2026-07-19) and at the same time MISSES em
# dashes inside multi-line triple-quoted LLM prompt literals, which are the ones
# that matter most: a prompt containing em dashes teaches the model to emit them.
# Excluding comments removes noise, not coverage. Comments are not user-facing.
literal_check() {
  local label="$1" pattern="$2" hits
  hits=$(python3 scripts/string-literal-grep.py "$pattern" "${SWIFT_PATHS[@]}" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "FAIL  $label"
    echo "$hits" | sed 's/^/        /'
    fail=1
  else
    echo "ok    $label"
  fi
}

literal_check "no em dash in user-facing strings" '\u2014'
# The currency pattern must not match Swift's `$0` closure shorthand, which
# appears inside interpolated strings all over the codebase. Matching it was a
# bug in this check that buried the three real USD sites under 60 false
# positives. Every real shape (a `$%` format specifier, a literal price, the
# standalone word USD) is still caught, and the canary test proves it.
literal_check "no non-CAD currency in user-facing strings" '[$]%|[$][0-9]+[.,][0-9]|\bUSD\b'

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
# docs/index.html deleted with Andrew's approval 2026-07-18 (leftover upstream marketing page).
PRODUCT_DOCS=(README.md PRIVACY_AUDIT.md docs/pre-deploy-privacy-security.md)
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
