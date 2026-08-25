#!/usr/bin/env python3
"""Build the one page Andrew reads to decide whether v1 is done.

His verdict is the only thing that can close v1, and it is the scarcest input in
the project, so this page exists to spend as little of it as possible:

  - Only fixtures that PASSED the machine gate appear. Anything a script could
    reject has already been rejected, so every pair here is a genuine judgement
    call rather than an obvious defect.
  - Each pair shows what he SAID, what the app used to produce, and what it
    produces now, so the question is comparative rather than absolute. "Is this
    better than what you have been living with" is answerable in seconds;
    "is this good" is not.
  - Differences are marked, so he does not have to diff two paragraphs by eye.

Usage:
    scripts/build-verdict-page.py --results /tmp/eval-full.json --out page.html
"""

import argparse
import difflib
import html
import json
import re
from pathlib import Path

LAB_INDEX = (
    Path.home()
    / "Library/Containers/com.frolikov.afflow/Data/Library/Application Support"
    / "AFFlow/transcription-lab/transcription-lab-index.json"
)


def cyrillic_share(text):
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return 0.0
    return sum(1 for c in letters if 0x400 <= ord(c) <= 0x4FF) / len(letters)


def label(text):
    share = cyrillic_share(text)
    if share > 0.6:
        return "Russian"
    if share > 0.05:
        return "Mixed RU/EN"
    return "English"


