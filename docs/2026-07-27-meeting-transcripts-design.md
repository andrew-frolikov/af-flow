# Meeting transcripts for Google Meet and Zoom: design

Status: APPROVED by Andrew on 2026-07-27. P1 in progress.
Date: 2026-07-27
Author: Claude (Fable 5), at Andrew's request

## Decisions Andrew made on this design

- **Approved as written**, including the phase order.
- **He changed hard rule 1.** It read "never grant or request Screen Recording";
  it now permits it "if it's best practice and safe and secure for me".
- **We did not take Screen Recording, and the reasoning is recorded because the
  headroom now exists.** The audio-only process tap does the same job for
  meetings and is structurally incapable of seeing his screen, so taking the
  wider permission would be strictly worse exposure for no gain. The conditional
  he attached is what makes declining the correct reading of his instruction
  rather than an override of it. `CLAUDE.md` is updated to say both things: the
  rule is relaxed, and this app still touches no screen-capture API.
- **Audit fixes he selected:** the cancelled-generation crash, cleanup loading a
  model mid-dictation, and the dictation/meeting contention. The dictation
  latency MEDIUMs were not selected and stay on the ledger.
- **Standing instruction, restated:** the orchestrator pins the model per task
  and says so in the plan. Prefer inline edits over spawning an agent that must
  re-read context the session already holds.

## What he asked for

Connect AF Flow to Google Meet and Zoom so he gets a transcript of the meeting.

## The answer, in one paragraph

AF Flow does not need to connect to Google or Zoom at all, and it should not try.
The fork already contains a complete meeting-transcription subsystem that v1
deliberately switched off. It detects a call, records, transcribes locally with
WhisperKit, and writes markdown. Reviving it is mostly deletion of the switches
that turned it off, plus one genuinely new capability: hearing the other
participants. That capability was amputated during the security de-risk because
at the time it required Screen Recording, which hard rule 1 bans. macOS has
since grown an audio-only route that does not.

Cost: zero recurring, zero cloud, nothing leaves the Mac.

## Why not the official APIs

Listed so the option is closed on evidence rather than left open.

| Route | Verdict |
|---|---|
| Google Meet transcript API | Needs a paid Workspace tier. His account is consumer Gmail. Also OAuth tokens, which hard rule 1 forbids outright. |
| Zoom cloud recording API | Needs a paid Zoom plan, works only for meetings he hosts, and also needs OAuth tokens. |
| Local capture | No account, no plan, no token, works for any meeting on any platform whether he hosts it or not, including the ones with no API at all. |

Local capture is not the cheap substitute here. It is strictly more capable for
his case, and it is the only one of the three that hard rule 1 permits.

## What already exists, verified by reading the source

- `Meeting/MeetingDetector.swift` recognises Zoom, Teams, FaceTime, Webex by
  bundle id, and Google Meet, Zoom and Teams in a browser by window title.
- `Meeting/MeetingSession.swift` runs the recording lifecycle.
- `Transcription/ChunkedTranscriptionPipeline.swift` transcribes in 30-second
  chunks while the meeting is still running.
- `Audio/DualStreamCapture.swift` merges two audio streams and tags each chunk,
  so mic becomes "Me" and system audio becomes "Others". Free diarization.
- `Meeting/MeetingSummaryGenerator.swift` summarises afterwards with the local
  cleanup model.
- `Meeting/MeetingMarkdownWriter.swift` writes markdown into date folders.
- `UI/MeetingTranscriptWindow.swift` and a Settings section already exist.

## What is missing or broken, and this is the part that matters

### 1. The blocker: summarising a meeting will probably kill the app

This is the most important finding in the whole review and it is not a
meeting-code bug.

`MeetingSummaryGenerator` splits the transcript into 5,000-character chunks and
sends each through `TextCleanupManager.clean()`. That path has a hard 15-second
timeout (`TextCleanupManager.swift:255`). On timeout it throws `CancellationError`
and calls `group.cancelAll()`.

Ledger item 27, already open and already observed: a cancelled generation does
not fail cleanly. llama.cpp hits `GGML_ASSERT` in `ggml_metal_device_free` and
calls `ggml_abort`, which **kills the process** rather than throwing.

A dictation is a few hundred characters and finishes well inside 15 seconds,
which is why item 27 is currently rare enough to be filed as latent. A
5,000-character summarisation chunk on a 0.8B model will routinely exceed 15
seconds. **Enabling meeting summaries as they stand converts a latent crash into
one likely at the end of most meetings.**

