#!/usr/bin/env python3
"""Score the cleanup prompt against Andrew's own dictations, with no human reading.

WHY THIS SHAPE. Andrew's verdict is the only thing that can close v1, and it is
the scarcest input in the project. So nothing goes in front of him that a machine
could have rejected first. This is that machine.

**It scores differentially, from input and output alone.** There is no reference
text and no per-case labelling, which means it works unchanged for English,
Russian and mixed, it works on any fixture the app happens to have recorded, and
it does not rot when the prompt changes underneath it. Every check below is a
measured lean from his own 128 corrections, not a preference:

  function words deleted   he restores them about 5 to 1, so deleting is his
                           single most-corrected defect
  sentences merged         he splits 17 to 4 and merges almost never, so a drop
                           in sentence count is always wrong
  first word case          33 of 33 of his casing-only fixes were lowercasing
                           the first word of the message
  terminal period          he strips it 46 to 8
  script flipped           a token that changed alphabet is a translation, and
                           12.6 percent of his utterances are mixed
  words invented           anything in the output that was not in the input and
                           is not a licensed change

**What it deliberately cannot do, stated so nobody mistakes a pass for a
verdict:** it cannot detect flattening that preserves tokens. Re-ordering a
clause, or swapping a comma in a way that changes the reading, scores clean here.
It shrinks the human gate; it does not remove it.

Usage:
    scripts/prompt-eval.py [--limit N] [--model KIND] [--out FILE]
"""

import argparse
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

LAB_INDEX = (
    Path.home()
    / "Library/Containers/com.frolikov.afflow/Data/Library/Application Support"
    / "GhostPepper/transcription-lab/transcription-lab-index.json"
)
PROBE = Path(__file__).resolve().parent / "cleanup-model-probe.sh"

# Deleting any of these is the defect he corrects most often. Deliberately NOT a
# list of "important words": it is the closed class of English and Russian
# function words, which is a property of the languages rather than of anyone's
# imagination about which words matter.
FUNCTION_WORDS = {
    "a", "an", "the", "and", "or", "but", "so", "if", "of", "to", "in", "on", "at",
    "for", "with", "from", "by", "as", "is", "are", "was", "were", "be", "been",
    "it", "its", "this", "that", "these", "those", "i", "you", "he", "she", "we",
    "they", "me", "him", "her", "us", "them", "my", "your", "his", "our", "their",
    "do", "does", "did", "can", "could", "will", "would", "should", "have", "has",
    "had", "not", "no", "there", "here", "what", "which", "who", "when", "where",
    "и", "в", "на", "с", "со", "к", "по", "за", "из", "у", "о", "об", "от", "до",
    "для", "что", "чтобы", "как", "но", "а", "же", "ли", "бы", "не", "это", "этот",
    "то", "так", "все", "все", "мы", "вы", "он", "она", "они", "я", "мне", "меня",
    "нам", "нас", "их", "его", "ее", "мой", "моя", "наш",
}

# The only deletions the prompt licenses. Anything else that disappears is a bug.
LICENSED_DELETIONS = {
    "um", "uh", "uhm", "mm", "hmm", "эээ", "ммм", "ээ", "мм",
}

TOKEN = re.compile(r"[^\W\d_]+", re.UNICODE)


def tokens(text):
    return [t.lower() for t in TOKEN.findall(text)]


def is_cyrillic(word):
    return any("CYRILLIC" in unicodedata.name(c, "") for c in word)


def sentence_count(text):
    return len([s for s in re.split(r"[.!?]+", text) if s.strip()])


def run_probe(text, model):
    """Return (cleaned, reason). A None cleaned always carries a reason.

    Returning a bare None on failure hid four fixtures behind the word
    "PROBE FAILED" on 2026-07-26 while the same inputs worked standalone. A
    diagnostic that cannot say why is the same defect as a gate that cannot
    fail, so the reason is now part of the return value rather than discarded.
    """
    # RETRIED, because the probe aborts intermittently and it is not the
    # prompt's fault. Measured 2026-07-26: a Swift CancellationError is followed
    # by `GGML_ASSERT([rsets->data count] == 0)` inside ggml_metal_device_free,
    # so llama.cpp kills the process rather than returning an error. Different
    # fixtures crash on different runs, which is what proves it is a teardown
    # race and not an input the model cannot handle: every fixture that crashed
    # here succeeds when run again.
    #
    # Retrying is correct for MEASUREMENT and is not a fix. The defect is
    # recorded as a ledger item, because the app wraps generation in a timeout
    # that cancels the same way.
    marker = "Final cleaned output:"
    last = ""
    for attempt in range(4):
        try:
            result = subprocess.run(
                [str(PROBE), "--model", model, "--input", text],
                capture_output=True,
                text=True,
                timeout=300,
            )
        except subprocess.TimeoutExpired:
            last = "timed out after 300s"
            continue
        if marker in result.stdout:
            return result.stdout.split(marker, 1)[1].strip(), ""
        tail = (result.stderr or result.stdout or "").strip().replace("\n", " ")[-160:]
        last = f"exit {result.returncode} on attempt {attempt + 1}: {tail!r}"
    return None, last


