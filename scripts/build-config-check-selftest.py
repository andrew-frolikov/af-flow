#!/usr/bin/env python3
"""Stage each disagreement `build-config-check.py` must catch, and watch it react.

The pbxproj is hand-maintained on this machine: there is no xcodegen here, so
`project.yml` is a DESCRIPTION of the project rather than its source. A
description nobody executes drifts, and on 2026-08-30 it had: project.yml said
`ENABLE_HARDENED_RUNTIME: NO` while both real configurations said YES. Nothing
was broken by that particular drift, which is the point. The next one decides
whether a distribution build is debuggable.

Every state below is staged against synthesised files, so this runs offline and
in under a second.

Exit 0 all states distinguished, 1 otherwise.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CHECK = os.path.join(HERE, "build-config-check.py")

results = []


def check(label, condition, detail=""):
    results.append(bool(condition))
    print(f"{'PASS' if condition else 'FAIL'}  {label}")
    if detail and not condition:
        print("        " + str(detail).replace("\n", "\n        "))
    return bool(condition)


# Real object identifiers: the parser keys on the target's configuration list
# rather than on every XCBuildConfiguration in the file, because the project
# also carries configurations for the test bundle and the probe tool, and a
# check that read those too would assert the wrong rules against them.
PBX_TEMPLATE = """// !$*UTF8*$!
{{
/* Begin XCBuildConfiguration section */
\t\tE539A0CB0CD4C3B8D54B2855 /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{debug}
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t1E4BC3C9A2D9995B5339A1F0 /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{release}
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */
/* Begin XCConfigurationList section */
\t\t0B62CC6358D7DB2D8265F051 /* Build configuration list for PBXNativeTarget "AFFlow" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\tE539A0CB0CD4C3B8D54B2855 /* Debug */,
\t\t\t\t1E4BC3C9A2D9995B5339A1F0 /* Release */,
\t\t\t);
\t\t}};
/* End XCConfigurationList section */
}}
"""

GOOD_DEBUG = {
    "ENABLE_APP_SANDBOX": "YES",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "CODE_SIGN_ENTITLEMENTS": "AFFlow/AFFlow.entitlements",
}

GOOD_RELEASE = dict(GOOD_DEBUG, CODE_SIGN_INJECT_BASE_ENTITLEMENTS="NO")


def settings_block(mapping):
    return "\n".join(f"\t\t\t\t{k} = {v};" for k, v in sorted(mapping.items()))


GOOD_YML = """name: AFFlow
targets:
  AFFlow:
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: AFFlow/AFFlow.entitlements
        ENABLE_APP_SANDBOX: YES
      configs:
        Debug:
          ENABLE_HARDENED_RUNTIME: YES
        Release:
          ENABLE_HARDENED_RUNTIME: YES
          CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO
"""


def stage(root, debug=None, release=None, yml=None):
    where = tempfile.mkdtemp(dir=root)
    os.makedirs(os.path.join(where, "AFFlow.xcodeproj"))
    with open(os.path.join(where, "AFFlow.xcodeproj", "project.pbxproj"),
              "w", encoding="utf-8") as handle:
        handle.write(PBX_TEMPLATE.format(
            debug=settings_block(GOOD_DEBUG if debug is None else debug),
            release=settings_block(GOOD_RELEASE if release is None else release)))
    with open(os.path.join(where, "project.yml"), "w", encoding="utf-8") as handle:
        handle.write(GOOD_YML if yml is None else yml)
    return where


def run(where):
    return subprocess.run([sys.executable, CHECK, "--repo", where],
                          capture_output=True, text=True)


def main():
    if not os.path.exists(CHECK):
        print(f"FAIL  {CHECK} does not exist")
        print("\n1 state(s) not distinguished")
        return 1

    with tempfile.TemporaryDirectory() as root:
        got = run(stage(root))
        check("a project whose two files agree is clean",
              got.returncode == 0, got.stdout + got.stderr)

        got = run(stage(root, release=dict(GOOD_RELEASE, ENABLE_APP_SANDBOX="NO")))
        check("Release losing the App Sandbox is refused",
              got.returncode == 1, got.stdout + got.stderr)

        got = run(stage(root, release=dict(GOOD_RELEASE,
                                           ENABLE_HARDENED_RUNTIME="NO")))
        check("Release without the hardened runtime is refused",
              got.returncode == 1, got.stdout + got.stderr)

        without = dict(GOOD_RELEASE)
        without.pop("CODE_SIGN_INJECT_BASE_ENTITLEMENTS")
        got = run(stage(root, release=without))
        check("Release that never says no to injected base entitlements is "
              "refused, because get-task-allow arrives by default",
              got.returncode == 1, got.stdout + got.stderr)
        check("that refusal names get-task-allow",
              "get-task-allow" in (got.stdout + got.stderr),
              got.stdout + got.stderr)

        got = run(stage(root, release=dict(GOOD_RELEASE,
                                           CODE_SIGN_ENTITLEMENTS="Other.entitlements")))
        check("a Release configuration pointed at another entitlements file "
              "is refused",
              got.returncode == 1, got.stdout + got.stderr)

        # The drift that was actually there on 2026-08-30.
        drifted = GOOD_YML.replace("        Debug:\n          "
                                   "ENABLE_HARDENED_RUNTIME: YES",
                                   "        Debug:\n          "
                                   "ENABLE_HARDENED_RUNTIME: NO")
        got = run(stage(root, yml=drifted))
        check("project.yml contradicting the real pbxproj is refused",
              got.returncode == 1, got.stdout + got.stderr)
        check("the drift finding names both files",
              "project.yml" in (got.stdout + got.stderr)
              and "pbxproj" in (got.stdout + got.stderr),
              got.stdout + got.stderr)

        # Codex review, 2026-08-30: a key absent from project.yml used to be
        # skipped, so the file could lose a setting and this still said clean.
        silent = GOOD_YML.replace("          CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO\n", "")
        got = run(stage(root, yml=silent))
        check("a required key missing from project.yml is a finding, not a skip",
              got.returncode == 1, got.stdout + got.stderr)

        # Review, 2026-08-30: the pbxproj reader was wrapped and this one was
        # not, so an unreadable project.yml exited 1 and session-start rendered
        # it as "ACT ON THIS" rather than "COULD NOT CHECK".
        where = stage(root)
        with open(os.path.join(where, "project.yml"), "wb") as handle:
            handle.write(b"\xff\xfe\x00\x00 not text at all")
        got = run(where)
        check("an unreadable project.yml is 'could not check', not a finding",
              got.returncode == 2, got.stdout + got.stderr)

        missing = os.path.join(root, "nothing-here")
        os.makedirs(missing, exist_ok=True)
        got = run(missing)
        check("a repo with no project files is 'could not check', not clean",
              got.returncode == 2, got.stdout + got.stderr)

    print()
    failed = results.count(False)
    if failed:
        print(f"{failed} state(s) not distinguished")
        return 1
    print(f"all {len(results)} state(s) distinguished")
    return 0


if __name__ == "__main__":
    sys.exit(main())