Fixing item 27 is therefore not optional cleanup that happens to be nearby. It
is a prerequisite, and it is a bug he already has, which is why it belongs in
this work rather than after it.

### 2. The "Others" channel is stubbed to always fail

`Audio/SystemAudioRecorder.swift` throws unconditionally. `DualStreamCapture`
catches it and continues mic-only, so meetings would transcribe only his side.
With headphones on, the other participants would be recorded as silence.

The replacement is Core Audio process taps (`AudioHardwareCreateProcessTap`,
macOS 14.4+). It is audio only, it is a separate TCC category
(`NSAudioCaptureUsageDescription`), it cannot see the screen, and it does not
require or imply Screen Recording. It requires a signed binary, which AF Flow
already is.

**This needs his ratification, not just his permission.** Hard rule 1 says
"never grant or request Screen Recording", and the stub's own comment explains
it was disabled because system audio capture at that time required exactly that.
The rule's purpose is intact under the new API and its letter is not violated,
but the implementation comment that justified the stub is now out of date, and
changing it on my own reading of his security rule is precisely the kind of call
this project sends back to him.

### 3. The sandbox question: ANSWERED, and the answer is that nothing changes

**P0 ran on 2026-07-27. Core Audio process taps work inside AF Flow's App
Sandbox, with its existing entitlements, capturing real system audio.** 352
callbacks, 180,224 frames, peak 0.718 against a known tone. The sandbox stays
on, no entitlement is added beyond the audio-capture usage description, and the
decision this phase existed to surface never has to be put to Andrew.

Published reports called tap behaviour under App Sandbox "fragile" and at least
one project disabled the sandbox to work around it. On his Mac, on macOS 26.5,
that is not what happens. **The probe is why this is a measurement rather than a
repeated rumour**, and it lives at `scripts/audiotap-probe/` so the claim can be
re-run rather than trusted.

**Two false negatives were produced before the true answer, and both are worth
knowing because they will recur.**

1. **TCC attributes to the responsible process, not the bundle.** Running the
   probe binary straight from a shell makes the terminal responsible, so the
   permission is never requested for the app and the system hands back correctly
   shaped SILENCE: frames arrive, every sample is zero. That reads exactly like a
   denial. Launching with `open -a` fixed it. Anything testing a TCC-gated
   capability must go through LaunchServices or it is testing the terminal.
2. **The probe's own verdict conflated "blocked" with "nothing was playing."** A
   run with a quiet Mac reported BLOCKED while the sandbox was working perfectly.
   The probe now plays its own tone, so silence has only one meaning. A check
   that cannot tell "denied" from "nothing to hear" is the same defect this
   project keeps paying for, and it produced a confident wrong answer here.

A third confound was caught before it did damage: the default output device
changed between runs (speakers to AirPods), so an early sandboxed-versus-
unsandboxed comparison was not like for like. Re-run back to back on one device.

### 4. Attendee names and calendar are dead, and should stay dead

`MeetingSession` calls `captureAttendees()`, which OCRs the meeting window
through `WindowCaptureService` — stubbed to return nil, correctly, since it
needed Screen Recording. `populateFromCalendar()` is an empty `return`.

These do not crash; they silently do nothing. The fix is to stop calling them so
the code does not look like it works, not to revive them. Attendee names are not
worth Screen Recording.

### 5. Auto-detect must not come back the way it left

It was removed on 2026-07-27 because it polled every 5 seconds for the app's
whole lifetime and walked the accessibility tree of every browser window 20
levels deep, in a dictation app, while he spoke. Reviving that timer would undo
a performance fix made yesterday.

The replacement is event-driven and costs nothing when no meeting is running:
`NSWorkspace.didActivateApplicationNotification` fires only when he switches
apps. Manual start stays the primary route.

## Performance findings from the same read

Reported here because he asked for performance, and because two of them get
worse the moment meetings are on.

1. **`SpeechTranscriber` serialises every transcription behind a
   `DispatchSemaphore`** (`SpeechTranscriber.swift:9`). Today nothing competes.
   During a meeting, a chunk transcribes every 30 seconds, so a push-to-talk
   dictation started at the wrong moment waits behind it. This is a direct hit
   on release-to-text latency, the number the product is judged on. It also
   blocks a dispatch queue thread while awaiting a Task, which is a thread-pool
   hazard independent of meetings.
