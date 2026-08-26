#!/usr/bin/env python3
"""Every macOS list that shows a bundle's NAME must show one app called AF Flow.

WHY THIS EXISTS. On 2026-08-25 Andrew opened System Settings > Privacy and
Security > Input Monitoring and found "AF Flow" listed twice, both allowed. He
asked for "a single line, one application, no confusion for future users."

Two habits produced it, and both are invisible from inside the test suite:

  1. The test host was given its own bundle identifier in 2026-07-26 so it could
     never be installed as his app, but never its own DISPLAY NAME. macOS labels
     a privacy row with the bundle's display name, so the two rows were
     indistinguishable.
  2. Past sessions built throwaway bundles to verify a rename or a snapshot.
     Each requested a permission, each earned a PERMANENT row in System
     Settings, and each was then deleted. Seven such identifiers survived, and
     seven of their rows still held a granted microphone. Their LaunchServices
     records still carried `name: AF Flow`, which is what put his product's name
     on rows belonging to bundles that no longer existed.

The rule those produced is in `docs/design/af-flow-system-list-names.md` and in
the brand canon. A rule that lives only in a document is a rule that depends on
a future session having read it, which is this project's own meta-rule about
controls that depend on memory. This is the mechanism instead.

SCOPE, deliberately narrower than the headline. This covers surfaces that show a
bundle's DISPLAY NAME: System Settings, Finder, the Dock, Login Items. It does
NOT cover surfaces that show the EXECUTABLE name. `EXECUTABLE_NAME` is `AF Flow`
for the app and for the test host alike, so Activity Monitor, Force Quit and
`ps` still show two processes called "AF Flow" while a suite is running. That is
a deliberate trade: the executable name is part of the path his permission
grants are attached to. Named here so nobody reads a clean result as covering it.

Checked here, none of which the suite can see:
  - no TCC row for the family belongs to anything but the app or the test host
  - no LaunchServices record for the family points at a bundle that is gone
  - the name "AF Flow" is claimed by exactly one identifier, the app, checked
    over EVERY record rather than only the family, because the rule is about
    names and a scratch identifier can still carry the product's name

Exit 1 on any finding. Exit 2 when a source could not be READ, which is a third
answer and must not be reported as either of the others. Reading the TCC
databases needs Full Disk Access, so a checkout on another machine can
legitimately not know; the boundary sweep treats 2 as a skip the way it already
skips the binary link check without a Debug build. Session start prints the
distinction rather than swallowing it.

Costs about 3 seconds, almost all of it `lsregister -dump` over 22 MB. That
makes it the slowest thing in session-start.sh, and it is worth it: nothing
cheaper can see machine state.
"""

import os
import re
import sqlite3
import subprocess
import sys

APP_ID = "com.frolikov.afflow"
TEST_HOST_ID = "com.frolikov.afflow.testhost"

# The names decided in docs/design/af-flow-system-list-names.md. The bare product
# name belongs to the app and to nothing else; every other bundle in the family
# is the product name plus plain words naming its job.
EXPECTED_NAMES = {
    APP_ID: "AF Flow",
    TEST_HOST_ID: "AF Flow Tests",
}

# Two more identifiers this project builds under the same prefix. Neither is an
# app bundle: `.tests` is the xctest plugin inside the host and
# `.cleanup-model-probe` is a command line tool, so neither registers with
# LaunchServices and neither can request a permission. They are listed so that a
# reader comparing this file against project.yml does not think the list is
# stale. If either ever DOES appear below, that is a real finding and not a
# whitelist gap: it would mean something built one of them as an app.
KNOWN_NON_APP_IDS = {
    "com.frolikov.afflow.tests",
    "com.frolikov.afflow.cleanup-model-probe",
}

# The product name, and anything that starts with it. Rule 1 of the naming
# decision is stated over NAMES, so the check has to be able to see a name on a
# record whose identifier is outside the family entirely: a scratch bundle that
# kept the product's name is exactly the shape this rule forbids, and an
# identifier-keyed check is blind to it.
PRODUCT_NAME = "AF Flow"

SYSTEM_DB = "/Library/Application Support/com.apple.TCC/TCC.db"
USER_DB = os.path.expanduser("~/Library/Application Support/com.apple.TCC/TCC.db")
LSREGISTER = (
    "/System/Library/Frameworks/CoreServices.framework/Frameworks"
    "/LaunchServices.framework/Support/lsregister"
)

