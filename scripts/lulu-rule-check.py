#!/usr/bin/env python3
"""The firewall must not hold a standing Allow any:any for the AF Flow family.

WHY THIS EXISTS. On 2026-07-20 Andrew found a single rule for
`com.frolikov.afflow` reading `any address:any port` set to Allow, and deleted
it, because a standing allow-any rule means LuLu will never prompt or log for
this app again: the empirical backstop this project names as the mitigation for
the model-download residual risk was disarmed while the file still claimed it
was in force. On 2026-08-29 the same shape was back, three times over (app, test
host, AX probe), and nothing had noticed for as long as five weeks.

Session 18 wrote down that a check for the family's firewall rules would have
caught them the day they reappeared. That sentence is this file. A rule that
lives only in a document depends on a future session having read the document,
which is this project's own meta-rule about controls that depend on memory.

WHAT IT CHECKS, none of which the test suite can see:
  - no rule in the family is Allow with both address and port wild
  - the app itself carries a deliberate Block, the 2026-07-20 agreed end state,
    since all models are cached and the app is proven to need no network at run
    time
  - no rule records a path that no longer exists. Stale paths are the likely
    cause of the prompt storm Andrew reported on 2026-08-29: after the rename
    and rebuilds LuLu cannot match its own rules, so attempts prompt fresh.

WHAT IT DOES NOT CHECK. LuLu writes one rule per PROCESS and stores no hostname,
so nothing here can say which hosts were reached. That question was asked of
LuLu three times in July and is structurally unanswerable; it is named here so
it is not attempted a fourth time.

THE ACTION ENCODING. `action` is 0 for Block and 1 for Allow, LuLu's
`RULE_STATE_BLOCK` and `RULE_STATE_ALLOW`. Corroborated on this Mac rather than
taken on faith: every one of the 231 rules present on 2026-08-29 carried
action 1, including Finder, ControlCenter and softwareupdated, which a
default-deny firewall plainly is not blocking wholesale. The raw value is
printed with every finding, so a wrong mapping shows up as a nonsense verdict
rather than a silent one.

The rules database is root-owned and world-readable, so this reads it and never
writes it. Editing is Andrew's clicks in the LuLu UI; verification is this
script afterwards.

EXIT CODES. 0 clean, 1 finding, 2 the file could not be read or decoded. Two is
a third answer and must never be collapsed into either of the others: a firewall
database that cannot be read is not a firewall database with no bad rules in it.
"""

import os
import plistlib
import sys

# Overridable ONLY so the states below can be staged and watched: a checker
# that has only ever been seen red is a claim, not a control. Nothing in the
# repo sets it, and session start calls this script with a clean environment.
RULES_PATH = os.environ.get(
    "AF_FLOW_LULU_RULES_PATH", "/Library/Objective-See/LuLu/rules.plist"
)

APP_ID = "com.frolikov.afflow"
FAMILY_PREFIX = "com.frolikov.afflow"

ACTION_BLOCK = 0
ACTION_ALLOW = 1
ACTION_NAMES = {ACTION_BLOCK: "Block", ACTION_ALLOW: "Allow"}


def unreadable(message):
    print("LuLu firewall rules for the AF Flow family")
    print("=" * 60)
    print(f"  COULD NOT CHECK: {message}")
    sys.exit(2)


def resolve(node, objects, depth=0):
    """Walk an NSKeyedArchiver graph into plain Python.

    UIDs are indexes into `$objects`. The depth cap is a cycle guard: the
    archive is a graph, not a tree, and a class reference can point back up.
    """
    if isinstance(node, plistlib.UID):
        if depth > 60:
            return "<cycle>"
        return resolve(objects[node.data], objects, depth + 1)
    if isinstance(node, dict):
        return {k: resolve(v, objects, depth + 1) for k, v in node.items() if k != "$class"}
    if isinstance(node, list):
        return [resolve(v, objects, depth + 1) for v in node]
    return node


