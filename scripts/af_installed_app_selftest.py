#!/usr/bin/env python3
"""Stage each answer `af_installed_app.py` must give, and watch it give it.

Synthesised records rather than real bundles: a second bundle carrying
`com.frolikov.afflow` is forbidden by CLAUDE.md hard rule 11, and it is the
exact object whose existence this code is defending against.

Exit 0 all states distinguished, 1 otherwise.
"""

import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "af_installed_app", os.path.join(HERE, "af_installed_app.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

results = []


def check(label, condition, detail=""):
    results.append(bool(condition))
    print(f"{'PASS' if condition else 'FAIL'}  {label}")
    if detail and not condition:
        print("        " + str(detail).replace("\n", "\n        "))


def app(root, name):
    where = os.path.join(root, name)
    os.makedirs(where, exist_ok=True)
    return where


def main():
    with tempfile.TemporaryDirectory() as root:
        repo = app(root, "repo")
        installed = app(root, "Installed/AF Flow.app")
        other = app(root, "Elsewhere/AF Flow.app")
        inside_build = app(root, "repo/build/release/export/AF Flow.app")

        got = module.decide(None, repo)
        check("an unreadable registry is UNREADABLE, never NONE",
              got == ["UNREADABLE"], got)

        got = module.decide([], repo)
        check("an empty registry is NONE", got == ["NONE"], got)

        got = module.decide(
            [("com.frolikov.afflow.testhost", "AF Flow test host", installed)], repo)
        check("another identifier in the family is not a candidate",
              got == ["NONE"], got)

        got = module.decide(
            [("com.frolikov.afflow", "AF Flow", installed)], repo)
        check("one live bundle is ONE with its path",
              got == ["ONE", installed], got)

        got = module.decide(
            [("com.frolikov.afflow", "AF Flow", os.path.join(root, "gone.app"))],
            repo)
        check("a record pointing at a bundle that is gone is not a candidate",
              got == ["NONE"], got)

        got = module.decide(
            [("com.frolikov.afflow", "AF Flow", installed),
             ("com.frolikov.afflow", "AF Flow", inside_build)], repo)
        check("this script's own build output is never the installed app",
              got == ["ONE", installed], got)

        got = module.decide(
            [("com.frolikov.afflow", "AF Flow", installed),
             ("com.frolikov.afflow", "AF Flow", other)], repo)
        check("two live bundles are AMBIGUOUS, never the first one",
              got[0] == "AMBIGUOUS" and set(got[1:]) == {installed, other}, got)

        got = module.decide(
            [("com.frolikov.afflow", "AF Flow", installed),
             ("com.frolikov.afflow", "AF Flow", installed)], repo)
        check("the same path recorded twice is still ONE",
              got == ["ONE", installed], got)

    print()
    failed = results.count(False)
    if failed:
        print(f"{failed} state(s) not distinguished")
        return 1
    print(f"all {len(results)} state(s) distinguished")
    return 0


if __name__ == "__main__":
    sys.exit(main())
