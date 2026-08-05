#!/usr/bin/env python3
"""Every product-spec line must say WHO decided it.

Written 2026-08-05, after Andrew asked where the auto-paste requirement came
from and the answer was: nowhere he could be shown.

WHAT HAPPENED. CLAUDE.md said, under "Product spec v1 (slots locked
2026-07-18)", that dictated text should land at the cursor of the frontmost
app. Three weeks of work and an entire paste-debugging arc were spent
defending that line. Investigating it found:

  - The mechanism is INHERITED FORK CODE. `TextPaster.swift` was written by
    Matt Hartman on 2026-03-19 and `FocusedElementLocator.swift` by Jesse
    Vincent on 2026-03-24, in upstream Ghost Pepper. The fork baseline is
    2026-07-17. Nobody built it for Andrew; it was already there.
  - The requirement was written into a Claude-authored planning brief under
    "Locked product requirements (from interview 2026-07-18)".
  - The PROGRESS.md decision log records his real 2026-07-18 decisions
    individually, each with its evidence. Insertion appears in none of them.

So "he asked for a replacement of a tool that auto-inserts" was recorded as
"auto-insertion is a locked requirement". Those are different statements and
the documents could not tell them apart.

THE MECHANISM THAT WAS MISSING, which is what this script is. The spec had ONE
REGISTER: inherited behaviour, Claude's inferences, and Andrew's genuine dated
decisions were all written as identical declarative sentences under one
"locked" banner. A later session has no way to tell which lines he actually
decided, so it defends all of them equally.

Every spec bullet now carries one of three tags:

  [A: YYYY-MM-DD]  Andrew decided this, on that date. MUST match a dated line
                   in PROGRESS.md's Decision log. This cross-reference is the
                   load-bearing part: without it the same session that wrote
                   "slots locked" would cheerfully tag its own inference as
                   his. A tag that cannot be checked is a claim, not a tag.
  [fork]           Inherited upstream behaviour, kept by default, never chosen.
  [assumed]        Claude inferred it. NOT confirmed by Andrew.

And the rule that gives the tags teeth: an `[assumed]` or `[fork]` line may not
appear in the Definition of done. Shipping criteria are his to set.

    python3 scripts/spec-provenance-check.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLAUDE_MD = os.path.join(ROOT, "CLAUDE.md")
PROGRESS_MD = os.path.join(ROOT, "PROGRESS.md")

SPEC_HEADING = re.compile(r"^## Product spec v1")
DONE_HEADING = re.compile(r"^## Definition of done")
ANY_HEADING = re.compile(r"^## ")
BULLET = re.compile(r"^- ")

TAG = re.compile(r"\[(A: (\d{4}-\d{2}-\d{2})|fork|assumed)\]")
DECISION_LOG_ENTRY = re.compile(r"^- (\d{4}-\d{2}-\d{2})")
DECISION_LOG_HEADING = re.compile(r"^### .*?(\d{4}-\d{2}-\d{2})")


def section(lines, heading_pattern):
    """The lines under a heading, up to the next one."""
    out = []
    inside = False
    for line in lines:
        if heading_pattern.match(line):
            inside = True
            continue
        if inside and ANY_HEADING.match(line):
            break
        if inside:
            out.append(line)
    return out


def decision_dates():
    """How many separate decisions Andrew is recorded as taking, per date.

    A COUNT rather than a set, and that is the whole strength of this check.
    A date alone is far too cheap: the Decision log has several entries for
    2026-07-18, so a session could tag all ten spec bullets `[A: 2026-07-18]`
    and every one would pass a set-membership test while nine of them remained
    inventions. That is precisely the failure being fixed.

    Requiring at least as many logged decisions as bullets claiming the date
    forces someone to write down what he actually decided, one entry per
    decision. There is no way to satisfy it except by doing the work.
    """
    if not os.path.exists(PROGRESS_MD):
        return {}
    counts = {}
    with open(PROGRESS_MD) as handle:
        inside = False
        for line in handle:
            if line.startswith("## Decision log"):
                inside = True
                continue
            if inside and ANY_HEADING.match(line):
                break
            if not inside:
                continue
            # Both shapes the log actually uses: a dated bullet, and a dated
            # `### Session N decision, YYYY-MM-DD:` sub-heading.
            match = DECISION_LOG_ENTRY.match(line) or DECISION_LOG_HEADING.search(line)
            if match:
                date = match.group(1)
                counts[date] = counts.get(date, 0) + 1
    return counts


def main():
    with open(CLAUDE_MD) as handle:
        lines = handle.read().splitlines()

    logged = decision_dates()
    problems = []
    claimed = {}

    # The legend itself is bullets. Skip lines whose bullet IS a tag name,
    # rather than a spec line carrying one.
    spec = [
        line for line in section(lines, SPEC_HEADING)
        if BULLET.match(line) and not line.startswith("- `[")
    ]
    for line in spec:
        match = TAG.search(line)
        label = line[2:80]
        if not match:
            problems.append("UNTAGGED spec bullet: %s" % label)
            continue
        if match.group(2):
            claimed[match.group(2)] = claimed.get(match.group(2), 0) + 1
            if match.group(2) not in logged:
                problems.append(
                    "spec bullet claims [A: %s] but PROGRESS.md's Decision log has no entry "
                    "for that date: %s" % (match.group(2), label)
                )

    for date, count in sorted(claimed.items()):
        available = logged.get(date, 0)
        if available and count > available:
            problems.append(
                "%d spec bullets claim [A: %s] but the Decision log records only %d "
                "decision(s) that day. Write down what he decided, one entry each."
                % (count, date, available)
            )

    # The Definition of done is prose, not bullets, so it is checked as a
    # whole: no shipping criterion may rest on a line Andrew never set.
    done = "\n".join(section(lines, DONE_HEADING))
    for weak in ("[assumed]", "[fork]"):
        if weak in done:
            problems.append(
                "Definition of done contains %s. Shipping criteria are Andrew's to "
                "set; promote it to [A: date] or take it out." % weak
            )

    if not spec:
        problems.append("Found no bullets under 'Product spec v1'. Has the heading moved?")

    print("spec bullets checked: %d" % len(spec))
    print("decision-log entries: %s" % ", ".join("%s x%d" % (d, n) for d, n in sorted(logged.items())))
    if problems:
        print()
        for problem in problems:
            print("  " + problem)
        print()
        print("RESULT: %d problem(s)" % len(problems))
        return 1

    print("RESULT: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
