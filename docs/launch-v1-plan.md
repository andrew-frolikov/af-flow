# AF Flow v1 public launch plan

**Authored by Fable 5 with Andrew, 2026-08-29, through a structured interview. Opus 5 implements.**

**Goal:** Ship AF Flow v1 to the public — Developer ID signed, notarized, friends as first testers — with onboarding so clear a non-technical friend dictates within five minutes, and a support model where the app never phones home but hands the user a perfect prompt for whatever AI they already trust.

**Who this is for:** Andrew's friends first, then anyone via GitHub.

**Done looks like:** A notarized DMG on a public GitHub Release installs clean on a Mac that has never seen the app; a friend reaches their first successful dictation without Andrew on the phone; the Home card tells them when something breaks and the copy-to-AI button gets it fixed; no claim on any surface overstates what the app verifiably does.

## Decisions settled 2026-08-29 (do not re-ask)

| Decision | Choice |
|---|---|
| v1 scope | **Dictation only.** Meetings hidden behind an internal flag; tests keep running. Meetings return in v1.x. |
| Distribution | **GitHub Releases**, notarized DMG. Same link for friends and public. |
| Updates | **User-driven.** No update checks in the app, ever. FAQ and the copy-to-AI prompt carry the current version and the releases URL so any AI can say "1.1 exists." |
| Fresh-install models | **DMG bundles the Starter tier** (whisper-small + Qwen 0.8B). Dictation works the moment the app first opens, offline. |
| Bigger models | **A bundled, notarized, network-capable helper app** downloads them with pinned hashes and progress, writes to the models folder, quits. The main app stays kernel-denied forever. |
| Model choice UX | **One quality ladder**, two tiers: Starter (works now) / Full (best your machine handles). Per-model control stays in Settings. |
| Machine test | **Local benchmark**: auto-times the bundled model on a bundled ~5 s clip, extrapolates bigger tiers by ratios calibrated once on Andrew's Macs, labels them *estimated*, recommends in plain words. One click applies. |
| AI round-trip on the model screen | **Dropped — Andrew ratified.** The benchmark recommends directly. A small advice-only "Ask your AI about these results" copy button remains. No paste-back parsing anywhere in the app. |
| Copy-to-AI data | **Status only**: app + macOS versions, permission states, Globe-key state, hotkey config, models present with sizes, key settings, releases URL. Never a word of user text, never log content. Pinned by a redaction test seen failing. |
| Home widget | **Status-aware card.** Healthy: one quiet line ("Everything working · Full tier · v1.0"). Broken: expands, names the problem in plain words, big "Copy for your AI" button + "Fix it myself" deep link to the exact System Settings pane. Onboarding is resumable from it. |
| FAQ | **Native Help section in the sidebar, EN + RU**, content bundled in the app, on brand. Fix-something answers end with the copy-to-AI affordance. Short copy in the README. |
| Language hero claim | **EN + RU + mixed now.** The hero names what auto-detect is verified for. Other languages ship selectable in Settings and join the hero as each passes real dictation tests against ground truth. The hero never claims what is not verified. |

## Inputs

- The repo at `meeting-repair-pass1`, commit `d039636` or later.
- Andrew's Apple Developer Program membership (USD 99/yr ≈ CAD 135/yr, his purchase, not yet made). Phases 1's signing steps block on it; everything else does not.
- Andrew's M-series Macs for benchmark ratio calibration.

## Process

### Phase 1 — Release engineering (blocks the DMG, nothing else)

1. Add a Release configuration to project.yml: App Sandbox stays, hardened runtime on, `get-task-allow` off. The `AF_FLOW_APP_BUILD` entitlement refusal (network.client) must hold in Release too — extend the existing seen-failing check.
2. `scripts/release-build.sh`: archive → sign with Developer ID Application → `notarytool submit --wait` → staple → build DMG (starter models inside) → `spctl -a -vv` verify. Each step fails loudly; no step claims success it did not verify.
3. Expect and document the Team-ID change: Andrew's own Mac re-prompts microphone and Input Monitoring once. The LuLu family checker is unaffected (no rules is the end state) — but see Open item 3.
4. Gate: the DMG installs and launches clean on a Mac that has never seen the app (use a fresh macOS user account as proxy).

### Phase 2 — Scope gate

1. Meetings UI behind an internal flag (defaults key, off by default, no UI to enable in v1). Meeting tests keep running in CI; the flag is tested in both states.
2. Sweep visible strings for meeting references a dictation-only user would see.

### Phase 3 — Tiers and the benchmark

1. Tier definitions live beside the model catalogue (single source of truth discipline, same as `model_catalogue.py`): Starter = whisper-small + Qwen 0.8B. Full = **speech model TBD (Open item 1)** + Qwen 2B or 4B by RAM.
2. Bundle a ~5 s neutral speech clip (record one EN and one RU; benchmark uses both — the RU number is the honest one for this audience).
3. Benchmark harness: time the bundled model end-to-end on the clip; multiply by calibration ratios measured once on Andrew's machines; render bigger tiers as "estimated ~N s per 5 s of speech". Recommendation logic is a plain threshold comparison, stated in one sentence on screen.
4. Small "Ask your AI about these results" copy button: composes benchmark numbers + tier definitions into an advice prompt. No paste field.

### Phase 4 — The helper downloader

