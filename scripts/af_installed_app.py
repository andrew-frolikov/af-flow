#!/usr/bin/env python3
"""Which live bundle is the AF Flow Andrew launches, and is that question answerable.

Split out of `scripts/release-build.sh` on 2026-08-30 so the three answers can
be tested against synthesised registry records instead of against real bundles.
Testing it with real ones would mean building a second bundle carrying
`com.frolikov.afflow`, and a bundle that claims the product's identity is
exactly what took his Input Monitoring grant on 2026-07-26; CLAUDE.md hard rule
11 forbids it.

THREE ANSWERS, NEVER TWO:

    UNREADABLE   the registry could not be read. Not the same as empty, and
                 the first version of this collapsed the two: an unreadable
                 dump printed nothing and was reported as "no installed app",
                 so a release would have run without knowing what it had to
                 restore afterwards. Codex review, 2026-08-30.
    NONE         read it, nothing claims the identifier.
    ONE <path>   read it, exactly one live bundle claims it.
    AMBIGUOUS    two or more do. Refused rather than guessed: re-registering
                 the wrong one reproduces the duplicate-claimant failure this
                 whole mechanism exists to prevent.

Bundles inside the repo's own `build/` directory are never candidates. Those
are this script's caller's output, or a previous run's.

Usage:  af_installed_app.py --repo PATH
Prints one line: UNREADABLE | NONE | ONE\\tPATH | AMBIGUOUS\\tPATH\\tPATH...
"""

import argparse
import importlib.util
import os
import sys

IDENTIFIER = "com.frolikov.afflow"


def decide(records, repo):
    """records is what system-list-check.launch_services_records() returns, or None."""
    if records is None:
        return ["UNREADABLE"]
    build = os.path.join(os.path.abspath(repo), "build") + os.sep
    live = []
    for identifier, _name, path in records:
        if identifier != IDENTIFIER:
            continue
        if os.path.abspath(path).startswith(build):
            continue
        if os.path.isdir(path) and path not in live:
            live.append(path)
    if not live:
        return ["NONE"]
    if len(live) == 1:
        return ["ONE", live[0]]
    return ["AMBIGUOUS"] + live


def read_registry(repo):
    where = os.path.join(repo, "scripts", "system-list-check.py")
    try:
        spec = importlib.util.spec_from_file_location("system_list_check", where)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.launch_services_records()
    except Exception:                                  # noqa: BLE001
        # A parser that cannot be loaded is a registry that was not read.
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()
    print("\t".join(decide(read_registry(args.repo), args.repo)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
