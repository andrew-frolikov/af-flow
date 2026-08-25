# Privacy audit

AF Flow is a personal, fully local macOS dictation app. This file states the current privacy posture in plain terms. It does not repeat the audit inherited from the upstream project it was forked from, which described a different app (cloud features, system audio capture, an auto-updater) that AF Flow does not have.

## Current posture

- **Fully local.** Speech-to-text (WhisperKit) and text cleanup (a local LLM via LLM.swift) both run on-device. No text or audio is sent anywhere for processing.
- **No stored credentials anywhere.** AF Flow never stores, requests, or accepts a credential of any kind (key, token, or secret). This is a hard rule in [CLAUDE.md](CLAUDE.md), and `scripts/banned-symbol-sweep.sh` checks for it in code, config, and user-facing text on every change.
- **No auto-updater.** The update mechanism the upstream project used is gone: the package dependency, the updater code, and the update-feed config keys have all been removed.
- **No screen recording.** The code path that could request Screen Recording permission was removed, and the built app does not link any screen-capture framework.
- **Model downloads are one-time and verified.** The first time a speech or cleanup model is selected, it downloads once from Hugging Face and is checked against a known hash before use. After that, it runs from the local cache with no further network activity.
- **No telemetry.** No analytics or crash-reporting SDK is present.

## What is not yet verified

- **Network egress test: pending.** The de-risk checklist (CLAUDE.md, item 7) calls for installing LuLu, running it default-deny, and confirming that dictation works with Wi-Fi off and that nothing unexpected reaches the network while dictating with Wi-Fi on. This has not been run yet. Until it has, "fully local" is a description of the code, not a measured result.

## Where the real audit lives

The detailed security audit that this fork's de-risk checklist is based on lives in Andrew's vault, not in this repo: `AndrewFrolikov OS/Projects/heavy-work-runs/2026-07-18-dictation-app-stack-d4pp/06-security-audit.md`.

For a machine-checkable version of the rules in this file, run:

```
./scripts/banned-symbol-sweep.sh
```

It exits 0 when the codebase and docs are clean of the banned symbols and instructional text described above, and prints exactly what it found otherwise.
