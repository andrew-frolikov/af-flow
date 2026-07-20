# Fixtures: recorded once, scored many times

Created 2026-07-20 at C2 start, because the C1 demo audio was not retained and nothing could be re-scored.

## What this directory is for

C2 has to choose between four ASR models on Russian. Without paired audio and reference text, that choice is an impression formed from hearing each model once, which cannot be re-checked when C3 changes the cleanup prompt underneath it. LOOP.md Tier C exists to make it a measurement instead.

Recorded once by Andrew, reused for every scoring run for the rest of the project.

## The fixtures are Andrew's real speech, not a script

Decided by Andrew on 2026-07-20, and the reason is worth stating because it was nearly the other way.

The first plan was to have him read TESTS.md's T2 and T5 aloud. Those scripts turned out to have been **written by an agent** in the initial workspace-setup commit `bf50e10`, while LOOP.md claimed they were "written in Andrew's own voice". They were not. He caught the smell and asked directly whether anything had been faked.

A scripted read of invented sentences is a perfectly valid way to rank models on raw transcription accuracy, because scoring only needs a fixed reference text and any fixed text supplies one. What it cannot do is test his **register**, and his register is the entire premise of the voice layer: Slavic-influenced word order, and English technical vocabulary dropped into Russian sentences. Invented sentences test neither, so a model could win on the script and lose on his actual speech.

So the fixtures are unscripted. He speaks as he normally would, and the reference text is built by correcting the transcript rather than by writing the words first.

## How a fixture is made

1. **Record.** QuickTime Player, File, New Audio Recording. Speak naturally for roughly 40 seconds, real thoughts, no script. Save into this directory, for example `ru-real-1.m4a`.
2. **Draft.** Run the scorer. Any audio here without a matching `*.reference.txt` gets transcribed with the current default model and written out as `<stem>.draft-reference.txt`.
3. **Correct.** Andrew edits that draft into exactly what he actually said, including fillers, then renames it to `<stem>.reference.txt`.
4. **Score.** Run the scorer again. Now every model is measured against it.

Step 3 is the human gate, and it is the step that makes the number mean anything. A reference produced by a model and never corrected would measure agreement with that model, not accuracy.

## The reference text includes the fillers, deliberately

This is the distinction that makes the scores mean anything.

The reference holds what Andrew actually said, fillers and all. It is **not** the desired final output.

- **ASR is scored against the reference verbatim.** A model that drops a filler is not being accurate, it is guessing at intent. We want to know which model hears the words correctly, including the ones we will throw away later.
- **Cleanup removes the fillers, and that is C3's job, scored separately.** TESTS.md's PASS criteria describe end-to-end output, not raw transcription.

Conflating the two would let a model with sloppy transcription and aggressive cleanup outscore an accurate one, which is exactly backwards for a chunk whose job is picking the transcription engine.

## What is tracked and what is not

**Not tracked:** the audio, and the reference text. `.gitignore` excludes `*.wav` and `*.m4a` globally, and both the recordings and their transcripts are Andrew's real unscripted speech, so they stay local.

**Tracked:** this file, and eventually a manifest holding per clip a SHA256, duration, sample rate and date. Any manifest hash change invalidates every prior score and is a human gate, per LOOP.md.

## What gets scored

Four candidates, all already in `SpeechModelCatalog`:

| Model | Size | Backend | On disk |
|---|---|---|---|
| `openai_whisper-large-v3-v20240930_turbo_632MB` | 624 MB | WhisperKit | yes, current default |
| `openai_whisper-large-v3_turbo_954MB` | 954 MB | WhisperKit | no |
| Parakeet v3 | about 1.4 GB | FluidAudio | no |
| Qwen3-ASR 0.6B int8 | about 900 MB | FluidAudio | no |

Metrics per clip per model: WER, CER, punctuation error rate, sentence-boundary direction, Latin-term preservation, and wall-clock time. The last one feeds the latency actuals table in PROGRESS.md, which is still empty.

Three of the four need downloading, and each download is what makes LuLu prompt with a real hostname. That prompt is what closes the last C0 waiver.
