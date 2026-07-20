#!/usr/bin/env python3
"""Scan Swift source for a regex, in CODE or in STRING LITERALS, correctly.

Replaces the two hand-rolled half-parsers this project used before
(code-grep.py and string-literal-grep.py). They were written independently,
each understood a different subset of Swift, and Codex found a new hole in one
of them on three consecutive review rounds:

  round 7  a line-oriented grep could not tell a comment from a string
  round 8  the entity-table exception matched by path suffix
  round 9  three at once: interpolation was discarded as if it were not code,
           nested string literals inside interpolation vanished, and `/*` was
           treated as "ignore the rest of the line"

The pattern is the lesson. Three rounds of patching a hand-written lexer
produced three more holes, because each fix only taught it the one construct
the reviewer happened to name. One tokenizer that actually models Swift's
nesting removes the whole class instead of the reported instance.

What it models:
  - `//` line comments
  - `/* */` block comments, including Swift's legal nesting
  - single-quoted, triple-quoted, and raw strings with any leading hash count
  - escapes, including the raw-string forms `\\#n` and `\\#(`
  - `\\( ... )` interpolation, whose contents are CODE and are scanned as code,
    recursively, so a string inside an interpolation inside a string is still
    found

Known limit, stated rather than hidden: BARE regex literals of the form
/pattern/ are not modelled, only the extended #/pattern/# form. The bare form is
genuinely ambiguous with division and with comment markers, and Swift itself
resolves it with rules a lexer this size cannot carry. None exist in this
codebase today. If one is ever added, this tool may mis-tokenize the line, and
the correct response is to move the gate to SwiftSyntax rather than to add
another special case here.

This is a lexer, not a Swift parser. It
does not resolve types, macros or conditional compilation. It is meant to make
"is this token code or copy" reliable, which is all the two gates need. If a
future finding needs real semantics, the answer is SwiftSyntax (already a
transitive dependency of this project), not another patch here.

Usage:
  swift-scan.py --mode code   PATTERN PATH... [--allow PATH_REGEX]
  swift-scan.py --mode string PATTERN PATH... [--allow PATH_REGEX]

Prints  file:line:text  per hit. Exit 0 if no hits, 1 if any.
"""

import os
import re
import sys

ENTITY_TABLE_FILE = os.path.join("GhostPepper", "Reader", "ReaderCapture.swift")


def tokenize(src):
    """Return a list of (kind, lineno, text) with kind in {'code', 'string'}.

    Comments produce no tokens at all: they are neither code that can call
    anything nor copy that a user reads.
    """
    out = []
    i = 0
    n = len(src)
    line = 1
    buf = []
    buf_line = 1
    mode = "code"
    triple = False
    hashes = 0
    depth = 0
    stack = []
    lit_id = [0]

    def flush(kind):
        if buf:
            out.append((kind, buf_line, "".join(buf), lit_id[0] if kind == "string" else -1))
            del buf[:]

    while i < n:
        ch = src[i]

        if ch == "\n":
            flush(mode)
            line += 1
            i += 1
            buf_line = line
            continue

        if mode == "code":
            if src.startswith("//", i):
                flush("code")
                nl = src.find("\n", i)
                i = n if nl == -1 else nl
                continue

            if src.startswith("/*", i):
                flush("code")
                nest = 1
                i += 2
                while i < n and nest:
                    if src.startswith("/*", i):
                        nest += 1
                        i += 2
                        continue
                    if src.startswith("*/", i):
                        nest -= 1
                        i += 2
                        continue
                    if src[i] == "\n":
                        line += 1
                    i += 1
                buf_line = line
                continue

            # A # run introduces either a raw string (#"..."#) or an extended
            # regex literal (#/.../#). Both must be consumed here, before the
            # comment and paren logic below.
            j = i
            h = 0
            while j < n and src[j] == "#":
                h += 1
                j += 1

            # Extended regex literal. Codex round 10, HIGH: without this, the
            # `//` inside #/https:\/\/x/# was read as a line comment and hid the
            # rest of the line, and a `)` inside a regex could unbalance the
            # interpolation paren counter and move real code into a string
            # token. A regex pattern is neither executable code that can call a
            # service nor copy a user reads, so it yields no token at all, the
            # same treatment comments get.
            if h > 0 and j < n and src[j] == "/":
                flush("code")
                closer = "/" + ("#" * h)
                i = j + 1
                while i < n:
                    if src.startswith(closer, i):
                        i += len(closer)
                        break
                    if src[i] == "\\":
                        i += 2
                        continue
                    if src[i] == "\n":
                        line += 1
                    i += 1
                buf_line = line
                continue

            if j < n and src[j] == '"':
                flush("code")
                hashes = h
                if src.startswith('"""', j):
                    triple = True
                    i = j + 3
                else:
                    triple = False
                    i = j + 1
                mode = "string"
                lit_id[0] += 1
                buf_line = line
                continue

            if stack and stack[-1]["mode"] == "interp":
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    if depth == 0:
                        flush("code")
                        st = stack.pop()
                        triple = st["triple"]
                        hashes = st["hashes"]
                        depth = st["outer_depth"]
                        mode = "string"
                        i += 1
                        buf_line = line
                        continue
                    depth -= 1

            buf.append(ch)
            i += 1
            continue

        # mode == "string"
        esc = "\\" + ("#" * hashes)

        if src.startswith(esc + "(", i):
            flush("string")
            stack.append(
                {"mode": "interp", "triple": triple, "hashes": hashes,
                 "outer_depth": depth}
            )
            depth = 0
            mode = "code"
            i += len(esc) + 1
            buf_line = line
            continue

        if src.startswith(esc, i) and i + len(esc) < n:
            buf.append(src[i:i + len(esc) + 1])
            i += len(esc) + 1
            continue

        closer = ('"""' if triple else '"') + ("#" * hashes)
        if src.startswith(closer, i):
            flush("string")
            i += len(closer)
            mode = "code"
            buf_line = line
            continue

        buf.append(ch)
        i += 1

    flush(mode)
    return out