def score(raw, cleaned):
    """Return the list of failures. Empty means this fixture passed."""
    failures = []
    raw_tokens = tokens(raw)
    out_tokens = tokens(cleaned)
    raw_counts = {}
    for t in raw_tokens:
        raw_counts[t] = raw_counts.get(t, 0) + 1
    out_counts = {}
    for t in out_tokens:
        out_counts[t] = out_counts.get(t, 0) + 1

    for word, count in raw_counts.items():
        missing = count - out_counts.get(word, 0)
        if missing <= 0:
            continue
        if word in LICENSED_DELETIONS:
            continue
        if word in FUNCTION_WORDS:
            failures.append(f"function word deleted: {word!r} x{missing}")

    invented = [w for w in out_counts if w not in raw_counts]
    if invented:
        failures.append(f"words not in the input: {invented[:5]}")

    if sentence_count(cleaned) < sentence_count(raw):
        failures.append(
            f"sentences merged: {sentence_count(raw)} in, {sentence_count(cleaned)} out"
        )

    stripped = cleaned.strip()
    if stripped.endswith("."):
        failures.append("terminal period not removed")

    if stripped and raw.strip():
        first_out = stripped.split()[0]
        if first_out[:1].isupper() and not first_out.isupper() and first_out.lower() not in {"i"}:
            failures.append(f"first word still capitalised: {first_out!r}")

    for word in out_counts:
        if word in raw_counts:
            continue
        flipped = [r for r in raw_counts if r.lower() == word.lower()]
        if not flipped and is_cyrillic(word) != any(is_cyrillic(r) for r in raw_counts):
            failures.append(f"script flipped: {word!r}")
            break

    if not stripped:
        failures.append("empty output")

    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--model", default="qwen35_0_8b_q4_k_m")
    parser.add_argument("--out", default="")
    parser.add_argument(
        "--source",
        default="lab",
        choices=["lab", "wispr"],
        help="lab = his AF Flow dictations; wispr = the archived corpus, which is "
             "where his Russian lives. v1 is defined across EN, RU and mixed, and "
             "the lab is almost all English, so RU coverage needs the archive.",
    )
    parser.add_argument("--lang", default="", choices=["", "ru", "mixed", "en"])
    args = parser.parse_args()

    if not LAB_INDEX.exists():
        print(f"No fixture corpus at {LAB_INDEX}", file=sys.stderr)
        return 1

    if args.source == "wispr":
        archive = (
            Path.home() / "Prototypes/af-flow-private/wispr-archive/text/history.json"
        )
        if not archive.exists():
            print(f"No archive at {archive}", file=sys.stderr)
            return 1
        raw_rows = json.loads(archive.read_text())
        rows = [
            {"id": r.get("transcriptEntityId"), "rawTranscription": r["asrText"], "createdAt": r.get("timestamp", 0)}
            for r in raw_rows
            if isinstance(r, dict) and (r.get("asrText") or "").strip()
        ]
    else:
        rows = json.loads(LAB_INDEX.read_text())
        rows = [r for r in rows if (r.get("rawTranscription") or "").strip()]

    if args.lang:
        def share(text):
            letters = [c for c in text if c.isalpha()]
            return sum(1 for c in letters if 0x400 <= ord(c) <= 0x4FF) / len(letters) if letters else 0.0
        bounds = {"ru": (0.6, 1.01), "mixed": (0.05, 0.6), "en": (-0.01, 0.05)}[args.lang]
        rows = [r for r in rows if bounds[0] < share(r["rawTranscription"]) <= bounds[1]]

    rows.sort(key=lambda r: r.get("createdAt", 0))
    if args.limit:
        rows = rows[-args.limit :]

    print(f"{len(rows)} fixtures, model {args.model}\n")

    results = []
    tally = {}
    for index, row in enumerate(rows, 1):
        raw = row["rawTranscription"].strip()
        cleaned, reason = run_probe(raw, args.model)
        if cleaned is None:
            print(f"[{index:>3}] PROBE FAILED  {reason}")
            continue
        failures = score(raw, cleaned)
        for f in failures:
            tally[f.split(":")[0]] = tally.get(f.split(":")[0], 0) + 1
        results.append({"id": row.get("id"), "raw": raw, "cleaned": cleaned, "failures": failures})
        flag = "pass" if not failures else f"{len(failures)} FAIL"
        print(f"[{index:>3}] {flag:>8}  {raw[:60]!r}")
        for f in failures:
            print(f"          {f}")

    passed = sum(1 for r in results if not r["failures"])
    print(f"\n{passed} of {len(results)} clean")
    print("\nfailures by kind:")
    for kind, count in sorted(tally.items(), key=lambda kv: -kv[1]):
        print(f"  {count:>4}  {kind}")

    if args.out:
        Path(args.out).write_text(json.dumps(results, ensure_ascii=False, indent=2))
        print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
