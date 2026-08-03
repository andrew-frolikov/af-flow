#!/usr/bin/env python3
"""Keep STATE.md small, current and honest, by mechanism rather than by memory.

WHY. On 2026-08-02 the contract still said "read PROGRESS.md at session start", and
PROGRESS.md had grown to 247 KB, about 68,000 tokens, which was roughly a third of a
session's context spent before any work began. STATE.md replaced that mandate.

The three ways STATE.md dies, in order of likelihood:

  1. it quietly re-bloats into PROGRESS.md 2.0, because every append feels justified
  2. it goes stale while sessions keep appending to the journal
  3. its item numbers drift, which has already happened once: ledger items 11 and 13
     are the same Wispr Left Control item recorded twice

All three are checkable, so none of them is left to discipline. This runs from
banned-symbol-sweep.sh, which already runs at every boundary, so nobody has to
remember it.

Exit 0 clean, 1 on a hard failure.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.join(ROOT, "STATE.md")
JOURNAL = os.path.join(ROOT, "PROGRESS.md")

# The cap is the single most important line in this file. Without it the small file
# becomes the big file within a month, and the whole benefit is gone.
SIZE_CAP = 8192

failures = []
warnings = []


def note(ok, message):
    print("%-5s %s" % ("ok" if ok else "FAIL", message))


def check_size():
    size = os.path.getsize(STATE)
    if size > SIZE_CAP:
        failures.append(
            "STATE.md is %d bytes, over the %d cap. Move detail into PROGRESS.md and "
            "leave a pointer. The cap is the mechanism; raising it is how this dies."
            % (size, SIZE_CAP))
        note(False, "STATE.md size %d / %d" % (size, SIZE_CAP))
    else:
        note(True, "STATE.md size %d / %d" % (size, SIZE_CAP))


def last_commit_for(path):
    try:
        out = subprocess.run(
            ["git", "-C", ROOT, "log", "-1", "--format=%ct", "--", path],
            capture_output=True, text=True, timeout=15).stdout.strip()
        return int(out) if out else 0
    except Exception:
        return 0


def check_staleness():
    journal = last_commit_for("PROGRESS.md")
    state = last_commit_for("STATE.md")
    if journal and state and journal > state:
        failures.append(
            "PROGRESS.md was committed after STATE.md was. The journal moved and the "
            "state did not, so the file the next session reads is already wrong. "
            "Reconcile STATE.md in the same commit that appends history.")
        note(False, "STATE.md is older than the journal")
    else:
        note(True, "STATE.md is at least as new as the journal")


def check_item_numbers():
    with open(STATE) as handle:
        text = handle.read()
    numbers = re.findall(r"^\| (\d+) \|", text, re.MULTILINE)
    duplicates = {n for n in numbers if numbers.count(n) > 1}
    if duplicates:
        failures.append(
            "STATE.md lists item number(s) %s more than once. Two rows with one number "
            "is how ledger items 11 and 13 became the same item twice."
            % ", ".join(sorted(duplicates)))
        note(False, "duplicate item numbers: %s" % ", ".join(sorted(duplicates)))
    else:
        note(True, "%d item numbers, no duplicates" % len(numbers))


def check_pointers():
    """Every pointer into the journal must actually land somewhere."""
    with open(STATE) as handle:
        state_text = handle.read()
    with open(JOURNAL) as handle:
        journal_text = handle.read()

    dangling = []
    for date in sorted(set(re.findall(r"PROGRESS\.md, (\d{4}-\d{2}-\d{2})", state_text))):
        if date not in journal_text:
            dangling.append(date)
    if dangling:
        failures.append(
            "STATE.md points at PROGRESS.md sections that do not exist: %s"
            % ", ".join(dangling))
        note(False, "dangling pointers: %s" % ", ".join(dangling))
    else:
        note(True, "every dated pointer into the journal resolves")


def check_journal_headings():
    with open(JOURNAL) as handle:
        headings = [line for line in handle if line.startswith("## ")]
    undated = [h.strip() for h in headings if not re.search(r"\d{4}-\d{2}-\d{2}", h)]
    if undated:
        warnings.append(
            "%d journal heading(s) carry no ISO date, so grep by date cannot find them: %s"
            % (len(undated), "; ".join(h[:60] for h in undated[:4])))
        note(True, "%d headings, %d without a date (warning)" % (len(headings), len(undated)))
    else:
        note(True, "%d headings, all dated" % len(headings))


def main():
    if not os.path.exists(STATE):
        print("FAIL  STATE.md does not exist. The contract tells every session to read it.")
        return 1

    print("state-check")
    print("-----------")
    check_size()
    check_staleness()
    check_item_numbers()
    check_pointers()
    check_journal_headings()

    for warning in warnings:
        print("\nwarning: %s" % warning)
    for failure in failures:
        print("\nFAIL: %s" % failure)

    print("\nRESULT: %s" % ("clean" if not failures else "%d failure(s)" % len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
