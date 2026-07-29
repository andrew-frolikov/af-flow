import AVFAudio
import XCTest
@testable import GhostPepper

@MainActor
final class SpeechTranscriberTests: XCTestCase {

    func testSpeechModelCatalogIncludesModelsSupportedByTheCurrentOS() {
        let ids = SpeechModelCatalog.availableModels.map(\.id)
        let backends = SpeechModelCatalog.availableModels.map(\.backend)

        // Ordered list, deliberately literal rather than mirrored from
        // SpeechModelCatalog.baseModels: this array IS the picker order
        // rendered by ModelsSidebarView/SettingsWindow, so a silent reorder
        // (e.g. demoting the multilingual default below an English-only
        // model) is a real regression this test must be able to catch.
        var expectedIDs = [
            "openai_whisper-large-v3-v20240930_turbo_632MB",
            "openai_whisper-large-v3_turbo_954MB",
            "openai_whisper-tiny.en",
            "openai_whisper-small.en",
            "openai_whisper-small",
            "fluid_parakeet-v3",
        ]
        var expectedBackends: [SpeechBackendKind] = [
            .whisperKit,
            .whisperKit,
            .whisperKit,
            .whisperKit,
            .whisperKit,
            .fluidAudio,
        ]

        if #available(macOS 15, iOS 18, *) {
            expectedIDs.append("fluid_qwen3-asr-0.6b-int8")
            expectedBackends.append(.fluidAudio)
        }
        if #available(macOS 26, *) {
            expectedIDs.append("apple_speech-analyzer")
            expectedBackends.append(.speechAnalyzer)
        }

        XCTAssertEqual(ids, expectedIDs)
        XCTAssertEqual(backends, expectedBackends)

        // Hard literal pin, deliberately NOT `SpeechModelCatalog.defaultModelID`
        // (that would reduce to X == X and could never fail regardless of
        // what the default is). This is one of exactly two assertions in the
        // whole suite that pin the shipped default speech model; see the
        // sibling pin in testModelManagerDefaultModelName below. Changed from
        // "openai_whisper-small.en" on 2026-07-19: an English-only default
        // silently mangled roughly 27 percent of real (Russian) dictation
        // instead of erroring. Do not revert this literal to a ".en" model;
        // a deliberate future change to the default must edit it on purpose.
        XCTAssertEqual(SpeechModelCatalog.defaultModelID, "openai_whisper-large-v3-v20240930_turbo_632MB")
    }

    func testSpeechAnalyzerDescriptorIsSystemManagedAndDoesNotFilterSpeakers() {
        let model = SpeechModelCatalog.speechAnalyzer

        XCTAssertEqual(model.name, "apple_speech-analyzer")
        XCTAssertEqual(model.backend, .speechAnalyzer)
        XCTAssertEqual(model.pickerTitle, "Apple SpeechAnalyzer")
        XCTAssertEqual(model.variantName, "System model")
        XCTAssertEqual(model.sizeDescription, "Managed by macOS")
        XCTAssertEqual(model.cachePathComponents, [])
        XCTAssertNil(model.fluidAudioVariant)
        XCTAssertTrue(model.isSystemManaged)
        XCTAssertFalse(model.supportsSpeakerFiltering)
        XCTAssertEqual(model.automaticLanguageLabel, "System language")

        if #available(macOS 26, *) {
            XCTAssertEqual(
                SpeechModelCatalog.model(named: "apple_speech-analyzer"),
                model
            )
        } else {
            XCTAssertNil(SpeechModelCatalog.model(named: "apple_speech-analyzer"))
        }

        XCTAssertEqual(
            SpeechModelCatalog.whisperSmallEnglish.automaticLanguageLabel,
            "Auto-detect"
        )
    }

    func testFluidAudioSpeechModelsSupportSpeakerFiltering() {
        XCTAssertFalse(SpeechModelCatalog.whisperTiny.supportsSpeakerFiltering)
        XCTAssertFalse(SpeechModelCatalog.whisperSmallEnglish.supportsSpeakerFiltering)
        XCTAssertFalse(SpeechModelCatalog.whisperSmallMultilingual.supportsSpeakerFiltering)
        XCTAssertTrue(SpeechModelCatalog.parakeetV3.supportsSpeakerFiltering)
        XCTAssertTrue(SpeechModelCatalog.qwen3AsrInt8.supportsSpeakerFiltering)
    }

    func testQwen3AsrInt8Descriptor() {
        let model = SpeechModelCatalog.qwen3AsrInt8
        XCTAssertEqual(model.name, "fluid_qwen3-asr-0.6b-int8")
        XCTAssertEqual(model.backend, .fluidAudio)
        XCTAssertEqual(model.fluidAudioVariant, .qwen3AsrInt8)
        XCTAssertTrue(model.pickerLabel.contains("Qwen3-ASR 0.6B"))
        XCTAssertTrue(model.pickerLabel.contains("int8"))
        XCTAssertTrue(model.pickerLabel.contains("~900 MB"))
    }

    func testQwen3ModelLookupIsAvailableOnSupportedOS() {
        if #available(macOS 15, iOS 18, *) {
            XCTAssertNotNil(SpeechModelCatalog.model(named: "fluid_qwen3-asr-0.6b-int8"))
        } else {
            XCTAssertNil(SpeechModelCatalog.model(named: "fluid_qwen3-asr-0.6b-int8"))
        }
    }

    // MARK: - ModelManager Tests

    func testModelManagerInitialState() {
        let manager = ModelManager()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isReady)
        XCTAssertNil(manager.whisperKit)
        XCTAssertNil(manager.error)
    }

    func testModelManagerDefaultModelName() throws {
        let manager = ModelManager()

        // Property, not identity. `ModelManager()`'s default parameter IS
        // `SpeechModelCatalog.defaultModelID`, so asserting
        // `manager.modelName == SpeechModelCatalog.defaultModelID` would
        // reduce to X == X and could never fail, even if the default
        // silently reverted to an English-only model. Instead: resolve the
        // model from the catalog (XCTUnwrap also guards that the default is
        // actually offered on this OS) and assert the property that matters
        // -- the shipped default must not be English-only, because 27
        // percent of real dictation is Russian and an English-only default
        // silently produces confident nonsense instead of an error (see
        // SpeechModelCatalog.defaultModelID's doc comment, changed
        // 2026-07-19). See the sibling hard literal pin in
        // testSpeechModelCatalogIncludesModelsSupportedByTheCurrentOS above.
        let defaultModel = try XCTUnwrap(
            SpeechModelCatalog.model(named: manager.modelName),
            "ModelManager's default model must exist in the catalog for the current OS"
        )
        XCTAssertFalse(
            defaultModel.name.hasSuffix(".en"),
            "The shipped default speech model must not be English-only"
        )
    }

    func testModelManagerCustomModelName() {
        let manager = ModelManager(modelName: "openai_whisper-tiny.en")
        XCTAssertEqual(manager.modelName, "openai_whisper-tiny.en")
    }

    func testModelManagerStateEnum() {
        // Verify all states are distinct
        let states: [ModelManagerState] = [.idle, .loading, .ready, .error]
        for (i, a) in states.enumerated() {
            for (j, b) in states.enumerated() {
                if i == j {
                    XCTAssertEqual(a, b)
                } else {
                    XCTAssertNotEqual(a, b)
                }
            }
        }
    }

    func testModelManagerQueuesLatestModelSelectionWhileAnotherModelLoads() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        let firstLoadGate = PipelineTestGate()
        var loadedNames: [String] = []
        let manager = ModelManager(
            modelName: SpeechModelCatalog.whisperSmallEnglish.id,
            modelLoadOverride: { descriptor in
                loadedNames.append(descriptor.name)
                if loadedNames.count == 1 {
                    await firstLoadGate.wait()
                }
            }
        )

        let initialLoad = Task { await manager.loadModel() }
        for _ in 0..<100 where loadedNames.isEmpty {
            await Task.yield()
        }

        let requestedModel = SpeechModelCatalog.speechAnalyzer.id
        let queuedLoad = Task {
            await manager.loadModel(name: requestedModel)
        }
        await Task.yield()
        XCTAssertEqual(manager.modelName, SpeechModelCatalog.whisperSmallEnglish.id)

        await firstLoadGate.release()
        await initialLoad.value
        await queuedLoad.value

        XCTAssertEqual(loadedNames, [
            SpeechModelCatalog.whisperSmallEnglish.id,
            requestedModel,
        ])
        XCTAssertEqual(manager.modelName, requestedModel)
        XCTAssertEqual(manager.state, .ready)
    }

    // MARK: - SpeechTranscriber Tests

    func testTranscriberReportsNotReadyBeforeModelLoad() {
        let manager = ModelManager()
        let transcriber = SpeechTranscriber(modelManager: manager)
        XCTAssertFalse(transcriber.isReady)
    }

    func testTranscriberEmptyAudioReturnsNil() async {
        let manager = ModelManager()
        let transcriber = SpeechTranscriber(modelManager: manager)
        let result = await transcriber.transcribe(audioBuffer: [])
        XCTAssertNil(result, "Empty audio buffer should return nil")
    }

    func testTranscriberReturnsNilWhenModelNotLoaded() async {
        let manager = ModelManager()
        let transcriber = SpeechTranscriber(modelManager: manager)
        // Non-empty buffer but model not loaded should return nil
        let silence = [Float](repeating: 0.0, count: 16000)
        let result = await transcriber.transcribe(audioBuffer: silence)
        XCTAssertNil(result, "Should return nil when model is not loaded")
    }

    func testChunkedPipelineStopWaitsForPendingTranscription() async {
        let transcriptionStarted = PipelineTestGate()
        let releaseTranscription = PipelineTestGate()
        let stopReturned = PipelineTestGate()
        let pipeline = ChunkedTranscriptionPipeline(
            transcribeChunk: { _ in
                await transcriptionStarted.release()
                await releaseTranscription.wait()
                return "finished"
            },
            chunkDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("GhostPepperTests")
                .appendingPathComponent(UUID().uuidString),
            chunkInterval: 60
        )

        pipeline.start()
        pipeline.appendAudio(
            TaggedAudioChunk(source: .mic, samples: [1, 2, 3], timestamp: 0)
        )

        let stopTask = Task {
            await pipeline.stop()
            await stopReturned.release()
        }

        await transcriptionStarted.wait()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let returnedBeforeTranscriptionFinished = await stopReturned.isOpen
        XCTAssertFalse(returnedBeforeTranscriptionFinished)

        await releaseTranscription.release()
        await stopTask.value

        let returnedAfterTranscriptionFinished = await stopReturned.isOpen
        XCTAssertTrue(returnedAfterTranscriptionFinished)
    }

    // MARK: - Qwen3-ASR ModelManager Tests

    func testModelManagerLoadsQwen3AsrModelThroughOverride() async throws {
        guard #available(macOS 15, iOS 18, *) else {
            throw XCTSkip("Qwen3-ASR requires macOS 15 or later.")
        }

        var loadedDescriptors: [SpeechModelDescriptor] = []
        let manager = ModelManager(
            modelName: "fluid_qwen3-asr-0.6b-int8",
            modelLoadOverride: { descriptor in
                loadedDescriptors.append(descriptor)
            },
            loadRetryDelayOverride: {}
        )

        await manager.loadModel()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertNil(manager.error)
        XCTAssertEqual(loadedDescriptors.count, 1)
        XCTAssertEqual(loadedDescriptors.first?.name, "fluid_qwen3-asr-0.6b-int8")
        XCTAssertEqual(loadedDescriptors.first?.fluidAudioVariant, .qwen3AsrInt8)
    }

    func testModelManagerSurfacesQwen3LoadFailure() async throws {
        guard #available(macOS 15, iOS 18, *) else {
            throw XCTSkip("Qwen3-ASR requires macOS 15 or later.")
        }

        struct DownloadFailed: Error {}
        let manager = ModelManager(
            modelName: "fluid_qwen3-asr-0.6b-int8",
            modelLoadOverride: { _ in throw DownloadFailed() },
            loadRetryDelayOverride: {}
        )

        await manager.loadModel()

        XCTAssertEqual(manager.state, .error)
        XCTAssertNotNil(manager.error)
    }

    func testModelManagerSwitchesBetweenWhisperAndQwen3() async throws {
        guard #available(macOS 15, iOS 18, *) else {
            throw XCTSkip("Qwen3-ASR requires macOS 15 or later.")
        }

        var loadedNames: [String] = []
        let manager = ModelManager(
            modelName: "openai_whisper-small.en",
            modelLoadOverride: { descriptor in
                loadedNames.append(descriptor.name)
            },
            loadRetryDelayOverride: {}
        )

        await manager.loadModel()
        XCTAssertEqual(manager.state, .ready)

        await manager.loadModel(name: "fluid_qwen3-asr-0.6b-int8")

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(manager.modelName, "fluid_qwen3-asr-0.6b-int8")
        XCTAssertEqual(loadedNames, [
            "openai_whisper-small.en",
            "fluid_qwen3-asr-0.6b-int8",
        ])
    }
}