findings = []
notes = []


def in_family(identifier):
    """Anchored on a dot, not on a bare prefix.

    `like 'com.frolikov.afflow%'` also matches `com.frolikov.afflowsomething`,
    which is a different vendor's bundle as far as anyone can tell.
    """
    return identifier == APP_ID or identifier.startswith(APP_ID + ".")


def path_state(path):
    """'here', 'gone' or 'unreadable'. Three answers, never two.

    `os.path.exists` swallows every OSError and returns False, so "permission
    denied" and "does not exist" collapse into one answer. That is reachable
    here rather than theoretical: this check is designed to run WITHOUT Full
    Disk Access, and without it a stat inside ~/Desktop, ~/Documents or
    ~/Downloads fails. An `AF Flow.app` sitting in any of those would otherwise
    be reported as a bundle that is gone, on a machine where nothing is wrong,
    and the remedy printed below would be a script that removes its record.
    """
    try:
        os.stat(path)
        return "here"
    except FileNotFoundError:
        return "gone"
    except NotADirectoryError:
        return "gone"
    except OSError:
        return "unreadable"


def tcc_rows(path):
    """Rows for the family, or None if the database could not be read.

    None and [] are DIFFERENT answers and the caller must not conflate them.
    Reading these files needs Full Disk Access, and without it the query returns
    nothing at all, which looks exactly like a clean machine. Reporting "clean"
    from an unreadable sensor is the failure this project has already paid for
    twice.
    """
    if not os.path.exists(path):
        return None
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            cursor = connection.execute(
                "select client, service, auth_value from access "
                "where client = ? or client like ?",
                (APP_ID, APP_ID + ".%"),
            )
            return cursor.fetchall()
        finally:
            connection.close()
    except sqlite3.Error:
        return None


