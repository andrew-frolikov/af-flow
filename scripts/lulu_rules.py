#!/usr/bin/env python3
"""Reading LuLu's rules database, in one place.

WHY THIS EXISTS. Two scripts now have an opinion about this file: the checker
that says the family must have no rules, and the remover that takes them out.
If they disagree about what "the family" means, the checker passes on a
database the remover mangled, or the remover takes ten of his rules because it
matched a substring. So both import this, and neither spells the rule itself.

THE SUBSTRING TRAP, which cost a wrong answer on 2026-08-29. Ten of the 228
keys in his database contain the string "frolikov", because his home directory
is `/Users/andriifrolikov`: uv, a git-remote-http under the Codex cache, the
Victoria 3 crash reporter, dota2, a Claude version. Exactly three are his app.
Matching is therefore on the SIGNING IDENTIFIER, with an exact boundary, never
on a substring of the key.

THE ACTION ENCODING, which is documented, not inferred. LuLu's own consts.h:

    #define RULE_STATE_BLOCK 0
    #define RULE_STATE_ALLOW 1
    #define RULE_ACTION @"action"

Read from the source of LuLu 4.3.2, the version installed here, on 2026-08-29.
It matters that this was checked rather than assumed, because the same header
defines the PASSIVE MODE action indexes the other way round:

    #define PREF_PASSIVE_MODE_ALLOW 0
    #define PREF_PASSIVE_MODE_BLOCK 1

Disassembling the extension leads to that second enum first, and reading it as
the rule action inverts every verdict this project makes about the firewall.
The observational corroboration agrees with the header: all 232 rules on this
Mac carry action 1, including Finder, ControlCenter and softwareupdated, and a
firewall blocking those wholesale would be visible in a second.

The file is root-owned and world-readable. Nothing in this module writes.
"""

import os
import plistlib

RULES_PATH = os.environ.get(
    "AF_FLOW_LULU_RULES_PATH", "/Library/Objective-See/LuLu/rules.plist"
)
REAL_RULES_PATH = "/Library/Objective-See/LuLu/rules.plist"

APP_ID = "com.frolikov.afflow"
FAMILY_PREFIX = "com.frolikov.afflow"

ACTION_BLOCK = 0
ACTION_ALLOW = 1
ACTION_NAMES = {ACTION_BLOCK: "Block", ACTION_ALLOW: "Allow"}


class Unreadable(Exception):
    """The database could not be read or decoded.

    A third answer on purpose. A firewall database that cannot be read is not a
    firewall database with no bad rules in it, and collapsing the two is how an
    unreadable source gets reported as a clean one.
    """


def resolve(node, objects, depth=0):
    """Walk an NSKeyedArchiver graph into plain Python.

    UIDs are indexes into `$objects`. The depth cap is a cycle guard: the
    archive is a graph, not a tree, and a class reference points back up.
    """
    if isinstance(node, plistlib.UID):
        if depth > 60:
            return "<cycle>"
        # Codex, 2026-08-29: a UID pointing outside $objects raised IndexError,
        # and both callers catch only Unreadable, so a corrupt archive arrived
        # as a traceback and exit 1 rather than the documented exit 2. Session
        # start would then have called corruption an ordinary firewall finding.
        if not 0 <= node.data < len(objects):
            raise Unreadable(
                f"the archive refers to object {node.data}, but it holds only "
                f"{len(objects)}. The file is corrupt."
            )
        return resolve(objects[node.data], objects, depth + 1)
    if isinstance(node, dict):
        return {
            k: resolve(v, objects, depth + 1) for k, v in node.items() if k != "$class"
        }
    if isinstance(node, list):
        return [resolve(v, objects, depth + 1) for v in node]
    return node


def load_archive(path=None):
    """The raw plist, with `$objects` still holding UIDs. Raises Unreadable."""
    path = path or RULES_PATH
    if not os.path.exists(path):
        raise Unreadable(f"{path} does not exist. Is LuLu installed?")
    try:
        with open(path, "rb") as handle:
            raw = plistlib.load(handle, fmt=plistlib.FMT_BINARY)
    except PermissionError:
        raise Unreadable(f"{path} is not readable by this user.")
    except Exception as error:  # a corrupt or re-formatted database
        raise Unreadable(f"{path} did not parse as a binary plist: {error}")

    if not isinstance(raw, dict):
        raise Unreadable(f"{path} decoded to {type(raw).__name__}, not a plist dictionary.")
    objects = raw.get("$objects")
    top = raw.get("$top")
    if not isinstance(objects, list) or not isinstance(top, dict) or "root" not in top:
        raise Unreadable(
            "rules.plist is not the NSKeyedArchiver shape these scripts decode. "
            "LuLu may have changed its format; re-read it before trusting any verdict."
        )
    return raw


