#!/bin/bash
# One command, one paste, roughly 4,000 tokens instead of 82,000.
#
# WHY THIS EXISTS. Until 2026-08-02 the contract said "read PROGRESS.md at session
# start". PROGRESS.md is 247 KB, about 68,000 tokens, and with LOOP.md and the rest the
# mandated read was around 82,000 tokens before any work began. Andrew measured the
# felt cost at 30 to 33 percent of a session and he was right.
#
# The split this rests on: a script prints everything that can be DERIVED, and STATE.md
# asserts the part no script can compute, which is intent and next steps. Derived facts
# cannot go stale because they are regenerated here; asserted facts are kept honest by
# scripts/state-check.py, which the boundary sweep runs.
#
# Usage: ./scripts/session-start.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

echo "======================================================================"
echo " AF Flow session start"
echo "======================================================================"

echo
echo "### Where the tree is"
git status -sb | head -20
echo
git log --format="  %ad  %h  %s" --date=format:"%a %m-%d %H:%M" -6

echo
echo "### What the app actually did"
python3 scripts/runtime-probe.py 2>&1 | sed -n '3,$p'

echo
echo "### Is the state file honest"
python3 scripts/state-check.py 2>&1 | sed -n '3,$p'

echo
echo "### Do the tests in the repo actually run"
python3 scripts/test-registration-check.py 2>&1 | sed -n '3,$p'

echo
echo "### Does every system list show one AF Flow"
# The status is captured rather than piped away. `cmd | sed` reports SED's exit
# status and this script has no `set -e`, so the earlier version printed the
# check's text and threw its verdict on the floor while its own comment claimed
# the session start "goes red". Nothing here can abort a session start, so the
# verdict is stated in a line a reader cannot miss instead.
SYSTEM_LIST_OUT=$(python3 scripts/system-list-check.py 2>&1)
SYSTEM_LIST_STATUS=$?
printf '%s\n' "$SYSTEM_LIST_OUT" | sed -n '3,$p'
case "$SYSTEM_LIST_STATUS" in
    0) : ;;
    2) echo ">>> COULD NOT CHECK. An unreadable database is not a clean one." ;;
    *) echo ">>> ACT ON THIS. A system list is showing something it should not." ;;
esac

echo
echo "### Does the firewall still hold an Allow-any for the family"
# Same discipline as the check above. Exit 2 means the rules database could not
# be read or decoded, which is NOT the same answer as "no bad rules": a firewall
# database that cannot be read is not a clean one. Three Allow any:any rules sat
# here for five weeks in 2026 with nothing looking.
LULU_OUT=$(python3 scripts/lulu-rule-check.py 2>&1)
LULU_STATUS=$?
printf '%s\n' "$LULU_OUT" | sed -n '3,$p'
case "$LULU_STATUS" in
    0) : ;;
    2) echo ">>> COULD NOT CHECK. An unreadable rules database is not a clean one." ;;
    *) echo ">>> ACT ON THIS. His firewall is not backstopping this app." ;;
esac

echo
echo "### Does anything name his data folder by hand"
# Same discipline as the system list check above: capture the status rather
# than piping it into sed, which would report SED's exit code. A finding here
# means a script or a call site can be pointed at an empty folder by a rename,
# which is how the probe above went blind on 2026-08-25.
PATH_CHECK_OUT=$(python3 scripts/app-support-path-check.py 2>&1)
PATH_CHECK_STATUS=$?
printf '%s\n' "$PATH_CHECK_OUT" | sed -n '3,$p'
case "$PATH_CHECK_STATUS" in
    0) : ;;
    2) echo ">>> COULD NOT CHECK. A source that cannot be read is not a clean one." ;;
    *) echo ">>> ACT ON THIS. A rename can silently orphan his data through these lines." ;;
esac

echo
echo "### Do the two files describing the build agree"
# Added 2026-08-30, when the answer was no. There is no xcodegen here, so the
# pbxproj is the truth and project.yml is what everyone reads; they had drifted
# on the hardened runtime. A distribution build is decided by settings nobody
# looks at, so they are looked at here, every session, in under a second.
BUILD_CONFIG_OUT=$(python3 scripts/build-config-check.py 2>&1)
BUILD_CONFIG_STATUS=$?
printf '%s\n' "$BUILD_CONFIG_OUT" | sed -n '2,$p'
case "$BUILD_CONFIG_STATUS" in
    0) : ;;
    2) echo ">>> COULD NOT CHECK. A project file that cannot be read is not a clean one." ;;
    *) echo ">>> ACT ON THIS. The build Andrew ships is configured by these lines." ;;
esac

echo
echo "### Does anything type for him, or listen with a tap that could modify?"
# Added 2026-09-09. Two properties no compiler or test notices being broken:
# nothing posts a synthetic event, and every tap is .listenOnly. The first is
# his product decision of 2026-08-05 and the second is what keeps the app
# inside the sandbox, which is what keeps the Mac App Store reachable.
SYNTHETIC_OUT=$(python3 scripts/no-synthetic-events-check.py 2>&1)
SYNTHETIC_STATUS=$?
printf '%s\n' "$SYNTHETIC_OUT"
case "$SYNTHETIC_STATUS" in
    0) : ;;
    2) echo ">>> COULD NOT CHECK. Source that cannot be read is not source that is clean." ;;
    *) echo ">>> ACT ON THIS. This decides both his paste behaviour and App Store eligibility." ;;
esac

echo
echo "### Does every spec line say who decided it"
python3 scripts/spec-provenance-check.py 2>&1

echo
echo "======================================================================"
echo " Now read STATE.md. Do NOT read PROGRESS.md whole."
echo ""
echo "   grep -n '^## ' PROGRESS.md      dated table of contents"
echo "   sed -n 'START,ENDp' PROGRESS.md read only that section"
echo ""
echo " Files never to read whole (see CLAUDE.md hard rule 10):"
for f in AFFlow/UI/MeetingTranscriptWindow.swift AFFlow/UI/SettingsWindow.swift AFFlow/AppState.swift; do
    [ -f "$f" ] && printf "   %-52s %5s KB\n" "$f" "$(( $(wc -c < "$f") / 1024 ))"
done
echo "======================================================================"
