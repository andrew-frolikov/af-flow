#!/usr/bin/env python3
"""Stage every state `lulu-rule-remove.py` must distinguish, and watch it react.

WHY THIS EXISTS. The script it tests rewrites the file that decides what may
leave this Mac. A remover that has only ever been seen succeeding is a claim,
so each guarantee below is staged as a real failure first: a build that does
not verify, a swap that verifies and then goes bad, and the substring trap that
would take ten of his rules instead of three.

Every case runs against a COPY of the real database in a temp directory. The
script refuses to drive the real LuLu unless it is pointed at the real path, so
nothing here can touch his firewall.

Exit 0 all states distinguished, 1 otherwise.
"""

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "lulu-rule-remove.py")
REAL_RULES = "/Library/Objective-See/LuLu/rules.plist"

# The family is decided by the production predicate, never by a list copied
# here. Codex, 2026-08-29: a hardcoded three-id list would call a legitimate
# fourth child (com.frolikov.afflow.cleanup-model-probe, which exists) foreign,
# so case 2 would fail for a remover that behaved perfectly.
sys.path.insert(0, HERE)
import lulu_rules as L  # noqa: E402

FAMILY = (
    "com.frolikov.afflow",
    "com.frolikov.afflow.testhost",
    "com.frolikov.afflow.axprobe",
)  # only used to check the dry-run OUTPUT names the three that exist today

results = []


def check(label, condition, detail=""):
    results.append(bool(condition))
    print(f"{'PASS' if condition else 'FAIL'}  {label}")
    if detail and not condition:
        print(f"        {detail}")
    return bool(condition)


def run(rules_path, *args, env_extra=None):
    env = dict(os.environ, AF_FLOW_LULU_RULES_PATH=rules_path)
    env.update(env_extra or {})
    return subprocess.run(
        [sys.executable, SCRIPT, *args], env=env, capture_output=True, text=True
    )


# ---------------------------------------------------------------- the fixture

def synthesise(path, entries):
    """Build a LuLu-shaped NSKeyedArchiver file.

    `entries` is {key: [ {id, action, addr, port, path, uuid}, ... ]}. The shape
    mirrors the real database: a root dictionary of key -> {rules, signingInfo,
    paths}, where each rule carries its signing identifier inside csInfo.
    """
    objects = ["$null"]

    def add(obj):
        objects.append(obj)
        return plistlib.UID(len(objects) - 1)

    key_uids, val_uids = [], []
    for key, rules in entries.items():
        key_uids.append(add(key))
        rule_uids = []
        for rule in rules:
            cs = add(
                {
                    "NS.keys": [add("signatureIdentifier")],
                    "NS.objects": [add(rule["id"])],
                }
            )
            rule_uids.append(
                add(
                    {
                        "uuid": add(rule.get("uuid", "U-" + rule["id"])),
                        "endpointAddr": add(rule.get("addr", "*")),
                        "endpointPort": add(rule.get("port", "*")),
                        "action": rule.get("action", 1),
                        "path": add(rule.get("path", "/bin/ls")),
                        "csInfo": cs,
                        "name": add(rule.get("name", "thing")),
                    }
                )
            )
        val_uids.append(
            add(
                {
                    "NS.keys": [add("rules"), add("paths")],
                    "NS.objects": [
                        add({"NS.objects": rule_uids}),
                        add({"NS.objects": [add("/bin/ls")]}),
                    ],
                }
            )
        )
    root = add({"NS.keys": key_uids, "NS.objects": val_uids})
    plist = {
        "$version": 100000,
        "$archiver": "NSKeyedArchiver",
        "$top": {"root": root},
        "$objects": objects,
    }
    with open(path, "wb") as handle:
        plistlib.dump(plist, handle, fmt=plistlib.FMT_BINARY)


def decode(path):
    """Read a rules file back into {key: [uuid, ...]} without trusting the script."""
    with open(path, "rb") as handle:
        raw = plistlib.load(handle, fmt=plistlib.FMT_BINARY)
    objects = raw["$objects"]

    def resolve(node, depth=0):
        if isinstance(node, plistlib.UID):
            if depth > 60:
                return "<cycle>"
            return resolve(objects[node.data], depth + 1)
        if isinstance(node, dict):
            return {k: resolve(v, depth + 1) for k, v in node.items() if k != "$class"}
        if isinstance(node, list):
            return [resolve(v, depth + 1) for v in node]
        return node

    root = resolve(raw["$top"]["root"])
    out = {}
    for key, value in zip(root["NS.keys"], root["NS.objects"]):
        pairs = dict(zip(value["NS.keys"], value["NS.objects"]))
        out[key] = [r.get("uuid") for r in pairs["rules"]["NS.objects"]]
    return out


