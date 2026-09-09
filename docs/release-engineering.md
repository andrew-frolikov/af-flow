# Release engineering: how AF Flow becomes an app a stranger's Mac will open

Phase 1 of `docs/launch-v1-plan.md`. Written 2026-08-30.

Everything here is about one gap. Every artefact this repo produced before now
was for one Mac: `AF_FLOW_APP_BUILD=1 ./scripts/run-tests.sh` builds a Debug app
signed with Andrew's own development certificate, and it works because his
machine already trusts that certificate. Nobody else's does. A friend who
downloads that build is told "AF Flow is damaged and can't be opened", which is
Gatekeeper refusing a bundle that is neither Developer ID signed nor notarized.

## What exists now

| Artefact | What it does |
|---|---|
| `scripts/release-build.sh` | archive, export, embed the starter models, sign, notarize, staple, DMG, staple the DMG, ask Gatekeeper. Every step states its postcondition and checks it. |
| `scripts/bundle-boundary-check.py` | reads a BUILT bundle's real signature and refuses the shapes that must never ship. |
| `scripts/bundle-boundary-check-selftest.py` | stages 18 states against real ad-hoc signed bundles and watches the checker distinguish them. Offline, no Developer ID needed. |
| `scripts/build-config-check.py` | asserts the build settings a release depends on, in both files that state them. Runs at session start. |
| `scripts/build-config-check-selftest.py` | stages 9 disagreements. |
| Release configuration | sandbox on, hardened runtime on, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`. |

## Two defects this phase found, and what each one cost

**The entitlement guarantee could only refuse a bundle it had already read.**
Since 2026-08-29 the app carries no `com.apple.security.network.client`, and
`run-tests.sh` enforced it with one line:

```
codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q "com.apple.security.network.client"
```

When `codesign` fails it prints nothing, so `grep` finds nothing, so the build
is reported boundary-clean. Staged on 2026-08-30: a copy of a bundle that
really did carry the entitlement, with its signature removed, was reported
CLEAN. An unsigned bundle, an empty `CODE_SIGN_IDENTITY` and an unreadable path
all read as verified. The check is now `bundle-boundary-check.py`, where
unreadable exits 2 and every caller treats that as failure, which is the
`lulu-rule-check.py` rule applied in a second system.

**project.yml and the pbxproj had already drifted.** There is no xcodegen on
this machine, so the pbxproj is hand-maintained and `project.yml` is a
description of it. project.yml said `ENABLE_HARDENED_RUNTIME: NO`; both real
configurations said YES. That drift was harmless, which is why it survived.
project.yml is the file everyone reads, because it is 80 lines rather than
1700, and the pbxproj is the file Xcode obeys. `build-config-check.py` now
refuses the two to disagree, and runs at session start.

## The Release configuration, and the one setting that was missing

`ENABLE_APP_SANDBOX` and `ENABLE_HARDENED_RUNTIME` were already YES in both
configurations. What was missing was `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`
in Release.

Seen failing at the artefact layer on 2026-08-30, not argued from the manual:
building Release with the injection left on produced

```
com.apple.security.app-sandbox              => true
com.apple.security.device.audio-input       => true
com.apple.security.files.user-selected...   => true
com.apple.security.get-task-allow           => true      <-- injected
```

A shipped build carrying `get-task-allow` lets any process on a friend's Mac
attach to the app that holds their microphone, and notarization rejects it.
With the setting in place the Release build carries exactly the three
entitlements in `AFFlow/AFFlow.entitlements` and nothing else.

## His own Mac will re-prompt for Microphone once. This is verified, not expected

The launch plan calls this "the Team-ID change". The Team ID does not change:
it is `Q4HNX2JLKT` before and after. What changes is the signing certificate,
and TCC binds a grant to a code requirement, not to a bundle identifier alone.
Read out of his own TCC database on 2026-08-30:

```
identifier "com.frolikov.afflow" and anchor apple generic
  and certificate leaf[subject.CN] = "Apple Development: andriy.frolikov@gmail.com (A75XPSV5W4)"
  and certificate 1[field.1.2.840.113635.100.6.2.1]
