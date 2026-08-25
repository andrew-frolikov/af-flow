#!/usr/bin/env python3
"""Check the app's assumptions about WhisperKit against what it actually emits.

Observability item 2, the reading half. `ModelManager.rawDetectionCensus` writes
one `RAW detectLanguage {...}` line per dictation recording the model's return
BEFORE this app interprets it; this reads them back and states which of the
code's assumptions the runtime agrees with.

WHY A CENSUS AND NOT A TEST. A test asserts a shape someone already believed.
The language prior had six of them, all green, all feeding linear probabilities
that production has never once produced, while `chooseLanguage(from:)` returned
nil on every dictation Andrew had ever made. Nothing was wrong with the tests
except that they and the code shared an assumption, and no test can catch that.
Only the runtime can, and only if someone writes down what it emitted.

So this asserts nothing about correctness. It reports distributions, and it
flags where a distribution contradicts something the code relies on.
"""

import json
import os
import sys
from collections import Counter

BUNDLE_ID = "com.frolikov.afflow"
LOG = os.path.expanduser(
    "~/Library/Containers/%s/Data/Library/Application Support/AFFlow/debug-log.jsonl"
    % BUNDLE_ID
)
PREFIX = "RAW detectLanguage "


def log_path():
    """An explicit path may be passed, so this can be exercised against a
    fixture. A reader nobody has run on real-shaped data is worth as little as
    the interpretation-only logging it replaces."""
    return sys.argv[1] if len(sys.argv) > 1 else LOG


def load():
    rows = []
    LOG = log_path()
    if not os.path.exists(LOG):
        return rows, "missing"
    with open(LOG, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                # One unreadable line costs that line. The whole point of the
                # JSONL move was that it cannot cost the file.
                continue
            message = entry.get("message", "")
            if not message.startswith(PREFIX):
                continue
            try:
                rows.append(json.loads(message[len(PREFIX):]))
            except ValueError:
                continue
    return rows, "ok"


def main():
    rows, status = load()
    print("model-shape-census")
    print("=" * 18)
    if status == "missing":
        print("no debug log at %s" % log_path())
        return 0
    if not rows:
        print("no census lines yet. They are written on each dictation from the")
        print("build of 2026-08-03 onward; make a few dictations and re-run.")
        return 0

    print("%d language detections recorded" % len(rows))
    print()

    counts = Counter(r["n"] for r in rows)
    positive = Counter(r["positive"] for r in rows)
    unscored = [r for r in rows if not r.get("reportedIsScored")]
    langs = Counter(r["language"] for r in rows if r.get("language"))
    all_values = [v for r in rows for v in r.get("probs", {}).values()
                  if isinstance(v, (int, float))]

    print("## how many languages are scored per call")
    for n, c in sorted(counts.items()):
        print("  n=%-3d %d call(s)" % (n, c))
    print()

    print("## sign of the scores")
    for p, c in sorted(positive.items()):
        print("  %d positive value(s): %d call(s)" % (p, c))
    if all_values:
        print("  range: %.6f to %.6f" % (min(all_values), max(all_values)))
    print()

    print("## which language whisper reported")
    for lang, c in langs.most_common():
        print("  %-6s %d" % (lang, c))
    print()

    print("## ASSUMPTIONS THE CODE RELIES ON")
    problems = 0

    # The gate that shipped read `english > 0 || russian > 0`. If nothing is ever
    # positive, that gate could never fire, which is the whole 2026-08-02 story.
    if all_values and max(all_values) <= 0:
        print("  CONFIRMED  every score is <= 0, so these are LOG probabilities.")
        print("             any comparison of the form `score > 0` is dead code.")
    elif all_values:
        print("  CHANGED    a positive score appeared. These may not be log")
        print("             probabilities any more; re-read restrictedLanguage.")
        problems += 1

    if counts and max(counts) <= 1:
        print("  CONFIRMED  the map never holds more than one entry, so a prior")
        print("             weighing en against ru can never be consulted.")
    elif counts:
        print("  CHANGED    a call scored %d languages at once. The two-sided"
              % max(counts))
        print("             prior path in restrictedLanguage is now reachable.")

    if unscored:
        print("  WARNING    %d call(s) reported a language with NO score for it"
              % len(unscored))
        for r in unscored[:5]:
            print("             language=%s probs=%s" % (r.get("language"), r.get("probs")))
        print("             this is the `raw: ur` shape that pasted Arabic script.")
        problems += 1
    else:
        print("  CONFIRMED  every reported language carried a score.")

    outside = sorted({r["language"] for r in rows
                      if r.get("language") not in ("en", "ru", None)})
    if outside:
        print("  WARNING    whisper reported languages outside en/ru: %s"
              % ", ".join(outside))
        print("             the restriction overrules these, so the DECODE is safe.")
        print("             it means the audio is being heard as a third language.")
    print()
    print("RESULT: %d contradiction(s) between the code's assumptions and the runtime"
          % problems)
    # Informational. A changed assumption is something to read, not a build break.
    return 0


if __name__ == "__main__":
    sys.exit(main())