def load_rules():
    if not os.path.exists(RULES_PATH):
        unreadable(f"{RULES_PATH} does not exist. Is LuLu installed?")
    try:
        with open(RULES_PATH, "rb") as handle:
            raw = plistlib.load(handle, fmt=plistlib.FMT_BINARY)
    except PermissionError:
        unreadable(f"{RULES_PATH} is not readable by this user.")
    except Exception as error:  # a corrupt or re-formatted database
        unreadable(f"{RULES_PATH} did not parse as a binary plist: {error}")

    objects = raw.get("$objects")
    top = raw.get("$top")
    if objects is None or top is None or "root" not in top:
        unreadable(
            "rules.plist is not the NSKeyedArchiver shape this script decodes. "
            "LuLu may have changed its format; re-read it before trusting any verdict."
        )

    try:
        root = resolve(top["root"], objects)
        keys = root["NS.keys"]
        values = root["NS.objects"]
    except Exception as error:
        unreadable(f"the archive decoded but did not hold the expected dictionary: {error}")

    if len(keys) != len(values):
        unreadable("the archived dictionary has a different number of keys and values.")

    rules = []
    for key, value in zip(keys, values):
        try:
            for rule in value["NS.objects"][0]["NS.objects"]:
                rule = dict(rule)
                rule["_key"] = key
                rules.append(rule)
        except Exception:
            # One malformed entry must not be read as "this app has no rules".
            unreadable(f"a rule entry under {key!r} did not decode.")
    return rules


def signing_id(rule):
    """The bundle id LuLu bound the rule to, read from the signing info.

    Preferred over splitting the dictionary key on ':', because a key is
    `<id>:<authority>` and an authority can itself contain a colon.
    """
    info = rule.get("csInfo")
    if isinstance(info, dict) and "NS.keys" in info:
        pairs = dict(zip(info["NS.keys"], info["NS.objects"]))
        identifier = pairs.get("signatureIdentifier")
        if isinstance(identifier, str):
            return identifier
    key = rule.get("_key", "")
    return key.split(":", 1)[0] if isinstance(key, str) else ""


def in_family(identifier):
    return identifier == FAMILY_PREFIX or identifier.startswith(FAMILY_PREFIX + ".")


def wild(value):
    return value in ("*", "any", None, "$null")


def describe(rule, identifier):
    action = rule.get("action")
    name = ACTION_NAMES.get(action, f"unknown({action!r})")
    return (
        f"{identifier}  {name} "
        f"{rule.get('endpointAddr')}:{rule.get('endpointPort')}  "
        f"(action={action!r}, uuid={rule.get('uuid')})"
    )


def main():
    rules = load_rules()
    family = [(r, signing_id(r)) for r in rules]
    family = [(r, i) for r, i in family if in_family(i)]

    print("LuLu firewall rules for the AF Flow family")
    print("=" * 60)
    print(f"ok    rules database read, {len(rules)} rule(s) total, {len(family)} in the family")

    findings = []

    if not family:
        # Not a finding. No rule means LuLu has never had to decide about this
        # app, which is the re-armed state, not a broken one.
        print("ok    no rule for the family, so LuLu still prompts for it")

    allow_any = [
        (r, i) for r, i in family
        if r.get("action") == ACTION_ALLOW and wild(r.get("endpointAddr")) and wild(r.get("endpointPort"))
    ]
    for rule, identifier in allow_any:
        findings.append(
            "standing Allow any:any, which means LuLu will never prompt or log "
            f"for this bundle again: {describe(rule, identifier)}"
        )

    app_rules = [(r, i) for r, i in family if i == APP_ID]
    if app_rules and not any(r.get("action") == ACTION_BLOCK for r, _ in app_rules):
        findings.append(
            f"{APP_ID} has {len(app_rules)} rule(s) and none of them is Block. "
            "Agreed 2026-07-20: every model is cached, so the app needs no "
            "network at run time and the rule should be Block."
        )

    for rule, identifier in family:
        recorded = rule.get("path")
        if isinstance(recorded, str) and recorded and not os.path.exists(recorded):
            findings.append(
                f"{identifier} carries a path that is gone, so LuLu cannot match "
                f"its own rule and every attempt prompts fresh: {recorded}"
            )

    if not findings:
        print("ok    no standing Allow any:any in the family")
        if app_rules:
            print("ok    the app carries a Block")
        print("ok    every recorded path still exists")
        print()
        print("RESULT: clean")
        return 0

    print()
    for finding in findings:
        print(f"FINDING: {finding}")
    print()
    print(f"RESULT: {len(findings)} finding(s)")
    print()
    print("The database is root-owned. The edit is three clicks in the LuLu UI:")
    print("  LuLu > Rules, search 'afflow', delete every row in the family,")
    print("  then add the app back as Block.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
