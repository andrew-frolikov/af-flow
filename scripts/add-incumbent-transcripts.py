#!/usr/bin/env python3
"""Add Wispr Flow's own transcript of each fixture clip, so the incumbent is scored too.

WHY. Every clip in the archive carries the transcript Wispr produced from that
exact audio, in `asrText`. Without it, C2 answers "which of four local models
is best", which is interesting. With it, C2 answers "does AF Flow beat the app
it is replacing, on Andrew's own voice", which is the question that actually
decides whether the project has succeeded. The 2026-07-19 extraction raised
this as its first C1 recommendation and it was unanswerable until the archive
existed.

The incumbent's row is marked `source: incumbent` so a re-capture of the local
models preserves it rather than overwriting it, and so nobody later mistakes a
cloud transcript for something this app produced.

Fair-comparison caveat, recorded rather than hidden: the `seconds` field for
the incumbent is Wispr's own end-to-end latency, which includes a network round
trip to a remote model and is not measured the same way as a local model's
wall-clock transcription time. Treat the incumbent's speed column as indicative
only. Its ACCURACY columns are directly comparable, because they are computed
from the same audio against the same reference.

Usage:
    scripts/add-incumbent-transcripts.py <fixtures-dir> <history.json>
"""

import json
import pathlib
import sys


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    fixtures = pathlib.Path(sys.argv[1]).expanduser()
    history = json.load(open(sys.argv[2]))

    by_id = {row["transcriptEntityId"]: row for row in history if row.get("transcriptEntityId")}

    added = 0
    missing = []
    for audio in sorted(fixtures.glob("*.wav")):
        stem = audio.stem
        # Filenames are <language>-<date>-<first 8 of transcriptEntityId>.wav
        fragment = stem.split("-")[-1]
        matches = [row for key, row in by_id.items() if key.startswith(fragment)]

        if len(matches) != 1:
            missing.append(f"{stem}: {len(matches)} rows matched id fragment {fragment!r}")
            continue

        row = matches[0]
        transcript = (row.get("asrText") or "").strip()
        if not transcript:
            missing.append(f"{stem}: matched a row but its asrText is empty")
            continue

        target = fixtures / f"{stem}.hypotheses.json"
        entries = json.loads(target.read_text()) if target.exists() else []
        entries = [e for e in entries if e.get("source") != "incumbent"]

        entries.append({
            "model": "Wispr Flow (cloud incumbent)",
            "modelID": "wispr-qwen-http",
            "language": "ru",
            "hypothesis": transcript,
            # Milliseconds in the archive. See the caveat in the docstring:
            # this is end-to-end including a network round trip, so it is not
            # comparable with a local model's transcription wall clock.
            "seconds": round((row.get("e2eLatency") or 0) / 1000.0, 3),
            "audioDuration": row.get("duration") or 0,
            "source": "incumbent",
        })

        target.write_text(json.dumps(entries, indent=2, sort_keys=True, ensure_ascii=False))
        added += 1

    print(f"added the incumbent transcript to {added} clip(s)")
    for line in missing:
        print(f"  NOT ADDED  {line}")
    if missing:
        print("\nA clip without an incumbent row still scores against the local models;")
        print("it just cannot answer the beat-the-incumbent question.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
