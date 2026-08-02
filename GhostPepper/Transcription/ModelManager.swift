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
                domain: "GhostPepper.ModelManager",
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
                        domain: "GhostPepper.ModelManager",
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
                domain: "GhostPepper.ModelManager",
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
                let results: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: audioBuffer, decodeOptions: decodeOptions)
                let text = results
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = SpeechTranscriber.removeArtifacts(from: text)
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

    /// The languages AF Flow's v1 supports, and the only ones he dictates in.
    ///
    /// Ukrainian is deliberately absent: Andrew removed it from v1 on
    /// 2026-07-18 on measured evidence, and adding it here would reopen the
    /// three-way confusion this restriction exists to close.
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

    private func loadWhisperModel(named modelName: String) async throws {
        let modelsDir = Self.whisperModelsDirectory
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let needsDownload = !Self.modelIsCached(SpeechModelCatalog.model(named: modelName)!)
        if needsDownload {
            _ = try await WhisperKit.download(
                variant: modelName,
                downloadBase: modelsDir
            ) { progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = progress.fractionCompleted
                }
            }
            downloadProgress = nil
        }

        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: modelsDir,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
    }

    private func loadFluidAudioModel(_ model: SpeechModelDescriptor) async throws {
        guard let fluidAudioVariant = model.fluidAudioVariant else {
            throw NSError(
                domain: "GhostPepper.ModelManager",
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
                domain: "GhostPepper.ModelManager",
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
                domain: "GhostPepper.ModelManager",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Missing FluidAudio variant for \(model.name)"]
            )
        }

        let qwenVariant: Qwen3AsrVariant
        switch fluidAudioVariant {
        case .qwen3AsrInt8: qwenVariant = .int8
        case .parakeetV3:
            throw NSError(
                domain: "GhostPepper.ModelManager",
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
            let modelPath = model.cachePathComponents.reduce(whisperModelsRootDirectory) { partialURL, component in
                partialURL.appendingPathComponent(component, isDirectory: true)
            }
            try? FileManager.default.removeItem(at: modelPath)
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
            let modelPath = model.cachePathComponents.reduce(whisperModelsRootDirectory) { partialURL, component in
                partialURL.appendingPathComponent(component, isDirectory: true)
            }
            return FileManager.default.fileExists(atPath: modelPath.path)
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

    private static var whisperModelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GhostPepper/whisper-models", isDirectory: true)
    }

    private static var whisperModelsRootDirectory: URL {
        whisperModelsDirectory.appendingPathComponent("models", isDirectory: true)
    }
}

/// Possible states for ModelManager.
enum ModelManagerState: Equatable {
    case idle
    case loading
    case ready
    case error
}
