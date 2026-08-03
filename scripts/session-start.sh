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
echo "======================================================================"
echo " Now read STATE.md. Do NOT read PROGRESS.md whole."
echo ""
echo "   grep -n '^## ' PROGRESS.md      dated table of contents"
echo "   sed -n 'START,ENDp' PROGRESS.md read only that section"
echo ""
echo " Files never to read whole (see CLAUDE.md hard rule 10):"
for f in GhostPepper/UI/MeetingTranscriptWindow.swift GhostPepper/UI/SettingsWindow.swift GhostPepper/AppState.swift; do
    [ -f "$f" ] && printf "   %-52s %5s KB\n" "$f" "$(( $(wc -c < "$f") / 1024 ))"
done
echo "======================================================================"
