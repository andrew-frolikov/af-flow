#!/usr/bin/env python3
"""Assert the build settings a distribution build depends on, in both places that state them.

WHY TWO PLACES. There is no xcodegen on this machine, so `AFFlow.xcodeproj`
is hand-maintained and `project.yml` is a DESCRIPTION of it rather than its
source. Xcode reads only the pbxproj. Every human and every agent reads only
project.yml, because it is 80 lines instead of 1700. So project.yml is the file
that decides what everyone BELIEVES and the pbxproj is the file that decides
what is TRUE, and nothing has ever compared them.

They had already drifted when this was written on 2026-08-30: project.yml said
`ENABLE_HARDENED_RUNTIME: NO` while both real configurations said YES. That
particular drift was harmless, which is exactly why it survived. The next one
decides whether the app Andrew hands his friends is debuggable, or sandboxed.

WHAT IT ASSERTS, per configuration of the AFFlow target:

  ENABLE_APP_SANDBOX = YES        both. The sandbox is the boundary.
  ENABLE_HARDENED_RUNTIME = YES   both. Release needs it to notarize; Debug
                                  has carried it since before this check, and
                                  keeping them the same means Release is not
                                  the first build to meet it.
  CODE_SIGN_ENTITLEMENTS          both, and the same file. Two entitlement
                                  files is how a boundary holds in one
                                  configuration and not the other.
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO   Release only. Xcode injects
                                  `com.apple.security.get-task-allow` when
                                  this is left at its default, and a
                                  debuggable distribution build lets any
                                  process attach to the app holding his
                                  microphone. `bundle-boundary-check.py`
                                  catches it in the built artefact; this
                                  catches it in the file, before a build.

Unreadable is not a pass: exit 2 means the check did not happen.

Usage:  build-config-check.py [--repo PATH]
Exit 0 clean, 1 findings, 2 could not check.
"""

import argparse
import os
import re
import sys

CLEAN, FINDINGS, UNCHECKED = 0, 1, 2

TARGET = "AFFlow"

REQUIRED = {
    "Debug": {
        "ENABLE_APP_SANDBOX": "YES",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "CODE_SIGN_ENTITLEMENTS": "AFFlow/AFFlow.entitlements",
    },
    "Release": {
        "ENABLE_APP_SANDBOX": "YES",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "CODE_SIGN_ENTITLEMENTS": "AFFlow/AFFlow.entitlements",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
    },
}

WHY = {
    "ENABLE_APP_SANDBOX":
        "The sandbox is the boundary, and it is what makes the absent network "
        "entitlement bind at all.",
    "ENABLE_HARDENED_RUNTIME":
        "Notarization refuses a Developer ID build without it.",
    "CODE_SIGN_ENTITLEMENTS":
        "Two entitlement files is how a boundary holds in one configuration "
        "and not the other.",
    "CODE_SIGN_INJECT_BASE_ENTITLEMENTS":
        "Left at its default, Xcode injects com.apple.security.get-task-allow "
        "and the shipped app is debuggable by any process.",
}


def unquote(value):
    value = value.strip().rstrip(";").strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def pbxproj_settings(path):
    """Return {config_name: {setting: value}} for the AFFlow target's configurations."""
    text = open(path, encoding="utf-8").read()

    listing = re.search(
        r'/\* Build configuration list for PBXNativeTarget "%s" \*/ = \{(.*?)\n\t\t\};'
        % re.escape(TARGET), text, re.S)
    if not listing:
        raise LookupError(
            f'no configuration list for PBXNativeTarget "{TARGET}"')
    wanted = set(re.findall(r"([0-9A-F]{8,})\s*/\*", listing.group(1)))
    if not wanted:
        raise LookupError(f'the "{TARGET}" configuration list names no configurations')

    found = {}
    for match in re.finditer(
            r"\n\t\t([0-9A-F]{8,}) /\* (\w+) \*/ = \{\n\t\t\tisa = XCBuildConfiguration;"
            r"(.*?)\n\t\t\tname = (\w+);", text, re.S):
        ident, _, body, name = match.groups()
        if ident not in wanted:
            continue
        settings = {}
        for line in body.splitlines():
            pair = re.match(r"\s*([A-Z][A-Z0-9_]*) = (.+);\s*$", line)
            if pair:
                settings[pair.group(1)] = unquote(pair.group(2))
        found[name] = settings
    if not found:
        raise LookupError(
            f'the "{TARGET}" configuration list points at no XCBuildConfiguration')
    return found


