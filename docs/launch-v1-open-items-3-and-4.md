# Open items 3 and 4: the helper's identity and its write path

Written 2026-08-30 for `docs/launch-v1-plan.md`. Andrew decides item 3; item 4
is mine to decide and document, and the recommendation below is the decision
unless he overrides it.

Settled and not re-opened here (2026-08-29): the main app never gets the
network back, and a bundled, notarized, network-capable helper app downloads
the bigger models with pinned hashes and progress.

## The facts both items rest on

- `scripts/lulu_rules.py` defines the family as `com.frolikov.afflow`, exact or
  a **dotted** child. So `com.frolikov.afflow.models` is in the family and
  `com.frolikov.afflowmodels` is not.
- `scripts/lulu-rule-check.py` currently asserts the family holds **zero**
  rules, and says why: the app has no network entitlement, so it needs none,
  and a rule for it is at best decoration and at worst what re-authorises it
  the day the entitlement returns.
- `scripts/system-list-check.py` audits the same family across the two TCC
  databases and LaunchServices. It is how "AF Flow" listed twice in Input
  Monitoring was found on 2026-08-25.
- His live data is 6.8 GB inside the app's sandbox container, of which 4.2 GB
  is `models` and 2.0 GB is `whisper-models`. `AppSupportDirectory` is the one
  place that names that folder, and the last change to that naming split his
  data in two for 24 days (2026-08-02 to 2026-08-26).
- A sandboxed app cannot write into another app's container. A child process
  it spawns with `fork`/`exec`/`posix_spawn`/`NSTask` **does** inherit its
  sandbox, so a plain helper binary run by the main app would be network-denied
  exactly like its parent. `com.apple.security.inherit` does not cause that
  inheritance; it declares it, and a child claiming it alongside any other
  sandbox entitlement is aborted.
- **But an XPC service is not a child process.** It is launched by `launchd`
  and gets its own sandbox from its own entitlements. That is the correction
  that changed the recommendation below, and it was found by a second
  evaluator on 2026-08-30, not by me.
- **App groups on macOS need no provisioning profile.**
  `com.apple.security.application-groups` is one of the unrestricted macOS
  entitlements: the profile requirement is an iOS rule, and macOS has no way to
  allowlist a group with a profile at all. The only macOS constraint is the
  Team ID prefix. My earlier draft had this backwards and treated it as an open
  risk.

---

## Item 3: the helper's bundle identifier

**Option 3A. Identifier inside the family, `com.frolikov.afflow.models`, and
`lulu-rule-check.py` gains one named exception.** (Recommended.)

The exception is written as narrowly as it can be stated: every family
identifier must hold zero rules, *except* exactly `com.frolikov.afflow.models`,
for which a rule is expected and is reported rather than flagged. An
`Allow any:any` for the main app stays the loudest finding the script has, and
the helper's own rule is printed in full every session so a widened one is
visible.

- The helper stays visible to `system-list-check.py`, which audits by family
  prefix. This is the argument that decides it: moving the helper out of the
  family to keep one checker quiet would make it invisible to the checker that
  watches privacy rows and LaunchServices claimants, and that second checker is
  the one that has actually caught things.
- It matches every other bundle this project ships (`.testhost`,
  `.cleanup-model-probe`, `.axprobe`), and CLAUDE.md hard rule 11's naming
  convention: display name "AF Flow Models", `CFBundleName` and
  `CFBundleDisplayName` identical.
- Cost, stated plainly: the LuLu checker stops meaning "no rule anywhere in the
  family" and starts meaning "no rule except this one". That is a weaker
  sentence. It is weaker because the world got more complicated, not because
  the check got sloppier, and the exception names one identifier rather than a
  pattern.

**Option 3B. Identifier outside the family, e.g. `com.frolikov.models`.**

- The LuLu checker keeps its absolute sentence, untouched.
- Cost: the helper disappears from `system-list-check.py`. It becomes the first
  AF Flow bundle whose identity the family audit cannot see, and the audit's
  own premise is that every bundle this project ships is inside the family.
  Widening that checker to a second prefix costs the same clarity the first
  option was accused of costing, only in the checker with the better track
  record.