private actor PipelineTestGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool { isReleased }

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

@MainActor
final class AppleSpeechAnalyzerBackendTests: XCTestCase {
    func testRequestedLocaleUsesExplicitLanguageOrCurrentLocale() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }

        XCTAssertEqual(
            AppleSpeechAnalyzerBackend.requestedLocale(
                languageCode: "es",
                currentLocale: Locale(identifier: "fr_CA")
            ).identifier,
            "es"
        )
        XCTAssertEqual(
            AppleSpeechAnalyzerBackend.requestedLocale(
                languageCode: nil,
                currentLocale: Locale(identifier: "fr_CA")
            ).identifier,
            "fr_CA"
        )
    }

    func testAnalyzerBufferClipsFloatSamplesToValidPCMRange() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )

        let buffer = try AppleSpeechAnalyzerBackend.makeAnalyzerBuffer(
            audioBuffer: [-2, -0.5, 0, 0.5, 2],
            format: format
        )
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])

        XCTAssertEqual(buffer.frameLength, 5)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channel, count: 5)), [-1, -0.5, 0, 0.5, 1])
    }

    func testAnalyzerBufferSanitizesNonFiniteFloatSamples() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )

        let buffer = try AppleSpeechAnalyzerBackend.makeAnalyzerBuffer(
            audioBuffer: [.nan, .infinity, -.infinity],
            format: format
        )
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])

        XCTAssertEqual(
            Array(UnsafeBufferPointer(start: channel, count: 3)),
            [0, 0, 0]
        )
    }

    func testAnalyzerResultTextConcatenatesFragmentsWithoutInsertingSpaces() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }

        XCTAssertEqual(
            AppleSpeechAnalyzerBackend.transcriptText(
                from: ["Hello", ",", " world", "."]
            ),
            "Hello, world."
        )
    }

    func testAnalyzerBufferConvertsToRequestedIntegerFormat() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )

        let buffer = try AppleSpeechAnalyzerBackend.makeAnalyzerBuffer(
            audioBuffer: [-1, 0, 1],
            format: format
        )

        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(buffer.frameLength, 3)
        let channel = try XCTUnwrap(buffer.int16ChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: 3))
        XCTAssertLessThanOrEqual(abs(Int(samples[0]) - Int(Int16.min)), 1)
        XCTAssertEqual(samples[1], 0)
        XCTAssertLessThanOrEqual(abs(Int(samples[2]) - Int(Int16.max)), 1)
    }

    func testPrepareRejectsUnsupportedLocaleWithoutFallback() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }

        do {
            _ = try await AppleSpeechAnalyzerBackend.prepare(
                languageCode: "zz_ZZ",
                currentLocale: Locale(identifier: "en_US"),
                supportedLocaleResolver: { _ in nil },
                progressHandler: { _ in }
            )
            XCTFail("Expected an unsupported-locale error")
        } catch let error as AppleSpeechAnalyzerError {
            guard case .unsupportedLocale("zz_ZZ") = error else {
                return XCTFail("Unexpected error: \(error.localizedDescription)")
            }
        }
    }
}

