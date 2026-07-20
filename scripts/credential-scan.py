#!/usr/bin/env python3
"""Scan every file in the repo for credential-shaped literals.

Codex round 11, HIGH: the credential check was a plain `grep -r`, so it never
got the protections the Swift scanner had already gained. It did not follow
symlinked directories, and it skipped unreadable files silently. A credential in
a non-Swift file behind a symlink was invisible to the required gate.

Same rules as swift-scan.py, and for the same reasons:
  - follow symlinked directories, with an inode guard against cycles
  - fail CLOSED on an unreadable file, because not reading is not checking
  - a dangling symlink is a note, not a failure: it resolves to nothing and so
    provably holds nothing

Usage: credential-scan.py ROOT
Prints  file:line:text  per hit. Exit 0 if none, 1 if any.
"""

import os
import re
import sys

PATTERN = re.compile(
    r"(sk-ant-[A-Za-z0-9_-]{20,}"
    r"|zo_sk_[A-Za-z0-9_-]{16,}"
    r"|xox[baprs]-[A-Za-z0-9-]{20,}"
    r"|ghp_[A-Za-z0-9_]{20,}"
    r"|github_pat_[A-Za-z0-9_]{20,}"
    r"|AKIA[0-9A-Z]{16}"
    r"|AIza[0-9A-Za-z_-]{30,}"
    r"|Bearer [A-Za-z0-9._~+/=-]{20,}"
    r"|-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----)"
)

SKIP_DIRS = {".git", "build", "xcuserdata", "DerivedData", ".handoff"}


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    hits = 0
    seen = set()

    for dirpath, dirnames, files in os.walk(root, followlinks=True):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        try:
            st = os.stat(dirpath)
            key = (st.st_dev, st.st_ino)
        except OSError:
            key = dirpath
        if key in seen:
            dirnames[:] = []
            continue
        seen.add(key)

        for name in sorted(files):
            path = os.path.join(dirpath, name)
            try:
                with open(path, "rb") as fh:
                    raw = fh.read()
            except OSError as exc:
                if os.path.islink(path) and not os.path.exists(path):
                    sys.stderr.write("note  dangling symlink, nothing to scan: %s\n" % path)
                    continue
                print("%s:0:UNREADABLE, not checked: %s" % (path, exc))
                hits += 1
                continue

            if b"\x00" in raw[:8000]:
                continue
            try:
                text = raw.decode("utf-8", errors="replace")
            except Exception:
                continue

            for num, line in enumerate(text.split("\n"), 1):
                if PATTERN.search(line):
                    print("%s:%d:%s" % (path, num, line.strip()[:160]))
                    hits += 1

    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
