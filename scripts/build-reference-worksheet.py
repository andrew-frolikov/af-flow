#!/usr/bin/env python3
"""Turn captured transcripts into a correction worksheet for Andrew.

WHY THIS EXISTS. The fixture workflow needs a reference text that says exactly
what he said, and only he can produce it. The naive way is to hand him one
model's draft and ask him to fix it, which has two problems. It is slow,
because he has to re-read every word to find the few that are wrong. And it is
biased, because whatever he does not notice stays in the reference, quietly
rigging the comparison in favour of whichever engine wrote the draft.

Several independent engines transcribed the same audio. Where they all agree,
the text is almost certainly right and he can skim it. Where they disagree is
exactly where his ear is needed, and that is a small fraction of the words. So
this prints the agreed text as a draft and lists only the disputed spots.

It never prints transcript content to a terminal that a session can read. It
writes files beside the audio and reports counts only. The content is his real
speech and the archive rules say it does not travel.

Usage:
    scripts/build-reference-worksheet.py <fixtures-dir>
"""

import difflib
import json
import re
import sys
from pathlib import Path

WORD = re.compile(r"\w+(?:'\w+)?|[^\w\s]", re.UNICODE)


def tokenize(text):
    return WORD.findall(text)


def fold(token):
    """Compare tokens the way the scorer does: case-blind, yo folded to ye.

    Without this the worksheet flags a capital letter as a disagreement
    needing his ear, when casing is measured separately and is a cleanup
    concern rather than a transcription one. That would bury the real
    disagreements in noise, which is the failure this script exists to avoid.
    """
    return token.lower().replace("ё", "е")


def most_central(hypotheses):
    """The spine is the transcript closest to all the others.

    Deliberately not "the default model's output" and not the incumbent's.
    Either choice would make one engine the yardstick for the reference that
    then scores it, which is the bias this whole approach exists to remove.
    """
    best, best_cost = None, None
    for candidate in hypotheses:
        cost = 0
        a = [fold(t) for t in tokenize(candidate["hypothesis"])]
        for other in hypotheses:
            if other is candidate:
                continue
            b = [fold(t) for t in tokenize(other["hypothesis"])]
            matcher = difflib.SequenceMatcher(None, a, b, autojunk=False)
            cost += len(a) + len(b) - 2 * sum(block.size for block in matcher.get_matching_blocks())
        if best_cost is None or cost < best_cost:
            best, best_cost = candidate, cost
    return best


def disagreements(spine, others):
    """Spans of the spine where at least one other engine heard something else.

    Returned as (start, end, {label: alternative}) over spine token indices.
    """
    spine_tokens = tokenize(spine["hypothesis"])
    folded_spine = [fold(t) for t in spine_tokens]
    spans = {}

    for other in others:
        other_tokens = tokenize(other["hypothesis"])
        matcher = difflib.SequenceMatcher(
            None, folded_spine, [fold(t) for t in other_tokens], autojunk=False
        )
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag == "equal":
                continue
            label = f"{other['model']} [{other['language']}]"
            heard = " ".join(other_tokens[j1:j2]) or "(nothing)"
            spans.setdefault((i1, i2), {})[label] = heard

    return sorted(spans.items())


def render(stem, spine, entries, spans):
    spine_tokens = tokenize(spine["hypothesis"])
    lines = [
        f"# Correction worksheet: {stem}",
        "",
        "HOW TO USE THIS",
        "",
        "1. Read the DRAFT below and edit it into exactly what you said, including",
        "   any fillers. It is what you said, not what you wish you had said, and",
        "   not the cleaned-up version you would want pasted.",
        "2. The DISPUTED SPOTS list is where the engines disagreed with each other.",
        "   Those are the places worth your ear. Everywhere else they agreed, so it",
        "   is very likely already correct.",
        f"3. Save the corrected draft as {stem}.reference.txt in this same folder.",
        "",
        f"Engines compared: {len(entries)}. Disputed spots: {len(spans)}.",
        f"Draft spine: {spine['model']} [{spine['language']}], chosen as the transcript",
        "closest to all the others rather than by which engine we favour.",
        "",
        "## DRAFT",
        "",
        spine["hypothesis"].strip(),
        "",
        "## DISPUTED SPOTS",
        "",
    ]

    if not spans:
        lines.append("None. Every engine produced the same words, so the draft above needs")
        lines.append("only a read-through rather than a correction pass.")
    else:
        for number, ((start, end), heard_by) in enumerate(spans, 1):
            before = " ".join(spine_tokens[max(0, start - 6):start])
            disputed = " ".join(spine_tokens[start:end]) or "(nothing)"
            after = " ".join(spine_tokens[end:end + 6])
            lines.append(f"{number}. ...{before}  >>> {disputed} <<<  {after}...")
            for label, heard in sorted(heard_by.items()):
                lines.append(f"      {label} heard: {heard}")
            lines.append("")

    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    fixtures = Path(sys.argv[1]).expanduser()
    if not fixtures.is_dir():
        print(f"not a directory: {fixtures}", file=sys.stderr)
        return 1

    written = 0
    for path in sorted(fixtures.glob("*.hypotheses.json")):
        stem = path.name[: -len(".hypotheses.json")]

        if (fixtures / f"{stem}.reference.txt").exists():
            print(f"{stem}: reference already corrected, skipping")
            continue

        entries = [e for e in json.loads(path.read_text()) if e.get("hypothesis", "").strip()]
        if not entries:
            print(f"{stem}: no usable transcripts")
            continue
        if len(entries) == 1:
            print(f"{stem}: only 1 transcript, so nothing can be cross-checked. "
                  "Correct it with full attention rather than skimming.")

        spine = most_central(entries)
        others = [e for e in entries if e is not spine]
        spans = disagreements(spine, others)

        (fixtures / f"{stem}.worksheet.md").write_text(render(stem, spine, entries, spans))
        (fixtures / f"{stem}.draft-reference.txt").write_text(spine["hypothesis"].strip() + "\n")

        agreement = ""
        total = len(tokenize(spine["hypothesis"]))
        if total:
            disputed = sum(max(1, end - start) for (start, end), _ in spans)
            agreement = f", engines agree on about {100 * (1 - min(disputed, total) / total):.0f}% of words"
        print(f"{stem}: {len(entries)} transcripts, {len(spans)} disputed spots{agreement}")
        written += 1

    print(f"\n{written} worksheet(s) written to {fixtures}")
    print("Content stays in those files and is deliberately not printed here.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