/// Andrew chose on 2026-07-27 to keep push-to-talk working while a meeting is
/// being transcribed. Both feed one shared speech model, so without an order his
/// dictation would queue behind 30-second meeting chunks and his text would
/// arrive seconds late.
///
/// These assert the ORDER rather than the mechanism, so a future rewrite that
/// loses the priority fails them instead of quietly passing.
final class TranscriptionSchedulerTests: XCTestCase {

    private actor Order {
        private(set) var entries: [String] = []
        func record(_ name: String) { entries.append(name) }
    }

    /// Waits until the scheduler actually holds the expected queue, so the
    /// assertion cannot pass on lucky task scheduling.
    private func waitUntilQueued(
        _ scheduler: TranscriptionScheduler,
        dictation: Int,
        background: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            let counts = await scheduler.queuedCounts
            if counts.dictation == dictation && counts.background == background { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let counts = await scheduler.queuedCounts
        XCTFail(
            "Timed out waiting for \(dictation) dictation and \(background) background waiters; saw \(counts).",
            file: file,
            line: line
        )
    }

    func testDictationOvertakesBackgroundWorkAlreadyWaiting() async {
        let scheduler = TranscriptionScheduler()
        let order = Order()

        // Something is already running, so everything else must queue.
        await scheduler.acquire(.background)

        // Two meeting chunks queue FIRST.
        let firstChunk = Task {
            await scheduler.acquire(.background)
            await order.record("chunk-1")
            await scheduler.release()
        }
        let secondChunk = Task {
            await scheduler.acquire(.background)
            await order.record("chunk-2")
            await scheduler.release()
        }

        // Confirmed queued, not merely slept past.
        await waitUntilQueued(scheduler, dictation: 0, background: 2)

        // Dictation arrives LAST and must still run first.
        let dictation = Task {
            await scheduler.acquire(.dictation)
            await order.record("dictation")
            await scheduler.release()
        }

        await waitUntilQueued(scheduler, dictation: 1, background: 2)

        await scheduler.release()

        _ = await (firstChunk.value, secondChunk.value, dictation.value)

        let entries = await order.entries
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(
            entries.first,
            "dictation",
            "His dictation arrived last and must still run first. Going after the queued meeting chunks is exactly the latency this priority exists to remove."
        )
    }

    /// Priority must not become starvation: a meeting has to keep making
    /// progress while he dictates, or it can never finish draining.
    func testBackgroundWorkIsNotStarvedByContinuousDictation() async {
        let scheduler = TranscriptionScheduler()
        let order = Order()

        await scheduler.acquire(.background)

        let chunk = Task {
            await scheduler.acquire(.background)
            await order.record("chunk")
            await scheduler.release()
        }
        await waitUntilQueued(scheduler, dictation: 0, background: 1)

        // A steady stream of dictations, each queued before the previous is served.
        var dictations: [Task<Void, Never>] = []
        for index in 0..<6 {
            let task = Task {
                await scheduler.acquire(.dictation)
                await order.record("dictation-\(index)")
                await scheduler.release()
            }
            dictations.append(task)
        }
        await waitUntilQueued(scheduler, dictation: 6, background: 1)

        await scheduler.release()
        for task in dictations { await task.value }
        await chunk.value

        let entries = await order.entries
        let chunkPosition = entries.firstIndex(of: "chunk")
        XCTAssertNotNil(chunkPosition, "The meeting chunk never ran at all.")
        XCTAssertLessThan(
            chunkPosition ?? .max,
            entries.count - 1,
            "The meeting chunk was served dead last behind every dictation. Strict priority means a meeting can never drain while he keeps talking."
        )
    }

    func testBackgroundWorkStillRunsWhenNothingIsWaiting() async {
        let scheduler = TranscriptionScheduler()
        let order = Order()

        await scheduler.acquire(.background)
        await order.record("chunk")
        await scheduler.release()

        await scheduler.acquire(.dictation)
        await order.record("dictation")
        await scheduler.release()

        let entries = await order.entries
        XCTAssertEqual(entries, ["chunk", "dictation"], "With no contention, order is simply arrival order.")
    }

    /// Every acquire is balanced by a release, on every early-return path.
    ///
    /// Renamed from "…DoNotOverlap", which is not what it measured. The review
    /// was blunt and correct: it entered and left the overlap counter AROUND the
    /// call rather than inside the critical section, never asserted the peak,
    /// and could not have distinguished a working arbiter from none at all
    /// because `ModelManager` is `@MainActor` and serialises this path anyway.
    /// A test whose title claims more than its body checks is the same defect
    /// this project keeps paying for, committed in the test written to prove it
    /// had been fixed.
    ///
    /// What this DOES check is real and worth keeping: `transcribe` returns
    /// early when no model is loaded, and a missed release on that path would
    /// wedge his dictation permanently.
    @MainActor
    func testSchedulerSlotIsReleasedOnEveryEarlyReturnPath() async {
        let manager = ModelManager()

        // No model is loaded, so every one of these takes an early return.
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    _ = await manager.transcribe(
                        audioBuffer: [0.1, 0.2, 0.3],
                        priority: index.isMultiple(of: 2) ? .dictation : .background
                    )
                }
            }
        }

        let queued = await manager.transcriptionScheduler.queuedCounts
        XCTAssertEqual(queued.dictation, 0, "A dictation request was left queued, so a release was missed.")
        XCTAssertEqual(queued.background, 0, "A background request was left queued, so a release was missed.")

        // And the slot is genuinely free rather than held. If a release were
        // missed this hangs rather than failing, which is worth knowing when
        // reading a timeout in CI.
        await manager.transcriptionScheduler.acquire(.dictation)
        await manager.transcriptionScheduler.release()
    }

    func testOnlyOneTranscriptionRunsAtATime() async {
        let scheduler = TranscriptionScheduler()
        let overlap = Overlap()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await scheduler.acquire(.background)
                    await overlap.enter()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await overlap.leave()
                    await scheduler.release()
                }
            }
        }

        let peak = await overlap.peak
        XCTAssertEqual(peak, 1, "Two transcriptions ran at once against one shared model.")
    }

    private actor Overlap {
        private var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }
}

