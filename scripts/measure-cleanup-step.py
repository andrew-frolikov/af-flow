#!/usr/bin/env python3
"""Measure what a cleanup model actually did to raw speech to text.

WHY THIS EXISTS. The Wispr extraction of 2026-07-19 measured the step where
Andrew corrected the cleaned text by hand, and found 126 genuine edits. It
never measured the step before it, where the cleanup model rewrote the raw
transcription, and it named that omission "the single largest missing piece of
evidence in the whole extraction". Every rule in cleanup-prompt-v1.md about
dropping words, merging sentences and stripping fillers was therefore written
against an unmeasured layer.

The archive has all three columns per row: asrText, formattedText, editedText.
So this measures the middle step directly, and it measures it on the incumbent,
which is the behaviour AF Flow's own cleanup has to beat rather than copy.

Two different questions, and they must not be collapsed:

  asrText     -> formattedText   what the cleanup model chose to change
  formattedText -> editedText    where Andrew judged it wrong

A change in the first that survives the second is cleanup Andrew accepted. A
change in the first that he reversed in the second is a cleanup defect with his
verdict attached, which is the strongest signal available anywhere in this data.

Prints aggregates only. No transcript content is ever printed, per the archive
handling rules.

Usage:
    scripts/measure-cleanup-step.py <path-to-history.json>
"""

import json
import re
import sys
from collections import Counter

WORD = re.compile(r"\w+", re.UNICODE)
SENTENCE_END = re.compile(r"[.!?]+")

# Words Andrew has said he wants removed as disfluency, kept deliberately
# short. The register rules in voice-observations.md are explicit that his
# discourse markers ("so", "and basically", "well") are NOT in this class.
FILLERS_EN = {"um", "uh", "erm", "hmm", "like"}
FILLERS_RU = {"э", "ну", "вот", "типа"}


def words(text):
    return WORD.findall((text or "").lower())


def edit_distance_within(a, b, limit):
    """True when a and b are at most `limit` single-character edits apart."""
    if abs(len(a) - len(b)) > limit:
        return False
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + (ca != cb),
            ))
        if min(current) > limit:
            return False
        previous = current
    return previous[-1] <= limit


def shared_prefix(a, b):
    length = 0
    for ca, cb in zip(a, b):
        if ca != cb:
            break
        length += 1
    return length


def survives(lost_word, candidate):
    """Is `candidate` plausibly the same word as `lost_word`, merely recast?

    Two tests, and the stem test is the one that matters for Russian: a noun
    whose case ending changed keeps its stem and would otherwise be counted as
    a deleted word on every single inflection fix.

    The stem test is PROPORTIONAL rather than a fixed prefix length, and that
    is not a detail. A flat four-character prefix rule excused "context"
    becoming "contacts", which is the exact sub-class voice-observations.md
    singles out as the hardest and least forgivable: two ordinary words, both
    real, where the substitution changes the meaning and no dictionary can fix
    it. The self-test caught it before any number was published. Requiring the
    shared stem to cover most of the shorter word keeps Russian inflection
    pairs together while holding those two apart.
    """
    shorter = min(len(lost_word), len(candidate))
    if shorter >= 4 and shared_prefix(lost_word, candidate) >= 0.7 * shorter:
        return True
    return edit_distance_within(lost_word, candidate, 2 if len(lost_word) > 5 else 1)


def sentences(text):
    return len([s for s in SENTENCE_END.split(text or "") if s.strip()])


def analyse(rows, language):
    rows = [r for r in rows if r.get("detectedLanguage") == language]
    usable = [
        r for r in rows
        if (r.get("asrText") or "").strip() and (r.get("formattedText") or "").strip()
    ]
    if not usable:
        return None

    stats = Counter()
    dropped_total = added_total = 0
    fillers = FILLERS_RU if language == "ru" else FILLERS_EN

    for row in usable:
        raw, clean = row["asrText"], row["formattedText"]
        raw_words, clean_words = words(raw), words(clean)

        if raw.strip() == clean.strip():
            stats["identical"] += 1
            continue
        stats["changed"] += 1

        if len(clean_words) < len(raw_words):
            stats["shorter"] += 1
            dropped_total += len(raw_words) - len(clean_words)
        elif len(clean_words) > len(raw_words):
            stats["longer"] += 1
            added_total += len(clean_words) - len(raw_words)
        else:
            stats["same_length"] += 1

        raw_sentences, clean_sentences = sentences(raw), sentences(clean)
        if clean_sentences > raw_sentences:
            stats["split_sentences"] += 1
        elif clean_sentences < raw_sentences:
            stats["merged_sentences"] += 1

        raw_fillers = sum(1 for w in raw_words if w in fillers)
        clean_fillers = sum(1 for w in clean_words if w in fillers)
        if clean_fillers < raw_fillers:
            stats["removed_filler"] += 1

        # Content words present in the raw transcription and absent afterwards,
        # ignoring the fillers we expect to lose. This is the no-drop rule's
        # actual evidence base, which has never been measured until now.
        #
        # The naive version of this, a plain Counter difference, is wrong and
        # inflates the result badly. A word that cleanup merely RECAST, fixing
        # a case ending or a spelling, disappears from the raw side and looks
        # identical to a word that was deleted outright. In Russian that is not
        # an edge case, it is most of what a cleanup pass does. The 2026-07-19
        # extraction was rightly criticised for publishing exactly this kind of
        # unvalidated heuristic as a measured rate, so the check below excludes
        # any lost word that has a plausible survivor on the cleaned side.
        lost = (Counter(raw_words) - Counter(clean_words))
        clean_set = set(clean_words)
        lost_content = {}
        for word, count in lost.items():
            if word in fillers or len(word) <= 2:
                continue
            if any(survives(word, candidate) for candidate in clean_set):
                stats["recast_not_dropped"] += 1
                continue
            lost_content[word] = count
        if lost_content:
            stats["lost_content_word"] += 1

        # Did Andrew then reverse the cleanup? Strongest signal in the data.
        edited = (row.get("editedText") or "").strip()
        if edited and edited != clean.strip():
            stats["andrew_edited_after"] += 1
            if set(words(edited)) & set(lost_content):
                stats["andrew_restored_a_dropped_word"] += 1

    return {"rows": len(usable), "stats": stats, "dropped": dropped_total, "added": added_total}


