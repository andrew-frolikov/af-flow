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
# Exact files only. Codex round 7, MEDIUM: a Reader/[A-Za-z]+ directory pattern
# allowlisted the live ReaderCaptureSheet.swift UI file too. Neither Reader file
# constructs a cloud client, so the entry is deleted rather than narrowed. Every
# entry below names one file, never a directory shape.
INERT_CLOUD_SOURCES='GhostPepper/(Calendar/GoogleCalendarService|Meeting/AirtableImporter|Meeting/GranolaImporter|PepperChat/ZoBackend|PepperChat/TrelloBackend|PepperChat/TrelloCommandParser|QA/AnthropicProvider|Reader/ReaderCapture|Reader/ReaderCaptureSheet)\.swift'
# The keychain helper defines the migration function and names the upstream
# service in a comment explaining why AF Flow does not use it. Test fixtures and
# the dev-only probe tool carry the upstream bundle id as literal strings.
DEFINITION_AND_FIXTURES='GhostPepper/QA/KeychainHelper\.swift|GhostPepperTests/[^:]*\.swift|CleanupModelProbe/main\.swift|GhostPepper/Meeting/MeetingTranscriptSettings\.swift'

# Same inert set as INERT_CLOUD_SOURCES, in the plain path form code-grep.py
# expects (no grep -n colon anchoring).
INERT_CLOUD_SOURCES_PATHS='GhostPepper/(Calendar/GoogleCalendarService|Meeting/AirtableImporter|Meeting/GranolaImporter|PepperChat/ZoBackend|PepperChat/TrelloBackend|PepperChat/TrelloCommandParser|QA/AnthropicProvider|Reader/ReaderCapture|Reader/ReaderCaptureSheet)\.swift'

# Documented single-symbol exception, added 2026-07-19 and flagged to Andrew.
# GranolaImporter.extractTranscript is a `nonisolated static func` that parses a
# local dictionary into a string. It contains no URLSession, no http, no
# dataTask: verified, zero matches. It is a pure parsing helper that happens to
# live on a cloud importer type, and MeetingMarkdownWriter calls it locally.
# It is therefore a naming problem, not a capability. Recorded here rather than
# silently excluded, and C6 should move the helper off that type so the
# exception can be deleted along with the file.
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
  # Anchor the allowlist to the start of the line, which is the FILE PATH.
  # Codex round 7, HIGH: filtering the whole grep hit meant a live file could
  # suppress itself by mentioning an allowlisted path anywhere in its content,
  # e.g. TrelloBackend(...) // see GhostPepper/PepperChat/TrelloBackend.swift.
  # The allowlist must match the WHOLE path, which in grep -n output ends at
  # the first colon. Codex round 7 caught that filtering the whole line let a
  # file suppress itself via a trailing comment; round 8 caught that anchoring
  # with ^($allow) alone was still prefix-only, so
  # GhostPepper/PepperChat/TrelloBackend.swift.evil/Live.swift would pass as
  # allowlisted. Requiring the colon closes both.
  if [ -n "$allow" ] && [ -n "$hits" ]; then
    hits=$(printf '%s\n' "$hits" | grep -vE "^($allow):" || true)
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

# The verifier proves itself BEFORE it verifies anything else. Rounds 7, 8 and 9
# each found a hole in this project's Swift parsing, and each one meant the
# sweep had been reporting clean while a real violation sat in the tree. A gate
# with a silently wrong parser is worse than no gate: it manufactures
# confidence. Canaries were being run by hand, which is not a control because it
# depends on someone remembering. Now it runs every time, first, and a failure
# here stops the sweep rather than letting 15 misleading "ok" lines print.
if ! python3 scripts/swift-scan-selftest.py; then
  echo ""
  echo "RESULT: verifier self-test failed, no other check can be trusted"
  exit 1
fi

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
# Match the bare IDENTIFIER, with no suffix requirement at all.
#
# Fable adversary finding 1, and the most important result of the whole review:
# requiring [.(] after the name meant `GoogleCalendarService\n    .shared` was
# invisible, because tokens end at newlines. That is not an attack. It is what
# any code formatter produces from a long line, so the check could switch itself
# off silently during ordinary editing.
#
# Finding 2: a typealias hid the call behind a new name. Matching the bare
# identifier catches the typealias DECLARATION, which is where the real name
# has to appear, so this needs no symbol table.
# Codex round 8, HIGH: MeetingSession started every recording with
# GoogleCalendarService.shared.currentMeeting(), a live URLSession call, and the
# old '\(' pattern never saw it because singleton access has no parenthesis
# after the type name.
#
# Deliberately scoped to the service OBJECTS that own a URLSession, not to their
# data types. CalendarEvent is a plain Codable struct with no networking and the
# meeting UI still passes it around; banning a value type would be theatre while
# the object that can actually reach the network is the control that does work.