def root_entries(raw):
    """The root dictionary's parallel UID arrays, as stored. Raises Unreadable.

    Returned by reference, so a caller may prune them in place. That is the
    whole reason the remover does not rebuild the graph: every object below the
    root is left exactly as LuLu wrote it.
    """
    objects = raw["$objects"]
    try:
        root = objects[raw["$top"]["root"].data]
        keys, values = root["NS.keys"], root["NS.objects"]
    except Exception as error:
        raise Unreadable(f"the archive decoded but held no root dictionary: {error}")
    if not isinstance(keys, list) or not isinstance(values, list):
        raise Unreadable("the root dictionary's keys and values are not arrays.")
    if len(keys) != len(values):
        raise Unreadable("the archived dictionary has a different number of keys and values.")
    return root, keys, values


def entry_rules(value):
    """The rule dictionaries under one decoded top-level value."""
    pairs = value
    if isinstance(value, dict) and "NS.keys" in value:
        pairs = dict(zip(value["NS.keys"], value["NS.objects"]))
    container = pairs.get("rules") if isinstance(pairs, dict) else None
    if not isinstance(container, dict) or "NS.objects" not in container:
        raise Unreadable("a top-level entry held no 'rules' array.")
    rules = container["NS.objects"]
    # Codex, 2026-08-29: a parseable archive whose rules array is not an array,
    # or holds something that is not a rule, raised TypeError out of the
    # comprehension below and surfaced as a traceback and exit 1. Unreadable is
    # a state this project has a named rule about; it must not arrive as a
    # crash wearing another exit code.
    if not isinstance(rules, list):
        raise Unreadable("a top-level entry's 'rules' is not an array.")
    for rule in rules:
        if not isinstance(rule, dict):
            raise Unreadable(
                f"a rule decoded to {type(rule).__name__}, not a dictionary."
            )
    return rules


def signing_id(rule, key=""):
    """The bundle id LuLu bound the rule to, read from the signing info.

    Preferred over splitting the key on ':', because a key is
    `<id>:<authority>` and an authority can itself contain a colon. For an
    unsigned binary LuLu keys the entry by PATH, and there is no signing
    identifier at all; the key is then the honest answer.
    """
    info = rule.get("csInfo")
    if isinstance(info, dict) and "NS.keys" in info:
        pairs = dict(zip(info["NS.keys"], info["NS.objects"]))
        identifier = pairs.get("signatureIdentifier")
        if isinstance(identifier, str) and identifier:
            return identifier
    return key.split(":", 1)[0] if isinstance(key, str) else ""


def in_family(identifier):
    """Exact identity or a dotted child of it. Never a substring of a path."""
    return identifier == FAMILY_PREFIX or identifier.startswith(FAMILY_PREFIX + ".")


# THE ONE EXCEPTION, decided by Andrew on 2026-08-30 (launch plan open item 3).
#
# The model downloader is the one member of the family that legitimately opens
# a connection, so it will earn a LuLu rule on his Mac and on every friend's.
# Its identifier is INSIDE the family on purpose: moving it outside to keep this
# checker's sentence absolute would hide it from `system-list-check.py`, the
# checker that audits privacy rows and LaunchServices claimants by the same
# prefix, and that is the checker with the track record.
#
# The exception names exactly this identifier, never a pattern, and it applies
# ONLY while a bundle carrying the identifier actually ships inside the
# installed app. If the downloader is ever dropped or renamed, the exception
# must die with it rather than silently permit a rule for a bundle that no
# longer exists, so `helper_ships` is asked every time and "could not tell" is
# treated as "does not ship".
HELPER_ID = "com.frolikov.afflow.models"

# Where a bundled helper can live inside the app. An XPC service is the decided
# design (open item 4D); the app-bundle helper paths are the 4A fallback. This
# list is the ONE place that says where to look.
HELPER_HOMES = (
    "Contents/XPCServices",
    "Contents/Helpers",
    "Contents/Library/LoginItems",
)