```

The grant names the Apple Development certificate literally, and the trailing
OID `1.2.840.113635.100.6.2.1` is the Apple Development marker. A Developer ID
Application certificate carries a different subject CN and the different marker
`1.2.840.113635.100.6.1.13`, so the requirement cannot match and macOS treats
the signed app as a different client.

**So the first launch of the notarized build re-prompts for Microphone, and for
Input Monitoring, exactly once. That is correct behaviour and not a defect.**
It also means the old rows stay in his privacy lists until removed;
`scripts/system-list-check.py` will show them and `scripts/tcc-orphan-cleanup.sh`
is the cure.

The LuLu family checker is unaffected: no rule is the end state, and an app
with no network entitlement earns no rule in either direction.

## What blocks, and what does not

Blocked on the **Apple Developer Program membership** (USD 99/yr, about
CAD 135/yr, Andrew's purchase, not made as of 2026-08-30): signing, notarizing,
stapling, the DMG, and the Gatekeeper verification. `release-build.sh` stops at
step 0c with exit code 3 and says so.

It deliberately does **not** fall back to the "Apple Development" certificate
that is present. That fallback would produce a DMG that opens on his Mac and
fails on every other one: a release that tests clean and is broken for exactly
the people it is for.

Not blocked, and done: the Release configuration, both checkers, the archive
itself. `scripts/release-build.sh --version 2.4.2 --without-models --stop-after archive`
runs today on the development certificate, prints NOT SHIPPABLE, and refuses
every step past the archive.

## The version number is not read from the project, on purpose

`AFFlow/Info.plist` carried `CFBundleShortVersionString = 2.4.2` until
2026-09-08, when the membership was bought and it became `1.0.0`. Historically,
inherited from the fork this app grew out of. Shipping that number is a claim
about a history AF Flow does not have. `release-build.sh` requires `--version`
and refuses to run when Info.plist disagrees with it, so the mismatch is loud
rather than silent. Setting it to 1.0.0 is Phase 9 of the launch plan.

## Before the first real run, once

```
xcrun notarytool store-credentials AF_FLOW_NOTARY \
    --apple-id andriy.frolikov@gmail.com --team-id Q4HNX2JLKT
```

It asks for an app-specific password from appleid.apple.com. **That password is
Andrew's to type. No agent session enters it**, and none is stored in this
repo (hard rule 1). Override the profile name with `AF_FLOW_NOTARY_PROFILE`.

## Every release build registers a second claimant, and cleans up after itself

Building this app registers its bundle at a new path with LaunchServices, under
`com.frolikov.afflow`, the identifier his Microphone and Input Monitoring
grants are attached to. On 2026-07-26 a claimant exactly like that took his
Input Monitoring grant and his dictation was dead for five hours with the app
reporting itself ready. On 2026-08-26 the opposite mistake, deleting a build
without unregistering it, left a live record pointing at a bundle that was
gone.

`release-build.sh` unregisters the copies it builds and re-registers his
installed app in an `EXIT` trap, so it survives every refusal path too. It
finds his installed app by importing `system-list-check.py`'s own dump parser
rather than by hand: the field holding the identifier is `identifier:`, while
the field named `bundle id:` holds the display name, and the first version of
that lookup read the wrong one and reported "no installed app" instead of a
parse failure.

## Phase 1 gate 4, which is not yet done

The DMG must install and launch clean on a Mac that has never seen AF Flow. The
proxy is a fresh macOS user account, which has its own TCC database and its own
LaunchServices registrations, so it reproduces a stranger's machine for
everything except Gatekeeper's first-download quarantine. Blocked on the
membership, like everything else after step 0c.