# Runs swift-scan.py and DISTINGUISHES "no hits" from "the scanner failed".
#
# Added 2026-07-21 after Codex round 2. Every call site used `|| true`, which
# collapses those two outcomes into the same empty string, so a scanner that
# could not run printed `ok` and the sweep reported clean. The self-test above
# catches a totally broken scanner, but not one that works for the self-test and
# then fails on a single invocation, which is the shape that would sit here
# undetected. Codex observed the real thing: `/dev/stderr: Operation not
# permitted` followed by `ok`.
#
# A gate that cannot tell "nothing found" from "I did not look" is the exact
# class this project has now hit eleven times.
scan() {
  local output status
  output=$(python3 scripts/swift-scan.py "$@" 2>&1)
  status=$?
  # swift-scan.py's convention: 0 means no hits, 1 means HITS FOUND, and 2 or
  # above is a real error. Both 0 and 1 are successful scans. Treating 1 as a
  # failure was the second bug in this fix, and it turned every normal run red,
  # which at least failed LOUDLY rather than the silent-green direction.
  if [ $status -ge 2 ]; then
    echo "SCANNER FAILED (exit $status) for: swift-scan.py $*" >&2
    echo "$output" >&2
    # A SENTINEL FILE, not a variable. Every call site wraps this in $(...),
    # which runs in a subshell, so `scanner_broken=1` was set in a child and
    # discarded. The first version of this fix did exactly that and reported
    # "RESULT: clean" while printing "SCANNER FAILED" three lines above.
    # Caught by canary before it shipped, which is the entire argument for
    # canarying a gate rather than reasoning about it.
    : > "$SCANNER_FAILED_SENTINEL"
    return $status
  fi
  printf '%s' "$output"
}
SCANNER_FAILED_SENTINEL="$(mktemp -t afflow-scanner)"
rm -f "$SCANNER_FAILED_SENTINEL"
trap 'rm -f "$SCANNER_FAILED_SENTINEL"' EXIT

# Runs through scripts/swift-scan.py in code mode, which yields only real code,
# because a comment recording that a capability was REMOVED necessarily names
# it and cannot call anything. On first run the identifier check returned four
# hits, three of which were exactly such comments.
cloud_hits=$(scan --mode code \
  '\b(ZoBackend|TrelloBackend|TrelloCommandParser|AirtableImporter|GranolaImporter|GoogleCalendarService|AnthropicProvider|ReaderCapture|ReaderCaptureSheet)\b' \
  "${SWIFT_PATHS[@]}" --allow "$INERT_CLOUD_SOURCES_PATHS" | \
  grep -vE 'GranolaImporter\.extractTranscript' || true)
if [ -n "$cloud_hits" ]; then
  echo "FAIL  no live reference to a cloud service object"
  echo "$cloud_hits" | sed 's/^/        /'
  fail=1
else
  echo "ok    no live reference to a cloud service object"
fi
check "no cloud callback wiring in live code" \
  'onSendToZo|onSendToTrello|isTrelloConfigured|trelloApiKey|trelloToken|trelloBoards|fetchTrelloBoards' swift \
  "$INERT_CLOUD_SOURCES"

# Layer 2 and 4: an actual credential, hardcoded. Codex round 9, HIGH: this
# sweep is the REQUIRED gate and it checked for key-entry UI, credential reads
# and credential writes, but never for a key literal sitting in a file. A
# hardcoded sk-ant-... or ghp_... would have shipped with the gate green.
#
# The pattern is the one already used by scripts/privacy-security-preflight.sh,
# which was optional and therefore not load-bearing. Hoisted into the required
# gate. Scans the whole repo, not just Swift: a key in a script or a plist is
# still a key.
# Runs scripts/credential-scan.py, not grep. Codex round 11, HIGH: a raw
# grep -r never gained the protections the Swift scanner already had, so it did
# not follow symlinked directories and skipped unreadable files silently. A key
# in a non-Swift file behind a symlink was invisible to the required gate.
#
# It scans the working tree rather than the git index, because `git grep` skips
# ignored files and ignored is exactly where a leaked key sits.
cred_hits=$(python3 scripts/credential-scan.py . 2>&1 | grep -v '^note ' || true)

# Second pass over Swift only, matching what the COMPILED app builds rather
# than what the source literally reads: literals concatenated, escapes decoded.
cred_swift=$(scan --mode string --join \
  '(sk-ant-[A-Za-z0-9_-]{20,}|zo_sk_[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{20,}|ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})' \
  "${SWIFT_PATHS[@]}")
cred_hits="$cred_hits$cred_swift"

if [ -n "$cred_hits" ]; then
  echo "FAIL  no credential-shaped literal anywhere in the repo"
  echo "$cred_hits" | sed 's/^/        /'
  fail=1
else
  echo "ok    no credential-shaped literal anywhere in the repo"