- It also reads wrong in his system lists: a bundle called "AF Flow Models"
  with an identifier that is not an AF Flow identifier is exactly the shape
  `system-list-check.py` exists to make suspicious.

**Option 3C. No LuLu rule at all, because the helper is launched rarely.**
Not viable. LuLu prompts on any outbound connection by an unknown binary, so a
friend or Andrew gets a prompt the first time and whatever they click becomes a
rule. Pretending no rule will exist is how three `Allow any:any` rules survived
five weeks.

---

## Item 4: where the downloaded bytes land. Mine to decide

**Decided: option 4D, with 4A as the fallback if a one-day spike does not land.**

**Option 4D. An XPC service inside the app bundle, holding
`com.apple.security.network.client`, writing into a file descriptor the app
hands it.** (Decided.)

`Contents/XPCServices/AF Flow Models.xpc`. The main app creates the destination
file **in its own models folder**, opens it, and passes the `NSFileHandle` over
`NSXPCConnection`. Sandbox permission is checked at `open()`, so the descriptor
carries the capability across the boundary; the service writes bytes into a
file it could never have opened itself. The app closes the file, verifies
SHA-256 and byte count, and deletes it if either is wrong.

- No app group, no shared writable surface, no second container, no move, no
  migration. The destination file is the only file that ever exists.
- Nothing new appears in his privacy lists or in LaunchServices: an XPC service
  is not an app and does not register.
- No non-sandboxed code. The service's entitlements are exactly
  `network.client` and nothing else.
- **Precedent rather than theory:** Sparkle ships a Downloader XPC Service for
  exactly this reason, so that a sandboxed host app can omit
  `com.apple.security.network.client`. That is production evidence, and it is
  the reason to prefer this over 4A.
- Honest costs. `launchd` terminates an idle service, so the download lives
  only while the app holds the connection: quitting the app during a 4 GB
  download loses it, where a separate helper app could have carried on. That is
  acceptable, and arguably correct for an app whose progress UI is the thing
  the user is watching. **Any option needs a resumable or restartable
  download**, because a service or a helper can be killed under memory pressure
  either way.
- **UNCERTAIN and to be settled by a spike before Phase 4 commits:** whether an
  embedded XPC service may hold an entitlement its host lacks is not stated in
  those words in Apple's documentation. Sparkle is strong evidence, not a
  citation. The spike is small: build the service, give it `network.client`,
  fetch one byte, pass one descriptor. If it fails, fall back to 4A, which
  costs nothing already spent.

**Option 4A. App group container used as a MAILBOX, not as a home.** (Fallback.)

Both apps carry `com.apple.security.application-groups` =
`["Q4HNX2JLKT.com.frolikov.afflow"]`. The helper downloads into the group
container, the main app moves the file into its own models folder and verifies
the hash at the destination.

- No provisioning profile is needed, contrary to my first draft.
- Both paths are on `/System/Volumes/Data`, so the move is a `rename(2)`, not a
  copy, and no transient double space is needed on a friend's Mac. A group
  member has full read/write in the group container including `unlink`, so the
  move is permitted. **To be checked by return code rather than argued**, at
  implementation.
- The models folder does not move and `AppSupportDirectory` does not change:
  6.8 GB of his live data stays where it is.
- **The strongest argument against it**, and the reason it is the fallback
  rather than the decision: it pays an entitlement and a shared container to
  solve a problem a passed file descriptor solves with neither, and a group
  container is a **persistent, shared, writable surface keyed only by the Team
  ID**. The destination-side hash check stops being good practice and becomes
  the only thing standing between that mailbox and the models folder.

**Option 4B. A non-sandboxed helper writing straight into the app's container.**
Rejected. A privacy-first app that removed its own network access would ship a
network-capable binary with no sandbox at all and the user's full file access:
a strictly larger blast radius than the capability it removed. Its convenience
premise is also doubtful, since macOS 14 added a consent prompt for one app
reading another app's container.

**Option 4C. A helper binary spawned by the app, handing bytes back on a pipe.**
Not viable, and recorded so it is not re-proposed: a spawned child inherits the
parent's sandbox and is network-denied too. 4D is the working version of the
same idea, and the difference is that `launchd` starts an XPC service rather
than the app starting a child.

