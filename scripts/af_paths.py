#!/usr/bin/env python3
"""Where AF Flow keeps its data, read from the app's own source.

WHY THIS EXISTS. On 2026-08-25 the rename find-and-replaced `GhostPepper` into
`AFFlow` inside path literals, while the migration in `AppSupportDirectory`
moved the real folder to `AF Flow`. Eight script literals and two Swift call
sites went with it, so the runtime probe read an empty directory and reported
that he had never dictated, on a day his debug log grew by megabytes.

So no script names that folder any more. This module reads it out of
`AFFlow/AppSupportDirectory.swift`, which is the one place allowed to decide
it, and a wrong answer here raises instead of returning a plausible path.
"""

import argparse
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_OF_TRUTH = os.path.join(REPO_ROOT, "AFFlow", "AppSupportDirectory.swift")

BUNDLE_ID = "com.frolikov.afflow"
TEST_HOST_BUNDLE_ID = "com.frolikov.afflow.testhost"


class FolderNameUnreadable(RuntimeError):
    """The Swift constant could not be read, which is not the same as absent."""


def _swift_constant(name):
    try:
        with open(SOURCE_OF_TRUTH, encoding="utf-8") as handle:
            source = handle.read()
    except OSError as exc:
        raise FolderNameUnreadable("cannot read %s: %s" % (SOURCE_OF_TRUTH, exc))

    match = re.search(r'static let %s = "([^"]+)"' % re.escape(name), source)
    if not match:
        raise FolderNameUnreadable(
            "%s no longer declares %s, so this module cannot know where the data lives"
            % (SOURCE_OF_TRUTH, name)
        )
    return match.group(1)


def folder_name():
    return _swift_constant("folderName")


def legacy_folder_name():
    return _swift_constant("legacyFolderName")


def interim_folder_name():
    """The folder the rename's find and replace created. See the Swift file."""
    return _swift_constant("interimFolderName")


def resolve(base):
    """Mirror `AppSupportDirectory.resolve`, WITHOUT moving anything.

    The app migrates; a reader must never touch his files. So this returns the
    legacy folder when that is the one holding the data, and otherwise returns
    the current name whether or not it exists yet.
    """
    current = os.path.join(base, folder_name())
    if os.path.isdir(current):
        return current
    legacy = os.path.join(base, legacy_folder_name())
    if os.path.isdir(legacy):
        return legacy
    return current


def container_base(bundle_id):
    return os.path.expanduser(
        "~/Library/Containers/%s/Data/Library/Application Support" % bundle_id
    )


def unsandboxed_base():
    return os.path.expanduser("~/Library/Application Support")


def app_support():
    """The sandboxed app's folder: debug log, meetings, lab, models."""
    return resolve(container_base(BUNDLE_ID))


def test_host_support():
    """The test host's own folder. A separate container, on purpose."""
    return resolve(container_base(TEST_HOST_BUNDLE_ID))


def unsandboxed_support():
    """Where the command-line probes land, since they have no container."""
    return resolve(unsandboxed_base())


def candidates(base):
    """Every folder that could hold his data, best first.

    Codex, round 2 of 2026-08-26: `resolve` answers "where does the app WRITE",
    and a reader that stops there cannot see a file which exists only in the
    folder the rename created. The Swift side absorbs that folder on launch;
    these scripts never run it, so between a stale build and the next launch a
    reader would report nothing staged and the eval would skip, exit 0.
    """
    seen, out = set(), []
    for name in (folder_name(), legacy_folder_name(), interim_folder_name()):
        path = os.path.join(base, name)
        if path in seen:
            continue
        seen.add(path)
        if os.path.isdir(path):
            out.append(path)
    current = os.path.join(base, folder_name())
    return out or [current]


def find(relative, base=None):
    """The first folder that actually holds `relative`, else where it belongs.

    Returning the canonical path when nothing has it is deliberate: the caller
    then prints a path that says where the thing SHOULD be, which is the useful
    message, rather than one that happens to be a stray.
    """
    base = base if base is not None else container_base(BUNDLE_ID)
    for folder in candidates(base):
        candidate = os.path.join(folder, relative)
        if os.path.exists(candidate):
            return candidate
    return os.path.join(base, folder_name(), relative)


def app_find(relative):
    return find(relative, container_base(BUNDLE_ID))


def test_host_find(relative):
    return find(relative, container_base(TEST_HOST_BUNDLE_ID))


TARGETS = {
    "app": app_support,
    "testhost": test_host_support,
    "unsandboxed": unsandboxed_support,
    "folder-name": folder_name,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--print", dest="target", choices=sorted(TARGETS), required=True)
    parser.add_argument(
        "--find",
        help="a path relative to the folder, resolved against every folder that could hold it",
    )
    args = parser.parse_args()
    try:
        if args.find:
            base = container_base(TEST_HOST_BUNDLE_ID) if args.target == "testhost" else (
                unsandboxed_base() if args.target == "unsandboxed" else container_base(BUNDLE_ID)
            )
            print(find(args.find, base))
            return 0
        print(TARGETS[args.target]())
    except FolderNameUnreadable as exc:
        sys.stderr.write("af_paths: %s\n" % exc)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
