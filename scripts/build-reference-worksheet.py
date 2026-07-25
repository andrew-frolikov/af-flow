#!/usr/bin/env python3
"""Turn captured transcripts into a correction worksheet for Andrew.

WHY THIS EXISTS. The fixture workflow needs a reference text that says exactly
what he said, and only he can produce it. The naive way is to hand him one
model's draft and ask him to fix it, which has two problems. It is slow,
because he has to re-read every word to find the few that are wrong. And it is
biased, because whatever he does not notice stays in the reference, quietly
rigging the comparison in favour of whichever engine wrote the draft.

Several independent engines transcribed the same audio, so where they disagree
is where his ear is most needed, and this prints those spans explicitly.

WHAT THIS DOES NOT DO, corrected 2026-07-24 after an audit found the earlier
claim was not just unearned but backwards. This used to tell him that where the
engines agree "it is very likely already correct" and that he could skim it.
Six of the engine rows are Whisper-family. Where they share a mistake they
agree, the span is never flagged, and the shared mistake is presented to him as
consensus. So the disputed list finds DISAGREEMENT and is structurally blind to
a wrong CONSENSUS, which is the one error that a majority vote cannot catch and
that then becomes the answer key.

Worse, the spans are computed against a spine that is one engine's verbatim
output, and on the real fixtures that spine is the app's current default model
on three clips of five. Every word he did not change was therefore about to be
scored against text that model wrote itself.

The worksheet now asks him to read the whole draft. The disputed list is a
priority order for his attention, not a permission to skip the rest.

It never prints transcript content to a terminal that a session can read. It
writes files beside the audio and reports counts only. The content is his real
speech and the archive rules say it does not travel.

Usage:
    scripts/build-reference-worksheet.py <fixtures-dir> [--force]

    --force regenerates a draft he has already edited. Without it, an edited
    draft is left alone, because that text exists nowhere else.
"""

import difflib
import hashlib
import json
import re
import sys
from pathlib import Path

WORD = re.compile(r"\w+(?:'\w+)?|[^\w\s]", re.UNICODE)


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


CYRILLIC = re.compile(r"[Ѐ-ӿ]")
LATIN = re.compile(r"[A-Za-z]")


def cyrillic_ratio(text):
    c, l = len(CYRILLIC.findall(text)), len(LATIN.findall(text))
    return c / (c + l) if (c + l) else 0.0


