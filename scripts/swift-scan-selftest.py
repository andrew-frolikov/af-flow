#!/usr/bin/env python3
"""Self-test for swift-scan.py's tokenizer. Run by banned-symbol-sweep.sh FIRST.

Why this exists, and why the sweep refuses to run without it passing.

Three consecutive Codex rounds (7, 8, 9) each found a new hole in the Swift
parsing this project's gates depend on. Every one of them meant the sweep had
been reporting "clean" while a real violation sat in the tree. A gate whose
parser is silently wrong is worse than no gate, because it manufactures
confidence.

Canary tests were being run by hand after each change. Hand-run canaries are
not a control: they depend on someone remembering. This file makes the tokenizer
prove itself on every single sweep, before the sweep looks at any real code. If
the tokenizer regresses, the sweep fails loudly instead of quietly passing
everything.

The cases below are exactly the constructs a reviewer would use to hide
something, plus the ones Codex actually used in rounds 7 to 9.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

_spec_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "swift-scan.py")
_globals = {"__name__": "swift_scan_module"}
with open(_spec_path, encoding="utf-8") as _fh:
    exec(compile(_fh.read(), _spec_path, "exec"), _globals)
tokenize = _globals["tokenize"]

# Each case: (label, swift source, needle, expected_kind)
# expected_kind is the token kind the needle MUST land in for the gates to work.
CASES = [
    ("plain string", 'let a = "USD 10"', "USD", "string"),
    ("plain code", "let a = Service.shared.go()", "Service", "code"),
    ("line comment is neither",
     '// Service.shared and USD 10\nlet a = 1', "Service", None),
    ("block comment is neither",
     '/* Service.shared USD 10 */\nlet a = 1', "Service", None),
    ("nested block comment",
     '/* outer /* inner */ still comment Service.shared */\nlet a = 1',
     "Service", None),
    ("code after block comment on same line",
     '/* note */ let a = "USD 10"', "USD", "string"),
    ("raw string, one hash", 'let a = #"USD 10"#', "USD", "string"),
    ("raw string, two hashes", 'let a = ##"USD 10"##', "USD", "string"),
    ("escaped quote inside string",
     'let a = "he said \\"USD 10\\" loudly"', "USD", "string"),
    ("string containing a line-comment marker",
     'let a = "http://x USD 10"', "USD", "string"),
    ("string containing a block-comment opener",
     'let a = "literal /* USD 10"', "USD", "string"),
    ("interpolation contents are CODE",
     'let a = "\\(Service.shared.go())"', "Service", "code"),
    ("raw-string interpolation contents are CODE",
     'let a = #"\\#(Service.shared.go())"#', "Service", "code"),
    ("nested string inside interpolation is STRING",
     'let a = "\\(c ? "USD 10" : "CAD 0")"', "USD", "string"),
    ("three-deep nested interpolation",
     'let a = "\\("\\("USD 10")")"', "USD", "string"),
    ("paren inside nested string inside interpolation",
     'let a = "\\(String("(") + "USD 10")"', "USD", "string"),
    ("multiline string with quotes",
     'let a = """\nhe said "USD 10" here\n"""', "USD", "string"),
    ("multiline string is not code",
     'let a = """\nService.shared.go()\n"""', "Service", "string"),
    # Codex round 10: an extended regex literal containing // must not be read
    # as a line comment and swallow the rest of the file.
    ("regex literal does not start a comment",
     'let r = #/https:\\/\\/x/#\nlet a = "USD 10"', "USD", "string"),
    ("regex literal itself yields no token",
     'let r = #/USD 10/#', "USD", None),
    # A ) inside a regex must not unbalance interpolation paren tracking and
    # push real code into a string token.
    ("regex paren inside interpolation does not unbalance",
     'let a = "\\(f(#/)/#) + Service.shared.go())"', "Service", "code"),
]


def kind_of(src, needle):
    """Return the token kind the needle appears in, or None if in neither."""
    for kind, _lineno, text in tokenize(src):
        if needle in text:
            return kind
    return None


def main():
    failures = []
    for label, src, needle, expected in CASES:
        got = kind_of(src, needle)
        if got != expected:
            failures.append(
                "  %-46s expected %-6s got %s" % (label, expected, got)
            )

    if failures:
        print("FAIL  swift-scan tokenizer self-test (%d of %d cases)"
              % (len(failures), len(CASES)))
        for line in failures:
            print(line)
        print("      The verifier itself is broken. Every 'ok' below would be")
        print("      meaningless, so the sweep stops here.")
        return 1

    print("ok    swift-scan tokenizer self-test (%d cases)" % len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