/// Whisper does not return nothing for silence, it invents. Its favourite
/// inventions are "Thank you." and "Thanks for watching!", because that is how
/// the videos it was trained on end.
///
/// Andrew reported seeing "Thank you" appear repeatedly in his dictation, and
/// his first real meeting recording, made alone with nobody else on the call,
/// contained a line reading `Others: Thank you.` A transcript that contains
/// words nobody said, attributed to other people, is worse than a missing one:
/// the invented text is fluent and plausible, so nothing about reading it
/// reveals the problem.
final class SilenceGateTests: XCTestCase {

    func testDigitalSilenceIsTreatedAsSilent() {
        XCTAssertTrue(ModelManager.isEffectivelySilent([Float](repeating: 0, count: 16_000)))
    }

    func testAnEmptyBufferIsTreatedAsSilent() {
        XCTAssertTrue(ModelManager.isEffectivelySilent([]))
    }

    /// Room tone and mic noise floor must still count as silence, or the gate
    /// does nothing in practice: a real microphone never returns exact zeroes.
    func testMicrophoneNoiseFloorIsTreatedAsSilent() {
        var noise = [Float]()
        var seed: UInt64 = 42
        for _ in 0..<16_000 {
            // Deterministic pseudo-noise at roughly -80 dBFS.
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(seed >> 40) / Float(1 << 24) - 0.5
            noise.append(unit * 0.0002)
        }
        XCTAssertTrue(
            ModelManager.isEffectivelySilent(noise),
            "A real microphone's noise floor must count as silence, or Whisper still gets a chance to invent words from it."
        )
    }

