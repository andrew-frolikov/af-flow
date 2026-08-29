#!/usr/bin/env python3
"""Read a built AF Flow bundle's real signature and refuse the shapes that must never ship.

WHAT IT CHECKS, and why each line is here rather than in a comment somewhere.

  network.client / network.server absent
      2026-08-29, Andrew's decision after the LuLu episode. The app must be
      INCAPABLE of egress at the kernel layer, not merely watched: Allow-any
      firewall rules for this bundle came back months after he deleted them,
      and a firewall's view of an app is only as good as its rule matching,
      which stale post-rename paths had already broken. Without the
      entitlement every outbound call dies in the sandbox and no rule is
      needed in either direction. This must hold in Release exactly as it
      holds in Debug: a distribution build is the one nobody rebuilds and
      re-checks by hand.

  app-sandbox present
      The sandbox is the boundary. It is also what makes the line above
      enforceable, because entitlements only bind an app the kernel sandboxes.
      Losing it in a distribution configuration would silently turn the
      egress guarantee into decoration.

  device.audio-input present
      A dictation app that ships without microphone access is a broken app
      that still passes every other check. Cheap to lose in a new build
      configuration, invisible until a stranger installs it.

  get-task-allow absent in Release
      A debuggable distribution build lets any process attach to the app that
      holds his microphone. Notarization also rejects it.

  hardened runtime on in Release
      Required for notarization; refused here so the failure arrives in
      seconds rather than after an upload.

  nothing beyond the declared entitlements
      THE FIRST VERSION OF THIS WAS A DENYLIST OF TWO KEYS, so every
      entitlement nobody had thought of was reported clean:
      `com.apple.security.cs.disable-library-validation`, a
      `temporary-exception.mach-lookup`, an added `files.all`. A check that
      enumerates what it fears only catches what its author already imagined,
      which is the same lesson `run-tests.sh` learned about its output
      directory. The shipped set is now compared against
      `AFFlow/AFFlow.entitlements`, the file in this repo, and anything extra
      is a finding. Found by review, 2026-08-30. Debug is allowed
      `get-task-allow` on top, because Xcode injects it and debugging needs it.

  no ad-hoc signature in Release
      An ad-hoc signature carries no team and no chain, so it cannot be
      notarized and Gatekeeper refuses the app on every Mac except the one
      that built it. It is also what a build silently falls back to when the
      Developer ID identity is missing, which is exactly the state this
      project will be in until Andrew buys the membership: the build would
      succeed, the DMG would open on his Mac, and it would fail on his
      friends' machines. `--allow-adhoc-signature` opts out, and only the
      selftest passes it, because the selftest cannot produce any other kind.

UNREADABLE IS NOT A PASS. Exit 2 means the check did not happen, and every
caller must treat that as failure. This is the defect in the line this script
replaces: `codesign -d --entitlements :- APP | grep -q network.client` reports
CLEAN whenever codesign itself fails, so an unsigned bundle, an empty signing
identity, or a bad path all read as a boundary that was verified. It could
only ever refuse a bundle it had already successfully read.

Same rule as `lulu-rule-check.py`, for the same reason, in a second system.

Usage:
    bundle-boundary-check.py APP_PATH --configuration {debug,release}

Exit 0 clean, 1 findings, 2 could not check.
"""

import argparse
import os
import plistlib
import subprocess
import sys

CLEAN = 0
FINDINGS = 1
UNCHECKED = 2

CONFIGURATIONS = ("debug", "release")

# Forbidden in EVERY configuration. The value is the sentence printed when the
# entitlement is found, so the refusal explains itself at the terminal rather
# than sending the reader to a document.
FORBIDDEN_ALWAYS = {
    "com.apple.security.network.client":
        "This app has no network by decision (2026-08-29). Remove it from "
        "project.yml and AFFlow/AFFlow.entitlements.",
    "com.apple.security.network.server":
        "Only the deleted Calendar OAuth ever needed it (de-risk checklist "
        "item 5, 2026-07-18).",
}

REQUIRED_ALWAYS = {
    "com.apple.security.app-sandbox":
        "The sandbox is the boundary, and it is what makes the missing "
        "network entitlement bind at all.",
    "com.apple.security.device.audio-input":
        "Without it the app cannot hear him, and every other check still "
        "passes.",
}

# Injected by Xcode into a development-signed build, and the reason Debug is
# allowed one key the entitlements file does not list.
DEBUG_EXTRA = {"com.apple.security.get-task-allow"}

FORBIDDEN_RELEASE = {
    "com.apple.security.get-task-allow":
        "A debuggable distribution build lets any process attach to the app "
        "holding his microphone, and notarization rejects it.",
}


def codesign_entitlements(app):
    """Return (entitlements_dict, error). An empty dict is a real answer; None is not."""
    got = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", "--xml", app],
        capture_output=True)
    if got.returncode != 0:
        return None, got.stderr.decode("utf-8", "replace").strip()
    raw = got.stdout.strip()
    if not raw:
        return {}, None
    try:
        return plistlib.loads(raw), None
    except Exception as problem:                      # noqa: BLE001
        return None, f"codesign returned bytes that are not a plist: {problem}"


