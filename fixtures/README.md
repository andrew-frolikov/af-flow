# Fixtures: recorded once, scored many times

Created 2026-07-20 at C2 start, because the C1 demo audio was not retained and nothing could be re-scored.

## What this directory is for

C2 has to choose between four ASR models on Russian. Without paired audio and reference text that choice is an impression formed from hearing each model once, which cannot be re-checked when C3 changes the cleanup prompt underneath it. LOOP.md Tier C exists to make it a measurement instead.

Recorded once by Andrew, reused for every scoring run for the rest of the project.

## What is tracked and what is not

**Not tracked:** the audio. `.gitignore` excludes `*.wav` and `*.m4a` globally, and the scripts contain personal detail.

**Tracked:** this file, the reference texts, and `manifest.json` (per clip: SHA256, duration, sample rate, date, script id). Any manifest hash change invalidates every prior score and is a human gate, per LOOP.md.

## The reference texts include the fillers, deliberately

This is the distinction that makes the scores mean anything.

`*.reference.txt` holds what Andrew actually says out loud, fillers and all (эээ, ну, значит). It is **not** the desired final output.

- **ASR is scored against the reference verbatim.** A model that drops "эээ" is not being accurate, it is guessing at intent. We want to know which model hears the words correctly, including the ones we will throw away later.
- **Cleanup removes the fillers, and that is C3's job, scored separately.** TESTS.md's PASS criteria (fillers gone, Shaw stays Latin) describe end-to-end output, not raw transcription.

Conflating these two would let a model with sloppy transcription and aggressive cleanup score better than an accurate one, which is exactly backwards for a chunk whose job is picking the transcription engine.

## What gets scored

Four candidates, all already in `SpeechModelCatalog`:

| Model | Size | Backend | On disk yet |
|---|---|---|---|
| `openai_whisper-large-v3-v20240930_turbo_632MB` | 624 MB | WhisperKit | yes, current default |
| `openai_whisper-large-v3_turbo_954MB` | 954 MB | WhisperKit | no |
| Parakeet v3 | about 1.4 GB | FluidAudio | no |
| Qwen3-ASR 0.6B int8 | about 900 MB | FluidAudio | no |

Metrics per clip per model: WER, CER, detected language, and wall-clock transcription time. The last one feeds the latency actuals table in PROGRESS.md, which is still empty.

Three of the four need downloading. Each download is what will make LuLu prompt with a real hostname, which is how the last C0 waiver closes.
