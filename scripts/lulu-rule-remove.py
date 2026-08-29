#!/usr/bin/env python3
"""Remove the AF Flow family's rules from LuLu's database, or say why not.

WHY THIS EXISTS. Three `Allow any-address:any-port` rules for the family (the
app, the test host, the AX probe) have now appeared twice: deleted 2026-07-20,
back by 2026-08-29. A standing allow-any rule means LuLu will never prompt or
log for that bundle again, so the empirical backstop this project names as its
mitigation was disarmed while the documents still claimed it was in force. The
recorded paths also point at bundles that no longer exist, which is the likely
cause of the prompt storm he reported: LuLu cannot match its own rule, so every
attempt prompts fresh.

LuLu has no CLI and no scriptable interface, by design: it ignores synthetic
clicks on its own window, which is exactly what stops malware from clicking
itself an Allow. So the only route is this file, and this file is root-owned.
ANDREW RUNS THIS, ONCE, WITH SUDO. Nothing here asks for his password.

WHAT IT GUARANTEES, in the order the guarantees matter:

  1. It builds a candidate in a temp file and never edits the original in
     place. The original is only ever replaced, atomically, at the very end.
  2. It refuses to swap a candidate that does not verify: the candidate must
     parse, must have lost exactly the entries named, and must still hold every
     other key with byte-equal rules. A count alone is not enough, because two
     compensating errors keep a count.
  3. A timestamped backup is taken before the swap, and its path is printed on
     success AND on every failure, because the path is only useful to him in
     the case where something went wrong.
  4. LuLu is stopped before the swap and started after. If the live database
     then fails to read, or does not hold what was verified, the backup is put
     back automatically.
  5. Dry run is the DEFAULT. Applying takes an explicit --apply.

WHY IT PRUNES RATHER THAN REBUILDS. The native path is NSKeyedArchiver through
PyObjC, which preserves LuLu's format exactly. There is no PyObjC on this Mac:
`Foundation` does not import under /usr/bin/python3. Rebuilding the archive
graph by hand is the documented fallback and it is a bad one, because a
re-serialised graph can differ from what LuLu's secure-coding unarchiver
accepts in ways nothing here would notice.

There is a third way, and it is the one taken. Each family entry is a WHOLE
top-level key in the root dictionary. So this removes those keys from the root
dictionary's two parallel UID arrays and leaves every other object in
`$objects` exactly as LuLu wrote it. Nothing is re-encoded, no UID is
renumbered, and the objects the removed keys pointed at simply stop being
reachable. LuLu decodes from `$top` and never visits them; they disappear from
the file the next time LuLu writes it.

EXIT CODES.
  0  clean: a dry run, or an apply that verified, or nothing to remove
  1  refused: the database holds something this script will not guess about
  2  the database could not be read or decoded
  3  the candidate did not verify; the original was NOT touched
  4  the swap was rolled back; the original is back in place
  5  the swap verified, but LuLu did not come back
"""

import argparse
import datetime
import os
import plistlib
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lulu_rules as L  # noqa: E402

EXIT_CLEAN = 0
EXIT_REFUSED = 1
EXIT_UNREADABLE = 2
EXIT_NOT_VERIFIED = 3
EXIT_ROLLED_BACK = 4
EXIT_LULU_MISSING = 5

EXTENSION_NAME = "com.objective-see.lulu.extension"
APP_NAME = "LuLu"

# Fault injection, for the selftest only. Honoured ONLY when this is pointed at
# something other than the real database, so no test can stage a failure
# against his firewall. See lulu-rule-remove-selftest.py cases 4 and 5.
FAULT = os.environ.get("AF_FLOW_LULU_FAULT", "")


def say(message=""):
    print(message, flush=True)


# ------------------------------------------------------------------ deciding

def family_entries(raw):
    """({key: [rule, ...]} to remove, the whole index). Raises Refused.

    An entry counts as the family's when EVERY rule in it belongs to the
    family. An entry holding both his app's rules and someone else's is not
    something this script will guess about: pruning the key would take a
    stranger's rule with it, and pruning inside the entry means rebuilding the
    graph, which is the thing this design exists to avoid.
    """
    whole = L.index(raw)
    doomed, mixed = {}, {}
    for key, rules in whole.items():
        flags = [L.in_family(rule["id"]) for rule in rules]
        if not any(flags):
            continue
        if all(flags):
            doomed[key] = rules
        else:
            mixed[key] = rules
    if mixed:
        raise Refused(
            "an entry holds both family and foreign rules, so removing its key "
            "would take a rule that is not his app's:\n"
            + "\n".join(
                f"    {key}\n" + "\n".join(f"      {L.describe(r)}" for r in rules)
                for key, rules in mixed.items()
            )
        )
    return doomed, whole


