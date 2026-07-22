#!/bin/bash
# Publishes a short AF Flow status to iCloud Drive so Andrew can read it on his
# phone. Run at every checkpoint.
#
# WHY THIS EXISTS. Local Claude Code sessions do not appear in the mobile app;
# they are files on this Mac and the app lists cloud sessions. So the session
# itself can never be on his phone. What he actually wanted was to see where the
# project stands, and that is a much smaller thing to move.
#
# WHAT LEAVES THE MAC, stated precisely because this project's whole premise is
# that nothing does: only the delimited MOBILE STATUS block from PROGRESS.md.
# That block is derived status, no transcripts, no audio, no dictation. The
# corpus stays in ~/Prototypes/af-flow-private/ and never goes near iCloud.
#
# Single source of truth on purpose: the block lives in PROGRESS.md and is
# copied, never retyped, so the phone cannot show something the repo disagrees
# with.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SOURCE="PROGRESS.md"
TARGET="$HOME/Library/Mobile Documents/com~apple~CloudDocs/AF Flow Status.md"

if [ ! -d "$(dirname "$TARGET")" ]; then
    echo "iCloud Drive is not available at $(dirname "$TARGET")" >&2
    exit 1
fi

block=$(awk '/<!-- MOBILE STATUS START -->/{flag=1; next} /<!-- MOBILE STATUS END -->/{flag=0} flag' "$SOURCE")

if [ -z "$block" ]; then
    echo "No MOBILE STATUS block found in $SOURCE. Nothing published." >&2
    exit 2
fi

{
    echo "# AF Flow"
    echo
    echo "$block"
    echo
    echo "---"
    echo "Updated $(date '+%Y-%m-%d %H:%M'). Derived status only; no dictation content."
} > "$TARGET"

echo "published to: $TARGET"
echo "readable on the phone in Files, iCloud Drive, as 'AF Flow Status'"
