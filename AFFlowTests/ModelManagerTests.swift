import XCTest
import Combine
import WhisperKit
@testable import AFFlow

@MainActor
final class ModelManagerTests: XCTestCase {
    // MARK: - Loading offline (2026-09-10)

    private func temporaryModelsRoot() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("afflow-models-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("whisper-models/models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return root
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func writeFile(_ text: String, to url: URL) throws {
        try makeDirectory(url.deletingLastPathComponent())
        try Data(text.utf8).write(to: url)
    }

    /// **The configuration behind 14 failed cold starts and no successes from
    /// 2026-08-29.** `download: true` without a `modelFolder` sends WhisperKit to
    /// Hugging Face on every load, whether or not the files are present.
    ///
    /// **The real guard is `modelFolder`.** WhisperKit's `setupModels` uses a
    /// given folder and then ignores `download` entirely. A mutation that restored
    /// only `download: true` left the real Starter load passing, which is how that
    /// was found. `download: false` stays as belt and braces for a lost folder.
    func testTheOfflineConfigHandsWhisperKitTheCoreMLFolderAndNeverDownloads() throws {
        let root = try temporaryModelsRoot()
        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "openai_whisper-small"))
        let folder = ModelManager.coreMLFolder(for: model, underModelsRoot: root)
        let base = root.deletingLastPathComponent()

        let config = ModelManager.offlineWhisperKitConfig(modelName: model.name, modelFolder: folder, downloadBase: base)

