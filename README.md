# AF Flow

A personal, fully local macOS dictation app for Andrew Frolikov. Hold a key, speak (English, Russian, Ukrainian, including mixed EN/RU), release, and cleaned-up text lands at the cursor in whatever app is frontmost.

Built on a fork of an MIT licensed Swift project. The upstream author's copyright travels with the code: see [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). There is no download link and no prebuilt binary. Build it yourself from this source.

## What runs locally

- Speech-to-text: WhisperKit, on-device.
- Cleanup: a local LLM via LLM.swift, on-device.
- No stored credentials, no cloud accounts, no telemetry. Nothing leaves the Mac.
- The only network activity is a one-time, hash-verified model download from Hugging Face the first time a model is selected.

## Requirements

- macOS 14.0 or later, Apple Silicon.
- Xcode 16 or later.

## Build from source

This repo ships a checked-in `AFFlow.xcodeproj` (the app's internal name; branding to "AF Flow" is tracked as a later chunk). To build and run:

```
open AFFlow.xcodeproj
```

Then press Cmd+R in Xcode, or from the terminal:

```
xcodebuild -project AFFlow.xcodeproj -scheme AFFlow build
```

On first launch, macOS will ask for Microphone and Accessibility permissions (needed for the hotkey and for pasting text). Grant both.

## The rules for this fork

- [CLAUDE.md](CLAUDE.md) is the build contract: hard rules, the de-risk checklist, and the product spec.
- [LOOP.md](LOOP.md) is the loop protocol used to verify each change before it lands.
- `scripts/banned-symbol-sweep.sh` is the machine-checkable version of the hard rules. It should always exit 0.

## License

MIT. AF Flow began as a fork, and the upstream author's copyright is retained in [LICENSE](LICENSE), which is a condition of that licence, not a leftover.