    /// And ordinary speech must NOT be gated. A silence gate that swallows quiet
    /// talking would be a far worse bug than the one it fixes, because he would
    /// lose real dictation.
    func testOrdinarySpeechIsNotTreatedAsSilent() {
        var tone = [Float]()
        for index in 0..<16_000 {
            // A quiet 200 Hz tone at about -34 dBFS, well below normal speech.
            tone.append(sin(Float(index) * 0.0785) * 0.02)
        }
        XCTAssertFalse(
            ModelManager.isEffectivelySilent(tone),
            "Quiet speech was gated as silence. Losing his real dictation is worse than the invented words this gate exists to stop."
        )
    }

    func testLoudSpeechIsNotTreatedAsSilent() {
        var tone = [Float]()
        for index in 0..<16_000 {
            tone.append(sin(Float(index) * 0.0785) * 0.4)
        }
        XCTAssertFalse(ModelManager.isEffectivelySilent(tone))
    }
}

/// Pins the three defects that made Andrew's 51-minute Zoom call of 2026-07-29
/// unreadable. All three are measured from that recording, not inferred.
///
/// The chunk timer fired ONCE in 51 minutes. `chunk-0-mic.wav` holds 1902.2
/// seconds of continuous audio and the app's first language-detection line is
/// 1907 seconds after the meeting started, so there were no drains at all in
/// the first 31 minutes 42 seconds.
///
/// One drain therefore handed Whisper a single 31-minute buffer. That produced
/// one language decision for half a meeting, one `[00:00]` timestamp for all of
/// it, and a 16 minute 3 second wait for the 8-second dictation he made at
/// 10:55 (`transcription=962992ms`), because the shared model was busy.
final class ChunkedTranscriptionPipelineTimingTests: XCTestCase {

    /// Collects what each inference call actually received, from whichever
    /// thread the pipeline runs it on.
    private final class ChunkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [[Float]] = []

        func record(_ samples: [Float]) {
            lock.lock()
            received.append(samples)
            lock.unlock()
        }

        var chunks: [[Float]] {
            lock.lock()
            defer { lock.unlock() }
            return received
        }

