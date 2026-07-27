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