# Raw strings escape as \#u{...}, \##u{...} and so on, one # per delimiter
# hash. Codex round 11, HIGH: matching only \u{...} let #"\#u{2014}"# through.
UNICODE_ESCAPE = re.compile(r"\\#*u\{([0-9A-Fa-f]{1,8})\}")


def decode_escapes(text):
    """Turn \\u{2014} into the character it produces at runtime.

    Fable adversary finding 5: a banned character written as an escape never
    appears literally in the source, so a literal scan could never see it, while
    the compiled app prints it. What ships is what matters.
    """
    def sub(m):
        try:
            return chr(int(m.group(1), 16))
        except (ValueError, OverflowError):
            return m.group(0)
    return UNICODE_ESCAPE.sub(sub, text)


JOINABLE = re.compile(r"^[+()\s]*$")


def join_adjacent(tokens):
    """Merge string literals that Swift will concatenate into one value.

    Fable adversary findings 3 and 6: the credential and currency checks are
    regexes over one token, so "sk-ant-" + "api03_..." and "US" + "D 10" and
    "US\(\"\")D 10" all slip through while the compiled app reconstructs the
    banned value perfectly. Matching what the user or an attacker actually gets
    means matching the concatenation, not the fragments.

    Merges a run of string tokens when everything between them is only +,
    parentheses and whitespace. Deliberately conservative: it will not merge
    across a statement boundary, an identifier or a comma.
    """
    merged = []
    i = 0
    n = len(tokens)
    while i < n:
        kind, lineno, text, lid = tokens[i]
        if kind != "string":
            merged.append(tokens[i])
            i += 1
            continue
        parts = [text]
        ids = {lid}
        j = i + 1
        last = i
        while j < n:
            if tokens[j][0] == "string":
                parts.append(tokens[j][2])
                ids.add(tokens[j][3])
                last = j
                j += 1
                continue
            if JOINABLE.match(tokens[j][2]):
                j += 1
                continue
            break
        if last > i:
            merged.append(("string", lineno, "".join(parts), -1))
            i = last + 1
        else:
            merged.append(tokens[i])
            i += 1
    return merged