1. New target "AF Flow Models": tiny, notarized, hardened runtime, network client entitlement, its own bundle id (see Open item 3 for the id decision — it interacts with the LuLu checker rule).
2. It reads the same pinned catalogue (URLs, SHA-256, byte counts) compiled from `TextCleanupManager.swift` — never a second copy. Speech models need the same pinning discipline before the helper ships them (Open item 2).
3. Write path into the sandboxed app's models folder: app group container vs non-sandboxed helper — Opus decides, documents the trade-off in this file's changelog (Open item 4).
4. Main app launches it with a tier argument; helper shows progress, verifies hash + size in place (the downloader script's own lesson: verify the bytes at the destination), quits. Download failure or offline: the app stays on Starter and says so; retry lives in Settings. Seen failing: a tampered hash must refuse and leave nothing behind.

### Phase 5 — Onboarding flow

Welcome → microphone → Input Monitoring → Globe key ("set it to Do Nothing", with the exact System Settings pane deep-linked) → model setup (Phase 3 screen) → first dictation moment (a guided hold-and-speak that ends with their words on the clipboard and a visible "now press ⌘V anywhere").

- Every permission step carries a quiet "Stuck? Copy this for your AI" affordance using the Phase 7 composer.
- Skippable at every step; whatever was skipped surfaces on the Home card, which is the resume path.
- All screens on `AppTheme` brand tokens, `applyAFFlowSkin()`, Fraunces never holds user or model content (Cyrillic rule).

### Phase 6 — Home: status card + language statement

1. Status-aware card per the settled decision. Health checks reuse the app's existing introspection (permission APIs, models on disk, Globe state).
2. The language statement — the niche claim, creative direction from Fable, Opus implements:
   - **Concept: one sentence that does the thing it claims.** A single dictated sentence rendered large, switching EN→RU mid-flow the way Andrew actually speaks, set in Inter (full Cyrillic), with the switch points marked by the pine `--signal` dot from the brand mark. Beneath it, one quiet line: *"English, Russian, and the way you actually mix them."*
   - Provocative-but-smart register: the provocation is the demonstration, not an insult to competitors. Candidate second line, RU surface: *«Код-свитчинг — это не баг».* Final copy chosen with Andrew at implementation.
   - A language joins the hero the day it passes verification, not before; leave the layout able to take a third without redesign.

### Phase 7 — The copy-to-AI composer

1. One composer, three call sites: onboarding stuck-moments, Home card, FAQ answers. Status-only fields per the settled decision, ending with clear instructions to the receiving AI ("walk this person through the fix; they are on macOS N; do not ask them to run Terminal commands unless they say they are comfortable").
2. The redaction guarantee is a test seen failing: plant a dictated string in every store the composer touches; the composed prompt must not contain it.

### Phase 8 — FAQ

EN + RU, bundled, native Help section. Fable's draft list (Andrew edits): what is this / why is it private / how do models work / why no auto-update and how to update / Globe key setup / permissions explained / why no Accessibility features (sandbox, honestly stated) / dictation not landing (clipboard model, ⌘V) / Russian quality tips / what the copy-to-AI button sends (verbatim transparency) / known limitations.

### Phase 9 — Claim audit and release

1. Re-run the 2026-08-25 publish-prep audit: every claim on every surface at the layer it can be verified; the missing upstream LICENSE resolved; README rewritten for the dictation-only scope with the language statement and a screenshot.
2. Version 1.0.0, tag, GitHub Release with the DMG, release notes.
3. Friends round: the release link plus one sentence — the onboarding must carry everything else. Their friction reports are the v1.0.x backlog.

## Edge cases

| Situation | What happens |
|---|---|
| Weak Mac (benchmark says only Starter is comfortable) | Full shown but discouraged with the estimated number; never hidden. |
| Helper offline / download fails / hash mismatch | App stays on Starter, says so plainly; retry in Settings; tampered bytes refused and removed. |
| User skips onboarding steps | Home card lists what is missing; each line deep-links back into the flow. |
| Globe key reclaimed by macOS later | Home card flags it with the fix link. |
| macOS revokes a permission after an update | Same card, same mechanism — the card is the single health surface. |
| User's AI gives wrong advice | Prompt includes ground truth (exact settings panes, exact states) to minimize it; FAQ is the human-readable fallback. |

## Hard rules (Andrew's, verbatim in spirit)

- The app **never** gets the network back. No exception for onboarding convenience.
- Everything visual follows `Context/brand-visual.md`; the language statement is on-brand, "provocative in a smart way."
- Claims never overstate: a language reaches the hero only once verified. ("Report at the layer of the claim.")
- Questions to Andrew as labelled options, recommended first. **Every phase gets one review, by a separate Claude agent running `/code-review`** (changed 2026-09-08; it was Codex). Tests before code; every guarantee seen failing.

## Open (named, with owners)

1. **Full-tier speech model for Russian** — STATE.md records turbo-954 failing Russian language ID. Opus benches large-v3 vs alternatives on Andrew's RU fixtures during Phase 3; Andrew ratifies the pairing.
2. **Speech-model hash pinning** — WhisperKit/FluidAudio fetch by name today, no pinned hashes. The helper must not ship unpinned downloads; Opus establishes pins during Phase 4.
3. **Helper bundle id vs the LuLu family checker** — `lulu-rule-check.py` (2026-08-29) enforces *no rule for the family*. A family-id helper that legitimately uses the network will earn a LuLu rule on Andrew's Mac and trip the checker. Decide: helper id outside the family, or amend the checker to allow exactly one scoped rule for exactly the helper id. Andrew decides on Opus's written trade-off, Phase 4.
4. **Helper write path** — app group container vs non-sandboxed helper. Opus decides and documents, Phase 4.
5. **Apple Developer purchase** — Andrew, before Phase 1's signing steps. Build and everything else proceed without it.
6. **Verification data for a third language** — Andrew records ground truth; gates the hero claim, not the launch.
7. **FAQ final copy** — Fable's list above; Andrew edits during Phase 8.