def launch_services_records():
    """(identifier, name, path) for EVERY record, or None if unreadable.

    Every record, not only the family: rule 1 is about the name, and a bundle
    carrying `AF Flow` under a scratch identifier breaks it just as completely.

    The subprocess is checked the way the sqlite reads are. Without this a
    missing or failing `lsregister` returned an empty list, which flowed
    straight through to `RESULT: clean` and exit 0. That is the exact failure
    this file's exit-2 state exists to prevent, and it was applied to sqlite and
    not to the subprocess. Found by review on 2026-08-25.
    """
    try:
        completed = subprocess.run(
            [LSREGISTER, "-dump"], capture_output=True, text=True, timeout=180
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0 or not completed.stdout.strip():
        return None

    blocks = re.split(r"^-{60,}$", completed.stdout, flags=re.M)
    # A dump with no block separators is a truncated or unrecognised dump, not
    # an empty registry. The real one carries thousands.
    if len(blocks) < 100:
        return None

    records = []
    for block in blocks:
        identifier = re.search(r"^identifier:\s+(\S+)", block, re.M)
        path = re.search(r"^path:\s+(.*?)\s+\(0x[0-9a-f]+\)\s*$", block, re.M)
        if not identifier or not path:
            continue
        name = re.search(r"^name:\s+(.*)$", block, re.M)
        records.append(
            (
                identifier.group(1),
                name.group(1).strip() if name else None,
                path.group(1),
            )
        )
    return records


def check_tcc(label, path):
    rows = tcc_rows(path)
    if rows is None:
        notes.append(
            f"could not read the {label} TCC database, so its rows were NOT checked"
        )
        return 1

    print(f"ok    {label} TCC database read, {len(rows)} row(s) for the family")
    strangers = {}
    for client, service, auth in rows:
        if client in EXPECTED_NAMES:
            continue
        strangers.setdefault(client, []).append(
            f"{service.replace('kTCCService', '')}{'=GRANTED' if auth == 2 else ''}"
        )
    # One finding per bundle, not one per service. The count at the bottom is
    # meant to answer "how many things are wrong", and a single dead probe
    # holding three services is one thing.
    for client in sorted(strangers):
        services = ", ".join(sorted(strangers[client]))
        granted = "GRANTED" in services
        detail = (
            " A bundle carrying that identifier would inherit those permissions "
            "with no prompt."
            if granted
            else ""
        )
        findings.append(
            f"{label} TCC database holds rows for '{client}' ({services}), which is "
            f"neither the app nor the test host.{detail}"
        )
    return 0


def check_launch_services():
    records = launch_services_records()
    if records is None:
        notes.append("could not read LaunchServices, so its records were NOT checked")
        return 1

    family = [r for r in records if in_family(r[0])]
    print(
        f"ok    LaunchServices read, {len(records)} record(s), "
        f"{len(family)} in the family"
    )

    for identifier, name, path in family:
        shown = name if name is not None else "(no name)"
        state = path_state(path)

        if name is None:
            # "I could not read a name" is not "the name is fine". An empty
            # AF_FLOW_DISPLAY_NAME produces exactly this, and silently skipping
            # it would make this check blind to the regression the change it
            # guards makes possible.
            findings.append(
                f"LaunchServices holds no name for '{identifier}' at {path}. An "
                f"empty AF_FLOW_DISPLAY_NAME looks like this."
            )
            continue

        if state == "unreadable":
            notes.append(
                f"could not stat the bundle for '{identifier}' at {path}, so "
                f"whether it still exists was NOT checked"
            )
            continue

        if state == "gone":
            if identifier in EXPECTED_NAMES:
                # A LIVE identifier whose bundle moved needs a re-register or a
                # rebuild, NEVER an unregister: removing the app's only record
                # is what puts tccutil into the -10814 state this whole line of
                # work started from, and System Settings resolves the row's name
                # through that same record.
                findings.append(
                    f"LaunchServices lists the LIVE identifier '{identifier}' at a "
                    f"bundle that is gone: {path}. Rebuild or re-register it. Do "
                    f"NOT run the cleanup script for this one."
                )
            else:
                findings.append(
                    f"LaunchServices still lists '{identifier}' as '{shown}' at a "
                    f"bundle that is gone: {path}"
                )
            continue

        expected = EXPECTED_NAMES.get(identifier)
        if expected is None:
            findings.append(
                f"LaunchServices knows an undecided family identifier "
                f"'{identifier}' as '{shown}' at {path}"
            )
        elif name != expected:
            findings.append(
                f"'{identifier}' shows in system lists as '{shown}', but its "
                f"decided name is '{expected}': {path}"
            )

    # The name-keyed pass. Rule 1 says the bare product name belongs to exactly
    # one identifier; nothing about that rule mentions the identifier's prefix,
    # so neither does this.
    for identifier, name, path in records:
        if name is None or not name.startswith(PRODUCT_NAME):
            continue
        if EXPECTED_NAMES.get(identifier) == name:
            continue
        findings.append(
            f"'{name}' is shown by '{identifier}' at {path}. The name "
            f"'{PRODUCT_NAME}' belongs to '{APP_ID}' alone, and every other "
            f"bundle in the family is named in "
            f"docs/design/af-flow-system-list-names.md."
        )
    return 0


def main():
    print("Does every system list show one AF Flow")
    print("---------------------------------------")

    unreadable = 0
    unreadable += check_tcc("system", SYSTEM_DB)
    unreadable += check_tcc("user", USER_DB)
    unreadable += check_launch_services()

    print()
    for note in notes:
        print(f"warning: {note}")
    if notes:
        print()

    if findings:
        for finding in sorted(set(findings)):
            print(f"FAIL  {finding}")
        print()
        print("Fix: for a DEAD identifier, scripts/tcc-orphan-cleanup.sh --apply")
        print("removes its rows and its stale LaunchServices record. A wrong NAME")
        print("is a build fix, and a live identifier at a missing path wants a")
        print("rebuild: see docs/design/af-flow-system-list-names.md.")
        print()
        print(f"RESULT: {len(set(findings))} finding(s)")
        return 1

    # An unreadable sensor is not a pass. Said out loud rather than folded into
    # the word "clean", because the whole point of this check is that a missing
    # row and an unread row look identical. Its own exit code, so a caller can
    # tell "there is nothing wrong" from "I could not look".
    if unreadable or notes:
        print(f"RESULT: {unreadable or len(notes)} source(s) unreadable, so this proved nothing")
        return 2

    print("RESULT: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
