#!/usr/bin/env python3
"""The AF Flow family must have NO firewall rule, except the downloader's.

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
family, in either direction, WITH ONE NAMED EXCEPTION decided by Andrew on
2026-08-30: `com.frolikov.afflow.models`, the model downloader, is the one
family member that legitimately opens connections, so a rule for exactly that
identifier is expected, printed in full every session, and excused ONLY while
a bundle carrying that identifier ships inside the installed app
(`lulu_rules.helper_ships`). "Could not tell" counts as "does not ship".

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

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

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
    everyone = [
        (key, rule)
        for key, rules in whole.items()
        for rule in rules
        if L.in_family(rule["id"])
    ]
    say(f"ok    rules database read, {total} rule(s) total, {len(everyone)} in the family")

    # THE ONE EXCEPTION. The model downloader, `L.HELPER_ID`, legitimately
    # opens connections, so a rule for exactly that identifier is expected,
    # and it is expected ONLY while a bundle carrying the identifier ships
    # inside the installed app. Decided by Andrew 2026-08-30 (open item 3).
    # Its rules are printed in full every session, so a widened one is seen.
    helper_rules = [(k, r) for k, r in everyone if r["id"] == L.HELPER_ID]
    family = [(k, r) for k, r in everyone if r["id"] != L.HELPER_ID]
    helper_findings = []
    if helper_rules:
        ships, where = L.helper_ships(REPO)
        if ships:
            say(f"ok    {L.HELPER_ID} ships in the build: {where}")
            for _key, rule in helper_rules:
                # An ALLOW is the downloader's own rule, printed in full so a
                # widened one is seen. A BLOCK is not "its own rule": it is
                # every download failing silently on this Mac, and it is
                # reported as such. A rule recorded at a path that is gone
                # cannot match and prompts fresh, helper or not.
                if rule["action"] != L.ACTION_ALLOW:
                    helper_findings.append(
                        f"a BLOCK for the downloader, so every model download fails "
                        f"on this Mac: {L.describe(rule)}"
                    )
                    continue
                say(f"ok    expected, the downloader's own rule: {L.describe(rule)}")
                recorded = rule.get("path")
                if isinstance(recorded, str) and recorded and not os.path.exists(recorded):
                    helper_findings.append(
                        f"{rule['id']} records a path that is gone, so LuLu cannot match "
                        f"its own rule and every attempt prompts fresh: {recorded}"
                    )
        else:
            for _key, rule in helper_rules:
                helper_findings.append(
                    f"a rule for {L.HELPER_ID}, but no shipped bundle carries that "
                    f"identifier ({where}), so the downloader exception does not "
                    f"apply: {L.describe(rule)}"
                )

    if not family and not helper_findings:
        if helper_rules:
            say("ok    apart from the downloader, the family has NO rule")
        else:
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

    quiet_findings.extend(helper_findings)
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

    # Two staged apps: one shipping the downloader as an XPC service, one not.
    # `AF_FLOW_LULU_APP_PATH` is honoured only because the rules path is also
    # staged; against the real database it is ignored.
    def staged_app(name, with_helper):
        app = os.path.join(workspace, name, "AF Flow.app")
        os.makedirs(os.path.join(app, "Contents"))
        if with_helper:
            service = os.path.join(app, "Contents", "XPCServices",
                                   "AF Flow Models.xpc", "Contents")
            os.makedirs(service)
            with open(os.path.join(service, "Info.plist"), "wb") as handle:
                plistlib.dump({"CFBundleIdentifier": L.HELPER_ID}, handle)
        return app
    app_with_helper = staged_app("with-helper", True)
    app_without_helper = staged_app("without-helper", False)

    def case(label, entries, expect, raw_bytes=None, app=None):
        path = os.path.join(workspace, label.split(".")[0] + ".plist")
        if raw_bytes is not None:
            with open(path, "wb") as handle:
                handle.write(raw_bytes)
        elif entries is not None:
            _archive(entries, path)
        env = dict(os.environ, AF_FLOW_LULU_RULES_PATH=path)
        env.pop("AF_FLOW_LULU_APP_PATH", None)
        if app is not None:
            env["AF_FLOW_LULU_APP_PATH"] = app
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

        # THE DOWNLOADER EXCEPTION, open item 3, decided 2026-08-30.
        helper_rule = {"id": L.HELPER_ID, "addr": "huggingface.co", "port": "443",
                       "path": here}
        # 9. The helper ships and holds a scoped rule: expected, printed, clean.
        proc = case("9. downloader rule, downloader ships -> clean and printed",
                    {f"{L.HELPER_ID}:auth": [helper_rule]},
                    EXIT_CLEAN, app=app_with_helper)
        printed = L.HELPER_ID in proc.stdout and "expected" in proc.stdout
        ok.append(printed)
        print(f"{'PASS' if printed else 'FAIL'}  9. the downloader's rule is printed in full")

        # 10. The same rule with NO shipped bundle carrying the identifier: the
        #     exception must die with the bundle, or it silently permits a
        #     rule for something no longer shipped.
        case("10. downloader rule, downloader NOT in the build -> finding",
             {f"{L.HELPER_ID}:auth": [helper_rule]},
             EXIT_FINDINGS, app=app_without_helper)

        # 11. The staged app path does not exist at all. (The genuine
        #     "could not tell" branch, `installed_app` returning None because
        #     the registry is UNREADABLE or AMBIGUOUS, cannot be staged from
        #     here; it returns False by construction and the third-pass review
        #     confirmed the wrapping `except Exception`.)
        case("11. downloader rule, staged app path absent -> finding",
             {f"{L.HELPER_ID}:auth": [helper_rule]},
             EXIT_FINDINGS, app=os.path.join(workspace, "absent-app"))

        # 12. The exception is for ONE identifier. The main app's rule is a
        #     finding even while the downloader ships beside it.
        proc = case("12. main app rule beside a shipping downloader -> finding",
                    {f"{L.HELPER_ID}:auth": [helper_rule],
                     "com.frolikov.afflow:auth": [{"id": "com.frolikov.afflow", "path": here}]},
                    EXIT_FINDINGS, app=app_with_helper)
        loud = "STANDING ALLOW ANY:ANY" in proc.stdout
        ok.append(loud)
        print(f"{'PASS' if loud else 'FAIL'}  12. and the main app's wildcard is still the loud one")

        # 13. A dotted child that is NOT the downloader gets no exception.
        case("13. a sibling id, not the downloader, beside a shipping downloader -> finding",
             {"com.frolikov.afflow.testhost:auth": [
                 {"id": "com.frolikov.afflow.testhost", "path": here}]},
             EXIT_FINDINGS, app=app_with_helper)

        # 14. The staged-app override is IGNORED against the real database.
        #     Proved by asking the library directly, not the checker: with no
        #     rules override set, `installed_app` must not return the staged path.
        saved = os.environ.get("AF_FLOW_LULU_RULES_PATH")
        os.environ.pop("AF_FLOW_LULU_RULES_PATH", None)
        os.environ["AF_FLOW_LULU_APP_PATH"] = app_with_helper
        try:
            probe = subprocess.run(
                [sys.executable, "-c",
                 "import sys; sys.path.insert(0, 'scripts'); import lulu_rules as L; "
                 "print(L.installed_app('.')[0])"],
                capture_output=True, text=True, env=dict(os.environ),
                cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        finally:
            os.environ.pop("AF_FLOW_LULU_APP_PATH", None)
            if saved is not None:
                os.environ["AF_FLOW_LULU_RULES_PATH"] = saved
        ignored = app_with_helper not in probe.stdout
        ok.append(ignored)
        print(f"{'PASS' if ignored else 'FAIL'}  14. the staged-app override is ignored against the real database")

        # 15. The override is ignored for an ALIAS of the real database too.
        #     A lexical compare called /System/Volumes/Data/Library/... a test
        #     database; it is the same inode. Codex, 2026-09-06.
        alias = "/System/Volumes/Data" + L.REAL_RULES_PATH
        if os.path.exists(alias) and os.path.exists(L.REAL_RULES_PATH):
            probe = subprocess.run(
                [sys.executable, "-c",
                 "import sys; sys.path.insert(0, 'scripts'); import lulu_rules as L; "
                 "print(L.is_test_database(), L.installed_app('.')[0])"],
                capture_output=True, text=True,
                env=dict(os.environ, AF_FLOW_LULU_RULES_PATH=alias,
                         AF_FLOW_LULU_APP_PATH=app_with_helper),
                cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
            good = probe.stdout.startswith("False") and app_with_helper not in probe.stdout
            ok.append(good)
            print(f"{'PASS' if good else 'FAIL'}  15. an alias of the real database is still the real database")
        else:
            print("skip  15. no /System/Volumes/Data alias on this machine")

        # 16. A helper reached only through a symlink does not "ship", and an
        #     Info.plist that is not a dictionary is "does not ship", not a crash.
        linked = os.path.join(workspace, "linked", "AF Flow.app")
        os.makedirs(os.path.join(linked, "Contents"))
        os.symlink(os.path.join(app_with_helper, "Contents", "XPCServices"),
                   os.path.join(linked, "Contents", "XPCServices"))
        case("16a. downloader reachable only through a symlink -> finding",
             {f"{L.HELPER_ID}:auth": [helper_rule]}, EXIT_FINDINGS, app=linked)
        # 16c. The symlink one level down: a real .xpc whose Contents points
        #      outside the app. Codex, 2026-09-06.
        inner = os.path.join(workspace, "inner-link", "AF Flow.app")
        os.makedirs(os.path.join(inner, "Contents", "XPCServices", "AF Flow Models.xpc"))
        os.symlink(os.path.join(app_with_helper, "Contents", "XPCServices",
                                "AF Flow Models.xpc", "Contents"),
                   os.path.join(inner, "Contents", "XPCServices", "AF Flow Models.xpc", "Contents"))
        case("16c. downloader whose Contents is a symlink out of the app -> finding",
             {f"{L.HELPER_ID}:auth": [helper_rule]}, EXIT_FINDINGS, app=inner)
        # 16d. Truncated XML: ExpatError, which the first except clause did
        #      not name, so this was a traceback. Third-pass review.
        trunc = staged_app("truncated-plist", True)
        with open(os.path.join(trunc, "Contents", "XPCServices", "AF Flow Models.xpc",
                               "Contents", "Info.plist"), "wb") as handle:
            handle.write(b'<?xml version="1.0"?><plist><dict><key>CFBundleIdentifier')
        proc = case("16d. downloader Info.plist that is truncated XML -> finding, not a traceback",
                    {f"{L.HELPER_ID}:auth": [helper_rule]}, EXIT_FINDINGS, app=trunc)
        # Exit 1 alone cannot tell a finding from a crash: an uncaught
        # exception also exits 1. The absence of a traceback is the claim.
        quiet = "Traceback" not in proc.stderr
        ok.append(quiet)
        print(f"{'PASS' if quiet else 'FAIL'}  16d. and it was a finding, not a traceback")

        # 17. A BLOCK for the downloader is not "its own rule": it is every
        #     download failing silently. Finding, even while it ships.
        case("17. a Block for the downloader while it ships -> finding",
             {f"{L.HELPER_ID}:auth": [dict(helper_rule, action=0)]},
             EXIT_FINDINGS, app=app_with_helper)

        # 18. The downloader's rule recorded at a path that is gone -> finding,
        #     the same rule the rest of the family gets.
        case("18. downloader rule recorded at a gone path -> finding",
             {f"{L.HELPER_ID}:auth": [dict(helper_rule, path=os.path.join(workspace, "gone.app"))]},
             EXIT_FINDINGS, app=app_with_helper)
        odd = staged_app("odd-plist", True)
        with open(os.path.join(odd, "Contents", "XPCServices", "AF Flow Models.xpc",
                               "Contents", "Info.plist"), "wb") as handle:
            plistlib.dump(["not", "a", "dict"], handle)
        proc = case("16b. downloader Info.plist that is not a dictionary -> finding, not a traceback",
                    {f"{L.HELPER_ID}:auth": [helper_rule]}, EXIT_FINDINGS, app=odd)
        quiet = "Traceback" not in proc.stderr
        ok.append(quiet)
        print(f"{'PASS' if quiet else 'FAIL'}  16b. and it was a finding, not a traceback")

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
