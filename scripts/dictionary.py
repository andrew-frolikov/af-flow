#!/usr/bin/env python3
"""Read and edit AF Flow's correction dictionary without corrupting it.

WHY THIS EXISTS, and it is the fourth capability added to this project's
tooling rather than a resolution to be careful.

On 2026-07-26 three entries were added to `commonlyMisheardDraft` by reading the
current value with `defaults read`, appending, and writing it back. That silently
destroyed the one non-ASCII rule in the dictionary: **`defaults read` prints
Unicode as `\\Uxxxx` escape TEXT**, so his real Cyrillic `промпут` was written
back as the literal fourteen characters `\\u043f\\u0440...`, and the rule could
never have matched again. It was caught only because the write was verified by
reading the plist back with `plistlib` and comparing against a backup.

The rule this encodes: **read app defaults with plistlib, never with
`defaults read`, whenever the value can contain non-ASCII.** Andrew dictates in
Russian, so on this project every value can.

Usage:
    scripts/dictionary.py list
    scripts/dictionary.py add "codecs -> Codex" ["another -> rule" ...]

Refuses to run while AF Flow is open, because the app rewrites this key on quit
and would overwrite the edit.
"""

import plistlib
import subprocess
import sys
from pathlib import Path

DOMAIN = "com.frolikov.afflow"
KEY = "commonlyMisheardDraft"
PLIST = Path.home() / "Library/Containers" / DOMAIN / "Data/Library/Preferences" / f"{DOMAIN}.plist"


def app_is_running() -> bool:
    result = subprocess.run(
        ["pgrep", "-f", "GhostPepper.app/Contents/MacOS/GhostPepper"],
        capture_output=True,
    )
    return result.returncode == 0


def read_rules() -> list[str]:
    """Read through plistlib so non-ASCII survives. This is the whole point."""
    if not PLIST.exists():
        return []
    data = plistlib.loads(PLIST.read_bytes())
    value = data.get(KEY, "")
    return [line for line in value.split("\n") if line.strip()]


def write_rules(rules: list[str]) -> None:
    # Written through subprocess arguments, which carry UTF-8 intact. The
    # corruption came from READING with `defaults read`, never from writing.
    subprocess.run(
        ["defaults", "write", DOMAIN, KEY, "-string", "\n".join(rules)],
        check=True,
    )


def verify(expected: list[str]) -> int:
    """Read the plist back and prove the write survived, byte for byte.

    Checks the escape-text failure specifically, because that is the one that
    looks correct in every tool that prints it.
    """
    actual = read_rules()
    problems = []
    if actual != expected:
        problems.append(f"round trip differs: wrote {len(expected)} rules, read {len(actual)}")
    for line in actual:
        if "\\u" in line or "\\U" in line:
            problems.append(f"escape text rather than real characters: {line!r}")
        if "->" not in line:
            problems.append(f"rule has no separator: {line!r}")
    for line in problems:
        print(f"  FAILED: {line}", file=sys.stderr)
    if problems:
        return 1
    non_ascii = [line for line in actual if any(ord(character) > 127 for character in line)]
    print(f"  verified {len(actual)} rules, {len(non_ascii)} carrying non-ASCII, all intact")
    return 0


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in {"list", "add"}:
        print(__doc__, file=sys.stderr)
        return 2

    command = sys.argv[1]
    rules = read_rules()

    if command == "list":
        for rule in rules:
            print(rule)
        return 0

    if app_is_running():
        print("REFUSING TO RUN: AF Flow is open.", file=sys.stderr)
        print("It rewrites this key when it quits, which would discard the edit.", file=sys.stderr)
        print("Quit AF Flow, run this again, and relaunch it afterwards.", file=sys.stderr)
        return 3

    additions = sys.argv[2:]
    if not additions:
        print("Nothing to add.", file=sys.stderr)
        return 2

    backup = Path("/tmp") / f"afflow-dictionary-backup-{len(rules)}.txt"
    backup.write_text("\n".join(rules), encoding="utf-8")
    print(f"backup: {backup}")

    existing = {rule.split("->")[0].strip().lower() for rule in rules}
    added = []
    for rule in additions:
        if "->" not in rule:
            print(f"REFUSING: {rule!r} has no '->' separator.", file=sys.stderr)
            return 2
        if rule.split("->")[0].strip().lower() in existing:
            print(f"  already present, skipped: {rule}")
            continue
        rules.append(rule)
        added.append(rule)

    if not added:
        print("  nothing new to add")
        return 0

    write_rules(rules)
    for rule in added:
        print(f"  added: {rule}")
    return verify(rules)


if __name__ == "__main__":
    sys.exit(main())
