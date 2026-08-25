import Foundation

/// Transcribes audio buffers using the currently selected speech backend.
///
/// Serializes transcription requests so only one runs at a time.
final class SpeechTranscriber {
    /// Who is asking, which decides who waits.
    ///
    /// Andrew chose on 2026-07-27 to keep push-to-talk working during a meeting.
    /// Both feed this one transcriber, so without an order his dictation would
    /// queue behind a 30-second meeting chunk and his text would arrive seconds
    /// late. Dictation is the thing he is watching; meeting chunks are not.
    enum Priority {
        /// Push-to-talk. He is waiting for this text right now.
        case dictation
        /// Meeting chunks and other background work.
        case background
    }

    private let modelManager: ModelManager

    /// Whether the underlying model is ready for transcription.
    @MainActor
    var isReady: Bool {
        modelManager.isReady
    }

    /// Whisper artifacts to filter out of transcription results.
    private static let artifacts: Set<String> = [
        "[BLANK_AUDIO]",
        "[NO_SPEECH]",
        "(blank audio)",
        "(no speech)",
        "[MUSIC]",
        "[APPLAUSE]",
        "[LAUGHTER]",
    ]

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    /// Removes Whisper hallucination artifacts like [BLANK_AUDIO] from text.
    /// Whether a transcript is implausibly short for the audio it came from.
    ///
    /// **The 2026-08-05 defect was not that half a dictation was lost. It was
    /// that nothing said so.** A 43.5-second recording of continuous speech
    /// returned 193 characters, the paste succeeded, and the log recorded a
    /// normal transcription. He found it by reading his own text and noticing
    /// words missing. `chunkingStrategy = .vad` fixes the known cause; this
    /// catches the next cause, whatever it turns out to be.
    ///
    /// The threshold is measured, not guessed. Across his archive on 2026-08-05
    /// his rate was 7.1 to 11.9 characters per second, in both languages, with
    /// the truncated one at 4.4 — the only outlier below 6. **5.0 sits between
    /// the failure at 4.4 and his slowest healthy recording at 6.0**, so it flags
    /// the real thing without crying wolf on a slow, thoughtful sentence.
    ///
    /// The margin is genuinely thin, 4.4 to 6.0, and the first version of this
    /// used 3.5 — which is below the FAILURE and would have caught nothing. The
    /// tests below carry his real pairs on both sides precisely so a threshold
    /// that flags nothing cannot pass as a working guard.
    ///
    /// Only audio over ten seconds is judged. Short utterances have too much
    /// variance: a two-second "yes" is 3 characters at 1.5 per second and
    /// perfectly correct.
    /// `speechDuration` is how much of the audio actually carries speech. Pass it
    /// whenever it is known; the rate is judged against it rather than against
    /// wall-clock.
    ///
    /// THE DENOMINATOR WAS WRONG FOR MEETINGS AND IT COST AN HOUR. Measured
    /// 2026-08-21: this guard had fired 202 times, 192 of them on 30.0-second
    /// meeting chunks, and every one was a false positive. Re-decoding all 16
    /// chunks of his 2026-08-19 Zoom gave 1,349 characters against the 1,338 the
    /// app stored on the day — nothing had been lost.
    ///
    /// A meeting is two channels and each is silent while the other person
    /// talks. `chunk-0-mic` held 7 seconds of speech in 30 seconds of audio and
    /// 110 characters of transcript: 3.7 per second of AUDIO, which looks like
    /// 85% loss, and 15.6 per second of SPEECH, which is faster than his healthy
    /// range. Only the silence made it look thin.
    ///
    /// A warning that is wrong 202 times out of 202 is worse than no warning,
    /// because it teaches the reader to skip the line that exists to catch real
    /// loss.
    static func looksTruncated(
        text: String,
        audioDuration: TimeInterval,
        speechDuration: TimeInterval? = nil
    ) -> Bool {
        // Unknown speech duration falls back to the audio, so callers that do
        // not measure it keep the 2026-08-05 protection.
        let judged = speechDuration ?? audioDuration

        // Below this there is not enough speech to infer a rate from at all.
        guard judged > 10 else { return false }

        let characters = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard characters > 0 else { return false }
        return Double(characters) / judged < 5.0
    }

