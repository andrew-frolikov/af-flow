# AF Flow

A fully local macOS dictation app. Hold a key, speak, release, and cleaned-up
text is on your clipboard. Press Cmd-V wherever you want it.

English and Russian, including the two mixed in one sentence, which is what it
was actually built for.

**Nothing leaves your Mac.** The app has no network entitlement at all, so the
kernel refuses every outbound connection it could attempt. That is not a policy
in a settings pane, it is a property of the signed binary, and you can check it
yourself:

```
codesign -d --entitlements :- "/Applications/AF Flow.app"
```

## Install

Download `AF Flow 1.0.0.dmg` from
[Releases](../../releases), open it, and drag the app to Applications.

The disk image is signed with a Developer ID certificate and notarized by
Apple, so macOS opens it without warnings.

Speech and cleanup models for the Starter tier ship inside the download, so
dictation works the first time you open it, offline.

## How it works

- **Speech to text:** WhisperKit, on device.
- **Cleanup:** a small local language model, on device, which fixes dictation
  artefacts without rewriting how you speak.
- **Delivery:** the clipboard. The app never types into other applications and
  never asks for Accessibility permission, so you decide where the text lands.
- **Bigger models:** an embedded helper service downloads them from Hugging
  Face with pinned SHA-256 hashes. It is the only part of the bundle allowed a
  network connection, and it writes into a file the app opens for it.

## Requirements

- macOS 14 or later, Apple Silicon.
- Microphone and Input Monitoring permission, both requested on first launch.

## What it does not do

- **No Ukrainian yet.** It is not claimed until it has been tested against real
  ground truth, and it has not been.
- **No meeting transcription in 1.0.** The code is present and tested but
  switched off; it returns in a later release.
- **No automatic updates, no telemetry, no accounts.** Check
  [Releases](../../releases) yourself when you want a newer version.

## Build from source

```
open AFFlow.xcodeproj
```

Then Cmd-R, or from the terminal:

```
xcodebuild -project AFFlow.xcodeproj -scheme AFFlow build
```

Tests need the app closed, and the wrapper enforces that:

```
./scripts/run-tests.sh
```

## Licence and attribution

Built on a fork of an MIT licensed Swift project. The upstream author's
copyright travels with the code: see [LICENSE](LICENSE) and
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