def is_test_database():
    """True when the rules path was overridden away from the real database.

    Compared by FILE IDENTITY, not by spelling. `/System/Volumes/Data/Library/...`
    is the same inode as `/Library/...` on this Mac, and a lexical compare
    called that alias a test database, which would have let the staged-app
    override excuse a real rule. Codex, 2026-09-06.
    """
    try:
        if os.path.exists(RULES_PATH) and os.path.exists(REAL_RULES_PATH):
            return not os.path.samefile(RULES_PATH, REAL_RULES_PATH)
    except OSError:
        pass
    return os.path.realpath(RULES_PATH) != os.path.realpath(REAL_RULES_PATH)


def installed_app(repo):
    """Path of the one live AF Flow.app, or None with a reason.

    In a self-test, and ONLY when the rules database itself is already a staged
    file, `AF_FLOW_LULU_APP_PATH` names a staged app bundle instead. Against the
    real database that variable is ignored, so it cannot be used to excuse a
    real rule.
    """
    if is_test_database():
        staged = os.environ.get("AF_FLOW_LULU_APP_PATH")
        if staged:
            return staged, "staged for a self-test"
    import importlib.util  # local: only this path needs it
    where = os.path.join(repo, "scripts", "af_installed_app.py")
    try:
        spec = importlib.util.spec_from_file_location("af_installed_app", where)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        answer = module.decide(module.read_registry(repo), repo)
    except Exception as error:  # noqa: BLE001
        return None, f"the installed app could not be located: {error}"
    if answer[0] == "ONE":
        return answer[1], "the one live AF Flow.app"
    return None, f"the installed app is {answer[0]}"


def helper_ships(repo):
    """(True | False, reason). Never a third value: unknown counts as False.

    True only when a bundle under one of HELPER_HOMES inside the installed app
    declares CFBundleIdentifier == HELPER_ID.
    """
    app, why = installed_app(repo)
    if app is None:
        return False, why
    # A bundle that "ships inside the app" is one whose bytes are inside the
    # app, not one a link points at, at ANY level: the home, the bundle, its
    # Contents, or the plist. So the plist's real path must sit under the
    # app's real path; the per-level `islink` checks are only the cheap early
    # exits. And every way of failing to read is "does not ship", never a
    # traceback.
    app_real = os.path.realpath(app)
    for home in HELPER_HOMES:
        folder = os.path.join(app, home)
        if os.path.islink(folder) or not os.path.isdir(folder):
            continue
        try:
            entries = sorted(os.listdir(folder))
        except OSError:
            continue
        for entry in entries:
            bundle = os.path.join(folder, entry)
            info = os.path.join(bundle, "Contents", "Info.plist")
            if os.path.islink(bundle) or os.path.islink(info):
                continue
            if not os.path.realpath(info).startswith(app_real + os.sep):
                continue
            try:
                with open(info, "rb") as handle:
                    plist = plistlib.load(handle)
            except (OSError, plistlib.InvalidFileException, ValueError):
                continue
            if isinstance(plist, dict) and plist.get("CFBundleIdentifier") == HELPER_ID:
                return True, bundle
    return False, f"no bundle under {app} declares {HELPER_ID}"


def wild(value):
    return value in ("*", "any", None, "$null")


def index(raw):
    """{key: [{uuid, action, addr, port, path, id}, ...]} for the whole file.

    The shape both scripts compare against: enough to say what changed, and
    cheap enough to take before and after a rewrite.
    """
    objects = raw["$objects"]
    _, key_uids, value_uids = root_entries(raw)
    out = {}
    for key_uid, value_uid in zip(key_uids, value_uids):
        key = resolve(key_uid, objects)
        value = resolve(value_uid, objects)
        try:
            rules = entry_rules(value)
        except Unreadable:
            # One malformed entry must not be read as "this app has no rules".
            raise Unreadable(f"the entry under {key!r} did not decode.")
        out[key] = [
            {
                "uuid": r.get("uuid"),
                "action": r.get("action"),
                "addr": r.get("endpointAddr"),
                "port": r.get("endpointPort"),
                "path": r.get("path"),
                "name": r.get("name"),
                "id": signing_id(r, key),
            }
            for r in rules
        ]
    return out


def describe(rule, identifier=None):
    identifier = identifier if identifier is not None else rule.get("id", "")
    action = rule.get("action")
    name = ACTION_NAMES.get(action, f"unknown({action!r})")
    return (
        f"{identifier}  {name} {rule.get('addr')}:{rule.get('port')}  "
        f"(action={action!r}, uuid={rule.get('uuid')})"
    )
