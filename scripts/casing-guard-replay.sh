#!/bin/bash
# Run the casing guard against adversarial shapes built from Andrew's own archive.
#
# WHY THIS EXISTS. Replaying the guard over his archive proves what happened on
# the population that archive holds, and nothing about the population it lacks.
# Measured 2026-08-24: across the 50 archived dictations the raw punctuation
# inventory is `. , ? ' - %` — no quotes, brackets, guillemets, dashes or
# newlines, no `period + punctuation + word`, and no lowercase-initial-with-a-
# later-capital tokens in 1,835. All three defects found in review were invisible
# to a plain replay, and a clean replay was compatible with every one of them
# being live.
#
# So this synthesises the missing shapes FROM HIS OWN TRANSCRIPTIONS — his
# vocabulary, his languages, his sentence boundaries — and runs the real Swift
# function over them, not a re-implementation that can drift.
#
# His transcripts are never committed. This reads the live archive in place and
# prints counts only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ARCHIVE="${AF_FLOW_LAB_ARCHIVE:-$HOME/Library/Containers/com.frolikov.afflow/Data/Library/Application Support/GhostPepper/transcription-lab/transcription-lab-index.jsonl}"
if [ ! -f "$ARCHIVE" ]; then
    echo "no archive at: $ARCHIVE" >&2
    exit 1
fi
echo "archive: $ARCHIVE ($(wc -l < "$ARCHIVE" | tr -d ' ') entries)"

AF_FLOW_LAB_ARCHIVE="$ARCHIVE" AF_FLOW_RAW_OUTPUT=1 \
    ./scripts/run-tests.sh -only-testing:GhostPepperTests/CasingGuardAdversarialReplay 2>&1 \
    | grep -E "ADVERSARIAL-REPLAY|Test Case.*(failed|passed)|Executed [0-9]+ tests|was skipped|error:"