**Item 4 does not change item 3.** LuLu attributes a connection to the signing
identifier of the process that opens it, and an XPC service has its own bundle
identifier, so a rule appears either way.

**One thing I am reading, rather than being told.** The decision settled on
2026-08-29 says "a bundled, notarized, network-capable helper **app**". 4D is a
service rather than an app, and the app rather than the helper writes the file.
I am treating that decision at the level of its purpose, which is unchanged and
better served: the main app stays kernel-denied forever, downloads are
hash-pinned, and progress is shown. If Andrew meant the word "app" literally,
4A is the option that honours it and it is already worked out above.

## What each option costs if it is wrong

| Option | If it is wrong |
|---|---|
| 3A | **The exception outlives the thing it excuses.** If the downloader is ever dropped or renamed, the allowlist entry stays and silently permits a rule for an identifier no longer shipped. Mitigation, and it is cheap: the exception is conditional on that bundle actually existing in the build, and the check FAILS if it does not. |
| 3B | The helper is invisible to the family audit, and nobody notices until it holds something it should not. |
| 4D | The entitlement-on-an-embedded-service assumption is wrong. Discovered by a one-day spike before anything is built on it; fallback 4A costs nothing already spent. |
| 4A | The group container is a shared writable surface and the destination hash check becomes load-bearing rather than belt-and-braces. |
| 4B | A non-sandboxed, network-capable binary ships inside a privacy-first app. Discovered by whoever reads the entitlements, or by nobody. |

## Changelog

**2026-08-30, first draft.** Recommended 3A and 4A.

**2026-08-30, revised after an independent second evaluation.** Codex was rate
limited and Gemini had no auth configured, so the second evaluator was a Claude
reviewer that did not write the draft; that fallback is recorded because
CLAUDE.md hard rule 13 requires it. It overturned two things. The provisioning
caveat on app groups was **backwards**: macOS treats
`com.apple.security.application-groups` as unrestricted and has no profile
mechanism for it at all. And option 4C was dismissed on reasoning that is true
of child processes but **not of XPC services**, which `launchd` starts with
their own sandbox. That opened option 4D, which is what Sparkle ships, and 4D
is now the decision.

**2026-08-30, later. Andrew ratified 3A.** Helper identifier inside the family,
`com.frolikov.afflow.models`, with one named exception in `lulu-rule-check.py`
conditional on the bundle existing in the build.

**2026-09-06, item 3 built.** `lulu_rules.HELPER_ID` and `helper_ships()`: the
exception applies only while a bundle declaring that identifier physically
ships inside the installed app (realpath containment, no symlinks at any
level), and "could not tell" counts as "does not ship". The checker prints the
helper's rule in full every session; the remover leaves it alone while the
helper ships and removes it like any other family rule once it does not. The
test-only staged-app override is ignored whenever the rules database is the
real one, compared by inode: a lexical compare had called the
`/System/Volumes/Data` alias a staged file (Codex). Self-test cases 9 to 16c.
Item 4's spike is the next piece of work.

**2026-09-06, item 4 spike DONE: the answer is yes, on this Mac.** A throwaway
host app signed with his Apple Development identity, App Sandbox on, NO
`network.client`, embedding `Contents/XPCServices/SpikeNet.xpc` signed with
App Sandbox + `network.client`. The host's own `URLSession` fetch of
`http://127.0.0.1:8765/hello` failed with `NSPOSIXErrorDomain 1, Operation not
permitted`, the kernel refusal (the control held). The host then opened a file
in its own container and passed the `FileHandle` over `NSXPCConnection`; the
service fetched the same URL, status 200, wrote 21 bytes into that descriptor,
and the host read them back. `launchd` gave the service its own container
(`~/Library/Containers/com.frolikov.spike.net` appeared), so it ran sandboxed
under its OWN entitlements, not its host's. What the spike does NOT show,
stated so nobody upgrades it: a remote host (localhost drew no LuLu prompt and
earned no rule), Developer ID + notarization, or a launch through
LaunchServices rather than direct exec. None of those touches the mechanism
under test. **4D stands; 4A is not needed.** Spike files lived in the session
scratchpad and its two containers were removed afterwards.