def drop_wrong_script(entries):
    """Remove transcripts that are not even in the right alphabet.

    Found necessary on the first real run: whisper turbo 954 with language
    auto-detect returned Latin script for Russian audio on most clips, a
    language-identification failure rather than a transcription one. Averaging
    such a transcript into the disagreement set marks every single word as
    disputed, which turns a worksheet meant to save Andrew time into one that
    wastes it.

    Deliberately compared against the majority of the other engines rather than
    against a hardcoded expectation, so this stays correct for an English
    fixture too.
    """
    if len(entries) < 3:
        return entries, []
    ratios = sorted(cyrillic_ratio(e["hypothesis"]) for e in entries)
    majority = ratios[len(ratios) // 2]
    keep, dropped = [], []
    for entry in entries:
        if abs(cyrillic_ratio(entry["hypothesis"]) - majority) > 0.4:
            dropped.append(entry)
        else:
            keep.append(entry)
    return (keep, dropped) if keep else (entries, [])


def dedupe_opinions(entries):
    """Collapse engines that produced BYTE-IDENTICAL text into one voter.

    Measured on the real fixtures 2026-07-24: Parakeet v3 and Qwen3-ASR return
    exactly the same string in `auto` and in `ru` on all five clips, because
    the FluidAudio backend ignores the language argument entirely. Whisper does
    respond to it. So "Engines compared: 9" counted two engines twice and
    described a comparison that does not exist.

    It also corrupted the disagreement threshold, which requires two dissenters
    before a span is worth Andrew's attention. A lone dissent from Parakeet
    arrived as two identical votes and cleared the bar by itself, so the
    "at least two engines" rule was not the rule being applied.

    Deliberately keyed on the exact text rather than on the backend, so this
    stays true if a future model starts honouring the language argument.
    """
    by_text = {}
    for entry in entries:
        by_text.setdefault(entry["hypothesis"], []).append(entry)
    opinions = []
    for group in by_text.values():
        primary = dict(group[0])
        primary["voters"] = [f"{e['model']} [{e['language']}]" for e in group]
        opinions.append(primary)
    return opinions


def opinion_label(entry):
    voters = entry.get("voters") or [f"{entry['model']} [{entry['language']}]"]
    if len(voters) == 1:
        return voters[0]
    return f"{voters[0]} (identical: {', '.join(voters[1:])})"


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
            label = opinion_label(other)
            heard = " ".join(other_tokens[j1:j2]) or "(nothing)"
            spans.setdefault((i1, i2), {})[label] = heard

    # A span needs at least two engines disagreeing with the spine before it is
    # worth Andrew's attention. One dissenter among eight is far more likely to
    # be that engine being wrong than the consensus being wrong, and flagging
    # every such case rebuilt exactly the read-every-word job this script
    # exists to avoid. A wrong consensus is still catchable: he reads the draft
    # itself, not only the disputed list.
    return sorted((span, heard) for span, heard in spans.items() if len(heard) >= 2)


def render(stem, spine, entries, spans, dropped=(), unflagged_share=None):
    spine_tokens = tokenize(spine["hypothesis"])
    marks = sum(1 for c in spine["hypothesis"] if c in ".,!?;:…")
    terminators = sum(1 for c in spine["hypothesis"] if c in ".!?…")
    lines = [
        f"# Correction worksheet: {stem}",
        "",
        "HOW TO USE THIS",
        "",
        "1. Play the audio and read the WHOLE draft against it. Correct every word",
        "   that is wrong, not only the ones listed under DISPUTED SPOTS.",
        "",
        "   This instruction changed on 2026-07-24 and the reason matters. The draft",
        "   below is ONE engine's output verbatim. Anything you do not change stays",
        "   in the reference, and that engine is then scored against text it wrote",
        "   itself, so it scores near zero on those words by construction. Six of",
        "   the engine rows are Whisper-family, so where they share a mistake they",
        "   AGREE, the span is never flagged, and the shared mistake becomes the",
        "   answer key. The disputed list finds disagreement; it cannot find a wrong",
        "   consensus. Only your ear can.",
        "",
        "2. WORDS: exactly what you said, fillers included. Not what you wish you",
        "   had said, and not the cleaned-up version you would want pasted.",
        "",
        "3. PUNCTUATION: place full stops, question marks and commas where written",
        "   Russian would have them. This is scored, and right now the draft's",
        "   punctuation is that one engine's guess rather than anything you said.",
        f"   This draft has {marks} punctuation mark(s) and {terminators} sentence",
        "   ending(s) across "
        f"{len(spine['hypothesis'].split())} words."
        + ("  <-- almost certainly too few; the models under-punctuate Russian badly"
           if terminators <= max(1, len(spine["hypothesis"].split()) // 40) else ""),
        "",
        f"4. Save the corrected text as {stem}.reference.txt in this same folder.",
        "   Leave the .draft-reference.txt file alone; it is regenerated.",
        "",
        f"Independent engine opinions compared: {len(entries)}. Disputed spots: {len(spans)}.",
        *([f"Not flagged as disputed: {unflagged_share:.0f}% of the words. That is not a",
           "claim that they are correct, only that the engines agreed about them."]
          if unflagged_share is not None else []),
        *([f"EXCLUDED as wrong-alphabet output, a language-detection failure rather",
           f"than a transcription one: " + ", ".join(opinion_label(e) for e in dropped)]
          if dropped else []),
        f"Draft spine: {opinion_label(spine)}, chosen as the transcript",
        "closest to all the others rather than by which engine we favour. It is",
        "still one engine's text, which is what step 1 is about.",
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
    positional = [a for a in sys.argv[1:] if not a.startswith("--")]
    unknown = [a for a in sys.argv[1:] if a.startswith("--") and a != "--force"]
    if len(positional) != 1 or unknown:
        if unknown:
            print(f"unknown option(s): {' '.join(unknown)}\n", file=sys.stderr)
        print(__doc__)
        return 2

    fixtures = Path(positional[0]).expanduser()
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

        # Discard transcripts produced from DIFFERENT audio. Re-recording a clip
        # under the same stem would otherwise build a worksheet, and then a
        # reference, describing speech that is no longer there. Codex round 3.
        audio = next((fixtures / f"{stem}{ext}" for ext in (".wav", ".m4a", ".mp3", ".caf", ".aiff")
                      if (fixtures / f"{stem}{ext}").exists()), None)
        if audio is not None:
            actual = file_sha256(audio)
            fresh = [e for e in entries if e.get("fixtureSHA") == actual]
            if len(fresh) != len(entries):
                print(f"{stem}: ignored {len(entries) - len(fresh)} transcript(s) from different or unhashed audio")
            entries = fresh
        if not entries:
            print(f"{stem}: no transcripts matching the current audio, nothing to build")
            continue
        if not entries:
            print(f"{stem}: no usable transcripts")
            continue
        if len(entries) == 1:
            print(f"{stem}: only 1 transcript, so nothing can be cross-checked. "
                  "Correct it with full attention rather than skimming.")

        raw_count = len(entries)
        entries, dropped = drop_wrong_script(entries)
        entries = dedupe_opinions(entries)
        dropped = dedupe_opinions(dropped) if dropped else []
        spine = most_central(entries)
        others = [e for e in entries if e is not spine]
        spans = disagreements(spine, others)

        # Count each disputed token once. Summing span widths double-counted
        # overlapping spans and could exceed the token count, which is why the
        # first run reported a meaningless "0% agreement".
        total = len(tokenize(spine["hypothesis"]))
        touched = set()
        for (start, end), _ in spans:
            touched.update(range(start, max(end, start + 1)))
        unflagged = 100 * (1 - len(touched) / total) if total else None

        # Never clobber text he has already edited. The draft is regenerable by
        # definition, but only while it still IS the generated text: once he has
        # typed into it, overwriting is destroying work that exists nowhere else.
        draft_path = fixtures / f"{stem}.draft-reference.txt"
        fresh_draft = spine["hypothesis"].strip() + "\n"
        if draft_path.exists() and draft_path.read_text() != fresh_draft and "--force" not in sys.argv:
            print(f"{stem}: draft has been EDITED since it was generated. Leaving it alone.")
            print("        Re-run with --force to discard those edits and regenerate.")
            continue

        (fixtures / f"{stem}.worksheet.md").write_text(
            render(stem, spine, entries, spans, dropped, unflagged)
        )
        draft_path.write_text(fresh_draft)

        agreement = f", {unflagged:.0f}% of words not flagged" if unflagged is not None else ""
        note = f", {len(dropped)} dropped for wrong script" if dropped else ""
        collapsed = raw_count - len(entries) - len(dropped)
        dedup = f", {collapsed} collapsed as identical" if collapsed > 0 else ""
        print(f"{stem}: {len(entries)} independent opinions{note}{dedup}, "
              f"{len(spans)} disputed spots{agreement}")
        written += 1

    print(f"\n{written} worksheet(s) written to {fixtures}")
    print("Content stays in those files and is deliberately not printed here.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