class Refused(Exception):
    """The database holds something this script will not guess about."""


# ------------------------------------------------------------------ building

def build_candidate(raw, doomed_keys, out_path):
    """Prune the root dictionary and write the candidate. Returns what it wrote."""
    objects = raw["$objects"]
    _, key_uids, value_uids = L.root_entries(raw)

    keep_keys, keep_values, removed = [], [], []
    for key_uid, value_uid in zip(key_uids, value_uids):
        key = L.resolve(key_uid, objects)
        if key in doomed_keys:
            removed.append(key)
        else:
            keep_keys.append(key_uid)
            keep_values.append(value_uid)

    if sorted(removed) != sorted(doomed_keys):
        raise Refused(
            "the keys to remove did not all appear exactly once in the root "
            f"dictionary: expected {sorted(doomed_keys)}, matched {sorted(removed)}"
        )

    # Mutating the arrays in place mutates `raw`, which is what gets written.
    key_uids[:] = keep_keys
    value_uids[:] = keep_values

    with open(out_path, "wb") as handle:
        plistlib.dump(raw, handle, fmt=plistlib.FMT_BINARY)

    if FAULT == "corrupt-before-swap" and not is_real_database():
        with open(out_path, "wb") as handle:
            handle.write(b"a candidate that does not parse")
    return removed


def is_real_database():
    return os.path.realpath(L.RULES_PATH) == os.path.realpath(L.REAL_RULES_PATH)


# --------------------------------------------------------------- verification

def verify(path, before, doomed_keys, label):
    """The candidate must be the original minus exactly those keys.

    Every failure here is a refusal to proceed, never a warning. Checked in
    increasing strength, so the message names the first thing that is wrong.
    """
    problems = []

    # macOS's own parser, not just this script's. A file that only plistlib
    # will read is not one LuLu is going to read.
    lint = subprocess.run(["plutil", "-lint", path], capture_output=True, text=True)
    if lint.returncode != 0:
        return [f"{label} is not a plist macOS will parse: {lint.stdout.strip() or lint.stderr.strip()}"]

    try:
        raw = L.load_archive(path)
        after = L.index(raw)
    except L.Unreadable as error:
        return [f"{label} does not decode: {error}"]

    if raw.get("$archiver") != "NSKeyedArchiver":
        problems.append(f"{label} is no longer an NSKeyedArchiver archive")

    expected = {k: v for k, v in before.items() if k not in doomed_keys}

    if len(after) != len(expected):
        problems.append(
            f"{label} holds {len(after)} keys; the original held {len(before)} and "
            f"{len(doomed_keys)} were to be removed, so it should hold {len(expected)}"
        )

    still_here = [k for k in doomed_keys if k in after]
    if still_here:
        problems.append(f"{label} still holds {len(still_here)} of the removed keys: {still_here}")

    vanished = [k for k in expected if k not in after]
    if vanished:
        problems.append(
            f"{label} LOST {len(vanished)} key(s) that were not to be touched: {vanished[:5]}"
        )

    changed = [k for k in expected if k in after and after[k] != expected[k]]
    if changed:
        problems.append(
            f"{label} changed the rules under {len(changed)} untouched key(s): {changed[:5]}"
        )

    leftover = [k for k, rules in after.items() if any(L.in_family(r["id"]) for r in rules)]
    if leftover:
        problems.append(f"{label} still holds family rules under {leftover}")

    expected_rules = sum(len(v) for v in expected.values())
    actual_rules = sum(len(v) for v in after.values())
    if expected_rules != actual_rules:
        problems.append(
            f"{label} holds {actual_rules} rules; it should hold {expected_rules}"
        )
    return problems


# ------------------------------------------------------------- driving LuLu

def lulu_extension_pid():
    proc = subprocess.run(["pgrep", "-f", EXTENSION_NAME], capture_output=True, text=True)
    pids = [int(p) for p in proc.stdout.split() if p.strip().isdigit()]
    return pids[0] if pids else None


def lulu_app_running():
    return subprocess.run(["pgrep", "-x", APP_NAME], capture_output=True).returncode == 0


