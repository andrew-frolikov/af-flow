#!/usr/bin/env python3
"""Find a regex inside Swift STRING LITERALS only, ignoring comments.

Used by banned-symbol-sweep.sh to enforce CLAUDE.md hard rule 9 (no em dashes
in user-facing text, costs in CAD). A plain grep cannot do this job: a pattern
matching a quote followed by an em dash character also matches an ordinary
code comment that happens to quote something first, which produced eight false
positives on 2026-07-19 and would have pushed someone toward weakening the
check.

Comments are not user-facing, so excluding them removes noise, not coverage.
Every real shape is still caught, including em dashes inside multi-line
triple-quoted LLM prompt literals, which a single-line grep misses entirely
and which matter most: a prompt containing em dashes teaches the model to
emit them.

Usage: string-literal-grep.py PATTERN PATH [PATH ...]
Prints  file:line:text  per hit. Exit 0 if no hits, 1 if any.
"""

import os
import re
import sys


def string_spans(line, in_multiline):
    """Yield (start, end) spans of string content in one line.

    Returns (spans, in_multiline_after). Naive but adequate for Swift: it
    tracks triple-quoted blocks across lines, single-quoted strings within a
    line, escape sequences, and stops at // when outside a string.
    """
    spans = []
    i = 0
    n = len(line)

    if in_multiline:
        end = line.find('"""')
        if end == -1:
            return [(0, n)], True
        spans.append((0, end))
        i = end + 3
        in_multiline = False

    start = None
    while i < n:
        if line.startswith('"""', i):
            in_multiline = True
            i += 3
            spans.append((i, n))
            return spans, True
        ch = line[i]
        if start is None:
            if ch == '"':
                start = i + 1
            elif ch == '/' and i + 1 < n and line[i + 1] == '/':
                break
            elif ch == '/' and i + 1 < n and line[i + 1] == '*':
                break
            i += 1
        else:
            if ch == '\\':
                i += 2
                continue
            if ch == '"':
                spans.append((start, i))
                start = None
            i += 1

    if start is not None:
        spans.append((start, n))
    return spans, in_multiline


def is_allowed(content, is_entity_table_file):
    """The single deliberate exception, scoped as narrowly as it can be.

    Reader/ReaderCapture.swift holds an HTML entity decoding table whose entries
    map an entity name to the character it decodes to, so "&mdash;" is paired
    with a literal em dash. That character is data, not user-facing copy, and
    deleting it breaks HTML decoding.

    Codex round 7 rated the first version of this exception HIGH severity, and
    it was right. It skipped the whole LINE, in EVERY file, for BOTH rule 9
    patterns, so a string such as "&mdash; - USD 40" would have sailed through
    anywhere in the codebase. The exception now requires all three of: the one
    named file, a string whose entire content is exactly the entity name or the
    single character it decodes to, and nothing else.

    Recorded as provisional 2026-07-19, pending Andrew's ratification.
    """
    if not is_entity_table_file:
        return False
    # Written as escapes on purpose. This file must be able to name the two
    # characters it allowlists without itself containing them, so that the
    # rule 9 sweep over scripts/ needs no exclusion for the verifier.
    return content in ("&mdash;", "\u2014", "&ndash;", "\u2013")


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: string-literal-grep.py PATTERN PATH [PATH ...]\n")
        return 2

    pattern = re.compile(sys.argv[1])
    hits = 0

    for root_path in sys.argv[2:]:
        for dirpath, _dirnames, filenames in os.walk(root_path):
            for filename in sorted(filenames):
                if not filename.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, filename)
                try:
                    with open(path, encoding="utf-8") as handle:
                        lines = handle.readlines()
                except (OSError, UnicodeDecodeError):
                    continue

                is_entity_table_file = path.endswith(
                    os.path.join("Reader", "ReaderCapture.swift")
                )

                in_multiline = False
                for lineno, line in enumerate(lines, start=1):
                    line = line.rstrip("\n")
                    spans, in_multiline = string_spans(line, in_multiline)
                    for start, end in spans:
                        content = line[start:end]
                        if not pattern.search(content):
                            continue
                        if is_allowed(content, is_entity_table_file):
                            continue
                        print("%s:%d:%s" % (path, lineno, line.strip()))
                        hits += 1
                        break

    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
