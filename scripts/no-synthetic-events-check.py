#!/usr/bin/env python3
"""Assert AF Flow neither posts synthetic input events nor listens with a tap that can modify them.

WHY THIS EXISTS AT BUILD TIME RATHER THAN IN A TEST. Until 2026-09-09 the "we
never type for him" guarantee lived in a unit test, which injected a
`prepareCommandV` closure and failed if anything called it. That test could
only ever watch ONE seam. When the code behind the seam was deleted the test
had nothing left to spy on, and a test that cannot fail is not a guarantee.
Reintroducing `CGEvent.post` anywhere else in the app would not have tripped it.

WHAT IS AT STAKE. macOS splits one System Settings switch called "Accessibility"
into three separate TCC privileges, and which ones an app touches decides where
it can be sold:

  ListenEvent    a `CGEvent.tapCreate` with `options: .listenOnly`. COMPATIBLE
                 with the App Sandbox. This is how the push-to-talk chord is
                 read, and Apple DTS confirms sandboxed App Store apps may use
                 it. Changing that one argument to `.defaultTap` silently moves
                 the app to the Accessibility privilege, which is NOT sandbox
                 compatible, and nothing else in the build would say so.
  PostEvent      `CGEvent.post`. Technically sandbox compatible, but App Review
                 has cited Guideline 2.4.5 ("accessibility features should not
                 be used for non-accessibility purposes") to reject a clipboard
                 manager, twice, for simulating Cmd-V. AF Flow deliberately
                 does not do this: delivery is the clipboard and Andrew presses
                 Cmd-V himself, his decision of 2026-08-05.
  Accessibility  the `AXUIElement` inspection APIs. Barred by the sandbox
                 outright, proven here on 2026-08-21, and already dead by
                 design. NOT checked here: that subsystem is inert rather than
                 forbidden, and pretending one check covers both would be the
                 same overreach that made the App Store look closed.

So this check defends two properties that no compiler, test or human review
notices being broken:

  1. No source file in the app or the XPC service generates or posts a
     synthetic input event.
  2. Every event tap is created `.listenOnly`.

COMMENTS AND STRING LITERALS ARE BLANKED before matching, and the string half is
not an optimisation. The first version of this file stripped comments only, and
argued in this docstring that leaving strings alone was the safe direction
because a forbidden call spelled inside a string would merely be over-reported.
That was wrong in a way the argument could not see: a string containing `/*`
OPENED a comment, so everything after it was discarded. `AFFlow/QA/QMDService.swift`
holds the literal "**/*.md" on line 115, and 249 of its 330 lines vanished from
the scan. A planted `CGEvent.post` below that line was not reported, and the
check printed "clean". Swift block comments also NEST, which the first version
did not handle either. Both are handled below, and both have regression cases in
the selftest.

Unreadable is not a pass: exit 2 means the check did not happen.

Usage:  no-synthetic-events-check.py [--repo PATH]
Exit 0 clean, 1 findings, 2 could not check.
"""

import argparse
import os
import re
import sys

# The directories that ship. Tests may simulate whatever they like.
SHIPPING_DIRS = ("AFFlow", "AFFlowModels")

# Each entry is (regex, what it would mean). Matched against comment-stripped
# source, so a mention in prose is not a finding.
FORBIDDEN = [
    (re.compile(r"\.post\s*\(\s*tap\s*:"), "posts a synthetic event (PostEvent privilege)"),
    (re.compile(r"\.postToPid\s*\("), "posts a synthetic event to another process"),
    (re.compile(r"\.postToPSN\s*\("), "posts a synthetic event to another process"),
    (re.compile(r"\bCGEventPost\w*\s*\("), "posts a synthetic event (PostEvent privilege)"),
    (re.compile(r"\bCGEvent\s*\(\s*keyboardEventSource\s*:"), "builds a synthetic keyboard event"),
    (re.compile(r"\bCGEvent\s*\(\s*mouseEventSource\s*:"), "builds a synthetic mouse event"),
    (re.compile(r"\bCGEvent\s*\(\s*scrollWheelEvent2Source\s*:"), "builds a synthetic scroll event"),
    (re.compile(r"\bCGEventCreate\w*Event\b"), "builds a synthetic event"),
    (re.compile(r"\bCGEventSource\s*\("), "creates an event source, which exists only to synthesise events"),
    (re.compile(r"\bAXUIElementPostKeyboardEvent\b"), "posts a synthetic event through the Accessibility API"),
    (re.compile(r"\bAXUIElementPerformAction\b"), "drives another app's UI through the Accessibility API"),
]

