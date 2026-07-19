# Privacy and security gate

The upstream version of this file described a release gate for a publicly distributed app: notarized disk images, GitHub releases, update feeds. AF Flow has none of those. It is personal, built from source, and never distributed, so there is no deploy to gate.

What replaces it is a per-change gate, which is stricter because it runs every time rather than only before a release.

## Run before every closing commit

1. The machine-checkable rules:

   ```sh
   ./scripts/banned-symbol-sweep.sh
   ```

   Exits 0 when clean. It checks code, config, the built binary, and product docs for the capabilities the contract forbids. Never edit this script to make a failure go green. If a check looks wrong, leave it failing and raise it.

2. The static preflight inherited from upstream, which looks for tracked private data and credential-shaped strings:

   ```sh
   ./scripts/privacy-security-preflight.sh
   ```

3. The independent review at each chunk boundary. The exact command is recorded in PROGRESS.md. It runs on a separate subscription and costs nothing, so there is no reason to skip it.

4. Confirm no real personal data is tracked in git: recordings, transcripts, meeting notes, screenshots, debug logs, or exported audio. The `.gitignore` covers the known shapes, but check `git status` before committing rather than trusting it.

## The one check that is still outstanding

Network egress has not been measured yet. The de-risk checklist in CLAUDE.md, item 7, calls for installing LuLu in default-deny mode, confirming that only the model host is contacted during the one-time download, and then confirming that dictation still works completely with Wi-Fi switched off.

Until that has been run, statements about this app being local describe the code, not a measured result. Do not treat it as verified.

## Why this file is short now

The detailed threat analysis lives outside the repo, in Andrew's vault, at `AndrewFrolikov OS/Projects/heavy-work-runs/2026-07-18-dictation-app-stack-d4pp/06-security-audit.md`. Duplicating it here would create a second copy to keep in sync, and a stale security document is worse than none, which is exactly how the upstream version of this file ended up describing an app that no longer exists.