def yml_settings(path):
    """Return {config_name: {setting: value}} as project.yml DESCRIBES the AFFlow target.

    Deliberately a small indentation-aware reader rather than a YAML parser:
    PyYAML is not installed here, and this only needs the two nested maps that
    the pbxproj is being compared against.
    """
    lines = open(path, encoding="utf-8").read().splitlines()
    base, configs = {}, {}
    in_target = in_settings = False
    where = None
    config_name = None
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()

        if indent == 2 and stripped == f"{TARGET}:":
            in_target = True
            continue
        if in_target and indent <= 2 and stripped != f"{TARGET}:":
            in_target = in_settings = False
        if not in_target:
            continue

        if indent == 4 and stripped == "settings:":
            in_settings = True
            continue
        if in_settings and indent <= 4 and stripped != "settings:":
            in_settings = False
        if not in_settings:
            continue

        if indent == 6 and stripped == "base:":
            where, config_name = "base", None
            continue
        if indent == 6 and stripped == "configs:":
            where, config_name = "configs", None
            continue
        if where == "configs" and indent == 8 and stripped.endswith(":"):
            config_name = stripped[:-1]
            configs.setdefault(config_name, {})
            continue

        pair = re.match(r"([A-Z][A-Z0-9_]*):\s*(.+)$", stripped)
        if not pair:
            continue
        key, value = pair.group(1), unquote(pair.group(2))
        if where == "base" and indent == 8:
            base[key] = value
        elif where == "configs" and config_name and indent == 10:
            configs[config_name][key] = value

    resolved = {}
    for name in set(list(configs) + list(REQUIRED)):
        merged = dict(base)
        merged.update(configs.get(name, {}))
        resolved[name] = merged
    return resolved


def main():
    parser = argparse.ArgumentParser(
        description="Compare the build settings a distribution build depends "
                    "on, as the pbxproj states them and as project.yml "
                    "describes them.")
    parser.add_argument("--repo", default=None,
                        help="repository root (default: this script's parent)")
    args = parser.parse_args()

    repo = args.repo or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    pbx = os.path.join(repo, "AFFlow.xcodeproj", "project.pbxproj")
    yml = os.path.join(repo, "project.yml")

    print("### Do the build settings a release depends on say the same thing "
          "in both files")

    for path in (pbx, yml):
        if not os.path.isfile(path):
            print(f"unreadable: {path} is missing", file=sys.stderr)
            print("RESULT: COULD NOT CHECK. That is a failure, not a pass.",
                  file=sys.stderr)
            return UNCHECKED

    try:
        real = pbxproj_settings(pbx)
    except (LookupError, OSError) as problem:
        print(f"unreadable: {problem}", file=sys.stderr)
        print("RESULT: COULD NOT CHECK. That is a failure, not a pass.",
              file=sys.stderr)
        return UNCHECKED

    # `pbxproj_settings` was wrapped and this was not, so an unreadable or
    # newly-shaped project.yml raised, python exited 1, and session-start.sh
    # rendered that as "ACT ON THIS. The build Andrew ships is configured by
    # these lines" rather than "COULD NOT CHECK". The distinction this file's
    # docstring is about, missing from the file itself. Found by review,
    # 2026-08-30.
    try:
        described = yml_settings(yml)
    except Exception as problem:                       # noqa: BLE001
        print(f"unreadable: {yml}: {problem}", file=sys.stderr)
        print("RESULT: COULD NOT CHECK. That is a failure, not a pass.",
              file=sys.stderr)
        return UNCHECKED

    findings = []
    for config, wanted in REQUIRED.items():
        if config not in real:
            findings.append(
                f"the pbxproj has no {config} configuration for the "
                f"{TARGET} target")
            continue
        for key, value in sorted(wanted.items()):
            got = real[config].get(key)
            if got is None:
                findings.append(
                    f"pbxproj {config}: {key} is not set. Expected {value}. "
                    f"{WHY[key]}")
            elif got != value:
                findings.append(
                    f"pbxproj {config}: {key} is {got}, expected {value}. "
                    f"{WHY[key]}")

            # A KEY MISSING FROM project.yml USED TO BE SKIPPED SILENTLY, so
            # the file could lose a setting entirely, or the reader below could
            # stop recognising the target, and this still printed
            # "RESULT: clean". That is the check reporting agreement it never
            # established, which is the exact shape of the codesign|grep defect
            # this phase started from. Codex review, 2026-08-30.
            says = described.get(config, {}).get(key)
            if says is None:
                findings.append(
                    f"project.yml does not state {key} for {config}, so the "
                    f"two files cannot be compared on it. The pbxproj says "
                    f"{got}. Add it, under settings.base or "
                    f"settings.configs.{config}.")
            elif got is not None and says != got:
                findings.append(
                    f"DRIFT in {config}: project.yml says {key}={says}, the "
                    f"pbxproj says {key}={got}. Xcode reads the pbxproj; "
                    f"everyone reads project.yml.")

    checked = sum(len(v) for v in REQUIRED.values())
    if not findings:
        print(f"ok    {checked} setting(s) checked across "
              f"{len(REQUIRED)} configuration(s)")
        print("ok    project.yml describes the project that actually builds")
        print()
        print("RESULT: clean")
        return CLEAN

    for finding in findings:
        print(f"FINDING: {finding}")
    print()
    print(f"RESULT: {len(findings)} finding(s)")
    return FINDINGS


if __name__ == "__main__":
    sys.exit(main())
