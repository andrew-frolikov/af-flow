#!/usr/bin/env python3
"""Stage every state `bundle-boundary-check.py` must distinguish, and watch it react.

WHY THIS EXISTS, and why it is not the same as the line it replaces.

Until 2026-08-30 the network-entitlement guarantee lived as one line inside
`scripts/run-tests.sh`:

    if codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q "com.apple.security.network.client"

That line PASSES when `codesign` fails. An unsigned bundle, a bundle signed
with an empty identity, a path codesign cannot read: each produces no output,
so grep finds nothing, so the build is reported as boundary-clean. The check
whose entire job is to refuse could only ever refuse a bundle it had already
successfully read, and nothing distinguished "read it, the entitlement is
absent" from "could not read it at all". That is the `lulu-rule-check.py`
lesson in a second place: unreadable must FAIL, never pass.

Everything below is staged against real bundles, ad-hoc signed on this machine,
so no Developer ID and no network is needed to run it. A refusal that has never
been seen is not a refusal.

Exit 0 all states distinguished, 1 otherwise.
"""

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CHECK = os.path.join(HERE, "bundle-boundary-check.py")

CLEAN = 0        # checked, nothing wrong
FINDINGS = 1     # checked, something is wrong
UNCHECKED = 2    # could not check, which is never a pass

results = []


def check(label, condition, detail=""):
    results.append(bool(condition))
    print(f"{'PASS' if condition else 'FAIL'}  {label}")
    if detail and not condition:
        print("        " + str(detail).replace("\n", "\n        "))
    return bool(condition)


def make_bundle(root, name, entitlements, hardened, sign=True):
    """Build a minimal .app and ad-hoc sign it exactly as asked.

    Ad-hoc signing accepts `--options runtime` and an arbitrary entitlements
    plist, so every combination the checker cares about can be produced here
    without an Apple Developer ID and without a network.
    """
    app = os.path.join(root, name + ".app")
    macos = os.path.join(app, "Contents", "MacOS")
    os.makedirs(macos, exist_ok=True)
    with open(os.path.join(app, "Contents", "Info.plist"), "wb") as handle:
        plistlib.dump({
            "CFBundleExecutable": name,
            "CFBundleIdentifier": "com.frolikov.scratch.boundary-selftest",
            "CFBundleName": "scratch-boundary-selftest",
            "CFBundleDisplayName": "scratch-boundary-selftest",
            "CFBundlePackageType": "APPL",
        }, handle)

    source = os.path.join(root, name + ".c")
    with open(source, "w", encoding="utf-8") as handle:
        handle.write("int main(void){return 0;}\n")
    compiled = subprocess.run(["cc", "-o", os.path.join(macos, name), source],
                              capture_output=True, text=True)
    if compiled.returncode != 0:
        raise RuntimeError("could not compile the stub: " + compiled.stderr)

    if not sign:
        # `cc` emits a linker-signed binary on Apple silicon, so a bundle that
        # was never codesigned still carries an ad-hoc signature. The state
        # this stages is a bundle with NO signature at all, which is what an
        # empty CODE_SIGN_IDENTITY produces and what made the line this script
        # replaces report CLEAN.
        subprocess.run(["codesign", "--remove-signature", app],
                       capture_output=True)
        return app

    argv = ["codesign", "--force", "--sign", "-"]
    if hardened:
        argv += ["--options", "runtime"]
    if entitlements is not None:
        ents = os.path.join(root, name + ".entitlements")
        with open(ents, "wb") as handle:
            plistlib.dump(entitlements, handle)
        argv += ["--entitlements", ents]
    argv.append(app)
    signed = subprocess.run(argv, capture_output=True, text=True)
    if signed.returncode != 0:
        raise RuntimeError("could not sign the stub: " + signed.stderr)
    return app


