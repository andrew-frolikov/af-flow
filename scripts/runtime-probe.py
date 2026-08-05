#!/usr/bin/env python3
"""Read what AF Flow actually did, rather than what its tests say it does.

WHY THIS EXISTS. On 2026-08-02 three real defects were found in an afternoon, and
every one of them came out of files the app had been writing the whole time:

  * the language prior had never once run, because WhisperKit returns log
    probabilities and the gate tested `> 0`. Six passing tests said otherwise.
  * dictation "pasted the text two times" was the cleanup model repeating itself
    on a long input, visible as a 1.97 length ratio in the transcription lab.
  * ten solitary Globe presses started nothing, because push-to-talk had become a
    two-key chord.

None of that was reachable by reading a diff or running the suite, which is what
every other verifier on this project does. So this is the tier between them: a
script over the real artefacts, run at session start and after every install.

It is a script and not a model on purpose. It enumerates instead of sampling, it
costs nothing, and a number it prints is a measurement rather than a claim.

Usage:  python3 scripts/runtime-probe.py [--days N]
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict

CONTAINER = os.path.expanduser(
    "~/Library/Containers/com.frolikov.afflow/Data/Library/Application Support/GhostPepper"
)
LOG = os.path.join(CONTAINER, "debug-log.jsonl")
# Read from before the 2026-08-02 format change if the app has not launched
# since. The store migrates the array into the line file on first launch, so
# this fallback stops the probe going blind in the window between the two.
LEGACY_LOG = os.path.join(CONTAINER, "debug-log.json")
LAB = os.path.join(CONTAINER, "transcription-lab", "transcription-lab-index.jsonl")
# The pre-2026-08-04 single-array archive. Read only if the new one is absent.
LAB_LEGACY = os.path.join(CONTAINER, "transcription-lab", "transcription-lab-index.json")


def load_lab():
    """The lab index, in whichever format is on disk.

    It became append-only JSONL on 2026-08-04 and this probe kept reading the
    old array, so the lab section silently went blank: the instrument losing
    sight of the thing it exists to watch, which is the same failure it is here
    to catch.
    """
    if os.path.exists(LAB):
        rows = []
        with open(LAB, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
        return rows
    return load(LAB_LEGACY)

# CFAbsoluteTime is seconds since 2001-01-01 UTC.
EPOCH = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)


def when(value):
    try:
        return (EPOCH + datetime.timedelta(seconds=float(value))).astimezone()
    except Exception:
        return None


def load(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except FileNotFoundError:
        print("  not found: %s" % path)
        return []
    except Exception as error:
        print("  could not read %s: %s" % (path, error))
        return []


def load_log():
    """The debug log, one JSON object per line, newest last.

    A line that does not parse is skipped rather than fatal, matching the
    store: a process killed mid-append leaves half an object on the last line,
    and that must cost one entry rather than the whole history.
    """
    if not os.path.exists(LOG):
        if os.path.exists(LEGACY_LOG):
            print("  reading the pre-2026-08-02 array format; the app has not "
                  "launched since the change")
            return load(LEGACY_LOG)
        print("  not found: %s" % LOG)
        return []

    entries, skipped = [], 0
    try:
        with open(LOG) as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(json.loads(line))
                except ValueError:
                    skipped += 1
    except Exception as error:
        print("  could not read %s: %s" % (LOG, error))
        return []

    if skipped:
        print("  %d unparseable line(s) skipped" % skipped)
    return entries


def section(title):
    print("\n" + title)
    print("-" * len(title))


def probe_log(entries, since):
    section("Dictation decisions, from debug-log.jsonl")
    if not entries:
        return

    first, last = when(entries[0]["timestamp"]), when(entries[-1]["timestamp"])
    span = (last - first).total_seconds() / 86400 if first and last else 0
    print("  %d entries covering %.1f days (%s to %s)"
          % (len(entries), span,
             first.strftime("%a %m-%d %H:%M") if first else "?",
             last.strftime("%a %m-%d %H:%M") if last else "?"))
    if span < 3:
        print("  NOTE: the log holds under three days so far. Retention is thirty days")
        print("        as of 2026-08-02, so this fills in rather than rolling over.")

    number = r"(-?\d+(?:\.\d+)?(?:e-?\d+)?)"
    chosen = Counter()
    overruled = 0
    fell_open = []
    no_sound = []
    slow = []
    positive = negative = absent = 0

    for entry in entries:
        stamp = when(entry["timestamp"])
        if since and stamp and stamp < since:
            continue
        message = entry.get("message", "")

        if "Language chosen" in message:
            match = re.search(r"Language chosen: (\w+)", message)
            if match:
                chosen[match.group(1)] += 1
            if "OVERRULED" in message:
                overruled += 1
            for value in re.findall(r"p\((?:en|ru)\)=" + number, message):
                value = float(value)
                positive += value > 0
                negative += value < 0
                absent += value == 0

        if "neither en nor ru" in message or "Falling back to Whisper" in message:
            fell_open.append((stamp, message[:90]))

        if "No sound detected" in message:
            no_sound.append(stamp)

        match = re.search(r"transcription=(\d+)ms", message)
        if match and int(match.group(1)) > 10_000:
            slow.append((stamp, int(match.group(1))))

    print("  languages chosen: %s%s"
          % (dict(chosen) or "none",
             "   (%d overruled by the en/ru restriction)" % overruled if overruled else ""))

    if positive or negative:
        print("  probability values: %d positive, %d negative, %d absent"
              % (positive, negative, absent))
        if negative and not positive:
            print("    these are LOG probabilities. Any comparison against zero is broken.")

    if fell_open:
        print("  FELL OPEN TO 99 LANGUAGES %d time(s). This should now be impossible:" % len(fell_open))
        for stamp, text in fell_open[:5]:
            print("    %s  %s" % (stamp.strftime("%a %m-%d %H:%M") if stamp else "?", text))
    else:
        print("  never fell open to unrestricted detection.  ok")

    if no_sound:
        print("  'No sound detected' %d time(s): %s"
              % (len(no_sound), ", ".join(s.strftime("%a %m-%d %H:%M") for s in no_sound if s)))
        print("    check each against a real recording length; a long one is a lost dictation.")

    if slow:
        print("  transcriptions over 10s: %d" % len(slow))
        for stamp, ms in slow[:5]:
            print("    %s  %.1fs" % (stamp.strftime("%a %m-%d %H:%M") if stamp else "?", ms / 1000))


def probe_lab(entries, since):
    section("What the cleanup did to his words, from the transcription lab")
    if not entries:
        return

    rows = []
    for entry in entries:
        stamp = when(entry.get("createdAt"))
        if since and stamp and stamp < since:
            continue
        raw = re.sub(r"\s+", " ", (entry.get("rawTranscription") or "")).strip()
        clean = re.sub(r"\s+", " ", (entry.get("correctedTranscription") or "")).strip()
        rows.append((stamp, entry.get("audioDuration") or 0, raw, clean))

    if not rows:
        print("  nothing in range")
        return

    with_text = [r for r in rows if r[2]]
    print("  %d dictations, %d with text" % (len(rows), len(with_text)))

    doubled = [r for r in with_text if len(r[3]) / len(r[2]) > 1.7]
    shrunk = [r for r in with_text if len(r[2]) >= 40 and len(r[3]) / len(r[2]) < 0.75]
    lost = [r for r in rows if not r[2] and r[1] > 2]

    if doubled:
        print("  THE CLEANUP REPEATED ITSELF on %d dictation(s):" % len(doubled))
        for stamp, seconds, raw, clean in doubled:
            print("    %s  %.0fs  %d chars in, %d out (ratio %.2f)"
                  % (stamp.strftime("%a %m-%d %H:%M") if stamp else "?",
                     seconds, len(raw), len(clean), len(clean) / len(raw)))
    else:
        print("  no doubled outputs.  ok")

    if shrunk:
        print("  CLEANUP DROPPED MORE THAN A QUARTER on %d dictation(s):" % len(shrunk))
        for stamp, seconds, raw, clean in shrunk[:5]:
            print("    %s  %d chars in, %d out" % (
                stamp.strftime("%a %m-%d %H:%M") if stamp else "?", len(raw), len(clean)))
    else:
        print("  nothing over-trimmed.  ok")

    if lost:
        print("  RECORDINGS THAT PRODUCED NOTHING, over 2 seconds: %d" % len(lost))
        for stamp, seconds, _, _ in lost:
            print("    %s  %.1fs of audio, no text"
                  % (stamp.strftime("%a %m-%d %H:%M") if stamp else "?", seconds))
    else:
        print("  no lost dictations.  ok")


def probe_settings():
    section("Settings that decide whether dictation can work at all")

    def read(domain, key):
        try:
            return subprocess.run(["defaults", "read", domain, key],
                                  capture_output=True, text=True, timeout=10).stdout.strip()
        except Exception:
            return ""

    globe = read("com.apple.HIToolbox", "AppleFnUsageType")
    meaning = {"0": "Do Nothing, so Globe is free for AF Flow.  ok",
               "1": "Change Input Source. Globe ALSO switches his keyboard language.",
               "2": "Show Emoji. Globe ALSO opens the emoji picker.",
               "3": "Start Dictation. Globe ALSO starts Apple's dictation."}
    print("  Globe key: %s" % meaning.get(globe, "unset, so macOS still owns the key. Set it to Do Nothing."))

    try:
        export = subprocess.run(["defaults", "export", "com.frolikov.afflow", "-"],
                                capture_output=True, timeout=10).stdout
        import plistlib
        plist = plistlib.loads(export)
        for key in sorted(k for k in plist if k.startswith("chordBinding")):
            value = plist[key]
            try:
                keys = json.loads(value.decode() if isinstance(value, (bytes, bytearray)) else value)
                codes = [k.get("keyCode") for k in keys.get("keys", [])]
                names = {59: "Left Control", 63: "Globe", 54: "Right Command",
                         61: "Right Option", 49: "Space", 31: "O", 55: "Left Command"}
                print("  %s = %s" % (key.split(".")[-1],
                                     " + ".join(names.get(c, str(c)) for c in sorted(codes))))
            except Exception:
                print("  %s = unreadable" % key)
    except Exception as error:
        print("  could not read the app's bindings: %s" % error)


def probe_paste(entries):
    """Did his words actually reach the field he was typing into?

    Added 2026-08-05. Every instrument here pointed at TRANSCRIPTION, because
    that is where the previous defects were, so a 95% failure on the LAST step
    of the pipeline sat in plain text in this log for two days and nobody
    counted it. He reported it as "it didn't catch the last part": each
    dictation overwrites the clipboard, so a run of chunks that never paste
    leaves only the last one behind.
    """
    section("Did the text actually land, from debug-log.jsonl")
    landed = refused = secure = 0
    reasons = {}
    for entry in entries:
        message = entry.get("message", "")
        if "landed in the focused field" in message:
            landed += 1
        elif "could not confirm a target" in message:
            refused += 1
        elif "blocked by Secure Input" in message:
            secure += 1
        elif message.startswith("Paste refused: "):
            reason = message[len("Paste refused: "):][:60]
            reasons[reason] = reasons.get(reason, 0) + 1

    total = landed + refused + secure
    if total == 0:
        print("  no paste outcomes recorded yet.")
        return

    rate = 100.0 * refused / total
    print("  %d paste(s): %d landed, %d refused, %d blocked by Secure Input"
          % (total, landed, refused, secure))
    if rate >= 25:
        print("  %.0f%% NEVER REACHED A FIELD  <== his words only went to the clipboard."
              % rate)
        print("     Each dictation overwrites it, so a run of them leaves only the last.")
    elif refused:
        print("  %.0f%% refused." % rate)
    else:
        print("  every paste landed.  ok")

    if reasons:
        print("  why they were refused:")
        for reason, count in sorted(reasons.items(), key=lambda r: -r[1]):
            print("    %4d  %s" % (count, reason))
    elif refused:
        print("  (no reason recorded; that logging landed 2026-08-05, so these predate it)")


def probe_bundles():
    section("Bundle identity")
    try:
        found = subprocess.run(
            ["mdfind", "kMDItemCFBundleIdentifier == 'com.frolikov.afflow'"],
            capture_output=True, text=True, timeout=20).stdout.split("\n")
        apps = [p for p in found if p.strip().endswith(".app")]
        print("  %d bundle(s) claim com.frolikov.afflow%s"
              % (len(apps), "" if len(apps) <= 1 else "  <== more than one breaks his permissions"))
        for app in apps:
            print("    %s" % app)
    except Exception as error:
        print("  could not check: %s" % error)

    # A second bundle ON DISK is not the only way to end up with two AF Flows.
    # On 2026-08-03 a test-host process was left RUNNING from `xcodebuild test`,
    # out of `build/run-derived`, alongside the app he actually launches. Two
    # processes competing for the microphone is exactly what run-tests.sh
    # refuses to create, and nothing noticed it afterwards because the test host
    # carries a different bundle id and so never appeared in the check above.
    # It was found by looking at the Dock in a screenshot, which is not a
    # control.
    try:
        # `pgrep -f` matches COMMAND LINES, so any shell that happens to mention
        # this path matches too, including the one running this probe. That is a
        # false alarm generator, and a check that cries wolf gets ignored, so
        # each pid is resolved to its actual executable with `ps -o comm=` and
        # only real GhostPepper binaries are counted.
        found = subprocess.run(
            ["pgrep", "-f", "GhostPepper.app/Contents/MacOS/GhostPepper"],
            capture_output=True, text=True, timeout=20).stdout.split()
        lines = []
        for pid in found:
            executable = subprocess.run(
                ["ps", "-p", pid, "-o", "comm="],
                capture_output=True, text=True, timeout=10).stdout.strip()
            if executable.endswith("GhostPepper.app/Contents/MacOS/GhostPepper"):
                lines.append("%s  %s" % (pid, executable))
        if len(lines) > 1:
            print("  %d GhostPepper PROCESSES are running  <== they compete for the microphone"
                  % len(lines))
            for line in lines:
                print("    %s" % line.strip()[:160])
            print("    kill any running out of build/run-derived; that is a leftover test host.")
        elif lines:
            print("  1 process running.  ok")
        else:
            print("  not running.")
    except Exception as error:
        print("  could not check running processes: %s" % error)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=float, default=0,
                        help="only look at the last N days (default: everything on disk)")
    arguments = parser.parse_args()
    since = (datetime.datetime.now(datetime.timezone.utc).astimezone()
             - datetime.timedelta(days=arguments.days)) if arguments.days else None

    print("AF Flow runtime probe")
    print("=====================")
    if since:
        print("since %s" % since.strftime("%a %Y-%m-%d %H:%M"))

    log_entries = load_log()
    probe_log(log_entries, since)
    probe_lab(load_lab(), since)
    probe_paste(log_entries)
    probe_settings()
    probe_bundles()
    print("\nThis reads what the app did. The test suite reads what it was told to do.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