2. **Ledger 28: the cleanup probe reloads the model per invocation.** Already
   filed, and it is the same teardown race as item 27 getting more chances to
   fire.
3. **Ledger 24: the test suite reaches the network on every run** and leaks a
   346 MB partial file. Already filed, contract-relevant, unrelated to meetings.
## The Codex audit, 15 findings, and which of them survive checking

Run 2026-07-27 against HEAD on Andrew's ChatGPT subscription, so zero Claude
window. Raw verdict: 5 HIGH, 8 MEDIUM, 2 LOW. It was pointed at the current code
rather than at a diff, because v1 closed and there is no chunk boundary to review.

It independently found the summarisation crash and the dictation/meeting
contention above, from a cold read, which is worth stating because those were the
two findings this design already rested on.

Every finding below was checked against the source before being repeated here.
Two did not survive.

### Confirmed HIGH

1. **Cleanup runs on the release-to-text path even when the model is not ready.**
   `AppState.swift:2358`. `canAttemptCleanup` gates which *prompt* gets built and
   nothing else: the code falls through to `cleanWithPerformance` regardless, and
   `TextCleanupManager.clean()` calls `loadModel()`. So a dictation started when
   the model is unloaded blocks on a model load, and on a cold cache on a
   download, while he waits for his text. Traced through the call chain and
   confirmed.

   **This compounds with finding 11 below**, and the compound is the real story.
   One `activeLLM` slot is shared by dictation cleanup, meeting Q&A, summaries
   and wiki generation. Every meeting summary therefore evicts the dictation
   model, and the next dictation pays a full model load on the hot path. Today
   that is rare. With meetings on it would happen after every call.

2. **Push-to-talk is not blocked while a meeting is recording.** `AppState.swift:907`.
   Two `AVAudioEngine` mic taps, one shared `SpeechTranscriber`, one Metal
   device. Same finding as the serialisation item above, reached independently.

3. **The cancelled-generation abort.** `TextCleanupManager.swift:537`, ledger 27.
   Codex's suggested fix is stronger than mine and I am adopting it: do not wrap
   generation in a cancelling timeout at all, because cancellation is what
   triggers `ggml_abort`. Use a backend stop primitive or let generation finish
   and handle the slow case separately.

4. **Dormant cloud importers still define Keychain token slots.**
   `Meeting/GranolaImporter.swift:26` publishes a `granolaApiKey` that writes
   straight to the Keychain. Inherited fork code, never used, but hard rule 1
   says API keys do not exist in this project, and this is reachable fork
   surface he already approved removing.

### Refuted, and why

5. **"Remove the `com.apple.security.network.client` entitlement."** Rejected as
   written. That entitlement is what performs the one-time hash-verified model
   download from Hugging Face, which the README documents as the app's only
   network activity and which the de-risk checklist explicitly permits. The
   checklist called for removing `network.server`, which was done. Stripping the
   client entitlement would break first-run model setup to fix nothing. The
   defensible kernel is that 24 URLSession call sites exist in dormant cloud
   code; the answer to that is deleting the dormant code, which is finding 4,
   not removing the entitlement the working feature needs.

6. **"Defaults do not implement fn/globe primary plus Right Command fallback."**
   Refuted. `AppState.swift:365` explicitly sets Right Command plus Right Option,
   which is the chord he actually uses. Codex was reading `CLAUDE.md`'s original
   spec, which he changed and which was never updated. The bug is in the contract
   document, not in the code, and the fix is to correct `CLAUDE.md`.

### Confirmed MEDIUM and LOW, worth having

- **`AudioRecorder.swift:244`**: `stopRecording()` maps the entire audio buffer
  just to print a maximum amplitude, on the release path. Pure latency for a log
  line.
- **`TextPaster.swift:109`**: clipboard preservation copies every pasteboard
  representation synchronously, including large binary items, before pasting.
  A large image on the clipboard slows down his dictation.
- **`TextPaster.swift:160`**: no `IsSecureEventInputEnabled` preflight, so Secure
  Input failures are silent. The product spec called for exactly this check.
- **`PostPasteLearningCoordinator.swift:12`**: up to 16 accessibility polling
  passes after every single paste.
- **`ChunkedTranscriptionPipeline.swift:116`**: meeting chunks queue into ASR
  with no backpressure, so slow transcription grows memory and delays live
  dictation.
- **`MeetingSession.swift:97`**: with system audio off, *every* audible voice
  picked up by the mic is labelled "Me", including other participants coming
  through his speakers. A transcript that confidently attributes their words to
  him is worse than one that says it does not know. This is why mic-only is a
  poor destination and the tap matters.