def codesign_flags(app):
    """Return (set_of_flag_names, error) from the code directory."""
    got = subprocess.run(["codesign", "-d", "-v", app],
                         capture_output=True, text=True)
    if got.returncode != 0:
        return None, got.stderr.strip()
    for line in (got.stderr + got.stdout).splitlines():
        if "flags=" not in line:
            continue
        field = line.split("flags=", 1)[1].split()[0]
        if "(" in field:
            inside = field.split("(", 1)[1].rstrip(")")
            return {name.strip() for name in inside.split(",") if name.strip()}, None
        return set(), None
    return None, "codesign printed no CodeDirectory flags line"


def main():
    parser = argparse.ArgumentParser(
        description="Refuse a built bundle whose signature crosses a boundary "
                    "this app does not cross.")
    parser.add_argument("app", help="path to the built .app")
    parser.add_argument("--configuration", required=True,
                        help="debug or release")
    parser.add_argument("--declared", default=None,
                        help="the entitlements file the bundle is supposed to "
                             "carry (default: AFFlow/AFFlow.entitlements next "
                             "to this script's repository)")
    parser.add_argument("--allow-adhoc-signature", action="store_true",
                        help="accept an ad-hoc signature in Release. Only the "
                             "selftest passes this; a shipping build never "
                             "should.")
    args = parser.parse_args()

    configuration = args.configuration.lower()
    if configuration not in CONFIGURATIONS:
        print(f"unknown configuration '{args.configuration}'. "
              f"Expected one of: {', '.join(CONFIGURATIONS)}.", file=sys.stderr)
        print("Guessing would mean checking the wrong rules, so this refuses.",
              file=sys.stderr)
        return UNCHECKED

    app = args.app
    print(f"### Does {os.path.basename(app)} stay inside its boundary "
          f"({configuration})")

    if not os.path.isdir(app):
        print(f"unreadable: no bundle at {app}", file=sys.stderr)
        print("RESULT: COULD NOT CHECK. That is a failure, not a pass.",
              file=sys.stderr)
        return UNCHECKED

    entitlements, problem = codesign_entitlements(app)
    if entitlements is None:
        print(f"unreadable: {problem}", file=sys.stderr)
        print("A bundle whose signature cannot be read has not been checked. "
              "The entitlements it carries are unknown, not absent.",
              file=sys.stderr)
        print("RESULT: COULD NOT CHECK. That is a failure, not a pass.",
              file=sys.stderr)
        return UNCHECKED

    flags, problem = codesign_flags(app)
    if flags is None:
        print(f"unreadable: {problem}", file=sys.stderr)
        print("RESULT: COULD NOT CHECK. That is a failure, not a pass.",
              file=sys.stderr)
        return UNCHECKED

    print(f"ok    signature read, {len(entitlements)} entitlement(s), "
          f"flags: {', '.join(sorted(flags)) or 'none'}")

    # Read BEFORE anything is judged: an unreadable declaration means the
    # comparison below cannot happen, and a check that cannot happen is not a
    # pass.
    declared_path = args.declared or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "AFFlow", "AFFlow.entitlements")
    try:
        with open(declared_path, "rb") as handle:
            declared = set(plistlib.load(handle))
    except Exception as problem:                       # noqa: BLE001
        print(f"unreadable: {declared_path}: {problem}", file=sys.stderr)
        print("RESULT: COULD NOT CHECK. That is a failure, not a pass.",
              file=sys.stderr)
        return UNCHECKED

    findings = []

    allowed = set(declared) | (DEBUG_EXTRA if configuration == "debug" else set())
    for key in sorted(set(entitlements) - allowed):
        findings.append(
            f"CARRIES {key}, which {os.path.basename(declared_path)} does not "
            f"declare. Every entitlement this app ships is in that file; "
            f"anything else arrived from a template, an Xcode default, or a "
            f"re-sign.")

    forbidden = dict(FORBIDDEN_ALWAYS)
    if configuration == "release":
        forbidden.update(FORBIDDEN_RELEASE)

    for key, why in sorted(forbidden.items()):
        if entitlements.get(key):
            findings.append(f"CARRIES {key}. {why}")

    for key, why in sorted(REQUIRED_ALWAYS.items()):
        if not entitlements.get(key):
            findings.append(f"MISSING {key}. {why}")

    if (configuration == "release" and "adhoc" in flags
            and not args.allow_adhoc_signature):
        findings.append(
            "The signature is AD-HOC. It carries no team and no chain, so it "
            "cannot be notarized and Gatekeeper refuses it on every Mac but "
            "this one. This is also what a build falls back to when the "
            "Developer ID identity is missing: it would succeed here and fail "
            "on his friends' machines.")

    if configuration == "release" and "runtime" not in flags:
        findings.append(
            "The hardened runtime is OFF. Notarization refuses a Developer ID "
            "build without it, so this bundle cannot ship. Set "
            "ENABLE_HARDENED_RUNTIME in the Release configuration, or sign "
            "with --options runtime.")

    if not findings:
        print(f"ok    entitlements are exactly what "
              f"{os.path.basename(declared_path)} declares")
        if configuration == "release":
            print("ok    hardened runtime on, get-task-allow absent")
            if args.allow_adhoc_signature and "adhoc" in flags:
                print("note  ad-hoc signature accepted because "
                      "--allow-adhoc-signature was passed. NOT shippable.")
        print()
        print("RESULT: clean")
        return CLEAN

    for finding in findings:
        print(f"FINDING: {finding}")
    print()
    print(f"RESULT: {len(findings)} finding(s)")
    print("REFUSING TO REPORT SUCCESS. Do not install or ship this bundle.",
          file=sys.stderr)
    return FINDINGS


if __name__ == "__main__":
    sys.exit(main())
