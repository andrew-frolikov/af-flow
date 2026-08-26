# AF Flow: names in the system permission lists

Decided by Fable, 2026-08-25. Scope: every string a human meets in a macOS list that shows a bundle's name, above all System Settings > Privacy and Security. Companion to `af-flow-visual-system.md`. The diagnosis (two "AF Flow" rows in Input Monitoring, four orphaned probe rows) is recorded in PROGRESS.md; this file is the naming decision only.

## A. The names

| Bundle | CFBundleName | CFBundleDisplayName | Bundle id |
|---|---|---|---|
| The app | `AF Flow` | `AF Flow` | `com.frolikov.afflow`, unchanged |
| Test host | `AF Flow Tests` | `AF Flow Tests` | `com.frolikov.afflow.testhost`, unchanged: TCC keys on the id, so renaming it would forfeit the working Input Monitoring grant. Display names are free to change; grants do not move |

Why "AF Flow Tests": it sorts immediately under "AF Flow", so the family reads as one group in an alphabetical list; "Tests" is a plain word that tells a stranger this row is not the app; and it avoids developer vocabulary ("Host", "Harness", "Runner") that means nothing to a future user.

The rules behind the row, binding on any future helper, probe or extension that ships:

1. **The bare name "AF Flow" belongs to exactly one bundle, the app.** Nothing else may carry it. Two identical labels was the entire incident.
2. **Every other shipped bundle is "AF Flow " plus one or two plain English words naming its job**, title case: AF Flow Tests, AF Flow Helper. Never a parenthetical, never a version number, never jargon.
3. **CFBundleName and CFBundleDisplayName are always identical.** Different macOS surfaces read different keys; giving them different values invites the same bundle to appear under two names.
4. **The bundle id mirrors the visible name**: `com.frolikov.afflow.<role>`, role lowercase, one word.

Acceptance test: a stranger reading the Settings list can point at the app, and can say roughly what every other family row is for.

## B. The recurrence rule, paste-ready for `Context/brand-visual.md`

Destination: "Hard rules that travel with the brand", or the end of "Application surfaces". Text to paste:

> **System permission lists are a brand surface, and a row there outlives the bundle that earned it.** Any bundle that requests a macOS permission buys a permanent line in System Settings labelled with its display name, kept after the bundle is deleted. Two hard rules follow. A throwaway bundle never requests a permission: if a verification needs one, it runs inside the app or the permanent test host, never inside a one-off bundle built for the check. And any disposable bundle that is built at all carries a scratch identity, never the product's: bundle id under `com.frolikov.scratch.*` and a lowercase display name like `scratch-rename-check`, so that if it leaks into LaunchServices or a settings list anyway, it neither wears the product's name nor sorts beside it. The bare product name belongs to exactly one bundle, the app; every other shipped bundle is the product name plus one or two plain words naming its job. Learned 2026-08-25, when Input Monitoring showed "AF Flow" twice and four deleted probe bundles still held rows under the product's family id.

Both halves are deliberate. Forbidding permissions on throwaways stops the permanent row; the scratch identity is the second belt, because a bundle id alone still registers with LaunchServices the moment it is built.

## C. What else I would rename or clean, briefly

- **The Microphone rows are the same disease and get the same cure.** `.axprobe`, `.tapprobe.sandboxed` and `.tapprobe.unsandboxed` are orphans of the identical habit; clean them with the same stub-and-reset pass as the four Input Monitoring orphans. Two of them registered as "AF Flow audio tap probe (sandboxed)" and "(unsandboxed)", which breaks every rule above at once: product name on a throwaway, parenthetical, jargon.
- **Nothing else.** `com.frolikov.afflow` is the right id, and the menu bar, Dock and Login Items already show only "AF Flow". Once the test host says "AF Flow Tests" and the orphans are gone, every list a user can open shows one app named AF Flow and nothing that pretends to be it.

## D. What implementation found and did, 2026-08-25

Recorded here rather than left to PROGRESS.md, because two numbers in this file
were counted before the databases were read and the decision above is what
future sessions will reach for.

**The orphan count was larger than section C assumed.** Measured against both
TCC databases: **fifteen rows across seven identifiers**, not four. `.axprobe`,
`.renamecheck`, `.snapcheck`, `.vcheck` and `.vsnap` each held Accessibility,
ListenEvent and Microphone rows between them, and `.tapprobe.sandboxed` and
`.tapprobe.unsandboxed` held AudioCapture. **Seven of the fifteen were GRANTED.**
Section C read the Input Monitoring rows alone, which is where he was looking.

**LaunchServices was a second surface, and the one he could actually see.**
TCC.db stores only the identifier; the name on a row in System Settings is
resolved through LaunchServices. Every deleted probe had left an LS record
behind reading `name: AF Flow` at a build directory that no longer existed,
fifteen of them, including an eighth identifier with no TCC row at all,
`com.frolikov.afflow.publiccheck`. Cleaning TCC without cleaning LaunchServices
would have left his product's name attached to bundles that do not exist.

**The stub-and-reset method needed one correction.** A stub under `$TMPDIR`
registers with LaunchServices without error and `tccutil` still cannot resolve
it. `~/Applications` works. No password is required, not even for rows in the
system database.

**Section A's names are implemented and verified by reading the built bundles:**
the test host is `AF Flow Tests` and the app is `AF Flow`, both name keys, both
identifiers unchanged. `AF_FLOW_DISPLAY_NAME` defaults to `$(PRODUCT_NAME)` on
the app target and `scripts/run-tests.sh` overrides it beside the identifier, so
the two cannot drift apart.

**Section B's rule is in the brand canon and in `CLAUDE.md` as rule 11**, and it
is enforced by `scripts/system-list-check.py` at session start and in the
boundary sweep rather than left to a future session having read it. Its first
run after wiring caught the app-build workflow leaking an LS record of its own,
which is the check earning its place: the routine procedure was a leak.

**The one sanctioned exception to "a throwaway never requests a permission"** is
`scripts/audiotap-probe/build.sh`. The question it answers is whether the App
Sandbox blocks a system audio tap, so it cannot run inside the sandboxed app or
the test host. It takes the rule's second belt instead: `com.frolikov.scratch.*`
and a lowercase scratch display name.
