#!/usr/bin/env python3
"""Find a regex in Swift CODE only, skipping comments and string literals.

The mirror image of string-literal-grep.py, and it exists for the same reason:
a line-oriented grep cannot tell code from prose, so it either floods the
operator with false positives or gets quietly weakened until it proves nothing.

Used for the cloud-service check. A comment that explains why a capability was
removed necessarily names it, and naming a class in a comment cannot call it.
On 2026-07-19 the identifier-level check reported four hits of which three were
exactly that: comments recording that the Trello path had been deleted. Left
alone, those three would have pushed someone toward narrowing the check that had
just caught a real HIGH finding.

Usage: code-grep.py PATTERN PATH [PATH ...] [--allow REGEX]
Prints  file:line:text  per hit. Exit 0 if no hits, 1 if any.
"""

import os
import re
import sys


def code_only(line, in_block_comment, in_multiline_string):
    """Return (code_text, in_block_comment_after, in_multiline_string_after).

    Strips // and /* */ comments and the contents of string literals, leaving
    only executable code. Deliberately simple: it does not need to parse Swift,
    only to avoid reporting words that cannot reach the network.
    """
    out = []
    i = 0
    n = len(line)

    while i < n:
        if in_multiline_string:
            end = line.find('"""', i)
            if end == -1:
                return "".join(out), in_block_comment, True
            i = end + 3
            in_multiline_string = False
            continue

        if in_block_comment:
            end = line.find("*/", i)
            if end == -1:
                return "".join(out), True, in_multiline_string
            i = end + 2
            in_block_comment = False
            continue

        if line.startswith("//", i):
            break
        if line.startswith("/*", i):
            in_block_comment = True
            i += 2
            continue
        if line.startswith('"""', i):
            in_multiline_string = True
            i += 3
            continue
        if line[i] == '"':
            i += 1
            while i < n:
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == '"':
                    i += 1
                    break
                i += 1
            continue

        out.append(line[i])
        i += 1

    return "".join(out), in_block_comment, in_multiline_string


def main():
    args = sys.argv[1:]
    allow = None
    if "--allow" in args:
        idx = args.index("--allow")
        allow = re.compile(args[idx + 1])
        args = args[:idx] + args[idx + 2:]

    if len(args) < 2:
        sys.stderr.write("usage: code-grep.py PATTERN PATH [PATH ...] [--allow REGEX]\n")
        return 2

    pattern = re.compile(args[0])
    hits = 0

    for root_path in args[1:]:
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

                # fullmatch, never search. A substring match would allowlist
                # GhostPepper/PepperChat/TrelloBackend.swift.evil/Live.swift,
                # since the allowlisted path is a prefix of it. Caught by the
                # canary for Codex round 8 finding 2 after that same bug had
                # already been fixed in the shell check but not here.
                if allow and allow.fullmatch(os.path.normpath(path)):
                    continue

                in_block = False
                in_multi = False
                for lineno, raw in enumerate(lines, start=1):
                    raw = raw.rstrip("\n")
                    code, in_block, in_multi = code_only(raw, in_block, in_multi)
                    if pattern.search(code):
                        print("%s:%d:%s" % (path, lineno, raw.strip()))
                        hits += 1

    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
