#!/usr/bin/env python3
"""Every test file in AFFlowTests must be registered in the Xcode project.

WHY THIS EXISTS. On 2026-08-02 a new test file, `MeetingNamingTests.swift`, was
written, saved, and run. The runner printed:

    Executed 0 tests, with 0 failures (0 unexpected)
    ** TEST EXECUTE SUCCEEDED **

The file was not in `project.pbxproj`, so it compiled into nothing and ran
nothing, and the suite called that success. It was only caught because the run
was a canary that was SUPPOSED to go red, and did not.

That is the project's signature failure wearing yet another face: a green
result asserting something that never executed. The suite cannot notice this on
its own, because from its point of view nothing is wrong: a test that does not
exist cannot fail. So it needs a check outside the suite.

`project.yml` globs the whole `AFFlowTests` directory, so anyone
regenerating with XcodeGen picks new files up automatically. But xcodegen is not
installed on this machine and `project.pbxproj` is committed and hand-edited,
which is exactly the gap this closes.

Exit 1 on any unregistered file, so the boundary sweep fails.
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(REPO, "AFFlow.xcodeproj", "project.pbxproj")
TEST_DIRS = ["AFFlowTests"]


def main():
    try:
        with open(PBXPROJ) as handle:
            project = handle.read()
    except OSError as error:
        print("test-registration: cannot read the project file: %s" % error)
        return 1

    missing, unbuilt, checked = [], [], 0
    for directory in TEST_DIRS:
        root = os.path.join(REPO, directory)
        if not os.path.isdir(root):
            continue
        for dirpath, _, filenames in os.walk(root):
            for name in sorted(filenames):
                if not name.endswith(".swift"):
                    continue
                checked += 1
                # A file is only actually RUN if it appears in a Sources build
                # phase. A bare PBXFileReference makes it visible in Xcode's
                # navigator and compiles nothing, which is a failure mode that
                # looks even more convincing than being absent entirely.
                if name not in project:
                    missing.append(os.path.join(directory, name))
                elif not re.search(
                    re.escape(name) + r" in Sources \*/", project
                ):
                    unbuilt.append(os.path.join(directory, name))

    print("test-registration")
    print("-" * len("test-registration"))
    print("ok    %d test file(s) checked against project.pbxproj" % checked)

    if not missing and not unbuilt:
        print("ok    every test file is in a Sources build phase")
        print("\nRESULT: clean")
        return 0

    for path in missing:
        print("FAIL  %s is not in project.pbxproj at all: it runs NOTHING" % path)
    for path in unbuilt:
        print("FAIL  %s is referenced but not in a Sources build phase: it runs NOTHING" % path)
    print()
    print("A test file the project does not build reports 'Executed 0 tests' and")
    print("'TEST EXECUTE SUCCEEDED'. Add it to project.pbxproj (four entries:")
    print("PBXBuildFile, PBXFileReference, the group's children, and the target's")
    print("Sources phase), then re-run.")
    print("\nRESULT: %d failure(s)" % (len(missing) + len(unbuilt)))
    return 1


if __name__ == "__main__":
    sys.exit(main())