def stop_lulu(restart_extension):
    """Quiet the app, and the filter, before the database is touched.

    LuLu's extension holds its rules in memory: `Rules.m` loads the file at
    start and writes it on every mutation, and there is no file watch. A swap
    made while it runs therefore lasts only until its next save, which then
    puts the removed rules back.

    This CANNOT guarantee the filter stays down: macOS owns its lifecycle and
    restarts it whenever it likes. So this is only the narrowing of the window,
    and the actual guarantee is `restart_filter_after_swap` below, which is
    what makes the removal stick. Codex, 2026-08-29: an earlier version treated
    the first absent PID here as quiescence and then swapped, which a restart
    landing in between would have quietly undone.
    """
    if lulu_app_running():
        say("  quitting the LuLu app")
        subprocess.run(["pkill", "-x", APP_NAME], capture_output=True)
        for _ in range(50):
            if not lulu_app_running():
                break
            time.sleep(0.1)
    if not restart_extension:
        say("  leaving the system extension running (--keep-extension)")
        say("  NOTE: it holds the old rules in memory and will write them back")
        return
    pid = lulu_extension_pid()
    if pid is None:
        say("  the system extension is not running")
        return
    say(f"  pausing the system extension (pid {pid})")
    subprocess.run(["kill", str(pid)], capture_output=True)
    for _ in range(50):
        if lulu_extension_pid() != pid:
            break
        time.sleep(0.1)


def restart_filter_after_swap():
    """Guarantee the RUNNING filter is one that read the new database.

    Runs AFTER the swap, and kills whatever filter is running WITHOUT asking
    how old it is. Codex, 2026-08-29, second round: the first version compared
    against the pid seen before the run and treated any different pid as
    post-swap. That is wrong, because macOS can replace the extension during
    the stop window, which produces a new pid on a process that still read the
    OLD database and will write the removed rules back at its next save. A pid
    is not a timestamp.

    Killing unconditionally is correct and cheap: the swap has already
    happened, so ANY process that appears after this kill loaded the new file.
    Killing one that was already fresh costs a restart and nothing else.

    Returns (came_back, why). came_back False means his firewall is not
    filtering, which is said out loud rather than folded into a generic error.
    """
    victim = lulu_extension_pid()
    if victim is not None:
        say(f"  restarting the filter (pid {victim}) so it reads the new database")
        subprocess.run(["kill", str(victim)], capture_output=True)
    else:
        say("  no filter running; waiting for the one macOS starts next")

    for _ in range(120):
        current = lulu_extension_pid()
        if current is not None and current != victim:
            say(f"  the network filter is back (pid {current}), on the new database")
            return True, ""
        time.sleep(0.5)
    return False, "the network filter did not come back within 60 seconds"


def start_lulu(restart_extension):
    """Relaunch the app AS HIM, and make sure the filter is a post-swap one.

    `open` under sudo would launch LuLu as root and leave it unable to talk to
    his session, so the launch is dropped back to SUDO_USER.
    """
    user = os.environ.get("SUDO_USER")
    command = ["open", "-a", APP_NAME]
    if user and os.geteuid() == 0:
        command = ["sudo", "-u", user] + command
    say("  relaunching the LuLu app")
    subprocess.run(command, capture_output=True)

    if not restart_extension:
        return True
    came_back, _ = restart_filter_after_swap()
    return came_back


def restore(backup, path):
    """Put the backup back atomically, never by truncating the live file.

    Codex, 2026-08-29: the first version copied straight onto the live path, so
    an interrupted restore left a partial database where his firewall's rules
    used to be, and a copy error escaped as a traceback. The backup is written
    beside the target and moved into place in one step, the same way the
    candidate is.
    """
    staging = path + ".restoring"
    try:
        shutil.copy2(backup, staging)
        os.chmod(staging, 0o644)
        if os.geteuid() == 0:
            os.chown(staging, 0, 0)
        os.replace(staging, path)
        return True, ""
    except OSError as error:
        if os.path.exists(staging):
            try:
                os.unlink(staging)
            except OSError:
                pass
        return False, str(error)


# ---------------------------------------------------------------------- main

