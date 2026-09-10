import Foundation
import FluidAudio
import WhisperKit

/// Manages local speech model lifecycle: download, load, and readiness state.
@MainActor
final class ModelManager: ObservableObject {
    typealias ModelLoadOverride = @MainActor (SpeechModelDescriptor) async throws -> Void
    typealias RetryDelayOverride = @MainActor () async -> Void
    typealias SpeechAnalyzerBackendFactory = @MainActor (
        _ language: String?
    ) async throws -> any SpeechAnalyzerTranscribing

    private(set) var whisperKit: WhisperKit?
    private var fluidAudioManager: AsrManager?
    private var fluidAudioModels: AsrModels?
    private var sortformerModels: SortformerModels?
    private var diarizerManager: DiarizerManager?
    /// Stored as `Any?` because `Qwen3AsrManager` is `@available(macOS 15, *)`
    /// and the app deploys to macOS 14. Cast at use sites under `#available`.
    private var qwen3AsrManagerStorage: Any?
    private var speechAnalyzerBackend: (any SpeechAnalyzerTranscribing)?
    private var loadedSpeechAnalyzerLanguage: String?

    @Published private(set) var state: ModelManagerState = .idle
    @Published private(set) var downloadProgress: Double?
    private(set) var modelName: String
    @Published private(set) var error: Error?

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    var isReady: Bool {
        state == .ready
    }

    static let availableModels = SpeechModelCatalog.availableModels
    private static let retryDelayNanoseconds: UInt64 = 500_000_000

    var cachedModelNames: Set<String> {
        Self.availableModels.reduce(into: Set<String>()) { names, model in
            if Self.modelIsCached(model) {
                names.insert(model.name)
            }
        }
    }