fi

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
# These run through scripts/swift-scan.py rather than grep, because
# they must match INSIDE Swift string literals and nowhere else. A line-oriented
# grep flags ordinary code comments that quote something before an em dash (it
# produced eight false positives on 2026-07-19) and at the same time MISSES em
# dashes inside multi-line triple-quoted LLM prompt literals, which are the ones
# that matter most: a prompt containing em dashes teaches the model to emit them.
# Excluding comments removes noise, not coverage. Comments are not user-facing.
literal_check() {
  local label="$1" pattern="$2" hits
  hits=$(scan --mode string --join "$pattern" "${SWIFT_PATHS[@]}")
  if [ -n "$hits" ]; then
    echo "FAIL  $label"
    echo "$hits" | sed 's/^/        /'
    fail=1
  else
    echo "ok    $label"
  fi
}

# Fable adversary finding 8: U+2015 HORIZONTAL BAR and U+2E3A render as em
# dashes and sailed straight through a U+2014-only check.
#
# Scoped to em-dash LOOKALIKES only. The first version of this fix used the
# range U+2012 to U+2015, which swept in the en dash and immediately failed two
# correct lines, including a window-title matcher whose en dash is DATA that
# Microsoft Teams puts in its own title bar. Removing it would have broken
# meeting detection. Hard rule 9 bans em dashes; an en dash is a different
# character with a different job, and widening past the rule creates pressure to
# weaken the check later.
literal_check "no em dash in user-facing strings" '[\u2014\u2015\u2E3A\u2E3B]'
# The currency pattern must not match Swift's `$0` closure shorthand, which
# appears inside interpolated strings all over the codebase. Matching it was a
# bug in this check that buried the three real USD sites under 60 false
# positives. Every real shape (a `$%` format specifier, a literal price, the
# standalone word USD) is still caught, and the canary test proves it.
# Two or more digits after the $ catches whole-dollar prices ($10, $50) while
# still skipping Swift's single-digit closure shorthand ($0, $1). Codex round 7,
# HIGH: the previous pattern required a decimal point and so missed exactly the
# shape that was sitting unlabelled in PROGRESS.md.
# Codex round 8 asked for every literal dollar amount to be caught, on the
# reasoning that stripping interpolation removes Swift's $0 shorthand. The
# interpolation stripping is now in place, but it does NOT settle this case:
# the remaining collisions are regex REPLACEMENT TEMPLATES, literal text like
# "[$2]($1)" passed to replacingOccurrences with .regularExpression. Those are
# plain characters in the string, not interpolation, so no amount of
# interpolation handling separates them from a price.
#
# So `$` plus a single bare digit is genuinely ambiguous in Swift source, and a
# check that flags it would fail on three correct lines today. The rule instead
# catches every shape that is unambiguously money: a format specifier, a decimal
# amount, two or more digits, the word USD, or a single digit carrying an
# explicit currency word.
#
# KNOWN LIMITATION, recorded rather than hidden: a bare "$9" with no decimal and
# no currency word is not flagged. Accepted because every cost this app can
# display is CAD 0 on-device, so a one-digit hardcoded price is not a shape that
# can legitimately occur here, while regex backreferences demonstrably do.
literal_check "no non-CAD currency in user-facing strings" \
  '[$]%|[$][0-9]+[.,][0-9]|[$][0-9]{2,}|\bUSD\b|[$][0-9] ?(USD|CAD|dollar)'

# Rule 9 applies to helper-script output too. Codex round 7, MEDIUM: the sweep
# only looked at Swift, so scripts/extract_granola.py printed an em dash to the
# terminal while the gate reported clean. Scripts are small and their strings
# are almost all output, so this checks the raw character rather than parsing
# Python and shell quoting. No exclusions: the verifier scripts write the
# characters they allowlist as \u escapes precisely so this can stay absolute.
# macOS ships bash 3.2, whose $'...' does not expand \u escapes, so a grep
# pattern written that way silently searches for the literal text instead of
# the character. Done in python for the same reason the Swift checks are.
script_hits=$(python3 -c "
import os
bad = (chr(0x2014), chr(0x2013))
for dirpath, _dirs, files in os.walk('scripts'):
    for name in sorted(files):
        path = os.path.join(dirpath, name)
        try:
            lines = open(path, encoding='utf-8').readlines()
        except Exception:
            continue
        for num, line in enumerate(lines, 1):
            if any(c in line for c in bad):
                print('%s:%d:%s' % (path, num, line.strip()))
" 2>/dev/null || true)
if [ -n "$script_hits" ]; then
  echo "FAIL  no em dash in helper scripts"
  echo "$script_hits" | sed 's/^/        /'
  fail=1
else
  echo "ok    no em dash in helper scripts"
fi

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

# STATE.md must stay small, current and honest, and nobody should have to remember
# to check it. This sweep already runs at every boundary, so the check rides it.
# Added 2026-08-02 with STATE.md itself; see scripts/state-check.py for the why.
echo ""
if ! python3 "$(dirname "$0")/state-check.py"; then
  fail=1
fi

echo ""
if [ "$fail" -eq 0 ]; then
  if [ -e "$SCANNER_FAILED_SENTINEL" ]; then
  echo "RESULT: a scanner invocation FAILED, so no check above can be trusted"
  exit 1
fi
echo "RESULT: clean"
else
  echo "RESULT: banned symbols present, see FAIL lines above"
fi
exit "$fail"