def report(label, result):
    if not result:
        print(f"\n{label}: no usable rows")
        return
    n, s = result["rows"], result["stats"]
    changed = s["changed"] or 1
    print(f"\n{label}: {n} rows with both a raw and a cleaned transcript")
    print(f"  cleanup changed nothing at all        {s['identical']:5d}  ({100*s['identical']/n:.1f}%)")
    print(f"  cleanup changed something             {s['changed']:5d}  ({100*s['changed']/n:.1f}%)")
    print(f"    of those, came out shorter          {s['shorter']:5d}  ({100*s['shorter']/changed:.1f}%)")
    print(f"    of those, came out longer           {s['longer']:5d}  ({100*s['longer']/changed:.1f}%)")
    print(f"    of those, same word count           {s['same_length']:5d}  ({100*s['same_length']/changed:.1f}%)")
    print(f"  net words removed across all rows     {result['dropped']:5d}")
    print(f"  net words added across all rows       {result['added']:5d}")
    print(f"  sentences SPLIT by cleanup            {s['split_sentences']:5d}")
    print(f"  sentences MERGED by cleanup           {s['merged_sentences']:5d}")
    print(f"  a filler was removed                  {s['removed_filler']:5d}")
    print(f"  a CONTENT word was lost outright      {s['lost_content_word']:5d}  ({100*s['lost_content_word']/n:.1f}% of rows)")
    print(f"    (excluded as recast, not dropped)   {s['recast_not_dropped']:5d}")
    print(f"  Andrew edited the result afterwards   {s['andrew_edited_after']:5d}")
    print(f"    and restored a word cleanup dropped {s['andrew_restored_a_dropped_word']:5d}")


def self_test():
    """The rule from LOOP.md: a check with logic of its own needs its own test
    in the same command, or the first thing to break silently is the thing
    meant to notice breakage. These cases are the ones a Russian transcript
    actually produces.
    """
    cases = [
        # (lost word, candidate on the cleaned side, should count as survived)
        ("приложения", "приложение", True),    # case ending changed, the whole point
        ("ответить", "ответь", True),          # verb form changed
        ("приблизились", "верились", False),   # different word, the defect we must catch
        ("context", "contacts", False),        # the hard sub-class, both real words
        ("хорошо", "хорошо", True),            # identical
        ("prompt", "prompts", True),           # plural
        ("wispr", "whisper", False),           # brand mangling must not be excused
        ("token", "moment", False),            # substitution
    ]
    failures = []
    for lost, candidate, expected in cases:
        actual = survives(lost, candidate)
        if actual != expected:
            failures.append(f"  survives({lost!r}, {candidate!r}) = {actual}, expected {expected}")

    if not edit_distance_within("kitten", "sitting", 3):
        failures.append("  edit_distance_within('kitten','sitting',3) should be True")
    if edit_distance_within("kitten", "sitting", 2):
        failures.append("  edit_distance_within('kitten','sitting',2) should be False")

    if failures:
        print("SELF-TEST FAILED:")
        print("\n".join(failures))
        return False
    print(f"self-test: {len(cases) + 2} cases pass")
    return True


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        return 0 if self_test() else 1

    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    if not self_test():
        print("refusing to report numbers from logic that fails its own test", file=sys.stderr)
        return 1

    rows = json.load(open(sys.argv[1]))
    print(f"loaded {len(rows)} rows")
    print("Aggregates only. No transcript content is printed, per the archive rules.")

    for language, label in (("en", "ENGLISH"), ("ru", "RUSSIAN")):
        report(label, analyse(rows, language))

    return 0


if __name__ == "__main__":
    sys.exit(main())