- **`ChunkedTranscriptionPipeline.swift:183`**: meeting chunk WAVs written to
  temp with no retention policy.
- **`MeetingDetector.swift:90`**: confirms the no-polling requirement above.

### How these map onto the phases

Findings 1, 2 and 3 are P1 work and all three are prerequisites for meetings
rather than nice-to-haves. Finding 4 and the fork-surface items fold into P3.
The dictation-latency MEDIUMs are P4. Nothing here changes the architecture.

## Proposed architecture

No new subsystem. Three existing seams, one new implementation behind an
existing protocol.

```
  mic  ──────────────► AudioRecorder ────┐
                                          ├─► DualStreamCapture ─► ChunkedTranscriptionPipeline
  system audio ─────► SystemAudioRecorder ┘        (unchanged)              (unchanged)
                       ▲                                                        │
                       │                                                        ▼
              REPLACED: throws  ──►  Core Audio process tap          MeetingSession ─► markdown
```

`SystemAudioRecorder` keeps its exact public surface
(`startRecording`/`stopRecording`/`onConvertedAudioChunk`), so nothing
downstream changes and the existing mic-only fallback stays as the safety net.
If the tap is unavailable for any reason, meetings degrade to mic-only exactly
as they do today rather than failing.

## Output

Markdown into the vault plus the in-app window, per his answer.

- Transcripts continue to be written by `MeetingMarkdownWriter` into date
  folders.
- The save directory is set to a folder inside the notes vault so Claude
  sessions can read them. Exact path proposed at implementation time; the
  Settings picker already exists, so this is configuration rather than code.
- The in-app transcript window stays as the live view during a call.

## Phases

Each phase is a safe stopping point with its own commit and its own Codex round.

| Phase | What | Gate |
|---|---|---|
| **P0** | ~~Probe: does a process tap work in a sandboxed AF Flow build?~~ **DONE 2026-07-27. YES.** Real audio captured under AF Flow's exact entitlements, peak 0.718. Sandbox stays on. `scripts/audiotap-probe/`. | ~~Human-gated.~~ Needed no permission click in the end: the grant already existed once the request was attributed to an app rather than to the terminal. |
| **P1** | Fix ledger 27, the cancelled-generation abort. Drain or await generation before releasing the model; bound generation by a token budget the generator actually checks. | Must be provably fixed before P2 ships, because meetings make it routine. Verified by reproducing the abort first, then failing to reproduce it. |
| **P2** | Implement `SystemAudioRecorder` on the process tap. Add `NSAudioCaptureUsageDescription`. Raise deployment target to 14.4. | Both channels transcribe in a real call. Egress check: nothing new on the wire. |
| **P3** | Un-hide the meeting UI. Event-driven detection, no polling. Stop calling the dead OCR and calendar paths. | He starts a real Meet or Zoom call and gets a transcript. |
| **P4** | Vault output path, plus the `SpeechTranscriber` serialisation fix. | Transcript lands in the vault; dictation latency during a meeting measured, not assumed. |
| **P5** | Codex review of the whole diff, full suite run, PROGRESS.md written up. | Suite at or better than 489 tests / 3 known failures. Sweep clean. |

P1 is worth doing whatever he decides about meetings, because it is a crash in
the app he uses daily.

## Risks, stated plainly

- ~~The probe may say the sandbox blocks it.~~ **Closed 2026-07-27: it does not.**
  The sandbox stays on and he is not asked to weaken it. This was the largest
  open risk in the design and it resolved in the cheapest possible direction.
- **Meeting transcription and dictation share one transcriber and one Metal
  device.** The serialisation fix reduces the latency cost but concurrent
  inference on shared state is ledger item 15, still unbenchmarked. P4 measures
  it rather than assuming it is fine.
- **Speaker separation is two channels, not real diarization.** Everyone on the
  far end is "Others". Distinguishing individual remote speakers is out of scope.
- **This is fork surface he asked to shrink.** v1's plan was to remove visible
  fork surface; this deliberately revives some of it. That is a change of
  direction he has now made, and it is recorded here so it does not read later
  as drift.

## Definition of done

He joins a real Google Meet or Zoom call, AF Flow transcribes both sides locally,
and when the call ends a markdown transcript is in his vault and readable in a
Claude session. Wi-Fi can be off for everything except the call itself. His
dictation still works during and after the meeting. No crash at summarisation.
