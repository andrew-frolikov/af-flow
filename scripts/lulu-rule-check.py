#!/usr/bin/env python3
"""The AF Flow family must have NO firewall rule at all.

WHY THIS EXISTS, and why the rule got stricter. On 2026-07-20 Andrew found a
single rule for `com.frolikov.afflow` reading `any address:any port` set to
Allow, and deleted it: a standing allow-any rule means LuLu will never prompt
or log for that bundle again, so the empirical backstop this project names as
its mitigation was disarmed while the documents still claimed it was in force.
On 2026-08-29 the same shape was back, three times over (app, test host, AX
probe), and nothing had noticed for as long as five weeks.

Until 2026-08-29 the agreed end state was "the app carries a Block". It is now
NO RULE AT ALL, because the app no longer has anything to make a rule about:
`com.apple.security.network.client` was removed from its entitlements, so under
the App Sandbox every outbound connection dies in the kernel before LuLu is
consulted. A firewall rule for a process that cannot open a socket is at best
decoration, and at worst the thing that quietly re-authorises it the day the
entitlement comes back. So the rule this file enforces is: nothing in the
family, in either direction.

Session 18 wrote down that a check for the family's firewall rules would have
caught them the day they reappeared. That sentence is this file. A rule that
lives only in a document depends on a future session having read the document,
which is this project's own meta-rule about controls that depend on memory.

WHAT IT DOES NOT CHECK. LuLu writes one rule per PROCESS and stores no
hostname, so nothing here can say which hosts were reached. That question was
asked of LuLu three times in July and is structurally unanswerable; it is named
here so it is not attempted a fourth time.

The database is root-owned and world-readable, so this reads it and never
writes it. Removing rules is `scripts/lulu-rule-remove.py`, which he runs once
with sudo; this is the verification either side of that.

EXIT CODES. 0 clean, 1 findings, 2 the file could not be read or decoded. Two
is a third answer and must never be collapsed into either of the others: a
firewall database that cannot be read is not a firewall database with no bad
rules in it.
"""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lulu_rules as L  # noqa: E402

EXIT_CLEAN = 0
EXIT_FINDINGS = 1
EXIT_UNREADABLE = 2


def run(quiet=False):
    """Returns an exit code. Prints findings unless asked not to."""
    def say(message=""):
        if not quiet:
            print(message)

    try:
        raw = L.load_archive()
        whole = L.index(raw)
    except L.Unreadable as error:
        say(f"  COULD NOT CHECK: {error}")
        return EXIT_UNREADABLE

    total = sum(len(rules) for rules in whole.values())
    family = [
        (key, rule)
        for key, rules in whole.items()
        for rule in rules
        if L.in_family(rule["id"])
    ]
    say(f"ok    rules database read, {total} rule(s) total, {len(family)} in the family")

    if not family:
        say("ok    the family has NO rule, which is the agreed end state")
        say("ok    the app has no network entitlement, so it needs none")
        say()
        say("RESULT: clean")
        return EXIT_CLEAN

    # The wildcard rules are called out first and separately. Any family rule
    # is a finding now, but an Allow any:any is the one that silences LuLu
    # entirely, and burying it in a list of equals is how it survived five
    # weeks the first time.
    loud, quiet_findings = [], []
    for key, rule in family:
        allow_any = (
            rule["action"] == L.ACTION_ALLOW
            and L.wild(rule["addr"])
            and L.wild(rule["port"])
        )
        if allow_any:
            loud.append(
                "STANDING ALLOW ANY:ANY. LuLu will never prompt or log for this "
                f"bundle again: {L.describe(rule)}"
            )
        else:
            quiet_findings.append(
                "a rule for the family, which should have none at all: "
                f"{L.describe(rule)}"
            )
        recorded = rule.get("path")
        if isinstance(recorded, str) and recorded and not os.path.exists(recorded):
            quiet_findings.append(
                f"{rule['id']} records a path that is gone, so LuLu cannot match "
                f"its own rule and every attempt prompts fresh: {recorded}"
            )

    say()
    for finding in loud:
        say(f"FINDING: {finding}")
    for finding in quiet_findings:
        say(f"FINDING: {finding}")
    say()
    say(f"RESULT: {len(loud) + len(quiet_findings)} finding(s)")
    say()
    say("The database is root-owned, and LuLu has no CLI. Remove them with:")
    say("  sudo python3 scripts/lulu-rule-remove.py --apply")
    say("Run it without --apply first; that is a dry run and the default.")
    return EXIT_FINDINGS


# ---------------------------------------------------------------- selftest

def _archive(entries, out):
    """Build a LuLu-shaped NSKeyedArchiver file, so the decoder is exercised."""
    objects = ["$null"]

    def add(obj):
        objects.append(obj)
        return plistlib.UID(len(objects) - 1)

    key_uids, val_uids = [], []
    for key, rules in entries.items():
        key_uids.append(add(key))
        rule_uids = []
        for rule in rules:
            cs = add({
                "NS.keys": [add("signatureIdentifier")],
                "NS.objects": [add(rule["id"])],
            })
            rule_uids.append(add({
                "uuid": add(rule.get("uuid", "U")),
                "endpointAddr": add(rule.get("addr", "*")),
                "endpointPort": add(rule.get("port", "*")),
                "action": rule.get("action", 1),
                "path": add(rule.get("path", "/bin/ls")),
                "csInfo": cs,
                "name": add("AF Flow"),
            }))
        val_uids.append(add({
            "NS.keys": [add("rules")],
            "NS.objects": [add({"NS.objects": rule_uids})],
        }))
    root = add({"NS.keys": key_uids, "NS.objects": val_uids})
    with open(out, "wb") as handle:
        plistlib.dump({
            "$version": 100000, "$archiver": "NSKeyedArchiver",
            "$top": {"root": root}, "$objects": objects,
        }, handle, fmt=plistlib.FMT_BINARY)