        XCTAssertEqual(config.modelFolder, folder.path, "modelFolder is what makes WhisperKit read the files on disk; it overrides download.")
        XCTAssertFalse(config.download, "Belt and braces: if the folder were ever lost, download: false still keeps the load off the network.")
        XCTAssertEqual(config.downloadBase, base, "The tokenizer resolves under downloadBase, at models/openai/<repo>.")
        XCTAssertEqual(config.load, true)
    }

    /// **The half of the first fix that was wrong.** `cachePathComponents` named
    /// the tokenizer folder for tiny, small and small.en, and WhisperKit looks for
    /// `MelSpectrogram.mlmodelc` directly inside the folder it is handed, so the
    /// Starter model the DMG ships could not load. Every WhisperKit model, not
    /// only turbo, loads from its Core ML folder.
    func testEveryWhisperKitModelIsLoadedFromItsCoreMLFolder() throws {
        let root = try temporaryModelsRoot()
        // The catalog's own list, so a model added later is covered without
        // anyone remembering to add it here.
        let whisperKitModels = SpeechModelCatalog.availableModels.filter { $0.backend == .whisperKit }
        XCTAssertFalse(whisperKitModels.isEmpty)
        for model in whisperKitModels {
            let name = model.name
            let expected = root.appendingPathComponent("argmaxinc/whisperkit-coreml/\(name)", isDirectory: true)
            XCTAssertEqual(
                ModelManager.coreMLFolder(for: model, underModelsRoot: root).standardizedFileURL.path,
                expected.standardizedFileURL.path,
                name
            )
        }
    }

    /// The app spells WhisperKit's tokenizer mapping itself, because the package's
    /// own is internal. The pins are what actually lands on disk, so the two may
    /// not disagree for any pinned model.
    func testTheTokenizerFolderIsWhereThePinnedTokenizerLands() throws {
        XCTAssertFalse(SpeechModelPins.files.isEmpty)
        for (name, pins) in SpeechModelPins.files {
            let model = try XCTUnwrap(SpeechModelCatalog.model(named: name), name)
            let repo = try XCTUnwrap(SpeechModelCatalog.tokenizerRepo(for: model), name)
            XCTAssertTrue(
                pins.contains { $0.relativePath == "whisper-models/models/\(repo)/tokenizer.json" },
                "\(name): no pinned tokenizer.json under \(repo)"
            )
        }
    }

    /// A model counts as installed only when BOTH of its folders hold what
    /// WhisperKit reads. The old check looked at one folder, so a model whose
    /// loader could never find its files reported itself installed.
    func testAModelIsInstalledOnlyWhenBothItsFoldersHoldWhatWhisperKitReads() throws {
        let root = try temporaryModelsRoot()
        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "openai_whisper-small"))
        let coreML = ModelManager.coreMLFolder(for: model, underModelsRoot: root)
        let tokenizer = try XCTUnwrap(ModelManager.tokenizerFolder(for: model, underModelsRoot: root))

        // Spelled out here, NOT read from `ModelManager.requiredTokenizerFiles`.
        // Looping over that constant made this test blind to its own subject: a
        // mutation dropping config.json from the constant also dropped it from the
        // loop, and the test stayed green. Seen on 2026-09-10.
        let tokenizerFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]
        for required in tokenizerFiles {
            try writeFile("{}", to: tokenizer.appendingPathComponent(required))
        }
        XCTAssertFalse(
            ModelManager.whisperKitFilesPresent(for: model, underModelsRoot: root),
            "A tokenizer with no Core ML models is the layout the old check accepted."
        )

        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try makeDirectory(coreML.appendingPathComponent("\(name).mlmodelc", isDirectory: true))
        }
        XCTAssertTrue(ModelManager.whisperKitFilesPresent(for: model, underModelsRoot: root))

        // Each required tokenizer file, removed on its own, must make the model
        // not installed: without any one of them WhisperKit reaches for the Hub.
        for required in tokenizerFiles {
            let url = tokenizer.appendingPathComponent(required)
            try FileManager.default.removeItem(at: url)
            XCTAssertFalse(
                ModelManager.whisperKitFilesPresent(for: model, underModelsRoot: root),
                "Without \(required) WhisperKit falls back to the Hub."
            )
            try writeFile("{}", to: url)
        }
        XCTAssertTrue(ModelManager.whisperKitFilesPresent(for: model, underModelsRoot: root))
    }

    /// WhisperKit resolves an `.mlpackage` through an inner path and does not
    /// compile it, so an uncompiled package must not count as installed.
    func testAnUncompiledPackageDoesNotCountAsInstalled() throws {
        let root = try temporaryModelsRoot()
        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "openai_whisper-small"))
        let coreML = ModelManager.coreMLFolder(for: model, underModelsRoot: root)
        let tokenizer = try XCTUnwrap(ModelManager.tokenizerFolder(for: model, underModelsRoot: root))
        for required in ModelManager.requiredTokenizerFiles {
            try writeFile("{}", to: tokenizer.appendingPathComponent(required))
        }
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try makeDirectory(coreML.appendingPathComponent("\(name).mlpackage", isDirectory: true))
        }
        XCTAssertFalse(ModelManager.whisperKitFilesPresent(for: model, underModelsRoot: root))
    }

    /// A truncated tokenizer file makes WhisperKit's local load throw, and it then
    /// falls back to the Hub, which surfaces as a hostname error. Refused first.
    func testADamagedTokenizerIsRefusedBeforeWhisperKitCanFallBackToTheHub() throws {
        let root = try temporaryModelsRoot()
        let folder = root.appendingPathComponent("openai/whisper-small", isDirectory: true)
        try writeFile("{\"model_type\": \"whisper\"}", to: folder.appendingPathComponent("config.json"))
        try writeFile("{\"model\": {}}", to: folder.appendingPathComponent("tokenizer.json"))
        try writeFile("{}", to: folder.appendingPathComponent("tokenizer_config.json"))
        XCTAssertTrue(ModelManager.tokenizerFilesParse(in: folder))

        try writeFile("{\"model\": {\"vocab", to: folder.appendingPathComponent("tokenizer.json"))
        XCTAssertFalse(ModelManager.tokenizerFilesParse(in: folder))

        try writeFile("{\"model\": {}}", to: folder.appendingPathComponent("tokenizer.json"))
        try writeFile("{\"model_type\": \"whis", to: folder.appendingPathComponent("config.json"))
        XCTAssertFalse(ModelManager.tokenizerFilesParse(in: folder), "A truncated config.json reaches the Hub too.")
    }

    /// A fresh install asks for turbo, which the DMG does not carry. A launch-type
    /// load uses the bundled Starter model instead, but only when no model was ever
    /// chosen. A saved choice is never overridden, even one that cannot load: that
    /// fails with its reason on screen.
    func testTheStarterFallbackOnlyFillsAChoiceThatWasNeverMade() {
        let turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
        XCTAssertEqual(
            QualityTier.launchSpeechModelID(preferred: turbo, hasSavedChoice: false, preferredIsLoadable: false, starterIsInstalled: true),
            QualityTier.starterSpeechModelID,
            "A friend's first launch: nothing chosen, turbo missing, Starter bundled."
        )
        XCTAssertEqual(
            QualityTier.launchSpeechModelID(preferred: turbo, hasSavedChoice: true, preferredIsLoadable: false, starterIsInstalled: true),
            turbo,
            "A saved choice that cannot load is kept, and its load reports why."
        )
        XCTAssertEqual(
            QualityTier.launchSpeechModelID(preferred: turbo, hasSavedChoice: true, preferredIsLoadable: true, starterIsInstalled: true),
            turbo,
            "Andrew's Mac: turbo chosen and present."
        )
        XCTAssertEqual(
            QualityTier.launchSpeechModelID(preferred: turbo, hasSavedChoice: false, preferredIsLoadable: false, starterIsInstalled: false),
            turbo,
            "Nothing to fall back to: keep the default and let the load report it."
        )
    }

    /// **The claim that matters for a friend's Mac, run for real.** Loads the
    /// Starter model the DMG ships through the real load path, from the test
    /// host's own container. Gated, because it needs those files staged there
    /// first and takes a few seconds.
    func testTheStarterModelLoadsFromDiskThroughTheRealLoadPath() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AF_FLOW_STARTER_OFFLINE_LOAD"] == "1",
            "stage Starter whisper-small into the test host container, then run AF_FLOW_STARTER_OFFLINE_LOAD=1 scripts/run-tests.sh"
        )
        let starter = try XCTUnwrap(SpeechModelCatalog.model(named: QualityTier.starterSpeechModelID))
        XCTAssertTrue(
            ModelManager.whisperKitFilesPresent(for: starter),
            "Starter files are not staged in \(ModelManager.coreMLFolder(for: starter).path)"
        )

        let manager = ModelManager(modelName: starter.name)
        await manager.loadModel(name: starter.name)

        XCTAssertNil(manager.error, "load error: \(String(describing: manager.error))")
        XCTAssertEqual(manager.state, .ready)
    }

    func testModelManagerRetriesTimedOutSpeechModelLoadOnce() async {
        let timeoutError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )
        var attempts = 0
        let manager = ModelManager(
            modelName: "openai_whisper-small.en",
            modelLoadOverride: { _ in
                attempts += 1
                if attempts == 1 {
                    throw timeoutError
                }
            },
            loadRetryDelayOverride: {}
        )

        await manager.loadModel(name: "openai_whisper-small.en")

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(manager.state, .ready)
        XCTAssertNil(manager.error)
    }

    func testDeleteCachedModelNotifiesObserversForInventoryRefresh() throws {
        let manager = ModelManager(modelName: "openai_whisper-small.en")
        let expectation = expectation(description: "model manager publishes cache deletion")
        var cancellable: AnyCancellable? = manager.objectWillChange.sink {
            expectation.fulfill()
        }

        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "openai_whisper-tiny.en"))
        manager.deleteCachedModel(model)

        wait(for: [expectation], timeout: 1.0)
        withExtendedLifetime(cancellable) {}
        cancellable = nil
    }

    func testDeleteCachedCurrentModelResetsReadyState() async throws {
        let manager = ModelManager(
            modelName: "openai_whisper-small.en",
            modelLoadOverride: { _ in }
        )

        await manager.loadModel(name: "openai_whisper-small.en")
        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "openai_whisper-small.en"))

        manager.deleteCachedModel(model)

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.error)
    }

    func testRescueSingleSpeakerSpansUsesSpeechSegmentsWhenOnlyOneSpeakerIsDetected() {
        let originalSpans = [
            DiarizationSummary.Span(speakerID: "Speaker 0", startTime: 2.48, endTime: 4.24)
        ]
        let speechSegments = [
            DiarizationSummary.MergedSpan(startTime: 2.204, endTime: 4.5878125)
        ]

        let rescuedSpans = ModelManager.rescuedSingleSpeakerSpans(
            from: originalSpans,
            usingSpeechSegments: speechSegments
        )

        XCTAssertEqual(
            rescuedSpans,
            [
                DiarizationSummary.Span(
                    speakerID: "Speaker 0",
                    startTime: 2.204,
                    endTime: 4.5878125
                )
            ]
        )
    }

    func testRescueSingleSpeakerSpansKeepsOriginalSpansWhenMultipleSpeakersAreDetected() {
        let originalSpans = [
            DiarizationSummary.Span(speakerID: "Speaker 0", startTime: 0.4, endTime: 1.0),
            DiarizationSummary.Span(speakerID: "Speaker 1", startTime: 1.2, endTime: 1.8)
        ]
        let speechSegments = [
            DiarizationSummary.MergedSpan(startTime: 0.3, endTime: 1.9)
        ]

        let rescuedSpans = ModelManager.rescuedSingleSpeakerSpans(
            from: originalSpans,
            usingSpeechSegments: speechSegments
        )

        XCTAssertEqual(rescuedSpans, originalSpans)
    }

    func testRescueSingleSpeakerSpansKeepsOriginalSpansWhenNoSpeechSegmentsExist() {
        let originalSpans = [
            DiarizationSummary.Span(speakerID: "Speaker 0", startTime: 2.48, endTime: 4.24)
        ]

        let rescuedSpans = ModelManager.rescuedSingleSpeakerSpans(
            from: originalSpans,
            usingSpeechSegments: []
        )

        XCTAssertEqual(rescuedSpans, originalSpans)
    }

    func testSpeechAnalyzerLoadAndTranscriptionUseInjectedBackend() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        let backend = StubSpeechAnalyzerBackend(result: "AF Flow transcription")
        var requestedLanguages: [String?] = []
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { language in
                requestedLanguages.append(language)
                return backend
            }
        )

        await manager.loadModel(language: "es")
        let result = await manager.transcribe(audioBuffer: [0.25, -0.25])

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(requestedLanguages.count, 1)
        XCTAssertEqual(requestedLanguages[0], "es")
        XCTAssertEqual(result, "AF Flow transcription")
        XCTAssertEqual(backend.receivedAudioBuffers, [[0.25, -0.25]])
    }

    func testSpeechAnalyzerReloadsOnlyWhenPreparedLanguageChanges() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        var requestedLanguages: [String?] = []
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { language in
                requestedLanguages.append(language)
                return StubSpeechAnalyzerBackend(result: nil)
            }
        )

        await manager.loadModel(language: "en")
        await manager.loadModel(language: "en")
        await manager.loadModel(language: "es")

        XCTAssertEqual(requestedLanguages.count, 2)
        XCTAssertEqual(requestedLanguages[0], "en")
        XCTAssertEqual(requestedLanguages[1], "es")
        XCTAssertEqual(manager.state, .ready)
    }

    func testSpeechAnalyzerLoadFailureUsesExistingErrorState() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        struct AssetFailure: Error {}
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { _ in throw AssetFailure() }
        )

        await manager.loadModel(language: "es")

        XCTAssertEqual(manager.state, .error)
        XCTAssertNotNil(manager.error)
    }

    func testDeletingSystemManagedSpeechAnalyzerDoesNothing() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        let manager = ModelManager(
            modelName: SpeechModelCatalog.speechAnalyzer.id,
            speechAnalyzerBackendFactory: { _ in
                StubSpeechAnalyzerBackend(result: nil)
            }
        )
        await manager.loadModel()

        manager.deleteCachedModel(SpeechModelCatalog.speechAnalyzer)

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(manager.modelName, SpeechModelCatalog.speechAnalyzer.id)
    }
}

@MainActor
private final class StubSpeechAnalyzerBackend: SpeechAnalyzerTranscribing {
    let result: String?
    private(set) var receivedAudioBuffers: [[Float]] = []

    init(result: String?) {
        self.result = result
    }

    func transcribe(audioBuffer: [Float]) async throws -> String? {
        receivedAudioBuffers.append(audioBuffer)
        return result
    }
}
