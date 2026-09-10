#!/usr/bin/env python3
"""Prove no-synthetic-events-check.py fires on what it claims to catch, and stays quiet otherwise.

A check nobody has watched fail is a claim. Every case below states the source
it feeds in and whether that source should be a finding, so a future change that
makes the check permissive breaks here rather than in a release.

THE BYPASS CASES ARE THE POINT. The first version of the check passed its own
selftest while being blind to five real evasions: a string literal containing
`/*` silently discarded the rest of a file, `CGEventTapCreate`, `postToPid`,
`postToPSN` and `tapCreateForPid` matched nothing, and `.listenOnly` was matched
anywhere inside a call rather than as the value of `options:`. Every one of them
is now a case here. They were found by an independent review, not by this file,
which is exactly why they are pinned: the selftest tested the cases its author
had already thought of.

Usage:  no-synthetic-events-check-selftest.py
Exit 0 all cases pass, 1 a case failed.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

check = __import__("no-synthetic-events-check")

CASES = [
    (
        "clean: a listen-only tap and a pasteboard write",
        """
        func start() -> Bool {
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: cb,
                userInfo: nil
            ) else { return false }
            pasteboard.setString(text, forType: .string)
            return true
        }
        """,
        0,
    ),
    (
        "posts a keystroke: both the builder and the post are named",
        """
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        down?.post(tap: .cghidEventTap)
        """,
        2,
    ),
    ("CGEventPost, the C spelling", "CGEventPost(kCGHIDEventTap, event)", 1),
    ("an event source, which exists only to synthesise", "let source = CGEventSource(stateID: .hidSystemState)", 1),
    (
        "a tap that can modify events",
        """
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cb,
            userInfo: nil
        )
        """,
        1,
    ),
    (
        "a tap whose options cannot be read",
        "CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, callback: cb)",
        1,
    ),
    ("PROSE ONLY: a line comment naming the forbidden call", "// never calls CGEvent.post(tap: .cghidEventTap)\nlet x = 1", 0),
    ("PROSE ONLY: a doc comment naming it", "/// It does not use CGEventSource( at all.\nlet x = 1", 0),
    ("PROSE ONLY: a block comment naming it", "/* historical: down.post(tap: .cghidEventTap) */\nlet x = 1", 0),
    ("PROSE ONLY: Swift block comments NEST", "/* outer /* inner */ CGEventPost(a, b) */\nlet x = 1", 0),
    ("a violation sharing a line with a trailing comment", "down.post(tap: .cghidEventTap) // real code\n", 1),
    ("code after a block comment is still scanned", "/* CGEventPost(a, b) */\nCGEventPost(a, b)\n", 1),

    # --- Bypasses an independent review found in the first version. ---
    (
        "BYPASS: a string containing /* must not open a comment",
        'let glob = "**/*.md"\nkeyDown.post(tap: .cghidEventTap)\n',
        1,
    ),
    (
        "BYPASS: a string containing // must not blank the rest of the line",
        'let url = "https://example.com"\nCGEventPost(a, b)\n',
        1,
    ),
    ("BYPASS: CGEventTapCreate, the C spelling", "CGEventTapCreate(.cghidEventTap, .headInsertEventTap, .defaultTap, m, cb, nil)", 1),
    ("BYPASS: CGEventPostToPid", "CGEventPostToPid(pid, event)", 1),
    ("BYPASS: postToPid", "e?.postToPid(pid)", 1),
    ("BYPASS: postToPSN", "e?.postToPSN(&psn)", 1),
    (
        "BYPASS: tapCreateForPid taps another process",
        "CGEvent.tapCreateForPid(pid: p, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: m, callback: cb)",
        1,
    ),
    (
        "BYPASS: .listenOnly elsewhere in the call does not excuse options:",
        'CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: mode, '
        'eventsOfInterest: m, callback: cb, userInfo: label(".listenOnly"))',
        1,
    ),
    (
        "a forbidden call inside a string is NOT reported, because it cannot run",
        'let help = "we never call CGEventPost(a, b) here"\nlet x = 1',
        0,
    ),
    (
        "a raw string's backslashes do not escape its terminator",
        'let re = #"\\\\"#\nCGEventPost(a, b)\n',
        1,
    ),
    (
        "an escaped quote does not end a string early",
        'let s = "he said \\"/*\\" loudly"\nCGEventPost(a, b)\n',
        1,
    ),
]


def main():
    failures = []

    for name, source, expected in CASES:
        findings = check.check_source("Fixture.swift", source)
        if len(findings) != expected:
            failures.append(
                "  %s\n    expected %d finding(s), got %d: %s"
                % (name, expected, len(findings), findings or "none")
            )

    # Line numbers must survive sanitizing, or a finding points at the wrong
    # line and the reader stops trusting the whole report.
    numbered = check.check_source("Fixture.swift", "let a = 1\n/* two\n   lines */\nlet b = 2\nCGEventPost(x, y)\n")
    if len(numbered) != 1 or not numbered[0].startswith("Fixture.swift:5 "):
        failures.append("  line numbers survive sanitizing\n    expected a finding on line 5, got: %s" % numbered)

    # Sanitizing must preserve offsets exactly, or every reported line is a
    # guess. Cheap to assert, and it catches a whole class of edits.
    for _, source, _ in CASES:
        if len(check.sanitize(source)) != len(source):
            failures.append("  sanitize preserves length\n    it did not, for: %s" % source[:50])
            break

    # "Unreadable is not a pass" has to hold for DIRECTORIES too, not only
    # files: os.walk swallows errors by default.
    with tempfile.TemporaryDirectory() as root:
        try:
            check.swift_files(root)
            failures.append("  a repo with no shipping directories must raise\n    it returned instead")
        except OSError:
            pass

    if failures:
        print("no-synthetic-events-check-selftest: %d case(s) FAILED" % len(failures))
        for failure in failures:
            print(failure)
        return 1

    print("no-synthetic-events-check-selftest: all %d cases pass." % (len(CASES) + 3))
    return 0


if __name__ == "__main__":
    sys.exit(main())