    private let modelLoadOverride: ModelLoadOverride?
    private let loadRetryDelayOverride: RetryDelayOverride?
    private let speechAnalyzerBackendFactory: SpeechAnalyzerBackendFactory?
    private var queuedLoadRequest: (name: String, language: String?)?
    private var queuedLoadWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        modelName: String = SpeechModelCatalog.defaultModelID,
        modelLoadOverride: ModelLoadOverride? = nil,
        loadRetryDelayOverride: RetryDelayOverride? = nil,
        speechAnalyzerBackendFactory: SpeechAnalyzerBackendFactory? = nil
    ) {
        self.modelName = modelName
        self.modelLoadOverride = modelLoadOverride
        self.loadRetryDelayOverride = loadRetryDelayOverride
        self.speechAnalyzerBackendFactory = speechAnalyzerBackendFactory
    }

    func loadModel(name: String? = nil, language: String? = nil) async {
        let requestedName = name ?? modelName
        guard let requestedModel = SpeechModelCatalog.model(named: requestedName) else {
            let missingModelError = NSError(
                domain: "AFFlow.ModelManager",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Unknown speech model \(requestedName)"]
            )
            error = missingModelError
            state = .error
            return
        }

        if state == .loading {
            queuedLoadRequest = (requestedName, language)
            await withCheckedContinuation { continuation in
                queuedLoadWaiters.append(continuation)
            }
            return
        }

        let speechAnalyzerLanguageChanged = requestedModel.backend == .speechAnalyzer
            && speechAnalyzerBackend != nil
            && loadedSpeechAnalyzerLanguage != language
        if state == .ready && (requestedName != modelName || speechAnalyzerLanguageChanged) {
            resetLoadedModels()
        } else if state == .ready {
            return
        }
        modelName = requestedName

        guard state == .idle || state == .error else { return }

        state = .loading
        error = nil
        debugLogger?(.model, "Loading speech model \(modelName).")

        do {
            do {
                try await loadRequestedModel(requestedModel, language: language)
            } catch {
                guard Self.isRetryableLoadError(error) else {
                    throw error
                }

                debugLogger?(.model, "Speech model \(modelName) load timed out. Retrying once.")
                clearLoadedModelInstances()
                await retryLoadDelay()
                try await loadRequestedModel(requestedModel, language: language)
            }
            self.state = .ready
            debugLogger?(.model, "Speech model \(modelName) loaded successfully.")
        } catch {
            self.error = error
            self.state = .error
            debugLogger?(.model, "Speech model \(modelName) failed to load: \(error.localizedDescription)")
        }

        guard let queuedLoadRequest else { return }
        self.queuedLoadRequest = nil
        await loadModel(name: queuedLoadRequest.name, language: queuedLoadRequest.language)

        let waiters = queuedLoadWaiters
        queuedLoadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func loadRequestedModel(
        _ requestedModel: SpeechModelDescriptor,
        language: String?
    ) async throws {
        if let modelLoadOverride {
            try await modelLoadOverride(requestedModel)
            return
        }

        switch requestedModel.backend {
        case .whisperKit:
            try await loadWhisperModel(named: requestedModel.name)
        case .fluidAudio:
            switch requestedModel.fluidAudioVariant {
            case .qwen3AsrInt8:
                if #available(macOS 15, iOS 18, *) {
                    try await loadQwen3AsrModel(requestedModel)
                } else {
                    throw NSError(
                        domain: "AFFlow.ModelManager",
                        code: 501,
                        userInfo: [NSLocalizedDescriptionKey: "Qwen3-ASR requires macOS 15 or later."]
                    )
                }
            case .parakeetV3, .none:
                try await loadFluidAudioModel(requestedModel)
            }
        case .speechAnalyzer:
            try await loadSpeechAnalyzer(language: language)
        }
    }

    private func loadSpeechAnalyzer(language: String?) async throws {
        let backend: any SpeechAnalyzerTranscribing
        if let speechAnalyzerBackendFactory {
            backend = try await speechAnalyzerBackendFactory(language)
        } else if #available(macOS 26.0, *) {
            backend = try await AppleSpeechAnalyzerBackend.prepare(
                languageCode: language,
                progressHandler: { [weak self] progress in
                    self?.downloadProgress = progress
                }
            )
        } else {
            throw NSError(
                domain: "AFFlow.ModelManager",
                code: 501,
                userInfo: [NSLocalizedDescriptionKey: "Apple SpeechAnalyzer requires macOS 26 or later."]
            )
        }

        speechAnalyzerBackend = backend
        loadedSpeechAnalyzerLanguage = language
        downloadProgress = nil
    }

    /// Serialises transcription across the buffer-at-a-time routes to the model.
    ///
    /// It sits HERE rather than in `SpeechTranscriber` because speaker-filtered
    /// dictation and post-meeting speaker tagging reach inference without
    /// passing through that type. Guarding the wrapper left them free to overlap
    /// a push-to-talk transcription on the same model.
    ///
    /// **What it does NOT cover, stated because the first version of this
    /// comment claimed "every route by construction" and that was false.** The
    /// streaming sessions from `makeRecordingTranscriptionSession()` drive their
    /// own `SlidingWindowAsrManager` or `Qwen3AsrManager` over shared models for
    /// the life of a recording, and a per-buffer slot is the wrong shape for
    /// them. `fullBufferTranscription` is routed through here; the streaming
    /// halves are not. Those paths are live only for FluidAudio and Qwen speech
    /// models, and Andrew currently runs WhisperKit turbo, so this is a gap
    /// rather than a daily defect. Ledger item: give a streaming session the
    /// slot for its lifetime, or give it its own arbiter.
    let transcriptionScheduler = TranscriptionScheduler()

    /// Below this RMS the buffer is treated as silence. Roughly the noise floor.
    nonisolated static let silenceRMSThreshold: Float = 0.001

    /// How many seconds of the buffer actually carry speech.
    ///
    /// Frame-wise rather than whole-buffer RMS, because a meeting channel is a
    /// mixture: loud where its speaker talks and near-zero where the other one
    /// does. Averaging across the whole thing hides that structure, and hiding
    /// it is what made `looksTruncated` fire 202 times without ever being right.
    ///
    /// The threshold is the same noise floor `isEffectivelySilent` uses, so the
    /// two agree about what silence is.
    /// Whether the truncation rate is judged against voiced time rather than
    /// wall-clock. Only meeting and other background work, never dictation.
    nonisolated static func usesSpeechDurationForTruncation(_ priority: SpeechTranscriber.Priority) -> Bool {
        switch priority {
        case .dictation: return false
        case .background: return true
        }
    }

    nonisolated static func speechDuration(of samples: [Float], sampleRate: Double = 16_000) -> TimeInterval {
        let frameLength = max(1, Int(sampleRate * 0.02))
        guard samples.count >= frameLength else { return 0 }

        var voicedFrames = 0
        var index = 0
        while index + frameLength <= samples.count {
            var sumOfSquares: Float = 0
            for offset in index..<(index + frameLength) {
                let sample = samples[offset]
                sumOfSquares += sample * sample
            }
            if (sumOfSquares / Float(frameLength)).squareRoot() >= silenceRMSThreshold {
                voicedFrames += 1
            }
            index += frameLength
        }

        return Double(voicedFrames) * Double(frameLength) / sampleRate
    }

    nonisolated static func isEffectivelySilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(samples.count)).squareRoot() < silenceRMSThreshold
    }

    func transcribe(
        audioBuffer: [Float],
        language: String? = nil,
        priority: SpeechTranscriber.Priority = .dictation
    ) async -> String? {
        guard !audioBuffer.isEmpty else { return nil }

        // Silence never reaches the model, on ANY path.
        //
        // Whisper does not return nothing for silence, it INVENTS, and its
        // favourite inventions are "Thank you." and "Thanks for watching!",
        // because that is how the videos it was trained on end. Andrew reported
        // seeing "Thank you" appear repeatedly, in his dictation as well as in a
        // meeting recording made alone where nobody else spoke.
        //
        // The gate lives HERE rather than in the meeting pipeline for the same
        // reason the scheduler does: every route to inference passes through
        // this function, and guarding one caller would leave the others
        // inventing text. Push-to-talk on a moment of silence is the common case
        // and it is his daily experience.
        //
        // The threshold is roughly the noise floor, far below real speech, so
        // this drops digital silence rather than quiet talking.
        guard !Self.isEffectivelySilent(audioBuffer) else {
            debugLogger?(.model, "Skipped transcription: the audio is silent, and Whisper invents words for silence.")
            return nil
        }

        guard let model = SpeechModelCatalog.model(named: modelName) else { return nil }

        await transcriptionScheduler.acquire(priority)
        defer { Task { [transcriptionScheduler] in await transcriptionScheduler.release() } }

        do {
            switch model.backend {
            case .whisperKit:
                guard let whisperKit else { return nil }
                var decodeOptions = DecodingOptions()
                if let language {
                    decodeOptions.language = language
                } else {
                    // AUTO-DETECT IS RESTRICTED TO THE TWO LANGUAGES HE SPEAKS.
                    //
                    // Reported 2026-07-27: "sometimes it translates whatever I'm
                    // saying. I notice that when I speak English sometimes it
                    // translates it into Russian. Looks correct in Russian, but
                    // there was no point to translate it."
                    //
                    // Nothing translates. Whisper DECODES IN THE LANGUAGE IT WAS
                    // TOLD, so a mis-detection does not garble the text, it
                    // renders his meaning fluently in the wrong language. That is
                    // why it looks correct and why he cannot catch it by reading.
                    //
                    // Unrestricted `detectLanguage` chooses among 99 languages
                    // when only two are possible. His own history shows the
                    // failure: 1220 dictations, 887 English, 332 Russian, and one
                    // Bulgarian. Every language but two is a pure loss.
                    //
                    // So detection runs explicitly and the answer is constrained to
                    // en and ru. This costs no extra work: passing an explicit
                    // language makes WhisperKit skip the detection pass it would
                    // otherwise run itself.
                    //
                    // THERE IS NO ELSE BRANCH ANY MORE, and that is the point.
                    // `decodeOptions.detectLanguage = true` was the door to all 99
                    // languages, and until 2026-08-02 every single dictation went
                    // through it, because the gate in front of it could never
                    // return a value. Andrew closed the door by decision on that
                    // date: en or ru, always.
                    decodeOptions.language = await detectRestrictedLanguage(audioBuffer: audioBuffer)
                }
                decodeOptions = Self.applyDictationChunking(to: decodeOptions)
                let results: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: audioBuffer, decodeOptions: decodeOptions)
                let text = results
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = SpeechTranscriber.removeArtifacts(from: text)
                // Say so when the result is implausibly short for the audio. The
                // 2026-08-05 loss was silent, and silence is what let it survive.
                let seconds = Double(audioBuffer.count) / 16_000
                // DICTATION KEEPS THE WALL-CLOCK DENOMINATOR. Codex, 2026-08-21:
                // the 5 chars/s threshold and the 10-second floor were calibrated
                // against whole dictation durations — his lost recording was 193
                // characters in 43.5 s (4.4/s, flagged) against a slowest healthy
                // 6.0/s. Dividing by voiced time instead would raise every rate
                // and let the case this guard exists for slip through: 80
                // characters from a 20 s dictation with 15 s voiced goes 4.0/s to
                // 5.3/s, and under 10 voiced seconds it is not judged at all.
                //
                // The speech denominator is for MEETING chunks, where a channel
                // is silent whenever the other person talks and the wall-clock
                // rate is meaningless.
                let speechSeconds = Self.usesSpeechDurationForTruncation(priority)
                    ? Self.speechDuration(of: audioBuffer)
                    : nil
                if SpeechTranscriber.looksTruncated(
                    text: cleaned,
                    audioDuration: seconds,
                    speechDuration: speechSeconds
                ) {
                    debugLogger?(
                        .model,
                        speechSeconds.map { speech in
                            String(
                                format: "TRUNCATION SUSPECTED: %.1fs of speech in %.1fs of audio produced only %d characters (%.1f per second of speech). His healthy range is 7 to 12 per second.",
                                speech, seconds, cleaned.count,
                                Double(cleaned.count) / max(speech, 0.001)
                            )
                        } ?? String(
                            format: "TRUNCATION SUSPECTED: %.1fs of audio produced only %d characters (%.1f/s). His healthy range is 7 to 12 per second.",
                            seconds, cleaned.count, Double(cleaned.count) / max(seconds, 0.001)
                        )
                    )
                }
                return cleaned.isEmpty ? nil : cleaned
            case .fluidAudio:
                switch model.fluidAudioVariant {
                case .qwen3AsrInt8:
                    if #available(macOS 15, iOS 18, *) {
                        guard let manager = qwen3AsrManagerStorage as? Qwen3AsrManager else { return nil }
                        let text: String = try await manager.transcribe(
                            audioSamples: audioBuffer,
                            language: nil as String?
                        )
                        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return cleaned.isEmpty ? nil : cleaned
                    }
                    return nil
                case .parakeetV3, .none:
                    guard let fluidAudioManager else { return nil }
                    let result = try await fluidAudioManager.transcribe(audioBuffer, source: .microphone)
                    let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return cleaned.isEmpty ? nil : cleaned
                }
            case .speechAnalyzer:
                guard let speechAnalyzerBackend else { return nil }
                return try await speechAnalyzerBackend.transcribe(audioBuffer: audioBuffer)
            }
        } catch {
            debugLogger?(.model, "Speech transcription failed for \(modelName): \(error.localizedDescription)")
            return nil
        }
    }

    /// The languages AUTO-DETECT is tuned and tested for.
    ///
    /// This is not the list of languages the app can transcribe. It is the list
    /// auto-detect will choose BETWEEN, kept to a verified pair because a wider
    /// candidate set reopens the Slavic confusion this restriction exists to
    /// close. Any other language, Ukrainian included, is dictated by selecting
    /// it in Settings, and that path is unrestricted.
    static let supportedAutoDetectLanguages = ["en", "ru"]

    /// His measured prior, from 1220 real dictations in the Wispr archive:
    /// 887 English against 332 Russian, roughly 2.7 to 1.
    ///
    /// It is applied because a prior is exactly what a detector lacks. Whisper
    /// scores a 3-second clip of accented English against Russian with no idea
    /// who is speaking; this project does know. Where the acoustic evidence is
    /// genuinely close, the answer that is right more than twice as often should
    /// win, and where it is not close the prior cannot overturn it.
    static let englishPrior: Float = 887
    static let russianPrior: Float = 332

    // `chooseLanguage(from:)` was deleted on 2026-08-02. It guarded on
    // `english > 0 || russian > 0`, which a log probability can never satisfy, so it
    // returned nil on every dictation he has ever made and the prior below never once
    // decided anything. It was dead code that six passing tests pinned as working.
    // `restrictedLanguage(probabilities:reportedLanguage:)` replaces it.

    /// Below this confidence a single-language detection is treated as no better
    /// than a guess, and his measured prior decides instead.
    static let lowConfidenceFloor: Float = 0.5

    /// Reads whichever shape WhisperKit hands back as a probability in 0 to 1.
    ///
    /// IT HANDS BACK LOG PROBABILITIES, and that is the whole bug. His live log on
    /// 2026-08-02 shows `p(en)=-0.00074`, `p(en)=-2.154`, `p(ru)=-0.293`, and a map
    /// with exactly one entry in it ("1 probabilities"). Across all 23 logged
    /// decisions: zero positive values, 23 negative, 23 absent.
    ///
    /// A present value of exactly zero is read as a log probability of 1.0, which is
    /// the only sensible reading when the map contains the winning language: a linear
    /// probability of zero would not be reported as the winner.
    static func normalisedProbability(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        if value > 1 { return 0 }   // not a probability at all; treat as no evidence
        return value > 0 ? value : exp(value)
    }

    /// Picks between the two languages he speaks. ALWAYS answers, never falls open.
    ///
    /// THE SAME DEFECT THROUGH A DIFFERENT DOOR, found on 2026-07-29. WhisperKit
    /// can return an EMPTY `langProbs` while `detection.language` holds the
    /// answer. Reading only the probabilities meant declining, and declining
    /// hands the decode back to unrestricted detection across 99 languages, which
    /// is the exact failure the restriction exists to prevent. His log:
    /// `Language detection returned neither en nor ru (raw: ru)`, and his Russian
    /// came back as Portuguese, Dutch, Afrikaans, Korean, Chinese, Greek and Urdu
    /// inside one paragraph.
    ///
    /// The probabilities still decide whenever they carry an answer, so the
    /// measured prior that fixed his accented English is untouched.
    ///
    /// Stated precisely, because the first version of this comment claimed the
    /// fallback runs only on an empty map and the code is broader than that: the
    /// reported language is consulted whenever the probabilities yield no answer
    /// for EITHER of his two languages. That covers the empty map WhisperKit
    /// returned on 2026-07-29 and also a map that scores only other languages. It
    /// is the behaviour worth having, since a map naming only Bulgarian is exactly
    /// as useless to him as an empty one, and it is still restricted to en and ru:
    /// this must not become a third door into the 99.
    /// Splits dictation audio on speech activity instead of fixed windows.
    ///
    /// **He lost half of a 43-second Russian dictation on 2026-08-05** and the
    /// app said nothing: language detection succeeded, transcription returned,
    /// 193 characters were pasted, and the audio held continuous speech from 0
    /// to 42 seconds at RMS 500-1100. His measured rate is 9 to 11 characters a
    /// second, so it should have been about 400. The text simply stopped
    /// mid-phrase, on "при самой легкой".
    ///
    /// Two hypotheses died first: not a token cap and not a Russian problem, as
    /// a 74.6-second Russian dictation the same evening came back whole. Rather
    /// than keep guessing at WhisperKit's sequential-window loop, his actual
    /// file was decoded under six option sets (`DecodeOptionsBakeOffTests`):
    ///
    ///     shipped default        193 chars
    ///     vad chunking           406 chars   <-- whole, ends on a full sentence
    ///     no prefill prompt      404 chars
    ///     word timestamps        193 chars
    ///     with timestamps        193 chars
    ///
    /// Then across all 39 of his recordings over five seconds, because a fix
    /// validated on the one file that motivated it is this project's signature
    /// mistake: **vad was better on 1 and worse on 0**, while turning the prefill
    /// prompt off was better on 1 and WORSE on another. So vad, and not prefill.
    ///
    /// It is rare — 1 in 39 — which is exactly why it survived: it costs half a
    /// dictation, at random, and reports success. `SpeechTranscriber` now also
    /// flags an implausibly short result so the next one is not silent either.
    nonisolated static func applyDictationChunking(to options: DecodingOptions) -> DecodingOptions {
        var updated = options
        updated.chunkingStrategy = .vad
        return updated
    }

    /// A census line describing WhisperKit's RAW return, before this app reads it.
    ///
    /// Observability item 2. Every other log line here records the app's
    /// INTERPRETATION ("whisper said en at 99.9%"), and an interpretation cannot
    /// disagree with the assumption that produced it. The language prior survived
    /// its whole life that way: the gate tested `english > 0`, WhisperKit emits
    /// LOG probabilities so every value is negative, `chooseLanguage` returned nil
    /// on every dictation Andrew ever made, and six tests agreed because they fed
    /// linear probabilities production has never produced. Nothing in the log said
    /// otherwise, because the log only ever said what the code believed.
    ///
    /// So this records shape, not meaning: every key, every value unmodified, the
    /// count, and how many values are positive. A script can then check the code's
    /// assumptions against what the runtime actually emits, which is a census
    /// rather than a test. Two facts that would have ended that bug in a day are
    /// both visible in one line of it: `n=1` and `positive=0`.
    ///
    /// Deterministic key order so successive lines diff cleanly. No transcript
    /// text goes in here, only language codes and scores, so it is not sensitive.
    nonisolated static func rawDetectionCensus(
        probabilities: [String: Float],
        reportedLanguage: String?
    ) -> String {
        let keys = probabilities.keys.sorted()
        let pairs = keys.map { key in
            "\"\(key)\":\(probabilities[key].map { String($0) } ?? "null")"
        }
        let positive = probabilities.values.filter { $0 > 0 }.count
        let reported = reportedLanguage.map { "\"\($0)\"" } ?? "null"
        // The reported winner not being present in the map is exactly the case
        // that made the prior unusable, so it is called out rather than inferred.
        let reportedIsScored = reportedLanguage.map { probabilities[$0] != nil } ?? false
        return "RAW detectLanguage {"
            + "\"language\":\(reported),"
            + "\"n\":\(probabilities.count),"
            + "\"positive\":\(positive),"
            + "\"reportedIsScored\":\(reportedIsScored),"
            + "\"probs\":{\(pairs.joined(separator: ","))}}"
    }

    static func restrictedLanguage(probabilities: [String: Float], reportedLanguage: String?) -> String {
        let english = probabilities["en"].map(normalisedProbability)
        let russian = probabilities["ru"].map(normalisedProbability)

        // Both scored: the measured prior weights them against each other. This is
        // the path the original code was written for, and the path WhisperKit does
        // not currently produce. It is kept because it is correct if it ever does.
        if let english, let russian {
            return english * englishPrior >= russian * russianPrior ? "en" : "ru"
        }

        // One scored, which is the real shape. Absence carries NO information here:
        // the map holds only the winner, so the other language being missing says
        // nothing about it. The only usable signal is which language won and how
        // sure it was, so the prior can act only as a tie-break on a weak detection.
        //
        // Said plainly because the old comment overclaimed: this does NOT rescue
        // confident mis-detections. His accented English scored as Russian at 98 per
        // cent would still come back Russian, and the fix for that is a better
        // detector or a force-language control, not a prior.
        if english != nil || russian != nil {
            // TRUST THE WINNER, because there is nothing to weigh it against.
            //
            // The first version of this applied the prior below a confidence floor, and
            // Codex showed that unsound: Russian at 0.40 becomes English even though the
            // absent English score might be 0.01, with the rest of the mass sitting on a
            // third language entirely. Absence is not a low score, it is no score, and
            // this comment said exactly that two paragraphs before contradicting itself.
            //
            // So the prior acts only where it has something to decide: an unsupported
            // winner, or no winner at all. It cannot rescue a confident mis-detection,
            // and pretending otherwise is what the deleted code did for a year.
            return english != nil ? "en" : "ru"
        }

        // Neither scored, so Whisper named a third language, or nothing at all.
        //
        // NEVER FALL OPEN. Andrew ratified this on 2026-08-02: en and ru are the only
        // possible answers, always. Handing the decode back to unrestricted detection
        // is what turned his English into Urdu on 2026-07-31 and his Russian into
        // seven languages in the 51-minute meeting. With no evidence about either of
        // his languages, his measured 887-to-332 prior decides, and English wins it.
        //
        // The cost, stated rather than hidden: a meeting participant genuinely
        // speaking a third language will now be decoded as English or Russian.
        if let reported = reportedLanguage?.lowercased(),
           supportedAutoDetectLanguages.contains(reported) {
            return reported
        }
        return englishPrior >= russianPrior ? "en" : "ru"
    }

    /// Always returns en or ru. There is no third answer and no fall-through, by
    /// Andrew's decision of 2026-08-02.
    private func detectRestrictedLanguage(audioBuffer: [Float]) async -> String {
        let priorDefault = Self.englishPrior >= Self.russianPrior ? "en" : "ru"
        guard let whisperKit else { return priorDefault }
        do {
            let detection = try await whisperKit.detectLangauge(audioArray: audioBuffer)
            // Logged BEFORE anything reads it, so the census records what the
            // runtime emitted and not what this app made of it. See
            // `rawDetectionCensus`.
            debugLogger?(
                .model,
                Self.rawDetectionCensus(
                    probabilities: detection.langProbs,
                    reportedLanguage: detection.language
                )
            )
            let chosen = Self.restrictedLanguage(
                probabilities: detection.langProbs,
                reportedLanguage: detection.language
            )
            // Logged on every dictation, including agreements, because the
            // failure this fixes is INVISIBLE in the output. A wrong choice
            // produces fluent, correct-looking text in the wrong language, so
            // the only place it can ever be caught is here.
            //
            // The confidence is logged as a real probability now, not as the raw
            // log value, because reading "-2.15" as "unconfident" is exactly the
            // step nobody took for the life of this bug.
            let named = detection.langProbs[detection.language].map {
                String(format: "%.1f%%", Self.normalisedProbability($0) * 100)
            } ?? "no score"
            let agrees = chosen == detection.language
            debugLogger?(
                .model,
                "Language chosen: \(chosen). whisper said \(detection.language) at \(named)\(agrees ? "" : ", OVERRULED by the en/ru restriction")."
            )
            return chosen
        } catch {
            debugLogger?(
                .model,
                "Language detection failed (\(error.localizedDescription)). Using \(priorDefault) from his measured prior rather than opening the decode to 99 languages."
            )
            return priorDefault
        }
    }

    func makeRecordingTranscriptionSession() -> RecordingTranscriptionSession? {
        guard let model = SpeechModelCatalog.model(named: modelName),
              model.backend == .fluidAudio else {
            return nil
        }

        switch model.fluidAudioVariant {
        case .qwen3AsrInt8:
            if #available(macOS 15, iOS 18, *),
               let manager = qwen3AsrManagerStorage as? Qwen3AsrManager {
                return QwenRecordingTranscriptionSession(asrManager: manager)
            }
            return nil
        case .parakeetV3, .none:
            guard let fluidAudioModels,
                  let fluidAudioManager else {
                return nil
            }
            let scheduler = transcriptionScheduler
            return SlidingWindowRecordingTranscriptionSession(
                models: fluidAudioModels,
                fullBufferTranscription: { audioBuffer in
                    // Routed through the arbiter like every other inference.
                    // This closure used to call the manager directly, so a live
                    // dictation on a FluidAudio model could overlap a scheduled
                    // meeting chunk against the same models.
                    await scheduler.acquire(.dictation)
                    defer { Task { await scheduler.release() } }
                    do {
                        let result = try await fluidAudioManager.transcribe(audioBuffer, source: .microphone)
                        let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return cleaned.isEmpty ? nil : cleaned
                    } catch {
                        return nil
                    }
                }
            )
        }
    }

    func makeRecordingSessionCoordinator() async -> RecordingSessionCoordinator? {
        guard let model = SpeechModelCatalog.model(named: modelName),
              model.backend == .fluidAudio else {
            return nil
        }

        do {
            let diarizerModels = try await loadSortformerModels()
            let diarizer = SortformerDiarizer()
            diarizer.initialize(models: diarizerModels)
            let session = FluidAudioSpeechSession { [weak self] audioBuffer in
                await self?.transcribe(audioBuffer: audioBuffer)
            }

            return RecordingSessionCoordinator(
                session: session,
                processAudioChunk: { samples in
                    do {
                        _ = try diarizer.process(samples: samples)
                    } catch {
                        self.debugLogger?(
                            .model,
                            "Speaker filtering diarization chunk failed: \(error.localizedDescription)"
                        )
                    }
                },
                finish: {
                    diarizer.timeline.finalize()
                    let segments = diarizer.timeline.speakers.values
                        .flatMap { $0.finalizedSegments }
                    return Self.diarizationSpans(from: segments)
                },
                cleanup: {
                    diarizer.cleanup()
                }
            )
        } catch {
            debugLogger?(.model, "Speaker filtering diarizer failed to load: \(error.localizedDescription)")
            return nil
        }
    }

    func transcribeWithSpeakerTagging(
        audioBuffer: [Float],
        priority: SpeechTranscriber.Priority = .dictation
    ) async -> SpeakerTaggedTranscriptionResult? {
        guard let model = SpeechModelCatalog.model(named: modelName),
              model.supportsSpeakerFiltering,
              audioBuffer.isEmpty == false else {
            return nil
        }

        do {
            let diarizerModels = try await loadSortformerModels()
            let diarizer = SortformerDiarizer()
            diarizer.initialize(models: diarizerModels)
            defer { diarizer.cleanup() }

            let session = FluidAudioSpeechSession { [weak self] filteredAudio in
                await self?.transcribe(audioBuffer: filteredAudio, priority: priority)
            }
            session.appendAudioChunk(audioBuffer)

            for audioChunk in Self.audioChunks(
                from: audioBuffer,
                maxCount: Self.speakerTaggingChunkSizeSamples
            ) {
                do {
                    _ = try diarizer.process(samples: audioChunk)
                } catch {
                    debugLogger?(
                        .model,
                        "Speaker tagging diarization chunk failed: \(error.localizedDescription)"
                    )
                }
            }

            diarizer.timeline.finalize()
            let segments = diarizer.timeline.speakers.values
                .flatMap { $0.finalizedSegments }
            let spans = await speakerTaggingSpans(
                from: Self.diarizationSpans(from: segments),
                audioBuffer: audioBuffer
            )
            let finalizationResult = await session.finalize(spans: spans)
            let speakerTaggedTranscript = await session.speakerTaggedTranscript(spans: spans)

            return SpeakerTaggedTranscriptionResult(
                filteredTranscript: finalizationResult.filteredTranscript,
                diarizationSummary: finalizationResult.summary,
                speakerTaggedTranscript: speakerTaggedTranscript
            )
        } catch {
            debugLogger?(.model, "Speaker tagging diarizer failed to load: \(error.localizedDescription)")
            return nil
        }
    }

    private func speakerTaggingSpans(
        from spans: [DiarizationSummary.Span],
        audioBuffer: [Float]
    ) async -> [DiarizationSummary.Span] {
        guard Self.singleDetectedSpeakerID(in: spans) != nil,
              let speechSegments = await singleSpeakerSpeechSegments(from: audioBuffer) else {
            return spans
        }

        let rescuedSpans = Self.rescuedSingleSpeakerSpans(
            from: spans,
            usingSpeechSegments: speechSegments
        )
        if rescuedSpans != spans {
            debugLogger?(.model, "Speaker tagging rescued single-speaker spans with VAD speech segments.")
        }
        return rescuedSpans
    }

    private func singleSpeakerSpeechSegments(
        from audioBuffer: [Float]
    ) async -> [DiarizationSummary.MergedSpan]? {
        guard audioBuffer.isEmpty == false else {
            return nil
        }

        do {
            let vadManager = try await VadManager()
            let speechSegments = try await vadManager.segmentSpeech(audioBuffer)
                .map { segment in
                    DiarizationSummary.MergedSpan(
                        startTime: segment.startTime,
                        endTime: segment.endTime
                    )
                }
                .filter { $0.duration > 0 }
            return speechSegments.isEmpty ? nil : speechSegments
        } catch {
            debugLogger?(.model, "Single-speaker VAD rescue failed: \(error.localizedDescription)")
            return nil
        }
    }

    func extractSpeakerEmbedding(from audioBuffer: [Float]) async throws -> [Float] {
        let diarizerManager = try await loadDiarizerManager()
        return try diarizerManager.extractSpeakerEmbedding(from: audioBuffer)
    }

    /// Loads a WhisperKit model from its files on this Mac.
    ///
    /// **Every cold start failed from 2026-08-29 to 2026-09-10: 14 failures and no
    /// successes, after 84 successful loads of turbo before it.** The app gave up
    /// its network entitlement on 2026-08-29 (762f11f) and this function still
    /// built its config with `download: true` and no `modelFolder`. WhisperKit's
    /// `setupModels` reads that as "fetch from Hugging Face", and
    /// `WhisperKit.download` begins with a remote file listing before it looks at
    /// the disk. A process started before that day kept dictating, and ledger 29
    /// took that uptime as proof offline loading worked.
    ///
    /// **The first fix was half right, and an independent review caught it the
    /// same day.** It handed WhisperKit `cachePathComponents`, which named the Core
    /// ML folder for turbo but the TOKENIZER folder for tiny, small and small.en.
    /// WhisperKit looks for `MelSpectrogram.mlmodelc` directly inside the folder it
    /// is given, so the Starter model the DMG ships still could not load. That
    /// field now names the Core ML folder for every WhisperKit model.
    ///
    /// So a model loads only when both of its folders hold what WhisperKit reads,
    /// and WhisperKit is handed the Core ML folder with `download: false`. The
    /// tokenizer resolves under `downloadBase`; with its required files present and
    /// parseable, it loads before WhisperKit would consult the Hub. NOT covered:
    /// files that parse as JSON but are not a valid tokenizer or config still make
    /// WhisperKit fall back to the Hub, where the kernel refuses it. Downloads
    /// belong to the XPC service, not yet wired for speech models (ledger 37).
    private func loadWhisperModel(named modelName: String) async throws {
        let modelsDir = Self.whisperModelsDirectory
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        guard let descriptor = SpeechModelCatalog.model(named: modelName) else {
            // Unreachable today: `loadModel` rejects an unknown id first. Kept so a
            // new caller gets an error rather than a crash.
            throw SpeechModelLoadError.notInCatalog(modelName: modelName)
        }
        guard Self.modelIsCached(descriptor) else {
            throw SpeechModelLoadError.notOnDisk(modelTitle: descriptor.statusName)
        }
        if let tokenizer = Self.tokenizerFolder(for: descriptor),
           !Self.tokenizerFilesParse(in: tokenizer) {
            throw SpeechModelLoadError.damaged(modelTitle: descriptor.statusName)
        }

        whisperKit = try await WhisperKit(Self.offlineWhisperKitConfig(
            modelName: modelName,
            modelFolder: Self.coreMLFolder(for: descriptor),
            downloadBase: modelsDir
        ))
    }

    /// The configuration for a model already on disk. Pure, so a test can hold
    /// it to `download == false` without loading a model.
    static func offlineWhisperKitConfig(modelName: String, modelFolder: URL, downloadBase: URL) -> WhisperKitConfig {
        WhisperKitConfig(
            model: modelName,
            downloadBase: downloadBase,
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
    }

    private func loadFluidAudioModel(_ model: SpeechModelDescriptor) async throws {
        guard let fluidAudioVariant = model.fluidAudioVariant else {
            throw NSError(
                domain: "AFFlow.ModelManager",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Missing FluidAudio variant for \(model.name)"]
            )
        }

        let version: AsrModelVersion
        switch fluidAudioVariant {
        case .parakeetV3:
            version = .v3
        case .qwen3AsrInt8:
            // Routed via loadQwen3AsrModel; should never reach here.
            throw NSError(
                domain: "AFFlow.ModelManager",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected variant for Parakeet loader"]
            )
        }

        let models = try await AsrModels.downloadAndLoad(version: version) { progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress.fractionCompleted
            }
        }
        downloadProgress = nil
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        fluidAudioModels = models
        fluidAudioManager = manager
    }

    @available(macOS 15, iOS 18, *)
    private func loadQwen3AsrModel(_ model: SpeechModelDescriptor) async throws {
        guard let fluidAudioVariant = model.fluidAudioVariant else {
            throw NSError(
                domain: "AFFlow.ModelManager",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Missing FluidAudio variant for \(model.name)"]
            )
        }

        let qwenVariant: Qwen3AsrVariant
        switch fluidAudioVariant {
        case .qwen3AsrInt8: qwenVariant = .int8
        case .parakeetV3:
            throw NSError(
                domain: "AFFlow.ModelManager",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected variant for Qwen3-ASR loader"]
            )
        }

        let directory = try await Qwen3AsrModels.download(variant: qwenVariant) { progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress.fractionCompleted
            }
        }
        downloadProgress = nil
        let manager = Qwen3AsrManager()
        try await manager.loadModels(from: directory)
        qwen3AsrManagerStorage = manager
    }

    private func resetLoadedModels() {
        clearLoadedModelInstances()
        state = .idle
    }

    private func clearLoadedModelInstances() {
        whisperKit = nil
        fluidAudioManager = nil
        fluidAudioModels = nil
        sortformerModels = nil
        qwen3AsrManagerStorage = nil
        speechAnalyzerBackend = nil
        loadedSpeechAnalyzerLanguage = nil
        downloadProgress = nil
    }

    private func retryLoadDelay() async {
        if let loadRetryDelayOverride {
            await loadRetryDelayOverride()
            return
        }

        try? await Task.sleep(nanoseconds: Self.retryDelayNanoseconds)
    }

    private func loadSortformerModels() async throws -> SortformerModels {
        if let sortformerModels {
            return sortformerModels
        }

        let models = try await SortformerModels.loadFromHuggingFace(config: .default)
        sortformerModels = models
        return models
    }

    private func loadDiarizerManager() async throws -> DiarizerManager {
        if let diarizerManager {
            return diarizerManager
        }

        let models = try await DiarizerModels.downloadIfNeeded()
        let diarizerManager = DiarizerManager()
        diarizerManager.initialize(models: models)
        self.diarizerManager = diarizerManager
        return diarizerManager
    }

    static func rescuedSingleSpeakerSpans(
        from spans: [DiarizationSummary.Span],
        usingSpeechSegments speechSegments: [DiarizationSummary.MergedSpan]
    ) -> [DiarizationSummary.Span] {
        guard let speakerID = singleDetectedSpeakerID(in: spans) else {
            return spans
        }

        let rescuedSpans = speechSegments
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.endTime < rhs.endTime
                }
                return lhs.startTime < rhs.startTime
            }
            .map { segment in
                DiarizationSummary.Span(
                    speakerID: speakerID,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            }
            .filter { $0.duration > 0 }

        return rescuedSpans.isEmpty ? spans : rescuedSpans
    }

    private static func diarizationSpans(from segments: [DiarizerSegment]) -> [DiarizationSummary.Span] {
        segments
            .map { segment in
                DiarizationSummary.Span(
                    speakerID: "Speaker \(segment.speakerIndex)",
                    startTime: TimeInterval(segment.startTime),
                    endTime: TimeInterval(segment.endTime)
                )
            }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.endTime < rhs.endTime
                }
                return lhs.startTime < rhs.startTime
            }
    }

    private static func singleDetectedSpeakerID(
        in spans: [DiarizationSummary.Span]
    ) -> String? {
        let speakerIDs = spans.reduce(into: [String]()) { orderedSpeakerIDs, span in
            if orderedSpeakerIDs.contains(span.speakerID) == false {
                orderedSpeakerIDs.append(span.speakerID)
            }
        }
        guard speakerIDs.count == 1 else {
            return nil
        }
        return speakerIDs.first
    }

    private static let speakerTaggingChunkSizeSamples = 16_000

    private static func audioChunks(from audioBuffer: [Float], maxCount: Int) -> [[Float]] {
        guard maxCount > 0, audioBuffer.isEmpty == false else {
            return []
        }

        var audioChunks: [[Float]] = []
        audioChunks.reserveCapacity((audioBuffer.count + maxCount - 1) / maxCount)

        var startIndex = 0
        while startIndex < audioBuffer.count {
            let endIndex = min(startIndex + maxCount, audioBuffer.count)
            audioChunks.append(Array(audioBuffer[startIndex..<endIndex]))
            startIndex = endIndex
        }

        return audioChunks
    }

    private static func isRetryableLoadError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return true
        }

        if nsError.localizedDescription.localizedCaseInsensitiveContains("timed out") {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isRetryableLoadError(underlyingError) {
            return true
        }

        return false
    }

    func deleteCachedModel(_ model: SpeechModelDescriptor) {
        guard model.isSystemManaged == false else {
            return
        }
        Self.removeCachedModelFiles(for: model)

        if model.name == modelName {
            clearLoadedModelInstances()
            state = .idle
            error = nil
            return
        }

        objectWillChange.send()
    }

    private static func removeCachedModelFiles(for model: SpeechModelDescriptor) {
        switch model.backend {
        case .whisperKit:
            // The Core ML folder only. The tokenizer under openai/<repo> is shared
            // (both turbo variants read whisper-large-v3), and removing the Core ML
            // folder is what makes `whisperKitFilesPresent` false.
            try? FileManager.default.removeItem(at: coreMLFolder(for: model))
        case .fluidAudio:
            guard let fluidAudioVariant = model.fluidAudioVariant else { return }
            switch fluidAudioVariant {
            case .parakeetV3:
                let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
                try? FileManager.default.removeItem(at: cacheDir)
            case .qwen3AsrInt8:
                break // Qwen3 cache cleanup handled by FluidAudio internally
            }
        case .speechAnalyzer:
            break
        }
    }

    static func isCached(_ model: SpeechModelDescriptor) -> Bool {
        modelIsCached(model)
    }

    private static func modelIsCached(_ model: SpeechModelDescriptor) -> Bool {
        switch model.backend {
        case .whisperKit:
            return whisperKitFilesPresent(for: model)
        case .fluidAudio:
            guard let fluidAudioVariant = model.fluidAudioVariant else {
                return false
            }
            switch fluidAudioVariant {
            case .parakeetV3:
                return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
            case .qwen3AsrInt8:
                if #available(macOS 15, iOS 18, *) {
                    return Qwen3AsrModels.modelsExist(at: Qwen3AsrModels.defaultCacheDirectory(variant: .int8))
                }
                return false
            }
        case .speechAnalyzer:
            return true
        }
    }

    /// Internal rather than private so `AppSupportPathOwnershipTests` can
    /// check where it points. It used to spell the folder itself, which is how
    /// the 2026-08-25 rename sent it to an empty directory while 2.0 GB of
    /// already downloaded speech models sat in the real one.
    static var whisperModelsDirectory: URL {
        AppSupportDirectory.url.appendingPathComponent("whisper-models", isDirectory: true)
    }

    private static var whisperModelsRootDirectory: URL {
        whisperModelsDirectory.appendingPathComponent("models", isDirectory: true)
    }

    /// The three questions below, asked of this Mac's own models folder. Plain
    /// overloads rather than default arguments, because a default argument is
    /// evaluated outside the main actor and cannot read the root.
    static func coreMLFolder(for model: SpeechModelDescriptor) -> URL {
        coreMLFolder(for: model, underModelsRoot: whisperModelsRootDirectory)
    }

    static func tokenizerFolder(for model: SpeechModelDescriptor) -> URL? {
        tokenizerFolder(for: model, underModelsRoot: whisperModelsRootDirectory)
    }

    static func whisperKitFilesPresent(for model: SpeechModelDescriptor) -> Bool {
        whisperKitFilesPresent(for: model, underModelsRoot: whisperModelsRootDirectory)
    }

    /// The folder WhisperKit loads a model from, `argmaxinc/whisperkit-coreml/<variant>`,
    /// read from the catalog's `cachePathComponents`. Load, the installed check and
    /// delete all use this, so the folder that was checked is the folder that loads.
    static func coreMLFolder(
        for model: SpeechModelDescriptor,
        underModelsRoot root: URL
    ) -> URL {
        model.cachePathComponents.reduce(root) { partialURL, component in
            partialURL.appendingPathComponent(component, isDirectory: true)
        }
    }

    /// The model's tokenizer folder, `openai/<repo>`, or nil when it has none.
    static func tokenizerFolder(
        for model: SpeechModelDescriptor,
        underModelsRoot root: URL
    ) -> URL? {
        SpeechModelCatalog.tokenizerRepo(for: model).map { repo in
            repo.split(separator: "/").reduce(root) { partialURL, component in
                partialURL.appendingPathComponent(String(component), isDirectory: true)
            }
        }
    }

    /// The three files WhisperKit's tokenizer load reads from `openai/<repo>`
    /// before it would consult the Hub. `config.json` carries the model type.
    /// `tokenizer_config.json` is optional to swift-transformers in general, but it
    /// bundles fallback configs only for gpt2 and t5, so for Whisper a missing one
    /// comes back empty and WhisperKit falls through to the Hub. `tokenizer.json`
    /// is the vocabulary.
    static let requiredTokenizerFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]

    /// Whether BOTH folders hold what WhisperKit reads: the three compiled Core ML
    /// models it looks up by name, and the tokenizer files above. Checking one
    /// folder is how a model that could never load offline reported itself
    /// installed. Compiled `.mlmodelc` only: WhisperKit resolves an `.mlpackage`
    /// through an inner path and does not compile it, so a package alone would
    /// report installed and then fail to load.
    static func whisperKitFilesPresent(
        for model: SpeechModelDescriptor,
        underModelsRoot root: URL
    ) -> Bool {
        let fileManager = FileManager.default
        let coreML = coreMLFolder(for: model, underModelsRoot: root)
        let modelsPresent = ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            fileManager.fileExists(atPath: coreML.appendingPathComponent("\(name).mlmodelc").path)
        }
        guard modelsPresent, let tokenizer = tokenizerFolder(for: model, underModelsRoot: root) else {
            return false
        }
        return requiredTokenizerFiles.allSatisfy { name in
            fileManager.fileExists(atPath: tokenizer.appendingPathComponent(name).path)
        }
    }

    /// Whether every required tokenizer file parses as JSON. A truncated file makes
    /// the local load throw, and WhisperKit then falls back to the Hub. Runs on the
    /// main actor once per load, over two to three megabytes of JSON; the cost is
    /// not measured (ledger 38).
    static func tokenizerFilesParse(in folder: URL) -> Bool {
        requiredTokenizerFiles.allSatisfy { name in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return false }
            return (try? JSONSerialization.jsonObject(with: data)) != nil
        }
    }
}

/// Why a speech model was refused before WhisperKit was ever asked.
///
/// Each case names the real problem on screen, using the model's display name.
/// Until 2026-09-10 a model that was not on disk reached WhisperKit's own
/// download, which a process with no network entitlement fails as a hostname
/// lookup: true, and no help at all.
enum SpeechModelLoadError: LocalizedError, Equatable {
    case notInCatalog(modelName: String)
    case notOnDisk(modelTitle: String)
    case damaged(modelTitle: String)

    var errorDescription: String? {
        switch self {
        case .notInCatalog(let modelName):
            return "\(modelName) is not a speech model this version of AF Flow knows."
        case .notOnDisk(let modelTitle):
            return "\(modelTitle) is not on this Mac, and AF Flow does not download speech models itself. Choose a model that is already installed."
        case .damaged(let modelTitle):
            return "\(modelTitle) is on this Mac, but its tokenizer files are damaged, so it cannot load."
        }
    }
}

/// Possible states for ModelManager.
enum ModelManagerState: Equatable {
    case idle
    case loading
    case ready
    case error
}