    static func removeArtifacts(from text: String) -> String {
        var cleaned = text
        for artifact in artifacts {
            cleaned = cleaned.replacingOccurrences(of: artifact, with: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcribes a 16 kHz mono PCM float audio buffer into text.
    ///
    /// - Parameter audioBuffer: Array of Float samples at 16 kHz sample rate, mono.
    /// - Returns: The transcribed text, or nil if the buffer is empty,
    ///   the model is not ready, or transcription produced no output.
    func transcribe(
        audioBuffer: [Float],
        language: String? = nil,
        priority: Priority = .dictation
    ) async -> String? {
        guard !audioBuffer.isEmpty else { return nil }

        // Serialisation lives in `ModelManager.transcribe`, at the point where
        // inference actually happens, rather than here.
        //
        // It was here first, and the review found the hole: speaker-filtered
        // dictation and post-meeting speaker tagging reach the model WITHOUT
        // going through this type, so they could run concurrently against it
        // while a scheduled push-to-talk transcription was in flight. My test
        // passed anyway because it drove the scheduler directly rather than the
        // production path, which is the same defect as a guard nobody runs.
        //
        // Anchoring it to the inference call covers the buffer-at-a-time routes
        // without listing them. It does NOT cover the streaming sessions, which
        // hold their own ASR managers for a whole recording; see the note on
        // `ModelManager.transcriptionScheduler`.
        return await modelManager.transcribe(
            audioBuffer: audioBuffer,
            language: language,
            priority: priority
        )
    }
}

/// Runs one transcription at a time and lets dictation overtake background work.
///
/// The model is a single shared resource, so requests must serialise. What is
/// new is the ORDER: a waiting dictation is always served before any waiting
/// background chunk, so a meeting cannot push his push-to-talk latency out.
///
/// A dictation still waits for a background chunk that is already RUNNING,
/// because stopping one mid-inference is not free and, on the cleanup side, is
/// exactly the cancellation that aborts the process (ledger 27). The wait is
/// bounded by one chunk rather than by the queue behind it.
actor TranscriptionScheduler {
    private var isRunning = false
    private var dictationWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []
    private var consecutiveDictationHandovers = 0
    private let maxConsecutiveDictationHandovers = 3

    /// How many requests are queued, by priority.
    ///
    /// Exists so tests can wait until work is genuinely QUEUED before asserting
    /// the order. Codex caught that the first version used `Task.sleep` and
    /// could therefore pass on favourable scheduling even with the priority
    /// removed, which is the same defect as a canary that never runs.
    var queuedCounts: (dictation: Int, background: Int) {
        (dictationWaiters.count, backgroundWaiters.count)
    }

    func acquire(_ priority: SpeechTranscriber.Priority) async {
        if !isRunning {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            switch priority {
            case .dictation:
                dictationWaiters.append(continuation)
            case .background:
                backgroundWaiters.append(continuation)
            }
        }
    }

    func release() {
        // Strict priority would starve meeting chunks for as long as he keeps
        // dictating, and a meeting cannot then finish draining. Codex raised it;
        // the answer is aging rather than fairness, because dictation latency is
        // the thing he can feel.
        //
        // Every fourth handover goes to the oldest waiting background chunk if
        // one exists. Dictation still overtakes, it just cannot overtake
        // forever.
        if !backgroundWaiters.isEmpty, consecutiveDictationHandovers >= maxConsecutiveDictationHandovers {
            consecutiveDictationHandovers = 0
            backgroundWaiters.removeFirst().resume()
            return
        }

        if !dictationWaiters.isEmpty {
            consecutiveDictationHandovers += 1
            dictationWaiters.removeFirst().resume()
            return
        }

        if !backgroundWaiters.isEmpty {
            consecutiveDictationHandovers = 0
            backgroundWaiters.removeFirst().resume()
            return
        }

        consecutiveDictationHandovers = 0
        isRunning = false
    }
}
