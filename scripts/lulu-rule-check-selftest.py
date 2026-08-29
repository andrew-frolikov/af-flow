"""Stage each state the LuLu checker must distinguish, and watch it react.

Builds real NSKeyedArchiver files in LuLu's own shape, so the decoder is
exercised rather than bypassed.
"""
import plistlib, subprocess, sys, os, tempfile

SCRIPT = "scripts/lulu-rule-check.py"

def archive(rules_by_key, out):
    """rules_by_key: {bundle_key: [rule_dict, ...]} -> a LuLu-shaped archive."""
    objects = ["$null"]
    def add(o):
        objects.append(o)
        return plistlib.UID(len(objects) - 1)

    keys_uids, vals_uids = [], []
    for key, rules in rules_by_key.items():
        keys_uids.append(add(key))
        rule_uids = []
        for r in rules:
            cs = add({
                "NS.keys": [add("signatureIdentifier")],
                "NS.objects": [add(r["id"])],
            })
            rule_uids.append(add({
                "uuid": add(r.get("uuid", "U")),
                "endpointAddr": add(r.get("addr", "*")),
                "endpointPort": add(r.get("port", "*")),
                "action": r["action"],
                "path": add(r["path"]),
                "csInfo": cs,
                "name": add("AF Flow"),
            }))
        rules_container = add({"NS.objects": rule_uids})
        vals_uids.append(add({
            "NS.keys": [add("rules")],
            "NS.objects": [rules_container],
        }))
    root = add({"NS.keys": keys_uids, "NS.objects": vals_uids})
    plist = {"$version": 100000, "$archiver": "NSKeyedArchiver",
             "$top": {"root": root}, "$objects": objects}
    with open(out, "wb") as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)

def run(path, label, expect):
    env = dict(os.environ, AF_FLOW_LULU_RULES_PATH=path)
    p = subprocess.run([sys.executable, SCRIPT], env=env,
                       capture_output=True, text=True)
    ok = p.returncode == expect
    print(f"{'PASS' if ok else 'FAIL'}  {label}: exit {p.returncode} (expected {expect})")
    for line in p.stdout.strip().splitlines():
        if line.startswith(("FINDING", "RESULT", "ok    no", "  COULD")):
            print(f"        {line}")
    return ok

tmp = tempfile.mkdtemp()
here = os.path.abspath(".")           # a path that certainly exists
allgood = []

# 1. No family rules at all: LuLu still prompts. That is the re-armed state.
p1 = f"{tmp}/none.plist"
archive({"com.apple.Safari:auth": [{"id": "com.apple.Safari", "action": 1, "path": here}]}, p1)
allgood.append(run(p1, "no family rule -> clean", 0))

# 2. The agreed end state: app blocked, path real, nothing else in the family.
p2 = f"{tmp}/blocked.plist"
archive({"com.frolikov.afflow:auth": [
    {"id": "com.frolikov.afflow", "action": 0, "path": here}]}, p2)
allgood.append(run(p2, "app Block, live path -> clean", 0))

# 3. Today's real shape: Allow any:any.
p3 = f"{tmp}/allowany.plist"
archive({"com.frolikov.afflow:auth": [
    {"id": "com.frolikov.afflow", "action": 1, "path": here}]}, p3)
allgood.append(run(p3, "Allow any:any -> finding", 1))

# 4. Blocked, but recorded at a path that is gone: the prompt-storm shape.
p4 = f"{tmp}/stale.plist"
archive({"com.frolikov.afflow:auth": [
    {"id": "com.frolikov.afflow", "action": 0, "path": "/nope/gone.app"}]}, p4)
allgood.append(run(p4, "Block at a dead path -> finding", 1))

# 5. Allow, but scoped to one host: NOT the disarming shape, so not a finding
#    on that count. Still flagged for the missing Block, which is correct.
p5 = f"{tmp}/scoped.plist"
archive({"com.frolikov.afflow.testhost:auth": [
    {"id": "com.frolikov.afflow.testhost", "action": 1,
     "addr": "huggingface.co", "port": "443", "path": here}]}, p5)
allgood.append(run(p5, "Allow to ONE host -> clean (not a wildcard)", 0))

# 6. Unreadable must be its OWN answer, never "no bad rules found".
p6 = f"{tmp}/garbage.plist"
open(p6, "wb").write(b"not a plist at all")
allgood.append(run(p6, "corrupt file -> exit 2, not 0", 2))

p7 = f"{tmp}/missing.plist"
allgood.append(run(p7, "absent file -> exit 2, not 0", 2))

print()
print("ALL STATES DISTINGUISHED" if all(allgood) else "SOME STATES NOT DISTINGUISHED")
sys.exit(0 if all(allgood) else 1)
