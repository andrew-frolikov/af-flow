#!/usr/bin/env python3
"""Register a new Swift file in AFFlow.xcodeproj/project.pbxproj.

There is no xcodegen on this machine, so the pbxproj is hand-maintained. A
Swift file that exists on disk but is not in a Sources build phase compiles
into nothing and its tests never run: 56 tests had never once executed before
2026-08-03 for exactly that reason. `scripts/test-registration-check.py`
catches it after the fact; this puts the file in correctly the first time.

Four edits are needed per file, and missing any one of them fails silently:

  1. PBXBuildFile          the "in Sources" entry
  2. PBXFileReference      the file itself
  3. the group             so it appears in Xcode's navigator
  4. PBXSourcesBuildPhase  the only one that actually compiles it

This works by copying the placement of a file that is ALREADY registered
correctly, rather than by parsing the pbxproj grammar. A sibling in the same
directory is registered in the same four places, so its four line positions are
the right four positions.

    python3 scripts/add-swift-file.py AFFlow/Foo.swift --like PermissionCensus.swift

Ids are derived from the file name, so a rerun is a no-op rather than a
duplicate.
"""

import argparse
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "AFFlow.xcodeproj", "project.pbxproj")

BUILD_FILE_PATTERN = re.compile(
    r"^\s*([0-9A-F]{24}) /\* (?P<name>.+?) in Sources \*/ = \{isa = PBXBuildFile; "
    r"fileRef = ([0-9A-F]{24}) /\* (?P=name) \*/; \};"
)


def object_id(name, salt):
    """A stable 24-hex-character id, the shape Xcode uses."""
    return hashlib.sha1((salt + ":" + name).encode()).hexdigest().upper()[:24]


def mentions(line, name):
    return ("/* %s " % name) in line or ("/* %s */" % name) in line


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", help="repo-relative path of the new Swift file")
    parser.add_argument(
        "--like",
        required=True,
        help="file name of an already-registered sibling to copy placement from",
    )
    args = parser.parse_args()

    name = os.path.basename(args.path)
    if not name.endswith(".swift"):
        sys.exit("Only .swift files. Got: " + name)
    if not os.path.exists(os.path.join(ROOT, args.path)):
        sys.exit("No such file on disk: " + args.path)

    with open(PBXPROJ) as handle:
        lines = handle.readlines()

    if any(mentions(line, name) for line in lines):
        print("already registered: %s" % name)
        return 0

    sibling = args.like
    anchors = [i for i, line in enumerate(lines) if mentions(line, sibling)]
    if len(anchors) != 4:
        sys.exit(
            "Expected 4 pbxproj lines for the sibling %s, found %d. "
            "Pick a sibling that is registered normally." % (sibling, len(anchors))
        )

    # The PBXBuildFile line is the only one carrying BOTH ids, so it is what
    # tells us which of the sibling's two ids is which. Without it the single-id
    # lines are ambiguous and a wrong guess produces a project that opens fine
    # and builds the wrong file.
    sibling_ids = None
    for index in anchors:
        match = BUILD_FILE_PATTERN.match(lines[index])
        if match:
            sibling_ids = (match.group(1), match.group(3))
            break
    if sibling_ids is None:
        sys.exit("Could not find the PBXBuildFile line for %s." % sibling)

    sibling_build_id, sibling_file_id = sibling_ids
    build_id = object_id(name, "build")
    file_id = object_id(name, "file")

    # Descending, so the earlier insertion points stay valid.
    for index in sorted(anchors, reverse=True):
        new_line = (
            lines[index]
            .replace(sibling_build_id, build_id)
            .replace(sibling_file_id, file_id)
            .replace(sibling, name)
        )
        lines.insert(index + 1, new_line)

    with open(PBXPROJ, "w") as handle:
        handle.writelines(lines)

    print("registered %s (build %s, file %s)" % (name, build_id, file_id))
    return 0


if __name__ == "__main__":
    sys.exit(main())
