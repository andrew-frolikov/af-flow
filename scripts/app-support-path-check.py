#!/usr/bin/env python3
"""Nothing in this repo may name his data folder by hand.

WHY THIS EXISTS. `AppSupportDirectory.swift` was written so a rename could not
orphan his data, and on 2026-08-25 the rename orphaned it anyway: two Swift
call sites and eight script literals spelled the folder themselves, so a find
and replace pointed them at `AFFlow` while the migration moved the real folder
to `AF Flow`. The app then re-downloaded 1.25 GB of models into the empty one
and the runtime probe reported no dictation history at all.

An XCTest can pin the Swift half. Nothing pinned the scripts, and the scripts
are what I read the app's behaviour through, so their failure is the silent
one. This checks both halves from outside the suite.

Exit states, three of them, because a source that cannot be READ returns
exactly what a clean one does:

    0  clean
    1  findings
    2  a source could not be read
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# CleanupModelProbe is a built executable that reads his cleanup models through
# TextCleanupManager, so a hand-built path in it fails exactly the same way and
# no XCTest covers it. Codex, round 2 of 2026-08-26.
SCANNED_DIRS = ("AFFlow", "AFFlowTests", "CleanupModelProbe", "CleanupModelProbeSupport", "scripts")
SCANNED_SUFFIXES = (".swift", ".py", ".sh")

# The two files allowed to know the answer, plus this checker, which has to
# quote what it bans.
# The files allowed to know the answer: the two that decide it, plus the two
# guards, which have to quote what they ban in order to look for it.
OWNERS = (
    "AppSupportDirectory.swift",
    "af_paths.py",
    "app-support-path-check.py",
    "AppSupportPathOwnershipTests.swift",
)

# The folder has worn three names. All three are banned in a data path, because
# the defect this catches is exactly a rename carrying a literal with it.
FAMILY = r"(?:AF Flow|AFFlow|GhostPepper)"

# `AFFlow` is deliberately absent from this one. It is also the name of the
# source directory and the module, so `os.path.join(REPO, "AFFlow")` and
# `repositoryRoot().appendingPathComponent("AFFlow")` are legitimate and
# common. A bare-name rule including it flagged six of those and would have
# trained a reader to ignore the check. Under Application Support it is still
# caught by the rules above, which key on a data child or the container path,
# and the app now absorbs that folder on launch either way.
UNAMBIGUOUS = r"(?:AF Flow|GhostPepper)"

RULES = (
    (
        re.compile(r"Library/Containers/com\.frolikov"),
        "builds one of his container paths by hand",
    ),
    (
        re.compile(r"Application Support[/\\][\"']?" + FAMILY),
        "names his data folder under Application Support",
    ),
    (
        # A literal that STARTS with the folder name and continues into a data
        # child. The lowercase requirement is what separates `AFFlow/models`
        # from `AFFlow/Transcription/ModelManager.swift`: his data children are
        # lowercase, the source tree's are not. Repo-relative source paths are
        # legitimate and appear all over the scripts.
        re.compile(r"[\"']" + FAMILY + r"/[a-z]"),
        "names a folder inside his data by hand",
    ),
    (
        # Codex, 2026-08-26: a base obtained elsewhere and then joined with a
        # bare `"AF Flow"` matched none of the rules above, because the literal
        # has no lowercase child and the line names neither Application Support
        # nor the API. Keyed on the path CALL, not the bare string, so the
        # hundreds of places that legitimately display the name are untouched.
        re.compile(
            r"(?:appendingPathComponent|os\.path\.join|Path\()[^\n]*[\"']"
            + UNAMBIGUOUS
            + r"[\"']"
        ),
        "joins a path onto his data folder by name",
    ),
    (
        re.compile(r"\.applicationSupportDirectory"),
        "asks the file system where Application Support is",
    ),
)

REMEDY = (
    "Use scripts/af_paths.py (python: `import af_paths`; shell: "
    "`python3 scripts/af_paths.py --print app`) or, in Swift, AppSupportDirectory."
)


def is_comment(line, suffix):
    stripped = line.strip()
    if suffix == ".swift":
        return stripped.startswith("//") or stripped.startswith("///")
    return stripped.startswith("#")


def scan_file(path, suffix):
    """Findings in one file. Raises OSError if it cannot be read."""
    findings = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            if is_comment(line, suffix):
                continue
            for pattern, why in RULES:
                if pattern.search(line):
                    findings.append((number, why, line.strip()))
                    break
    return findings


def files_to_scan(root):
    for relative in SCANNED_DIRS:
        base = os.path.join(root, relative)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirnames, filenames in os.walk(base):
            for name in sorted(filenames):
                if not name.endswith(SCANNED_SUFFIXES):
                    continue
                if name in OWNERS:
                    continue
                yield os.path.join(dirpath, name)


def run(root, quiet=False):
    scanned = 0
    findings = []
    unreadable = []

    for path in files_to_scan(root):
        suffix = os.path.splitext(path)[1]
        try:
            hits = scan_file(path, suffix)
        except OSError as exc:
            unreadable.append((path, exc))
            continue
        scanned += 1
        for number, why, text in hits:
            findings.append((os.path.relpath(path, root), number, why, text))

    if scanned == 0:
        unreadable.append((root, "nothing was scanned, so this verified nothing"))

    if not quiet:
        for path, exc in unreadable:
            print("UNREADABLE  %s: %s" % (path, exc))
        for path, number, why, text in findings:
            print("%s:%d  %s" % (path, number, why))
            print("            %s" % text[:120])
        if findings:
            print("")
            print(REMEDY)
        else:
            print("ok    %d file(s) scanned, none names his data folder by hand" % scanned)

    # Findings win. Both states fail the sweep, but exit 1 is the actionable
    # one, and returning 2 while holding findings would hide them behind a
    # "could not read" that reads like a skip.
    if findings:
        return 1
    return 2 if unreadable else 0


def selftest():
    """Stage the real defect and watch the checker catch it.

    A guard only ever seen passing is a claim. This plants the exact line the
    2026-08-25 rename produced, and a clean file beside it, and fails if the
    checker cannot tell them apart.
    """
    root = tempfile.mkdtemp(prefix="af-flow-path-check-selftest-")
    try:
        source_dir = os.path.join(root, "AFFlow")
        os.makedirs(source_dir)
        with open(os.path.join(source_dir, "Offender.swift"), "w", encoding="utf-8") as handle:
            handle.write(
                'let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!\n'
                'return appSupport.appendingPathComponent("AFFlow/whisper-models", isDirectory: true)\n'
            )
        code = run(root, quiet=True)
        if code != 1:
            print("SELFTEST FAILED: the rename's own line was not caught (exit %d)" % code)
            return 1

        os.remove(os.path.join(source_dir, "Offender.swift"))
        # The gap Codex found: a base from somewhere else, joined with a bare
        # folder name. It matched nothing until the rule above existed.
        with open(os.path.join(source_dir, "BareName.swift"), "w", encoding="utf-8") as handle:
            handle.write('return base.appendingPathComponent("AF Flow", isDirectory: true)\n')
        code = run(root, quiet=True)
        if code != 1:
            print("SELFTEST FAILED: a bare folder name handed to a path API was not caught (exit %d)" % code)
            return 1
        os.remove(os.path.join(source_dir, "BareName.swift"))
        with open(os.path.join(source_dir, "Clean.swift"), "w", encoding="utf-8") as handle:
            handle.write("return AppSupportDirectory.url.appendingPathComponent(\"models\")\n")
        code = run(root, quiet=True)
        if code != 0:
            print("SELFTEST FAILED: a clean file was reported as a finding (exit %d)" % code)
            return 1

        print("ok    selftest: the rename's line is caught, a clean file is not")
        return 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true", help="prove the checker can go red")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    # Two lines, because every checker here is read through `sed -n '3,$p'` at
    # session start. Without them that sed ate the first finding, which is the
    # line naming the file. Codex, round 2 of 2026-08-26.
    title = "Does anything name his data folder by hand"
    print(title)
    print("-" * len(title))
    code = run(REPO_ROOT)
    print("")
    print("RESULT: %s" % {0: "clean", 1: "findings", 2: "a source could not be read"}[code])
    return code


if __name__ == "__main__":
    sys.exit(main())