def is_entity_table_allowed(text, path):
    """The one deliberate exception, unchanged in scope.

    ReaderCapture.swift maps HTML entity names to the characters they decode to,
    so "&mdash;" is paired with a literal em dash. That character is data, not
    copy. Requires the exact file and a token whose entire content is the entity
    name or the single character it decodes to.

    RATIFIED by Andrew on 2026-07-20. This is the project's only allowlist
    exception to hard rule 9, and it is permanent unless ReaderCapture.swift is
    itself deleted (deferred to C6 with the rest of the inert cloud sources).

    Rejected alternative, recorded so nobody re-proposes it: rewriting the table
    to use "\\u{2014}" so no exception is needed at all. It looks cleaner and it
    is a false pass. decode_escapes deliberately resolves unicode escapes before
    matching, per the Fable adversary's finding 5 that a banned character written
    as an escape never appears in source but still ships in the binary. Editing
    source so a gate stops firing is the move LOOP.md forbids outright.
    """
    if os.path.normpath(path) != ENTITY_TABLE_FILE:
        return False
    # Escapes on purpose: this file must name the characters it allowlists
    # without containing them, so the rule 9 sweep over scripts/ needs no
    # exclusion for the verifier itself.
    return text in ("&mdash;", "\u2014", "&ndash;", "\u2013")


def main():
    args = sys.argv[1:]
    mode = "code"
    allow = None
    join_strings = False

    if "--mode" in args:
        k = args.index("--mode")
        mode = args[k + 1]
        args = args[:k] + args[k + 2:]
    if "--join" in args:
        args.remove("--join")
        join_strings = True
    if "--allow" in args:
        k = args.index("--allow")
        allow = re.compile(args[k + 1])
        args = args[:k] + args[k + 2:]

    if len(args) < 2 or mode not in ("code", "string"):
        sys.stderr.write(__doc__)
        return 2

    pattern = re.compile(args[0])
    hits = 0
    seen_dirs = set()

    for root in args[1:]:
        # followlinks=True. Fable adversary finding 4: os.walk skips symlinked
        # DIRECTORIES by default, so a source folder that is a symlink is never
        # scanned. This project already carries 12 file symlinks in
        # CleanupModelProbeSupport, so a directory symlink would read as
        # ordinary structure rather than as something suspicious. The inode set
        # stops a symlink cycle turning this into an infinite walk.
        for dirpath, dirnames, files in os.walk(root, followlinks=True):
            try:
                st = os.stat(dirpath)
                key = (st.st_dev, st.st_ino)
            except OSError:
                key = dirpath
            if key in seen_dirs:
                dirnames[:] = []
                continue
            seen_dirs.add(key)

            for name in sorted(files):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, name)
                if allow and allow.fullmatch(os.path.normpath(path)):
                    continue
                try:
                    with open(path, encoding="utf-8") as fh:
                        src = fh.read()
                except (OSError, UnicodeDecodeError) as exc:
                    # Fail CLOSED. Fable adversary finding 9: skipping an
                    # unreadable file silently meant chmod 000 on a file
                    # containing a live cloud call produced a clean report. A
                    # verifier that cannot read a file has not checked it, and
                    # must never imply otherwise.
                    #
                    # One exception, on evidence rather than convenience: a
                    # DANGLING symlink resolves to nothing, so it provably
                    # cannot hide a violation. It is reported as a note so it
                    # stays visible, but it does not fail the gate. A symlink
                    # that resolves is read and scanned normally.
                    if os.path.islink(path) and not os.path.exists(path):
                        sys.stderr.write(
                            "note  dangling symlink, nothing to scan: %s\n" % path
                        )
                        continue
                    print("%s:0:UNREADABLE, not checked: %s" % (path, exc))
                    hits += 1
                    continue

                lines = src.split("\n")
                tokens = tokenize(src)
                if join_strings:
                    tokens = join_adjacent(tokens)

                # A literal split by interpolation yields several tokens sharing
                # one id, so requiring a unique id is how the entity exception
                # demands a WHOLE literal (Fable adversary finding 7).
                counts = {}
                for kind, _ln, _tx, lid in tokens:
                    if kind == "string" and lid >= 0:
                        counts[lid] = counts.get(lid, 0) + 1

                for kind, lineno, text, lid in tokens:
                    if kind != mode:
                        continue
                    text = decode_escapes(text)
                    if not pattern.search(text):
                        continue
                    if mode == "string" and counts.get(lid) == 1 and \
                            is_entity_table_allowed(text, path):
                        continue
                    shown = lines[lineno - 1].strip() if lineno <= len(lines) else text
                    print("%s:%d:%s" % (path, lineno, shown))
                    hits += 1

    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