def selftest():
    """Stage each state this checker must distinguish, and watch it react.

    A guard only ever seen passing is a claim. Every case below is a file this
    checker is then run against in a subprocess, so the real entry point and
    the real exit codes are what get tested.
    """
    workspace = tempfile.mkdtemp(prefix="af-flow-lulu-check-selftest-")
    here = os.path.abspath(".")  # a path that certainly exists
    ok = []

    def case(label, entries, expect, raw_bytes=None):
        path = os.path.join(workspace, label.split(".")[0] + ".plist")
        if raw_bytes is not None:
            with open(path, "wb") as handle:
                handle.write(raw_bytes)
        elif entries is not None:
            _archive(entries, path)
        env = dict(os.environ, AF_FLOW_LULU_RULES_PATH=path)
        proc = subprocess.run(
            [sys.executable, os.path.abspath(__file__)],
            env=env, capture_output=True, text=True,
        )
        good = proc.returncode == expect
        ok.append(good)
        print(f"{'PASS' if good else 'FAIL'}  {label}: exit {proc.returncode} (expected {expect})")
        if not good:
            print("        " + proc.stdout.strip().replace("\n", "\n        "))
        return proc

    try:
        # 1. No family rule: the agreed end state.
        case("1. no family rule -> clean",
             {"com.apple.Safari:auth": [{"id": "com.apple.Safari", "path": here}]},
             EXIT_CLEAN)

        # 2. Today's real shape, and the loud one.
        proc = case("2. Allow any:any -> finding",
                    {"com.frolikov.afflow:auth": [{"id": "com.frolikov.afflow", "path": here}]},
                    EXIT_FINDINGS)
        loud = "STANDING ALLOW ANY:ANY" in proc.stdout
        ok.append(loud)
        print(f"{'PASS' if loud else 'FAIL'}  2. the wildcard rule is called out louder than the rest")

        # 3. A Block used to be the goal. It is a finding now: the app has no
        #    network entitlement, so it should carry no rule in EITHER
        #    direction. This case is the whole point of the 2026-08-29 change,
        #    and it passed as clean under the previous rule.
        case("3. a Block for the app -> finding, because it should have none",
             {"com.frolikov.afflow:auth": [
                 {"id": "com.frolikov.afflow", "action": 0, "path": here}]},
             EXIT_FINDINGS)

        # 4. Scoped to one host: not the disarming shape, still a finding.
        case("4. Allow to ONE host -> still a finding",
             {"com.frolikov.afflow.testhost:auth": [
                 {"id": "com.frolikov.afflow.testhost", "addr": "huggingface.co",
                  "port": "443", "path": here}]},
             EXIT_FINDINGS)

        # 5. THE SUBSTRING TRAP. His home directory is /Users/andriifrolikov,
        #    so ten of the 228 keys in his real database contain "frolikov"
        #    and only three are his app. A checker matching a substring calls
        #    uv and dota2 findings and trains him to ignore it.
        proc = case("5. 'frolikov' in a home path -> clean, it is not the family",
                    {"/Users/andriifrolikov/.local/bin/uv": [
                        {"id": "/Users/andriifrolikov/.local/bin/uv", "path": here}],
                     "/Users/andriifrolikov/Library/Application Support/Steam/dota2.app": [
                        {"id": "/Users/andriifrolikov/.../dota2.app", "path": here}]},
                    EXIT_CLEAN)

        # 6. A bundle id that merely STARTS with the family string but is a
        #    different app. `com.frolikov.afflowery` is not in the family.
        case("6. a longer id sharing the prefix -> clean, not a family member",
             {"com.frolikov.afflowery:auth": [
                 {"id": "com.frolikov.afflowery", "path": here}]},
             EXIT_CLEAN)

        # 7. Unreadable must be its OWN answer, never "no bad rules found".
        case("7. corrupt file -> exit 2, not 0", None, EXIT_UNREADABLE,
             raw_bytes=b"not a plist at all")
        env = dict(os.environ,
                   AF_FLOW_LULU_RULES_PATH=os.path.join(workspace, "absent.plist"))
        proc = subprocess.run([sys.executable, os.path.abspath(__file__)],
                              env=env, capture_output=True, text=True)
        good = proc.returncode == EXIT_UNREADABLE
        ok.append(good)
        print(f"{'PASS' if good else 'FAIL'}  8. absent file -> exit 2, not 0: exit {proc.returncode}")

        print()
        print("ALL STATES DISTINGUISHED" if all(ok) else "SOME STATES NOT DISTINGUISHED")
        return EXIT_CLEAN if all(ok) else EXIT_FINDINGS
    finally:
        shutil.rmtree(workspace, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true",
                        help="prove the checker can go red")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    # Two lines, because session start reads every checker through
    # `sed -n '3,$p'`. Without them that sed eats the first finding.
    title = "LuLu firewall rules for the AF Flow family"
    print(title)
    print("=" * len(title))
    return run()


if __name__ == "__main__":
    sys.exit(main())
