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
    python3 scripts/add-swift-file.py AFFlow/Resources/clip.wav \\
        --phase Resources --like hero-poster-graded.jpg

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

# EXTENDED 2026-08-30 TO REGISTER RESOURCES TOO, because Phase 3 of the launch
# plan bundles two benchmark clips and Phases 5 and 8 bundle more. The four
# edits and the failure mode are identical; only the build phase's name and the
# accepted extension differ, so a second near-identical script would have been
# a second place to fix the next bug found in this one. The file keeps its name
# so existing references stay valid; `--phase Resources` is the new door.
#
# The sibling's PBXBuildFile line is matched with the phase name in it, which is
# what makes the phase real rather than decorative: asking for Resources and
# naming a Swift sibling finds no anchor and stops, instead of quietly adding
# the file to the wrong phase.
def build_file_pattern(phase):
    # NOT {24}. Xcode writes 24-hex ids and so does this script, but the
    # resources in this project were registered by hand with 22-character ids
    # (`C1B0000000000000000011`), and a pattern demanding 24 silently matched
    # none of them: the script reported "could not find the PBXBuildFile line"
    # for a sibling that was sitting right there. Found on the first real use,
    # 2026-08-30.
    return re.compile(
        r"^\s*([0-9A-F]{16,32}) /\* (?P<name>.+?) in %s \*/ = \{isa = PBXBuildFile; "
        r"fileRef = ([0-9A-F]{16,32}) /\* (?P=name) \*/; \};" % re.escape(phase)
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
    parser.add_argument(
        "--phase",
        default="Sources",
        choices=["Sources", "Resources"],
        help="which build phase the sibling is in (default: Sources)",
    )
    args = parser.parse_args()

    name = os.path.basename(args.path)
    if args.phase == "Sources" and not name.endswith(".swift"):
        sys.exit("Sources takes .swift files. Got: " + name)
    if args.phase == "Resources" and name.endswith(".swift"):
        sys.exit("A .swift file belongs in Sources, not Resources: " + name)
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
    pattern = build_file_pattern(args.phase)
    sibling_ids = None
    for index in anchors:
        match = pattern.match(lines[index])
        if match:
            sibling_ids = (match.group(1), match.group(3))
            break
    if sibling_ids is None:
        sys.exit(
            "Could not find the PBXBuildFile line for %s in the %s phase. "
            "Either the sibling is in a different phase, or it is registered "
            "in a way this cannot copy." % (sibling, args.phase)
        )

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