def add_service(app, entitlements, hardened=True, sign=True):
    """Put a stub XPC service inside an app bundle and sign it as asked.

    The real service is built by Xcode; what this stages is the SIGNATURE
    question the checker asks about it, which is the part that can go wrong
    silently: a service that gained an entitlement, lost one, or was never
    embedded at all.
    """
    root = os.path.dirname(app)
    service = os.path.join(app, "Contents", "XPCServices", "AF Flow Models.xpc")
    macos = os.path.join(service, "Contents", "MacOS")
    os.makedirs(macos, exist_ok=True)
    with open(os.path.join(service, "Contents", "Info.plist"), "wb") as handle:
        plistlib.dump({
            "CFBundleExecutable": "AF Flow Models",
            "CFBundleIdentifier": "com.frolikov.afflow.models",
            "CFBundleName": "AF Flow Models",
            "CFBundlePackageType": "XPC!",
            "XPCService": {"ServiceType": "Application"},
        }, handle)
    source = os.path.join(root, "service-stub.c")
    with open(source, "w", encoding="utf-8") as handle:
        handle.write("int main(void){return 0;}\n")
    compiled = subprocess.run(["cc", "-o", os.path.join(macos, "AF Flow Models"), source],
                              capture_output=True, text=True)
    if compiled.returncode != 0:
        raise RuntimeError("could not compile the service stub: " + compiled.stderr)
    if not sign:
        subprocess.run(["codesign", "--remove-signature", service], capture_output=True)
        return service
    argv = ["codesign", "--force", "--sign", "-"]
    if hardened:
        argv += ["--options", "runtime"]
    if entitlements is not None:
        ents = os.path.join(root, "service.entitlements")
        with open(ents, "wb") as handle:
            plistlib.dump(entitlements, handle)
        argv += ["--entitlements", ents]
    argv.append(service)
    signed = subprocess.run(argv, capture_output=True, text=True)
    if signed.returncode != 0:
        raise RuntimeError("could not sign the service stub: " + signed.stderr)
    return service


# What AFFlowModels/AFFlowModels.entitlements declares. Read from the file
# rather than repeated, so the selftest cannot drift from the thing it checks.
def service_declared():
    path = os.path.join(REPO, "AFFlowModels", "AFFlowModels.entitlements")
    with open(path, "rb") as handle:
        return dict(plistlib.load(handle))


def run(app, configuration, *extra):
    return subprocess.run(
        [sys.executable, CHECK, app, "--configuration", configuration, *extra],
        capture_output=True, text=True, cwd=REPO)


# Every bundle here is ad-hoc signed, because that is the only kind this machine
# can produce without Andrew's Developer ID. A real Release build may not be:
# an ad-hoc signature does not notarize and Gatekeeper refuses it on any Mac but
# this one. So the checker refuses ad-hoc in Release by default and the selftest
# opts out explicitly, which keeps the guarantee real for `release-build.sh`.
ADHOC = "--allow-adhoc-signature"


SHIPPING = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.device.audio-input": True,
    "com.apple.security.files.user-selected.read-write": True,
}


def entitlements_without(key):
    copy = dict(SHIPPING)
    copy.pop(key, None)
    return copy


def entitlements_with(key, value=True):
    copy = dict(SHIPPING)
    copy[key] = value
    return copy