def mark_diff(before, after):
    """Highlight what changed, word by word, so he is not diffing by eye."""
    before_words = before.split()
    after_words = after.split()
    matcher = difflib.SequenceMatcher(None, before_words, after_words)
    out = []
    for tag, _, _, j1, j2 in matcher.get_opcodes():
        chunk = html.escape(" ".join(after_words[j1:j2]))
        if not chunk:
            continue
        if tag in {"replace", "insert"}:
            out.append(f"<mark>{chunk}</mark>")
        else:
            out.append(chunk)
    return " ".join(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--limit", type=int, default=15)
    args = parser.parse_args()

    results = json.loads(Path(args.results).read_text())
    lab = {r.get("id"): r for r in json.loads(LAB_INDEX.read_text())}

    clean = [r for r in results if not r["failures"] and r["cleaned"].strip()]
    # Spread across languages and lengths rather than taking the first N, so he
    # is not shown fifteen variations of the same easy case.
    clean.sort(key=lambda r: -len(r["raw"]))
    picked, seen_labels = [], {}
    for row in clean:
        kind = label(row["raw"])
        if seen_labels.get(kind, 0) >= max(3, args.limit // 2):
            continue
        seen_labels[kind] = seen_labels.get(kind, 0) + 1
        picked.append(row)
        if len(picked) >= args.limit:
            break

    cards = []
    for index, row in enumerate(picked, 1):
        entry = lab.get(row["id"], {})
        old = (entry.get("correctedTranscription") or "").strip()
        raw = row["raw"].strip()
        new = row["cleaned"].strip()
        old_block = (
            f'<div class="row"><div class="lab">Before, what the app gave you</div>'
            f'<div class="txt old">{html.escape(old)}</div></div>'
            if old and old != raw
            else ""
        )
        cards.append(
            f"""<article class="card">
  <header><span class="n">{index}</span><span class="tag">{label(raw)}</span>
  <span class="len">{len(raw)} characters</span></header>
  <div class="row"><div class="lab">What you said</div>
    <div class="txt raw">{html.escape(raw)}</div></div>
  {old_block}
  <div class="row"><div class="lab">Now, with the new voice layer</div>
    <div class="txt new">{mark_diff(raw, new)}</div></div>
</article>"""
        )

    page = f"""<title>AF Flow: does this sound like you?</title>
<style>
:root {{ --paper:#FBF8F3; --band:#F4EFE7; --ink:#1B2A3B; --soft:#42546A;
        --muted:#7C8797; --line:#E8E0D2; --teal:#2E8B7A; --gold:#B9822B;
        --card:#FFFFFF; --sunk:#FAF7F1; --newbg:#EFF7F4;
        --markbg:#CFEDE2; --markfg:#0F6E56; }}
body {{ margin:0; background:var(--paper); color:var(--ink);
       font:16px/1.65 -apple-system,BlinkMacSystemFont,system-ui,sans-serif; }}
.wrap {{ max-width:820px; margin:0 auto; padding:2.5rem 1.25rem 4rem; }}
h1 {{ font-family:Georgia,serif; font-weight:400; font-size:28px; margin:0 0 .4rem; }}
.sub {{ color:var(--soft); margin:0 0 2rem; }}
.ask {{ background:var(--band); border:1px solid var(--line); border-radius:12px;
        padding:1rem 1.25rem; margin-bottom:2rem; }}
.card {{ background:var(--card); border:1px solid var(--line); border-radius:12px;
         padding:1rem 1.25rem; margin-bottom:1.25rem; }}
header {{ display:flex; gap:.6rem; align-items:center; margin-bottom:.75rem; }}
.n {{ font-family:Georgia,serif; color:var(--muted); }}
.tag {{ font-size:12px; background:var(--band); color:var(--soft);
        padding:2px 9px; border-radius:20px; }}
.len {{ font-size:12px; color:var(--muted); margin-left:auto; }}
.row {{ margin:.6rem 0; }}
.lab {{ font-size:11.5px; text-transform:uppercase; letter-spacing:.06em;
        color:var(--muted); margin-bottom:.2rem; }}
.txt {{ padding:.55rem .7rem; border-radius:8px; }}
.raw {{ background:var(--sunk); color:var(--soft); }}
.old {{ background:var(--sunk); color:var(--soft); }}
.new {{ background:var(--newbg); }}
mark {{ background:var(--markbg); color:var(--markfg); padding:0 2px; border-radius:3px; }}
/* Dark tokens defined once, then pointed at by both the OS preference and an
   explicit data-theme, so a viewer toggle wins in either direction. Components
   read the tokens and are never restyled inside a media query. */
@media (prefers-color-scheme: dark) {{
  :root {{ --paper:#14181D; --band:#1B2129; --ink:#E8E4DC; --soft:#A9B4C2;
          --muted:#7C8797; --line:#2A323C; --card:#191E25; --sunk:#1B2129;
          --newbg:#16241F; --markbg:#1D4A3C; --markfg:#9FE1CB; }}
}}
:root[data-theme="dark"] {{ --paper:#14181D; --band:#1B2129; --ink:#E8E4DC;
  --soft:#A9B4C2; --muted:#7C8797; --line:#2A323C; --card:#191E25;
  --sunk:#1B2129; --newbg:#16241F; --markbg:#1D4A3C; --markfg:#9FE1CB; }}
:root[data-theme="light"] {{ --paper:#FBF8F3; --band:#F4EFE7; --ink:#1B2A3B;
  --soft:#42546A; --muted:#7C8797; --line:#E8E0D2; --card:#FFFFFF;
  --sunk:#FAF7F1; --newbg:#EFF7F4; --markbg:#CFEDE2; --markfg:#0F6E56; }}
</style>
<div class="wrap">
<h1>Does this sound like you?</h1>
<p class="sub">Your own dictations, cleaned by the new voice layer.</p>
<div class="ask">
  <strong>The only question:</strong> does the green text read like something you wrote?
  Not whether it is perfect. Highlighted words are what changed.
  Every pair here already passed the machine checks, so anything obviously
  broken has been filtered out before it reached you.
</div>
{"".join(cards)}
</div>"""

    Path(args.out).write_text(page, encoding="utf-8")
    print(f"wrote {args.out} with {len(picked)} pairs")
    for kind, count in seen_labels.items():
        print(f"  {kind}: {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