# The ONE sanctioned way to create a tap. Anything else is refused outright
# rather than inspected, because the C spellings take their options
# POSITIONALLY: there is no `options:` label to read, so "did it ask for
# listen-only" cannot be answered by looking at the call. One spelling that can
# be checked beats four that cannot.
FORBIDDEN_TAP_SPELLINGS = [
    (re.compile(r"\bCGEventTapCreate\w*\s*\("),
     "creates a tap through a C spelling whose options are positional and cannot be "
     "verified here; use CGEvent.tapCreate(options: .listenOnly)"),
    (re.compile(r"\bCGEvent\.tapCreateForPid\s*\("),
     "taps another process; use CGEvent.tapCreate(options: .listenOnly)"),
]

TAP_CREATE = re.compile(r"CGEvent\.tapCreate\s*\(")


def sanitize(source):
    """Blank comments and string literals, preserving length and line numbers.

    Every character that is not code becomes a space, and newlines are kept, so
    an offset into the result is an offset into the original and `line_of` stays
    honest. Handles what Swift actually has: nested block comments, line
    comments, single-line and multiline strings with backslash escapes, and raw strings
    with any number of hashes, in which backslash is not an escape.

    Blanking strings rather than leaving them is the whole fix described in the
    module docstring. It costs the ability to report a forbidden call spelled
    inside a string, which cannot execute anyway.
    """
    out = []
    i = 0
    n = len(source)

    def blank(text):
        out.append("".join(c if c == "\n" else " " for c in text))

    while i < n:
        ch = source[i]

        # Raw string: one or more #, then a quote. Backslash is not an escape.
        if ch == "#":
            j = i
            while j < n and source[j] == "#":
                j += 1
            hashes = j - i
            if hashes and source[j:j + 1] == '"':
                triple = source[j:j + 3] == '"""'
                opener = j + (3 if triple else 1)
                terminator = ('"""' if triple else '"') + ("#" * hashes)
                close = source.find(terminator, opener)
                stop = n if close == -1 else close + len(terminator)
                blank(source[i:stop])
                i = stop
                continue
            out.append(ch)
            i += 1
            continue

        if source[i:i + 3] == '"""':
            j = i + 3
            while j < n:
                if source[j] == "\\":
                    j += 2
                    continue
                if source[j:j + 3] == '"""':
                    j += 3
                    break
                j += 1
            else:
                j = n
            blank(source[i:j])
            i = j
            continue

        if ch == '"':
            j = i + 1
            while j < n:
                if source[j] == "\\":
                    j += 2
                    continue
                # An unterminated single-line string ends at the newline rather
                # than eating the rest of the file.
                if source[j] == '"' or source[j] == "\n":
                    j += 1 if source[j] == '"' else 0
                    break
                j += 1
            else:
                j = n
            blank(source[i:j])
            i = j
            continue

        if source[i:i + 2] == "//":
            j = source.find("\n", i)
            j = n if j == -1 else j
            blank(source[i:j])
            i = j
            continue

        # Swift block comments NEST.
        if source[i:i + 2] == "/*":
            depth = 0
            j = i
            while j < n:
                if source[j:j + 2] == "/*":
                    depth += 1
                    j += 2
                elif source[j:j + 2] == "*/":
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                else:
                    j += 1
            blank(source[i:j])
            i = j
            continue

        out.append(ch)
        i += 1

    return "".join(out)


def argument_text(source, open_paren_index):
    """Return the text between a call's parentheses, or None if unbalanced."""
    depth = 0
    i = open_paren_index
    n = len(source)
    while i < n:
        if source[i] == "(":
            depth += 1
        elif source[i] == ")":
            depth -= 1
            if depth == 0:
                return source[open_paren_index + 1:i]
        i += 1
    return None


