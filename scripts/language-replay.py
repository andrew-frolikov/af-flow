#!/usr/bin/env python3
"""Apply the OLD and NEW language rules to his real recordings, and diff them.

Observability item 4, the reading half. `LanguageReplayTests` runs WhisperKit's
language detector over his 50 saved dictations once and writes the RAW return
for each; this applies both rule sets to that record offline.

The split matters. Detection is the expensive part and it depends only on the
audio, so it runs once. **Both rules are pure functions of the detector's
output**, so comparing them is free and stays free: change a rule tomorrow and
re-run this in a second, with no model and no audio.

THE TWO RULES, as they actually shipped.

OLD, before 2026-08-02. `chooseLanguage(from:)` guarded on
`english > 0 || russian > 0`. WhisperKit returns LOG probabilities, so every
value is negative and that gate could never fire; the function returned nil on
every dictation he ever made, and `decodeOptions.detectLanguage = true` then
handed the decode to unrestricted detection across 99 languages. So the old
answer is simply whatever Whisper reported, whatever language that is. That is
how `raw: ur` pasted Arabic script into his document on 2026-07-31.

NEW, ratified 2026-08-02. `restrictedLanguage(probabilities:reportedLanguage:)`:
en and ru are the only possible answers, always. Both scored, the measured
887-to-332 prior decides; one scored, the winner is trusted; neither scored, a
supported reported language wins, else the prior, and English takes it.

This reports what CHANGED, not what is correct. Neither `asrText` nor
`editedText` is ground truth for the Russian clips (ledger item 3), so the
honest output is a diff plus the cases worth his eye, not an accuracy score.
"""

import json
import os
import sys

ENGLISH_PRIOR = 887.0
RUSSIAN_PRIOR = 332.0
SUPPORTED = ("en", "ru")

DEFAULT = os.path.expanduser(
    "~/Library/Containers/com.frolikov.afflow.testhost/Data/Library/"
    "Application Support/GhostPepper/replay/detections.jsonl"
)


def old_rule(probs, reported):
    """Whatever Whisper said. The gate in front of this could never fire."""
    return reported


def new_rule(probs, reported):
    """A transcription of `ModelManager.restrictedLanguage`."""
    english = probs.get("en")
    russian = probs.get("ru")

    if english is not None and russian is not None:
        # Both scored: the measured prior weighs them. WhisperKit does not
        # currently produce this shape; it is kept because it is correct if it
        # ever does.
        return "en" if english * ENGLISH_PRIOR >= russian * RUSSIAN_PRIOR else "ru"
    if english is not None:
        return "en"
    if russian is not None:
        return "ru"
    if reported and reported.lower() in SUPPORTED:
        return reported.lower()
    return "en" if ENGLISH_PRIOR >= RUSSIAN_PRIOR else "ru"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    if not os.path.exists(path):
        print("language-replay")
        print("=" * 15)
        print("no detections at %s" % path)
        print()
        print("stage the inputs and run the replay first:")
        print("  ./scripts/stage-language-replay.sh")
        print("  AF_FLOW_LANGUAGE_REPLAY=1 ./scripts/run-tests.sh \\")
        print("      -only-testing:GhostPepperTests/LanguageReplayTests")
        return 0

    rows = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue

    print("language-replay")
    print("=" * 15)
    print("%d recordings replayed through language detection" % len(rows))
    print()

    failed = [r for r in rows if r.get("error")]
    usable = [r for r in rows if not r.get("error")]

    changed, third_language, agreed = [], [], 0
    for row in usable:
        probs = row.get("probs") or {}
        reported = row.get("language")
        old = old_rule(probs, reported)
        new = new_rule(probs, reported)
        if old and old.lower() not in SUPPORTED:
            third_language.append((row, old, new))
        if (old or "").lower() != (new or "").lower():
            changed.append((row, old, new))
        else:
            agreed += 1

    print("## what the OLD rule would have decoded as a third language")
    print("   Each is a dictation that came back in a language he does not speak.")
    if third_language:
        for row, old, new in third_language:
            print("  %-40s %5.1fs  old=%-4s new=%-3s  text=%s"
                  % (row["file"][:40], row["duration"], old, new,
                     "yes" if row["hadText"] else "NONE"))
    else:
        print("  none in this sample")
    print()

    print("## where the two rules disagree (%d of %d)" % (len(changed), len(usable)))
    for row, old, new in changed[:25]:
        print("  %-40s %5.1fs  old=%-4s new=%-3s  n=%d"
              % (row["file"][:40], row["duration"], old, new, row.get("n", 0)))
    if len(changed) > 25:
        print("  ... and %d more" % (len(changed) - 25))
    print()

    print("## shape of the detector's output, over his real audio")
    ns = {}
    positives = 0
    for row in usable:
        ns[row.get("n", 0)] = ns.get(row.get("n", 0), 0) + 1
        positives += sum(1 for v in (row.get("probs") or {}).values() if v > 0)
    for n in sorted(ns):
        print("  %d language(s) scored: %d recording(s)" % (n, ns[n]))
    print("  positive scores anywhere in the sample: %d" % positives)
    if positives == 0:
        print("    confirms log probabilities: any `score > 0` gate is dead code.")
    print()

    if failed:
        print("## detection did not run (%d)" % len(failed))
        for row in failed:
            print("  %-40s %5.1fs  %s" % (row["file"][:40], row["duration"], row["error"]))
        print()

    print("agreed: %d   disagreed: %d   not run: %d" % (agreed, len(changed), len(failed)))
    print()
    print("RESULT: the new rule changes the answer on %d of %d recordings, and removes"
          % (len(changed), len(usable)))
    print("        %d third-language decode(s). Neither transcript is ground truth"
          % len(third_language))
    print("        (ledger item 3), so this is a diff, not an accuracy score.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