def digest(path):
    with open(path, "rb") as handle:
        return handle.read()


# --------------------------------------------------------------------- cases

def main():
    workspace = tempfile.mkdtemp(prefix="af-flow-lulu-remove-selftest-")
    try:
        # The fixture is the REAL database when it can be read, because a
        # synthetic one cannot reproduce the shape that actually bit: 228 keys,
        # ten of which contain the string "frolikov" and only three of which
        # are his app. When it cannot be read, a synthetic stand-in carrying
        # the same trap is used, so this harness still runs on another machine.
        fixture = os.path.join(workspace, "fixture.plist")
        if os.path.exists(REAL_RULES) and os.access(REAL_RULES, os.R_OK):
            shutil.copy2(REAL_RULES, fixture)
            source = "a copy of the real database"
        else:
            synthesise(
                fixture,
                {
                    "com.frolikov.afflow:Apple Development": [
                        {"id": "com.frolikov.afflow"}
                    ],
                    "com.frolikov.afflow.testhost:Apple Development": [
                        {"id": "com.frolikov.afflow.testhost"}
                    ],
                    "com.frolikov.afflow.axprobe:Apple Development": [
                        {"id": "com.frolikov.afflow.axprobe"}
                    ],
                    "$HOME/.local/bin/uv": [{"id": "$HOME/.local/bin/uv"}],
                    "com.apple.Safari:auth": [{"id": "com.apple.Safari"}],
                },
                )
            source = "a synthesised stand-in"
        print(f"fixture: {source}")
        if not check("0. the script under test exists", os.path.exists(SCRIPT),
                     f"{SCRIPT} is not there, so every case below is vacuous"):
            print("\nSOME STATES NOT DISTINGUISHED")
            return 1

        before = decode(fixture)
        # Ask the production predicate which keys are the family's, so this
        # harness cannot disagree with the code it is testing.
        family_index = L.index(L.load_archive(fixture))
        family_keys = [
            k for k, rules in family_index.items()
            if rules and all(L.in_family(r["id"]) for r in rules)
        ]
        trap_keys = [
            k for k in before
            if "frolikov" in k.lower() and k not in family_keys
        ]
        print(f"        {len(before)} keys, {len(family_keys)} in the family, "
              f"{len(trap_keys)} more containing 'frolikov'")
        check("the fixture carries the substring trap", len(trap_keys) >= 1,
              "no non-family key contains 'frolikov', so case 3 proves nothing")

        # 1. Dry run is the default. No flag, no write.
        work = os.path.join(workspace, "case1.plist")
        shutil.copy2(fixture, work)
        original = digest(work)
        proc = run(work)
        check("1. no flag -> dry run, exit 0", proc.returncode == 0,
              f"exit {proc.returncode}\n{proc.stdout}\n{proc.stderr}")
        check("1. no flag -> the file is untouched", digest(work) == original)
        check("1. dry run names every family key it would remove",
              all(k in proc.stdout for k in family_keys),
              proc.stdout)
        check("1. dry run says it changed nothing",
              "dry run" in proc.stdout.lower(), proc.stdout)

        # 2. Apply removes exactly the family, and nothing else moves.
        work = os.path.join(workspace, "case2.plist")
        shutil.copy2(fixture, work)
        proc = run(work, "--apply")
        applied = check("2. --apply exits 0", proc.returncode == 0,
                        f"exit {proc.returncode}\n{proc.stdout}\n{proc.stderr}")
        if applied:
            after = decode(work)
            check("2. every family key is gone",
                  not any(k in after for k in family_keys), str(list(after)[:3]))
            check("2. every other key survived, with identical rules",
                  {k: v for k, v in before.items() if k not in family_keys} == after,
                  "a key or a rule uuid changed under a removal")
            check("2. the substring trap did NOT take his other rules",
                  all(k in after for k in trap_keys),
                  f"lost: {[k for k in trap_keys if k not in after]}")
            backups = [f for f in os.listdir(workspace) if "backup" in f]
            check("2. a timestamped backup was written",
                  any(b.endswith(".plist") for b in backups), str(backups))
            check("2. the backup path is printed on success",
                  "backup" in proc.stdout.lower(), proc.stdout)
            if backups:
                path = os.path.join(workspace, sorted(backups)[-1])
                check("2. the backup is byte-identical to the original",
                      digest(path) == digest(fixture))

            # 3. Idempotent: running again finds nothing and writes nothing.
            settled = digest(work)
            proc2 = run(work, "--apply")
            check("3. a second --apply is a no-op, exit 0", proc2.returncode == 0,
                  f"exit {proc2.returncode}\n{proc2.stdout}")
            check("3. a second --apply does not rewrite the file",
                  digest(work) == settled)

        # 4. A build that fails verification must not be swapped in.
        work = os.path.join(workspace, "case4.plist")
        shutil.copy2(fixture, work)
        original = digest(work)
        proc = run(work, "--apply", env_extra={"AF_FLOW_LULU_FAULT": "corrupt-before-swap"})
        check("4. a build that fails verification -> exit 3 exactly",
              proc.returncode == 3, f"exit {proc.returncode}\n{proc.stdout}\n{proc.stderr}")
        check("4. the original is untouched when the build does not verify",
              digest(work) == original,
              "THE FILE WAS REPLACED WITH SOMETHING THAT DID NOT VERIFY")
        check("4. the backup path is printed on failure too",
              "backup" in proc.stdout.lower() + proc.stderr.lower(), proc.stdout)

        # 5. A swap that verifies and THEN goes bad must roll back.
        work = os.path.join(workspace, "case5.plist")
        shutil.copy2(fixture, work)
        original = digest(work)
        proc = run(work, "--apply", env_extra={"AF_FLOW_LULU_FAULT": "corrupt-after-swap"})
        check("5. a database that goes bad after the swap -> exit 4 exactly",
              proc.returncode == 4, f"exit {proc.returncode}\n{proc.stdout}\n{proc.stderr}")
        check("5. the original was restored from the backup",
              digest(work) == original,
              "ROLLBACK DID NOT RESTORE THE ORIGINAL")
        check("5. the rollback is reported, not silent",
              "roll" in (proc.stdout + proc.stderr).lower(), proc.stdout)

        # 6. Unreadable is its own answer, never "nothing to remove".
        missing = os.path.join(workspace, "not-here.plist")
        proc = run(missing, "--apply")
        check("6. an absent database -> exit 2, not 0", proc.returncode == 2,
              f"exit {proc.returncode}\n{proc.stdout}")
        garbage = os.path.join(workspace, "garbage.plist")
        with open(garbage, "wb") as handle:
            handle.write(b"not a plist at all")
        proc = run(garbage, "--apply")
        check("6. a corrupt database -> exit 2, not 0", proc.returncode == 2,
              f"exit {proc.returncode}\n{proc.stdout}")

        # 7. An entry mixing family and foreign rules is ambiguous. Refuse.
        mixed = os.path.join(workspace, "mixed.plist")
        synthesise(
            mixed,
            {
                "com.frolikov.afflow:Apple Development": [
                    {"id": "com.frolikov.afflow", "uuid": "OURS"},
                    {"id": "com.apple.Safari", "uuid": "THEIRS"},
                ],
                "com.apple.Safari:auth": [{"id": "com.apple.Safari", "uuid": "S"}],
            },
        )
        original = digest(mixed)
        proc = run(mixed, "--apply")
        check("7. an entry mixing family and foreign rules -> exit 1 exactly",
              proc.returncode == 1, f"exit {proc.returncode}\n{proc.stdout}\n{proc.stderr}")
        check("7. a refused mixed entry leaves the file untouched",
              digest(mixed) == original)

        # 8. A family entry that is already clean of wildcards is still removed,
        #    because the agreed end state is NO rule for the family at all.
        scoped = os.path.join(workspace, "scoped.plist")
        synthesise(
            scoped,
            {
                "com.frolikov.afflow:Apple Development": [
                    {"id": "com.frolikov.afflow", "action": 0,
                     "addr": "huggingface.co", "port": "443", "uuid": "BLOCKED"}
                ],
                "com.apple.Safari:auth": [{"id": "com.apple.Safari", "uuid": "S"}],
            },
        )
        proc = run(scoped, "--apply")
        if check("8. a non-wildcard family rule is still removed, exit 0",
                 proc.returncode == 0, f"exit {proc.returncode}\n{proc.stdout}"):
            after = decode(scoped)
            check("8. the family is gone and Safari is not",
                  list(after) == ["com.apple.Safari:auth"], str(list(after)))

        # 9. Fault injection must be impossible against his real firewall.
        #    Asserted two ways: the gate answers correctly for both paths, and
        #    no fault branch in the source is left unguarded.
        import importlib.util
        spec = importlib.util.spec_from_file_location("remover", SCRIPT)
        remover = importlib.util.module_from_spec(spec)
        os.environ["AF_FLOW_LULU_RULES_PATH"] = REAL_RULES
        spec.loader.exec_module(remover)
        check("9. the real database is recognised as real",
              remover.is_real_database() is True)
        remover.L.RULES_PATH = work
        check("9. a temp copy is NOT recognised as real",
              remover.is_real_database() is False)
        source = open(SCRIPT, encoding="utf-8").read()
        fault_lines = [
            line for line in source.splitlines()
            if "FAULT ==" in line and "is_real_database" not in line
        ]
        check("9. every fault-injection branch is gated on not-the-real-database",
              not fault_lines, str(fault_lines))

        # 10. A parseable archive whose rules array is not an array must be
        #     the unreadable answer, not a traceback wearing exit 1.
        malformed = os.path.join(workspace, "malformed.plist")
        with open(fixture, "rb") as handle:
            raw = plistlib.load(handle, fmt=plistlib.FMT_BINARY)
        objects = raw["$objects"]
        root = objects[raw["$top"]["root"].data]
        first_value = objects[root["NS.objects"][0].data]
        # NS.keys holds UIDs, so each one is resolved to its string first.
        pairs = {
            objects[k.data]: v
            for k, v in zip(first_value["NS.keys"], first_value["NS.objects"])
        }
        objects[pairs["rules"].data] = {"NS.objects": "not an array at all"}
        with open(malformed, "wb") as handle:
            plistlib.dump(raw, handle, fmt=plistlib.FMT_BINARY)
        proc = run(malformed, "--apply")
        check("10. a rules array that is not an array -> exit 2, not a traceback",
              proc.returncode == 2, f"exit {proc.returncode}\n{proc.stdout}{proc.stderr}")
        check("10. it did not crash with a traceback",
              "Traceback" not in proc.stderr, proc.stderr)

        # 11. The worst case: swapped, live database wrong, backup gone. The
        #     final line must NOT say the firewall holds what it held before.
        work = os.path.join(workspace, "case11.plist")
        shutil.copy2(fixture, work)
        proc = run(work, "--apply",
                   env_extra={"AF_FLOW_LULU_FAULT": "lose-backup-after-swap"})
        check("11. a rollback that cannot restore -> exit 4", proc.returncode == 4,
              f"exit {proc.returncode}\n{proc.stdout}{proc.stderr}")
        out = proc.stdout + proc.stderr
        check("11. it says the rollback FAILED", "ROLLBACK ITSELF FAILED" in out, out)
        check("11. it tells him how to restore by hand", "sudo cp" in out, out)
        check("11. it does NOT claim the firewall is as it was",
              "holds what it held before" not in out, out)

        # 12. A UID pointing outside $objects is corruption, and corruption is
        #     the unreadable answer, not a traceback wearing exit 1.
        baduid = os.path.join(workspace, "badptr.plist")
        with open(fixture, "rb") as handle:
            raw = plistlib.load(handle, fmt=plistlib.FMT_BINARY)
        # A NESTED dangling UID, not the root one: the root is caught by
        # root_entries, so pointing that at nothing would test the wrong guard.
        # This corrupts a key reference inside the root dictionary, which only
        # the bounds check inside resolve() can catch.
        root_obj = raw["$objects"][raw["$top"]["root"].data]
        root_obj["NS.keys"][3] = plistlib.UID(len(raw["$objects"]) + 500)
        with open(baduid, "wb") as handle:
            plistlib.dump(raw, handle, fmt=plistlib.FMT_BINARY)
        proc = run(baduid, "--apply")
        check("12. a UID outside $objects -> exit 2, not a traceback",
              proc.returncode == 2, f"exit {proc.returncode}\n{proc.stdout}{proc.stderr}")
        check("12. no traceback escaped", "Traceback" not in proc.stderr, proc.stderr)

        print()
        print("ALL STATES DISTINGUISHED" if all(results)
              else "SOME STATES NOT DISTINGUISHED")
        return 0 if all(results) else 1
    finally:
        shutil.rmtree(workspace, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