def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--apply", action="store_true",
        help="actually replace the database. Without it this only reports.",
    )
    parser.add_argument(
        "--keep-extension", action="store_true",
        help="do not restart the network filter. The removal will not stick.",
    )
    args = parser.parse_args()

    path = L.RULES_PATH
    real = is_real_database()
    restart_extension = real and not args.keep_extension

    title = "Remove the AF Flow family's rules from LuLu"
    say(title)
    say("=" * len(title))
    say(f"  database: {path}")

    # Read once to decide and report. If anything is to be applied, LuLu is
    # stopped and the file is read AGAIN, because it moves under a reader: it
    # gained a rule between two reads while this script was being written.
    try:
        raw = L.load_archive(path)
        doomed, whole = family_entries(raw)
    except L.Unreadable as error:
        say(f"  COULD NOT READ: {error}")
        say("\nRESULT: the database could not be read. That is not a clean one.")
        return EXIT_UNREADABLE
    except Refused as error:
        say(f"  REFUSED: {error}")
        say("\nRESULT: refused, nothing was written.")
        return EXIT_REFUSED

    total_rules = sum(len(v) for v in whole.values())
    say(f"  {len(whole)} keys, {total_rules} rules, {len(doomed)} keys in the family")
    say()

    if not doomed:
        say("Nothing to remove: the family has no rules, which is the agreed end state.")
        say("\nRESULT: clean")
        return EXIT_CLEAN

    say("Would remove these, and only these:")
    for key, rules in doomed.items():
        say(f"  {key}")
        for rule in rules:
            say(f"      {L.describe(rule)}")
            recorded = rule.get("path")
            if isinstance(recorded, str) and recorded and not os.path.exists(recorded):
                say(f"      recorded at a path that is gone: {recorded}")
    say()

    if not args.apply:
        say("This was a DRY RUN and the database was not touched.")
        say("Re-run with --apply to remove them.")
        say("\nRESULT: clean")
        return EXIT_CLEAN

    # ---------------------------------------------------------------- apply
    if real and os.geteuid() != 0:
        say("REFUSED: the real database is root-owned and this is not running as root.")
        say("\nRESULT: refused, nothing was written.")
        return EXIT_REFUSED

    directory = os.path.dirname(os.path.abspath(path)) or "."
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = os.path.join(directory, f"rules.backup-{stamp}.plist")
    candidate = os.path.join(directory, f".rules.candidate-{stamp}.plist")

    swapped = False

    if real:
        say("Stopping LuLu before the swap, so it cannot write over it.")
        stop_lulu(restart_extension)
        say()

    def bring_back(code, message):
        """Restart LuLu on an abandoned run, and never hide a filter that stayed down.

        Codex, 2026-08-29: every early return below used to throw away
        `start_lulu`'s answer, so a run that failed for an ordinary reason AND
        left his firewall off reported only the ordinary reason.
        """
        if not real:
            return finish(code, message)
        if start_lulu(restart_extension):
            return finish(code, message)
        say()
        say("  AND THE NETWORK FILTER DID NOT COME BACK. His firewall is not running.")
        say("  Open LuLu, or reboot, and check its icon before trusting this Mac online.")
        return finish(EXIT_LULU_MISSING, message + " LuLu is also NOT filtering.")

    def finish(code, message):
        """Every exit from here on names the backup. It only matters on failure."""
        say()
        if os.path.exists(backup):
            say(f"  backup: {backup}")
        say(f"\nRESULT: {message}")
        return code

    try:
        # Re-read the now-frozen file. Everything below is built from THESE
        # bytes, never from the read above, so a rule LuLu added in between is
        # carried across rather than silently dropped.
        raw = L.load_archive(path)
        doomed, whole = family_entries(raw)
    except (L.Unreadable, Refused) as error:
        say(f"  the database changed under this run and no longer decodes: {error}")
        code = EXIT_UNREADABLE if isinstance(error, L.Unreadable) else EXIT_REFUSED
        return bring_back(code, "nothing was written.")

    if not doomed:
        say("The family's rules were gone by the time the swap began. Nothing written.")
        return bring_back(EXIT_CLEAN, "clean")

    try:
        shutil.copy2(path, backup)
    except OSError as error:
        say(f"  COULD NOT BACK UP: {error}")
        return bring_back(EXIT_NOT_VERIFIED,
                          "nothing was written, because a backup could not be taken.")
    say(f"  backup: {backup}")

    try:
        before = dict(whole)
        removed = build_candidate(raw, set(doomed), candidate)
        say(f"  candidate built, {len(removed)} key(s) pruned")

        problems = verify(candidate, before, set(doomed), "the candidate")
        if problems:
            say()
            for problem in problems:
                say(f"  DID NOT VERIFY: {problem}")
            os.unlink(candidate)
            return bring_back(EXIT_NOT_VERIFIED,
                              "the candidate did not verify. The original was NOT touched.")
        say("  candidate verified: exactly those keys gone, every other rule identical")

        os.chmod(candidate, 0o644)
        if os.geteuid() == 0:
            os.chown(candidate, 0, 0)
        os.replace(candidate, path)
        swapped = True
        say("  swapped in")

        if FAULT == "corrupt-after-swap" and not is_real_database():
            with open(path, "wb") as handle:
                handle.write(b"a live database that went bad after the swap")
        if FAULT == "lose-backup-after-swap" and not is_real_database():
            # Stages the worst case: the swap happened, the live database is
            # wrong, AND the backup is not there to put back. The output at
            # that moment must not read as reassuring.
            with open(path, "wb") as handle:
                handle.write(b"a live database that went bad after the swap")
            os.unlink(backup)

    except Refused as error:
        say(f"  REFUSED: {error}")
        if os.path.exists(candidate):
            os.unlink(candidate)
        return bring_back(EXIT_REFUSED, "refused, the original was NOT touched.")
    except Exception as error:
        # Codex, 2026-08-29: this used to claim the original was untouched even
        # when os.replace had already succeeded, so a failure after the swap
        # reported the exact opposite of the state on disk.
        say(f"  FAILED: {error}")
        if not swapped:
            if os.path.exists(candidate):
                os.unlink(candidate)
            return bring_back(EXIT_NOT_VERIFIED, "the original was NOT touched.")
        say("  THE SWAP HAD ALREADY HAPPENED. Rolling back.")
        restored, why = restore(backup, path)
        if not restored:
            return bring_back(EXIT_ROLLED_BACK,
                              f"the swap happened and the rollback FAILED ({why}). "
                              f"Restore by hand from the backup.")
        return bring_back(EXIT_ROLLED_BACK, "rolled back after a failure during the swap.")

    came_back = True
    if real:
        say()
        say("Starting LuLu, and making sure the filter is one that read the new file.")
        subprocess.run(
            (["sudo", "-u", os.environ["SUDO_USER"]] if os.environ.get("SUDO_USER")
             and os.geteuid() == 0 else []) + ["open", "-a", APP_NAME],
            capture_output=True,
        )
        came_back, why = restart_filter_after_swap() if restart_extension else (True, "")
        say()

    problems = verify(path, before, set(doomed), "the live database")
    if problems:
        say()
        for problem in problems:
            say(f"  LIVE DATABASE IS WRONG: {problem}")
        say("  rolling back from the backup")
        if real:
            # Stop LuLu FIRST, so nothing is writing while the backup goes
            # back, and restore atomically rather than truncating the live
            # file. Codex, 2026-08-29.
            stop_lulu(restart_extension)
        restored, why = restore(backup, path)
        if not restored:
            say(f"  THE ROLLBACK ITSELF FAILED: {why}")
            say(f"  His firewall database is in an UNKNOWN state. Restore by hand:")
            say(f"    sudo cp '{backup}' '{path}'")
            return bring_back(EXIT_ROLLED_BACK,
                              "the rollback FAILED. Restore by hand from the backup.")
        rolled = verify(path, before, set(), "the rolled-back database")
        if rolled:
            # Codex, 2026-08-29: this branch used to warn and then print the
            # reassuring line anyway, which is the worst possible output at the
            # one moment it matters.
            say("  THE RESTORED DATABASE DOES NOT MATCH THE ORIGINAL EITHER.")
            for problem in rolled:
                say(f"    {problem}")
            return bring_back(EXIT_ROLLED_BACK,
                              "rolled back, but the restored database does not verify. "
                              "Check LuLu's rules by hand.")
        say("  rolled back: the original database is in place again")
        return bring_back(EXIT_ROLLED_BACK,
                          "rolled back. His firewall holds what it held before.")

    say("  the live database verified after the restart")

    if not came_back:
        say()
        say("  BUT THE NETWORK FILTER DID NOT COME BACK. His firewall is not running.")
        say("  The database is correct. Open LuLu, or reboot, and check its icon.")
        return finish(EXIT_LULU_MISSING, "the rules are removed, but LuLu is not filtering.")

    return finish(EXIT_CLEAN,
                  f"{len(removed)} key(s) removed and verified. The family has no rules.")


if __name__ == "__main__":
    sys.exit(main())