def split_arguments(text):
    """Split a call's argument text on TOP-LEVEL commas only."""
    parts = []
    depth = 0
    current = []
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(ch)
    parts.append("".join(current))
    return [p.strip() for p in parts if p.strip()]


def labelled_argument(text, label):
    """The VALUE of `label:` in a call's arguments, or None if absent.

    Reading the labelled argument rather than searching the whole call is
    deliberate: the first version asked whether `.listenOnly` appeared anywhere
    between the parentheses, which a string, a comment or an unrelated argument
    could satisfy while `options:` held something else entirely.
    """
    for part in split_arguments(text):
        if part.startswith(label + ":"):
            return part[len(label) + 1:].strip()
    return None


def line_of(source, index):
    return source.count("\n", 0, index) + 1


def swift_files(repo):
    """Every shipping .swift file. Raises OSError if anything cannot be walked."""

    def refuse(error):
        # os.walk swallows errors by default, so a directory we cannot read
        # would silently contribute zero files and the run would still say
        # "clean". Not reading is not checking.
        raise error

    found = []
    for directory in SHIPPING_DIRS:
        root = os.path.join(repo, directory)
        if not os.path.isdir(root):
            raise OSError("not a directory: %s" % root)
        for dirpath, dirnames, filenames in os.walk(root, onerror=refuse):
            # Build output and checked-out dependencies are not ours to police.
            dirnames[:] = [d for d in dirnames if d not in (".build", "build", "SourcePackages")]
            for name in sorted(filenames):
                if name.endswith(".swift"):
                    found.append(os.path.join(dirpath, name))
    return sorted(found)


def check_source(relative_path, source):
    """Findings for one file, matched against sanitized source."""
    findings = []
    code = sanitize(source)

    def report(index, label, meaning):
        findings.append("%s:%d %s: %s" % (relative_path, line_of(code, index), label, meaning))

    for pattern, meaning in FORBIDDEN:
        for match in pattern.finditer(code):
            report(match.start(), match.group(0).strip(), meaning)

    for pattern, meaning in FORBIDDEN_TAP_SPELLINGS:
        for match in pattern.finditer(code):
            report(match.start(), match.group(0).strip(), meaning)

    for match in TAP_CREATE.finditer(code):
        open_paren = code.index("(", match.start())
        arguments = argument_text(code, open_paren)
        if arguments is None:
            report(match.start(), "CGEvent.tapCreate",
                   "unbalanced parentheses, so its options could not be read")
            continue
        options = labelled_argument(arguments, "options")
        if options is None:
            report(match.start(), "CGEvent.tapCreate",
                   "no options: argument, so the tap mode cannot be confirmed")
        elif options != ".listenOnly":
            report(match.start(), "CGEvent.tapCreate",
                   "options: is %s, not .listenOnly, which moves the app from the ListenEvent "
                   "privilege to Accessibility and out of the App Sandbox" % options)
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = parser.parse_args()

    repo = os.path.abspath(args.repo)

    try:
        files = swift_files(repo)
    except OSError as error:
        print("no-synthetic-events-check: COULD NOT CHECK: %s" % error)
        return 2

    if not files:
        print("no-synthetic-events-check: COULD NOT CHECK: no Swift files found under %s" % ", ".join(SHIPPING_DIRS))
        return 2

    findings = []
    for path in files:
        try:
            with open(path, encoding="utf-8") as handle:
                source = handle.read()
        except (OSError, UnicodeDecodeError) as error:
            print("no-synthetic-events-check: COULD NOT CHECK: %s: %s" % (path, error))
            return 2
        findings.extend(check_source(os.path.relpath(path, repo), source))

    if findings:
        print("no-synthetic-events-check: %d finding(s) in %d file(s)" % (len(findings), len(files)))
        for finding in findings:
            print("  %s" % finding)
        print("")
        print("  Delivery is the clipboard; Andrew presses Cmd-V himself (2026-08-05).")
        print("  Posting events is the PostEvent privilege and App Review has rejected")
        print("  a clipboard manager under Guideline 2.4.5 for exactly this.")
        return 1

    print("no-synthetic-events-check: clean. %d file(s): nothing posts an event, every tap is .listenOnly." % len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