def main():
    if not os.path.exists(CHECK):
        print(f"FAIL  {CHECK} does not exist")
        print("\n1 state(s) not distinguished")
        return 1

    with tempfile.TemporaryDirectory() as root:
        # ---- the two shapes that must be accepted -------------------------
        app = make_bundle(root, "ReleaseClean", SHIPPING, hardened=True)
        got = run(app, "release", ADHOC)
        check("a Release build with the shipping entitlements and hardened "
              "runtime is clean",
              got.returncode == CLEAN, got.stdout + got.stderr)

        app = make_bundle(root, "DebugClean",
                          entitlements_with("com.apple.security.get-task-allow"),
                          hardened=False)
        got = run(app, "debug")
        check("a Debug build is clean without hardened runtime and with "
              "get-task-allow",
              got.returncode == CLEAN, got.stdout + got.stderr)

        # ---- an ad-hoc signature is not a distribution signature ----------
        app = make_bundle(root, "ReleaseAdhoc", SHIPPING, hardened=True)
        got = run(app, "release")          # deliberately WITHOUT the opt-out
        check("an ad-hoc signed RELEASE build is refused by default",
              got.returncode == FINDINGS, got.stdout + got.stderr)
        got = run(app, "debug")
        check("an ad-hoc signed DEBUG build is fine, that is how he builds",
              got.returncode == CLEAN, got.stdout + got.stderr)

        # ---- the guarantee that carried this project ----------------------
        app = make_bundle(root, "ReleaseNetwork",
                          entitlements_with("com.apple.security.network.client"),
                          hardened=True)
        got = run(app, "release", ADHOC)
        check("network.client in a RELEASE build is refused",
              got.returncode == FINDINGS, got.stdout + got.stderr)
        check("the network.client refusal names the entitlement",
              "network.client" in (got.stdout + got.stderr), got.stdout)

        app = make_bundle(root, "DebugNetwork",
                          entitlements_with("com.apple.security.network.client"),
                          hardened=False)
        got = run(app, "debug")
        check("network.client in a DEBUG build is refused too",
              got.returncode == FINDINGS, got.stdout + got.stderr)

        app = make_bundle(root, "ReleaseServer",
                          entitlements_with("com.apple.security.network.server"),
                          hardened=True)
        got = run(app, "release", ADHOC)
        check("network.server is refused (de-risk checklist item 5)",
              got.returncode == FINDINGS, got.stdout + got.stderr)

        # ---- what Release adds ---------------------------------------------
        app = make_bundle(root, "ReleaseTaskAllow",
                          entitlements_with("com.apple.security.get-task-allow"),
                          hardened=True)
        got = run(app, "release", ADHOC)
        check("get-task-allow in a Release build is refused",
              got.returncode == FINDINGS, got.stdout + got.stderr)

        app = make_bundle(root, "ReleaseSoft", SHIPPING, hardened=False)
        got = run(app, "release", ADHOC)
        check("a Release build without the hardened runtime is refused",
              got.returncode == FINDINGS, got.stdout + got.stderr)
        check("the hardened-runtime refusal says notarization needs it",
              "notariz" in (got.stdout + got.stderr).lower(), got.stdout)

        # ---- the embedded downloader, Phase 4 ------------------------------
        #
        # The app's "no network" guarantee now depends on a SECOND signature.
        # These states are the ones that look fine from the app's own
        # entitlements and are not: a service that gained something, lost
        # something, or was never embedded at all.
        declared_service = service_declared()

        app = make_bundle(root, "WithService", SHIPPING, hardened=True)
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as handle:
            info = plistlib.load(handle)
        info["CFBundleIdentifier"] = "com.frolikov.afflow"
        with open(os.path.join(app, "Contents", "Info.plist"), "wb") as handle:
            plistlib.dump(info, handle)
        add_service(app, declared_service)
        # The app is re-signed AFTER the service goes in: adding to a bundle
        # breaks its seal, which is the same order release-build.sh uses.
        subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime",
                        "--entitlements", os.path.join(root, "WithService.entitlements"), app],
                       capture_output=True)
        got = run(app, "debug")
        check("an app carrying a correct downloader is clean",
              got.returncode == CLEAN, got.stdout + got.stderr)

        app = make_bundle(root, "NoService", SHIPPING, hardened=True)
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as handle:
            info = plistlib.load(handle)
        info["CFBundleIdentifier"] = "com.frolikov.afflow"
        with open(os.path.join(app, "Contents", "Info.plist"), "wb") as handle:
            plistlib.dump(info, handle)
        got = run(app, "debug")
        check("THIS app with no downloader embedded is refused",
              got.returncode == FINDINGS, got.stdout + got.stderr)
        check("and the refusal says the Full tier could never install",
              "Full tier" in (got.stdout + got.stderr), got.stdout)

        app = make_bundle(root, "ServiceExtra", SHIPPING, hardened=True)
        widened = dict(declared_service)
        widened["com.apple.security.files.user-selected.read-write"] = True
        add_service(app, widened)
        got = run(app, "debug")
        check("a downloader that gained an entitlement is refused",
              got.returncode == FINDINGS, got.stdout + got.stderr)

        app = make_bundle(root, "ServiceNoNetwork", SHIPPING, hardened=True)
        narrowed = dict(declared_service)
        narrowed.pop("com.apple.security.network.client", None)
        add_service(app, narrowed)
        got = run(app, "debug")
        check("a downloader that LOST network.client is refused",
              got.returncode == FINDINGS, got.stdout + got.stderr)
        check("and that refusal says the app silently stays on Starter",
              "Starter" in (got.stdout + got.stderr), got.stdout)

        app = make_bundle(root, "ServiceUnsandboxed", SHIPPING, hardened=True)
        unsandboxed = dict(declared_service)
        unsandboxed.pop("com.apple.security.app-sandbox", None)
        add_service(app, unsandboxed)
        got = run(app, "debug")
        check("a downloader that lost the SANDBOX is refused",
              got.returncode == FINDINGS, got.stdout + got.stderr)

        app = make_bundle(root, "ServiceDebuggable", SHIPPING, hardened=True)
        debuggable = dict(declared_service)
        debuggable["com.apple.security.get-task-allow"] = True
        add_service(app, debuggable)
        got = run(app, "release", ADHOC)
        check("a debuggable downloader in a RELEASE build is refused",
              got.returncode == FINDINGS, got.stdout + got.stderr)
        got = run(app, "debug")
        check("and the same service is fine in Debug, where Xcode injects it",
              got.returncode == CLEAN, got.stdout + got.stderr)

        app = make_bundle(root, "ServiceUnsigned", SHIPPING, hardened=True)
        add_service(app, declared_service, sign=False)
        got = run(app, "debug")
        check("a downloader whose signature cannot be read is NOT reported clean",
              got.returncode == FINDINGS, got.stdout + got.stderr)

        # ---- an ALLOWLIST, not a denylist. Review, 2026-08-30 -------------
        # The check used to enumerate two feared keys, so every entitlement
        # nobody had thought of read as clean.
        for undeclared in ("com.apple.security.cs.disable-library-validation",
                           "com.apple.security.files.all",
                           "com.apple.security.temporary-exception.mach-lookup"
                           ".global-name"):
            app = make_bundle(root, "Undeclared" + str(abs(hash(undeclared)) % 9999),
                              entitlements_with(undeclared), hardened=True)
            got = run(app, "release", ADHOC)
            check(f"an entitlement the file does not declare is refused: "
                  f"{undeclared.rsplit('.', 1)[-1]}",
                  got.returncode == FINDINGS, got.stdout + got.stderr)

        app = make_bundle(root, "UndeclaredDebug",
                          entitlements_with("com.apple.security.files.all"),
                          hardened=False)
        got = run(app, "debug")
        check("an undeclared entitlement is refused in DEBUG too",
              got.returncode == FINDINGS, got.stdout + got.stderr)

        got = run(app, "debug", "--declared",
                  os.path.join(root, "no-such.entitlements"))
        check("an unreadable declaration is 'could not check', never clean",
              got.returncode == UNCHECKED, got.stdout + got.stderr)

        # ---- the boundary that is the whole point of the sandbox ----------
        app = make_bundle(root, "NoSandbox",
                          entitlements_without("com.apple.security.app-sandbox"),
                          hardened=True)
        got = run(app, "release", ADHOC)
        check("a build that lost the App Sandbox is refused",
              got.returncode == FINDINGS, got.stdout + got.stderr)

        # Codex, 2026-08-30: the check compared one way only, so a bundle that
        # LOST a declared entitlement read as "exactly what is declared".
        app = make_bundle(root, "NoFilePicker",
                          entitlements_without("com.apple.security.files.user-selected.read-write"),
                          hardened=True)
        got = run(app, "release", ADHOC)
        check("a build that quietly LOST a declared entitlement is refused",
              got.returncode == FINDINGS, got.stdout + got.stderr)
        check("that refusal says MISSING rather than CARRIES",
              "MISSING com.apple.security.files.user-selected" in got.stdout,
              got.stdout)

        app = make_bundle(root, "NoMic",
                          entitlements_without("com.apple.security.device.audio-input"),
                          hardened=True)
        got = run(app, "release", ADHOC)
        check("a build that lost microphone access is refused",
              got.returncode == FINDINGS, got.stdout + got.stderr)

        # ---- unreadable is not a pass. The hole in the line this replaces --
        app = make_bundle(root, "Unsigned", None, hardened=False, sign=False)
        got = run(app, "release", ADHOC)
        check("an UNSIGNED bundle is 'could not check', never clean",
              got.returncode == UNCHECKED, got.stdout + got.stderr)
        check("the unsigned verdict never reads as a pass",
              "clean" not in (got.stdout + got.stderr).lower().split("RESULT")[-1],
              got.stdout + got.stderr)

        app = make_bundle(root, "NoEntitlements", {}, hardened=True)
        got = run(app, "release", ADHOC)
        check("a signed bundle carrying NO entitlements is refused, not clean",
              got.returncode == FINDINGS, got.stdout + got.stderr)

        got = run(os.path.join(root, "DoesNotExist.app"), "release", ADHOC)
        check("a path that does not exist is 'could not check'",
              got.returncode == UNCHECKED, got.stdout + got.stderr)

        got = run(app, "banana", ADHOC)
        check("an unknown configuration is refused rather than assumed",
              got.returncode not in (CLEAN,), got.stdout + got.stderr)

    print()
    failed = results.count(False)
    if failed:
        print(f"{failed} state(s) not distinguished")
        return 1
    print(f"all {len(results)} state(s) distinguished")
    return 0


if __name__ == "__main__":
    sys.exit(main())