        var count: Int { chunks.count }
    }

    private final class SegmentRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [ChunkedTranscriptResult] = []

        func record(_ result: ChunkedTranscriptResult) {
            lock.lock()
            received.append(result)
            lock.unlock()
        }

        var segments: [ChunkedTranscriptResult] {
            lock.lock()
            defer { lock.unlock() }
            return received
        }
    }

    private final class BoolBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostPepperTests")
            .appendingPathComponent(UUID().uuidString)
    }

    private static func speech(seconds: Double, value: Float = 0.2) -> [Float] {
        [Float](repeating: value, count: Int(seconds * 16_000))
    }

    /// Stops a pipeline from a synchronous test, pumping the run loop so the
    /// pipeline's hops to the main actor can complete while we wait.
    private func stopPumpingTheRunLoop(_ pipeline: ChunkedTranscriptionPipeline) {
        let stopped = BoolBox()
        Task {
            await pipeline.stop()
            stopped.set()
        }
        let deadline = Date().addingTimeInterval(5)
        while !stopped.isSet, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// THE DEFECT THAT COST HIM THE MEETING.
    ///
    /// The pipeline drains on a `Timer` scheduled on whatever run loop `start()`
    /// was called from, so anything that stops that run loop servicing timers
    /// stops the whole pipeline, silently, while audio keeps piling up in memory.
    ///
    /// This test blocks the main thread for a second and a half, which is the
    /// shape of that failure and not its cause: the point is that a background
    /// pipeline must not depend on the main run loop at all. Audio keeps
    /// arriving from a capture callback on another thread throughout, exactly as
    /// `DualStreamCapture` delivers it.
    func testChunksKeepDrainingWhileTheMainRunLoopIsBlocked() {
        let recorder = ChunkRecorder()
        let pipeline = ChunkedTranscriptionPipeline(
            transcribeChunk: { samples in
                recorder.record(samples)
                return "text"
            },
            chunkDirectory: Self.scratchDirectory(),
            chunkInterval: 0.2
        )

        pipeline.start()

        let feeder = Thread {
            for _ in 0..<40 {
                pipeline.appendAudio(
                    TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 0.05), timestamp: 0)
                )
                Thread.sleep(forTimeInterval: 0.04)
            }
        }
        feeder.start()

        Thread.sleep(forTimeInterval: 1.6)

        let drains = recorder.count
        stopPumpingTheRunLoop(pipeline)

        XCTAssertGreaterThanOrEqual(
            drains,
            3,
            "The pipeline drained \(drains) times in 1.6 seconds at a 0.2 second interval while the main run loop was busy. His meeting drained once in 51 minutes."
        )
    }

    /// A segment must be stamped with when the audio was actually captured.
    ///
    /// It was stamped `chunkIndex * chunkInterval`, which is a count of drains
    /// rather than a time, so both segments of his meeting read `[00:00]` and
    /// the 0.68-second tail drained at 51 minutes would have read `[00:30]`.
    /// `TaggedAudioChunk` already carries the real capture time.
    func testASegmentIsStampedWithTheTimeTheAudioWasCaptured() async {
        let segments = SegmentRecorder()
        let pipeline = ChunkedTranscriptionPipeline(
            transcribeChunk: { _ in "text" },
            chunkDirectory: Self.scratchDirectory(),
            chunkInterval: 30
        )
        pipeline.onSegmentTranscribed = { segments.record($0) }

        pipeline.start()
        pipeline.appendAudio(
            TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 2), timestamp: 100)
        )
        await pipeline.stop()

        guard let segment = segments.segments.first else {
            return XCTFail("no segment was produced")
        }
        XCTAssertEqual(segment.startTime, 100, accuracy: 0.05, "the segment must start where the audio was captured")
        XCTAssertEqual(segment.endTime, 102, accuracy: 0.05, "and end two seconds later, because two seconds of audio arrived")
    }

    /// No single inference call may carry an unbounded amount of audio.
    ///
    /// `TranscriptionScheduler` says a dictation "still waits for a background
    /// chunk that is already RUNNING" and that "the wait is bounded by one chunk
    /// rather than by the queue behind it". That sentence was true and the bound
    /// it promised was not, because nothing limited a chunk's LENGTH. One
    /// 31-minute chunk made his 8-second dictation take 16 minutes.
    func testABacklogIsSplitSoOneInferenceCanNeverBeUnbounded() async {
        let recorder = ChunkRecorder()
        let segments = SegmentRecorder()
        let pipeline = ChunkedTranscriptionPipeline(
            transcribeChunk: { samples in
                recorder.record(samples)
                return "text"
            },
            chunkDirectory: Self.scratchDirectory(),
            chunkInterval: 30
        )
        pipeline.onSegmentTranscribed = { segments.record($0) }

        pipeline.start()
        // 90 seconds of audio reaches one drain, which is what a stalled timer
        // does. It must not become one 90-second inference.
        pipeline.appendAudio(
            TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 90), timestamp: 0)
        )
        await pipeline.stop()

        let longest = recorder.chunks.map(\.count).max() ?? 0
        XCTAssertLessThanOrEqual(
            longest,
            Int(31.5 * 16_000),
            "One inference call received \(Double(longest) / 16_000) seconds of audio. A dictation waiting behind it waits that long."
        )
        XCTAssertGreaterThanOrEqual(recorder.count, 3, "90 seconds of backlog should reach the model as at least three chunks")

        let starts = segments.segments.map(\.startTime).sorted()
        XCTAssertEqual(starts.count, recorder.count, "every transcribed chunk should produce a segment")
        if starts.count >= 2 {
            XCTAssertGreaterThan(starts[1], starts[0], "the split chunks must carry different timestamps")
        }
    }

    /// `overlapDuration` was declared, documented as "1 second overlap for
    /// dedup", and never read. So every chunk boundary in every meeting he had
    /// recorded was a hard cut through whatever word was being spoken at the
    /// 30-second mark.
    func testTheNextChunkStartsWithTheTailOfThePreviousOne() {
        let recorder = ChunkRecorder()
        let segments = SegmentRecorder()
        let pipeline = ChunkedTranscriptionPipeline(
            transcribeChunk: { samples in
                recorder.record(samples)
                return "text"
            },
            chunkDirectory: Self.scratchDirectory(),
            chunkInterval: 0.3,
            maxInferenceDuration: 30
        )
        pipeline.onSegmentTranscribed = { segments.record($0) }
        pipeline.start()

        // Two seconds of audio whose samples are all distinguishable, so an
        // overlap can be identified rather than inferred.
        var ramp = [Float]()
        for index in 0..<32_000 {
            ramp.append(Float(index) / 32_000)
        }
        pipeline.appendAudio(TaggedAudioChunk(source: .mic, samples: ramp, timestamp: 0))
        XCTAssertTrue(waitForChunks(recorder, count: 1), "the first chunk never drained")

        pipeline.appendAudio(
            TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 1, value: -0.5), timestamp: 2)
        )
        XCTAssertTrue(waitForChunks(recorder, count: 2), "the second chunk never drained")

        stopPumpingTheRunLoop(pipeline)

        let chunks = recorder.chunks
        guard chunks.count >= 2 else { return XCTFail("expected two chunks, got \(chunks.count)") }
        let overlapSamples = 16_000

        XCTAssertEqual(
            Array(chunks[1].prefix(overlapSamples)),
            Array(chunks[0].suffix(overlapSamples)),
            "The second chunk must start with the last second of the first, or a word spoken across the boundary is cut in half."
        )

        // And the timestamps must account for the overlap rather than double-count it.
        let ordered = segments.segments.sorted { $0.startTime < $1.startTime }
        guard ordered.count >= 2 else { return XCTFail("expected two segments") }
        XCTAssertEqual(ordered[0].endTime, 2, accuracy: 0.05)
        XCTAssertEqual(
            ordered[1].startTime,
            1,
            accuracy: 0.05,
            "the second chunk begins one second before the first one ended, because that second is re-fed"
        )
    }

    /// A CAPTURE CHANNEL CAN DIE MID-MEETING AND NOTHING NOTICED.
    ///
    /// New defect, 2026-07-29, and it is why 19 minutes of his 51-minute call
    /// exist nowhere: after the single drain at 10:53:24 the microphone delivered
    /// zero samples for the rest of the meeting. There is no `chunk-1-mic.wav`.
    ///
    /// `AudioRecorder` observes no engine-configuration change and nothing
    /// restarts a stopped engine. The system channel at least reports itself
    /// through `onCaptureInterrupted`; the microphone channel had nothing, and the
    /// only silence check in the session covers the first ten seconds. So the app
    /// recorded confidently for nineteen minutes while hearing nothing.
    ///
    /// Detecting it cannot depend on a run-loop timer, because a starved run loop
    /// is the other half of this bug. It rides the drain schedule instead.
    func testAChannelThatStopsDeliveringAudioIsReported() {
        let quiet = QuietRecorder()
        let pipeline = ChunkedTranscriptionPipeline(
            transcribeChunk: { _ in "text" },
            chunkDirectory: Self.scratchDirectory(),
            chunkInterval: 0.1
        )
        pipeline.onSourceWentQuiet = { quiet.record($0) }
        pipeline.start()

        // Both channels deliver, so both are known to be alive.
        pipeline.appendAudio(TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 0.05), timestamp: 0))
        pipeline.appendAudio(TaggedAudioChunk(source: .system, samples: Self.speech(seconds: 0.05), timestamp: 0))

        // Then the microphone dies while the far side keeps talking, which is the
        // shape of what happened to him.
        let deadline = Date().addingTimeInterval(3)
        var elapsedDrains = 0
        while Date() < deadline, quiet.sources.isEmpty {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            pipeline.appendAudio(
                TaggedAudioChunk(source: .system, samples: Self.speech(seconds: 0.05), timestamp: Double(elapsedDrains) * 0.05)
            )
            elapsedDrains += 1
        }

        let reported = quiet.sources
        stopPumpingTheRunLoop(pipeline)

        XCTAssertTrue(
            reported.contains(.mic),
            "The microphone stopped delivering audio and nothing said so. That silence cost him 19 minutes of a real meeting."
        )
        XCTAssertFalse(
            reported.contains(.system),
            "The channel that was still delivering must not be reported dead, or the warning means nothing."
        )
    }

    /// A REGRESSION THE REVIEW CAUGHT, not the recording.
    ///
    /// Splitting a backlog made a drain produce several pieces per channel, and
    /// they were processed as all of the microphone's and then all of the system's.
    /// `MeetingTranscript.appendSegment` appends without sorting, so a 90-second
    /// backlog would have written the transcript as me 0s, me 29s, me 58s, me 87s,
    /// others 0s, others 29s: a transcript that goes backwards halfway down.
    func testASplitBacklogKeepsBothChannelsInOneOrder() async {
        let segments = SegmentRecorder()
        let pipeline = ChunkedTranscriptionPipeline(
            transcribeChunk: { _ in "text" },
            chunkDirectory: Self.scratchDirectory(),
            chunkInterval: 30
        )
        pipeline.onSegmentTranscribed = { segments.record($0) }
        pipeline.start()

        pipeline.appendAudio(TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 90), timestamp: 0))
        pipeline.appendAudio(TaggedAudioChunk(source: .system, samples: Self.speech(seconds: 90, value: 0.3), timestamp: 0))
        await pipeline.stop()

        let starts = segments.segments.map(\.startTime)
        XCTAssertGreaterThanOrEqual(starts.count, 6, "expected several pieces per channel, got \(starts.count)")
        let ordered = zip(starts, starts.dropFirst()).allSatisfy { $0 <= $1 }
        XCTAssertTrue(
            ordered,
            "Segments were delivered out of chronological order: \(starts.map { String(format: "%.0f", $0) }.joined(separator: ", "))"
        )
    }

    /// THE OTHER REGRESSION THE REVIEW CAUGHT.
    ///
    /// Handing segments to the main queue instead of awaiting them stopped a busy
    /// main actor from throttling the pipeline, and it also let `stop()` return
    /// before the last segments had been appended. The caller's final save,
    /// speaker tagging and summary then run against a transcript missing its own
    /// ending, which is the class of loss this whole session is about.
    ///
    /// Run from the main actor, like the real caller: `MeetingSession.stop()` is
    /// `@MainActor`, so if the barrier could deadlock against the main queue this is
    /// where it would.
    @MainActor
    func testStopReturnsOnlyAfterEverySegmentHasBeenDelivered() async {
        let segments = SegmentRecorder()
        let saved = SavedChunkRecorder()
        let pipeline = ChunkedTranscriptionPipeline(
            transcribeChunk: { _ in "text" },
            chunkDirectory: Self.scratchDirectory(),
            chunkInterval: 30
        )
        // Deliberately slow consumers, because the failure is a race and a race that
        // only sometimes loses is not a test.
        pipeline.onSegmentTranscribed = { result in
            Thread.sleep(forTimeInterval: 0.05)
            segments.record(result)
        }
        pipeline.onChunkSaved = { url, _, _ in
            Thread.sleep(forTimeInterval: 0.05)
            saved.record(url)
        }
        pipeline.start()

        pipeline.appendAudio(TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 90), timestamp: 0))
        await pipeline.stop()

        XCTAssertGreaterThanOrEqual(
            segments.segments.count,
            4,
            "stop() returned with \(segments.segments.count) of 4 segments delivered, so a caller saving the transcript here would save an incomplete one."
        )
        XCTAssertGreaterThanOrEqual(
            saved.count,
            4,
            "stop() returned with \(saved.count) of 4 chunks recorded, so the speaker tagger would run against audio it has not been told about."
        )
    }

    private final class SavedChunkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func record(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return urls.count }
    }

    /// Audio that comes back after an outage must be stamped where it really is.
    ///
    /// Retaining an overlap tail means the buffer is never empty, so anchoring the
    /// capture time only on an empty buffer silently ignored every later
    /// timestamp. His microphone died for 19 minutes and came back at the stop; a
    /// channel that recovers mid-meeting would have had its returning audio
    /// stamped as though nothing had been missed, compressing the timeline and
    /// misaligning the speaker tagger against it.
    func testAudioReturningAfterAnOutageIsStampedWhereItActuallyIs() {
        let segments = SegmentRecorder()
        let recorder = ChunkRecorder()
        let pipeline = ChunkedTranscriptionPipeline(
            transcribeChunk: { samples in
                recorder.record(samples)
                return "text"
            },
            chunkDirectory: Self.scratchDirectory(),
            chunkInterval: 0.2
        )
        pipeline.onSegmentTranscribed = { segments.record($0) }
        pipeline.start()

        pipeline.appendAudio(TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 3), timestamp: 0))
        XCTAssertTrue(waitForChunks(recorder, count: 1), "the first chunk never drained")

        // The channel goes quiet and returns a hundred seconds later.
        pipeline.appendAudio(TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 3), timestamp: 100))
        XCTAssertTrue(waitForChunks(recorder, count: 2), "the chunk after the outage never drained")

        stopPumpingTheRunLoop(pipeline)

        let starts = segments.segments.map(\.startTime).sorted()
        XCTAssertTrue(
            starts.contains { abs($0) < 1 },
            "the audio before the outage should still be stamped at the start: \(starts)"
        )
        XCTAssertTrue(
            starts.contains { abs($0 - 100) < 1 },
            "The audio after the outage was stamped \(starts) instead of at 100s, so the transcript claims a gap that really happened did not happen."
        )
        XCTAssertFalse(
            starts.contains { $0 > 5 && $0 < 95 },
            "nothing should be stamped inside the outage, where no audio was captured: \(starts)"
        )
    }

    /// AUDIO CAPTURED BEFORE A GAP MUST STILL BE TRANSCRIBED.
    ///
    /// The first version of the re-anchoring fix cleared the whole buffer when it
    /// saw a discontinuity, which threw away everything captured since the last
    /// drain. That is losing his words in the course of fixing a bug about losing
    /// his words, and the review caught it because the test drained first and so
    /// never held un-drained audio across a gap.
    func testAudioCapturedBeforeAGapIsNotThrownAway() async {
        let recorder = ChunkRecorder()
        let segments = SegmentRecorder()
        let pipeline = ChunkedTranscriptionPipeline(
            transcribeChunk: { samples in
                recorder.record(samples)
                return "text"
            },
            chunkDirectory: Self.scratchDirectory(),
            chunkInterval: 30
        )
        pipeline.onSegmentTranscribed = { segments.record($0) }
        pipeline.start()

        // One second of speech, NOT yet drained, then the channel skips.
        pipeline.appendAudio(TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 1), timestamp: 0))
        pipeline.appendAudio(TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 1), timestamp: 100))
        await pipeline.stop()

        let delivered = recorder.chunks.reduce(0) { $0 + $1.count }
        XCTAssertEqual(
            delivered,
            32_000,
            "Two seconds of his speech went in and \(Double(delivered) / 16_000) reached the model."
        )
        let starts = segments.segments.map(\.startTime).sorted()
        XCTAssertEqual(starts.count, 2, "the two sides of the gap must be separate segments")
        if starts.count == 2 {
            XCTAssertEqual(starts[0], 0, accuracy: 0.05)
            XCTAssertEqual(starts[1], 100, accuracy: 0.05)
        }
    }

    /// Audio that arrives while capture is still starting must be kept.
    ///
    /// `MeetingSession` wires the capture callback and starts capture BEFORE it
    /// starts the pipeline, so this is a real ordering, not a contrived one. The
    /// first version of `start()` reset the buffers as a tidy-up and silently
    /// discarded the opening of the meeting.
    func testAudioArrivingBeforeStartIsNotDiscarded() async {
        let recorder = ChunkRecorder()
        let pipeline = ChunkedTranscriptionPipeline(
            transcribeChunk: { samples in
                recorder.record(samples)
                return "text"
            },
            chunkDirectory: Self.scratchDirectory(),
            chunkInterval: 30
        )

        pipeline.appendAudio(TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 2), timestamp: 0))
        pipeline.start()
        await pipeline.stop()

        let delivered = recorder.chunks.reduce(0) { $0 + $1.count }
        XCTAssertEqual(
            delivered,
            32_000,
            "The two seconds captured during startup were dropped: \(Double(delivered) / 16_000)s reached the model."
        )
    }

    /// The system copy of a moment must reach the transcript before the microphone
    /// copy of the same moment.
    ///
    /// `MeetingEchoFilter` drops a microphone segment that repeats what the system
    /// channel already said, so it can only work if the system segment is already
    /// there. Every version of this pipeline before now processed the microphone
    /// first, which made the filter unable to catch the bleed it exists for.
    func testTheSystemCopyOfAMomentArrivesBeforeTheMicrophoneCopy() async {
        let segments = SegmentRecorder()
        let pipeline = ChunkedTranscriptionPipeline(
            transcribeChunk: { _ in "text" },
            chunkDirectory: Self.scratchDirectory(),
            chunkInterval: 30
        )
        pipeline.onSegmentTranscribed = { segments.record($0) }
        pipeline.start()

        pipeline.appendAudio(TaggedAudioChunk(source: .mic, samples: Self.speech(seconds: 2), timestamp: 0))
        pipeline.appendAudio(TaggedAudioChunk(source: .system, samples: Self.speech(seconds: 2, value: 0.3), timestamp: 0))
        await pipeline.stop()

        let sources = segments.segments.map(\.source)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(
            sources.first,
            .system,
            "The microphone copy arrived first, so the echo filter has nothing to compare it against and his own transcript keeps the other side's words twice."
        )
    }

    private final class QuietRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var reported: [AudioStreamSource] = []

        func record(_ source: AudioStreamSource) {
            lock.lock()
            reported.append(source)
            lock.unlock()
        }

        var sources: [AudioStreamSource] {
            lock.lock()
            defer { lock.unlock() }
            return reported
        }
    }

    private func waitForChunks(_ recorder: ChunkRecorder, count: Int, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recorder.count >= count { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return recorder.count >= count
    }
}
