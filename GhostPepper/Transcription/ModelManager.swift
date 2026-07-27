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

    func transcribe(audioBuffer: [Float], language: String? = nil) async -> String? {
        guard !audioBuffer.isEmpty else { return nil }
        guard let model = SpeechModelCatalog.model(named: modelName) else { return nil }

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
                    // So detection runs explicitly, the answer is constrained to
                    // en and ru, and the decision is logged with both
                    // probabilities. This costs no extra work: passing an
                    // explicit language makes WhisperKit skip the detection pass
                    // it would otherwise run itself.
                    if let detected = await detectRestrictedLanguage(audioBuffer: audioBuffer) {
                        decodeOptions.language = detected
                    } else {
                        decodeOptions.detectLanguage = true
                    }
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

    /// Picks between English and Russian from Whisper's language probabilities.
    ///
    /// Pure and static so it can be tested without a model, which matters: this
    /// sits directly on the path of every word he dictates.
    static func chooseLanguage(from probabilities: [String: Float]) -> String? {
        let english = probabilities["en"] ?? 0
        let russian = probabilities["ru"] ?? 0
        guard english > 0 || russian > 0 else { return nil }
        return english * englishPrior >= russian * russianPrior ? "en" : "ru"
    }

    private func detectRestrictedLanguage(audioBuffer: [Float]) async -> String? {
        guard let whisperKit else { return nil }
        do {
            let detection = try await whisperKit.detectLangauge(audioArray: audioBuffer)
            guard let chosen = Self.chooseLanguage(from: detection.langProbs) else {
                debugLogger?(
                    .model,
                    "Language detection returned neither en nor ru (raw: \(detection.language)). Falling back to Whisper's own detection."
                )
                return nil
            }
            let english = detection.langProbs["en"] ?? 0
            let russian = detection.langProbs["ru"] ?? 0
            // Logged on every dictation, including agreements, because the
            // failure this fixes is INVISIBLE in the output. A wrong choice
            // produces fluent, correct-looking text in the wrong language, so
            // the only place it can ever be caught is here.
            debugLogger?(
                .model,
                "Language chosen: \(chosen). whisper said \(detection.language), p(en)=\(english), p(ru)=\(russian)."
            )
            return chosen
        } catch {
            debugLogger?(
                .model,
                "Language detection failed (\(error.localizedDescription)). Falling back to Whisper's own detection."
            )
            return nil
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
            return SlidingWindowRecordingTranscriptionSession(
                models: fluidAudioModels,
                fullBufferTranscription: { audioBuffer in
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

    func transcribeWithSpeakerTagging(audioBuffer: [Float]) async -> SpeakerTaggedTranscriptionResult? {
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
                await self?.transcribe(audioBuffer: filteredAudio)
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
