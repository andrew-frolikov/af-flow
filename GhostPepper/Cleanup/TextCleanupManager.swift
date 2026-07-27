import Combine
import CryptoKit
import Foundation
import LLM

private extension CleanupModelProbeThinkingMode {
    var llmThinkingMode: ThinkingMode {
        switch self {
        case .none:
            return .none
        case .suppressed:
            return .suppressed
        case .enabled:
            return .enabled
        }
    }
}

enum CleanupModelState: Equatable {
    case idle
    case downloading(kind: LocalCleanupModelKind, progress: Double)
    case loadingModel(kind: LocalCleanupModelKind)
    case ready
    case error
}

protocol TextCleaningManaging: AnyObject {
    func clean(text: String, prompt: String?, modelKind: LocalCleanupModelKind?) async throws -> String
}

typealias CleanupModelProbeExecutionOverride = @MainActor (
    _ text: String,
    _ prompt: String,
    _ modelKind: LocalCleanupModelKind,
    _ thinkingMode: CleanupModelProbeThinkingMode
) async throws -> CleanupModelProbeRawResult

enum CleanupModelRecommendation: Equatable {
    case veryFast
    case fast
    case full

    var label: String {
        switch self {
        case .veryFast:
            return "Very fast"
        case .fast:
            return "Fast"
        case .full:
            return "Full"
        }
    }
}

enum LocalCleanupModelKind: String, CaseIterable, Equatable, Identifiable {
    case qwen35_0_8b_q4_k_m
    case qwen35_2b_q4_k_m
    case qwen35_4b_q4_k_m
    case deepseek_r1_qwen_7b_q4_k_m
    case gemma4_12b_it_optiq_4bit_mlx

    var id: String { rawValue }

    static var fast: LocalCleanupModelKind { .qwen35_2b_q4_k_m }
    static var full: LocalCleanupModelKind { .qwen35_4b_q4_k_m }
    static var wikiDefault: LocalCleanupModelKind { .qwen35_4b_q4_k_m }
}

enum CleanupModelRuntime: Equatable {
    case gguf
    case mlxRepository(repoID: String)
}

struct CleanupModelDescriptor: Equatable {
    let kind: LocalCleanupModelKind
    let displayName: String
    let sizeDescription: String
    let fileName: String
    let url: String
    let expectedSHA256: String
    let expectedByteCount: Int64
    let maxTokenCount: Int32
    let recommendation: CleanupModelRecommendation?
    let runtime: CleanupModelRuntime

    init(
        kind: LocalCleanupModelKind,
        displayName: String,
        sizeDescription: String,
        fileName: String,
        url: String,
        expectedSHA256: String,
        expectedByteCount: Int64,
        maxTokenCount: Int32,
        recommendation: CleanupModelRecommendation?,
        runtime: CleanupModelRuntime = .gguf
    ) {
        self.kind = kind
        self.displayName = displayName
        self.sizeDescription = sizeDescription
        self.fileName = fileName
        self.url = url
        self.expectedSHA256 = expectedSHA256
        self.expectedByteCount = expectedByteCount
        self.maxTokenCount = maxTokenCount
        self.recommendation = recommendation
        self.runtime = runtime
    }
}

@MainActor
final class TextCleanupManager: ObservableObject, TextCleaningManaging {
    private struct HuggingFaceModelInfo: Decodable {
        let siblings: [Sibling]

        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
        }
    }

    private struct PreparedPromptContext {
        let modelKind: LocalCleanupModelKind
        let plan: CleanupPromptPrefillPlan
    }

    @Published private(set) var state: CleanupModelState = .idle
    @Published private(set) var errorMessage: String?
    @Published var selectedCleanupModelKind: LocalCleanupModelKind {
        didSet {
            defaults.set(selectedCleanupModelKind.rawValue, forKey: Self.selectedCleanupModelDefaultsKey)
        }
    }

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    private(set) var activeLLM: LLM?
    private(set) var activeLoadedModelKind: LocalCleanupModelKind?

    static let compactModel = CleanupModelDescriptor(
        kind: .qwen35_0_8b_q4_k_m,
        displayName: "Qwen 3.5 0.8B Q4_K_M (Very fast)",
        sizeDescription: "~535 MB",
        fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf",
        expectedSHA256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
        expectedByteCount: 532_517_120,
        maxTokenCount: 4096,
        recommendation: .veryFast
    )

    static let recommendedFastModel = CleanupModelDescriptor(
        kind: .qwen35_2b_q4_k_m,
        displayName: "Qwen 3.5 2B Q4_K_M (Fast)",
        sizeDescription: "~1.3 GB",
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf",
        expectedSHA256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
        expectedByteCount: 1_280_835_840,
        maxTokenCount: 4096,
        recommendation: .fast
    )

    static let recommendedFullModel = CleanupModelDescriptor(
        kind: .qwen35_4b_q4_k_m,
        displayName: "Qwen 3.5 4B Q4_K_M (Full)",
        sizeDescription: "~2.8 GB",
        fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf",
        expectedSHA256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
        expectedByteCount: 2_740_937_888,
        maxTokenCount: 8192,
        recommendation: .full
    )

    /// DeepSeek R1 Distill Qwen 7B — Qwen 2.5 7B base distilled from R1
    /// reasoning traces. Stronger chain-of-thought for agent tool-use loops
    /// than vanilla Qwen 4B. Always emits `<think>...</think>` blocks before
    /// answers; the QwenToolCallParser strips those so they don't surface as
    /// visible text. Cleanup-quality is unverified — primarily added for the
    /// agent path.
    static let deepseekR1Qwen7BModel = CleanupModelDescriptor(
        kind: .deepseek_r1_qwen_7b_q4_k_m,
        displayName: "DeepSeek R1 Distill Qwen 7B Q4_K_M",
        sizeDescription: "~4.7 GB",
        fileName: "DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf",
        url: "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/361004151d4f4f6b446dc5e6d46fbf4422a80d5f/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf",
        expectedSHA256: "731ece8d06dc7eda6f6572997feb9ee1258db0784827e642909d9b565641937b",
        expectedByteCount: 4_683_073_504,
        maxTokenCount: 8192,
        recommendation: nil
    )

    static let cleanupModels = [
        compactModel,
        recommendedFastModel,
        recommendedFullModel,
        deepseekR1Qwen7BModel,
    ]
    static let cleanupGenerationModels = cleanupModels.filter { $0.runtime == .gguf }
    static let wikiGenerationModels = cleanupModels
    static let fastModel = recommendedFastModel
    static let fullModel = recommendedFullModel

    static func cleanupModelKind(matchingArchivedName archivedName: String) -> LocalCleanupModelKind {
        if let exactMatch = cleanupModels.first(where: { $0.displayName == archivedName }) {
            return exactMatch.kind
        }

        if archivedName.contains("0.8B") {
            return .qwen35_0_8b_q4_k_m
        }

        if archivedName.contains("2B") || archivedName.contains("1.7B") {
            return .qwen35_2b_q4_k_m
        }

        return .qwen35_4b_q4_k_m
    }

    var isReady: Bool { state == .ready }
    var selectedCleanupModelDisplayName: String {
        descriptor(for: selectedCleanupModelKind).displayName
    }

    var hasUsableModelForCurrentPolicy: Bool {
        isModelAvailable(selectedCleanupModelKind)
    }

    private static let timeoutSeconds: TimeInterval = 15.0
    private static let selectedCleanupModelDefaultsKey = "selectedCleanupModelKind"
    private static let systemPromptSentinel = "<|ghost-pepper-system-prefill-split|>"
    private static let userInputSentinel = "<|ghost-pepper-user-prefill-split|>"
    private static let repositoryDownloadMarkerFileName = ".ghostpepper-model-cache-complete"

    private let defaults: UserDefaults
    private let cleanupModelAvailabilityOverrides: [LocalCleanupModelKind: Bool]
    private let probeExecutionOverride: CleanupModelProbeExecutionOverride?
    private let backendShutdownOverride: (() -> Void)?
    /// Owns the lifetime of in-flight generations so a slow one is never
    /// cancelled and the model is never released underneath one. Ledger 27.
    /// The single owner of exclusive access to `activeLLM`, and the only thing
    /// that decides when it is safe to release. Replaced a gate plus a tracker
    /// that both claimed the job; every bug in Codex round 3 lived in the gap
    /// between them.
    private let llmLease: LLMLease
    private var promptPrefillTask: Task<Void, Never>?
    private var preparedPromptContext: PreparedPromptContext?
    /// Tracks the in-flight download/load Task so the UI can cancel it. We
    /// only allow one load at a time (the manager has a single `activeLLM`
    /// slot), so a Task? is sufficient.
    private var activeLoadTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        selectedCleanupModelKind: LocalCleanupModelKind? = nil,
        cleanupModelAvailabilityOverrides: [LocalCleanupModelKind: Bool] = [:],
        probeExecutionOverride: CleanupModelProbeExecutionOverride? = nil,
        backendShutdownOverride: (() -> Void)? = nil,
        // Injectable so tests can put a generation in flight without loading a
        // model. The generation lifetime is what ledger 27 turns on, and it is
        // otherwise only reachable through a real llama.cpp run.
        llmLease: LLMLease = LLMLease()
    ) {
        self.defaults = defaults
        self.cleanupModelAvailabilityOverrides = cleanupModelAvailabilityOverrides
        self.probeExecutionOverride = probeExecutionOverride
        self.backendShutdownOverride = backendShutdownOverride
        self.llmLease = llmLease

        let storedKind = LocalCleanupModelKind(
            rawValue: defaults.string(forKey: Self.selectedCleanupModelDefaultsKey) ?? ""
        ) ?? .qwen35_0_8b_q4_k_m
        let initialKind = selectedCleanupModelKind ?? storedKind
        self.selectedCleanupModelKind = initialKind
        defaults.set(initialKind.rawValue, forKey: Self.selectedCleanupModelDefaultsKey)
    }

    func selectedModelKind(wordCount: Int, isQuestion: Bool) -> LocalCleanupModelKind? {
        isModelAvailable(selectedCleanupModelKind) ? selectedCleanupModelKind : nil
    }

    var statusText: String {
        switch state {
        case .idle:
            return ""
        case .downloading(_, let progress):
            let pct = Int(progress * 100)
            return "Downloading cleanup models (\(pct)%)..."
        case .loadingModel:
            return "Loading cleanup models..."
        case .ready:
            return ""
        case .error:
            return errorMessage ?? "Cleanup model error"
        }
    }

    private var modelsDirectory: URL {
        Self.modelsDirectory
    }

    private func modelPath(for fileName: String) -> URL {
        modelsDirectory.appendingPathComponent(fileName)
    }

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GhostPepper/models", isDirectory: true)
    }

    static func isModelDownloaded(_ kind: LocalCleanupModelKind) -> Bool {
        guard let desc = cleanupModels.first(where: { $0.kind == kind }) else { return false }
        let path = modelsDirectory.appendingPathComponent(desc.fileName)
        return isVerifiedModelFile(path, descriptor: desc)
    }

    func isModelDownloaded(_ kind: LocalCleanupModelKind) -> Bool {
        Self.isModelDownloaded(kind)
    }

    /// Ledger 27: async for the same reason as `unloadModel()`. Deleting the
    /// file on disk is safe at any time; releasing the loaded model is not.
    func deleteCachedModel(kind: LocalCleanupModelKind) async {
        let desc = descriptor(for: kind)
        let path = modelPath(for: desc.fileName)
        try? FileManager.default.removeItem(at: path)

        if activeLoadedModelKind == kind {
            await beginGenerationBarrier()
            activeLLM = nil
            activeLoadedModelKind = nil
            state = .idle
            errorMessage = nil
            await endGenerationBarrier()
            return
        }

        objectWillChange.send()
    }

    func clean(text: String, prompt: String? = nil, modelKind: LocalCleanupModelKind? = nil) async throws -> String {
        let requestedModelKind = modelKind ?? selectedCleanupModelKind
        await loadModel(kind: requestedModelKind)

        // `isModelAvailable` rather than `model(for:) != nil`, because the
        // override above deliberately does not manufacture an `LLM`. Asking for
        // a live object here would make an honoured override look unavailable,
        // and the test would fail for a reason that has nothing to do with what
        // it is testing.
        guard isModelAvailable(requestedModelKind) else {
            debugLogger?(
                .cleanup,
                "Skipped local cleanup because model \(requestedModelKind.rawValue) was not ready."
            )
            throw CleanupBackendError.unavailable
        }

        let activePrompt = prompt ?? TextCleaner.defaultPrompt
        do {
            let result = try await probe(
                text: text,
                prompt: activePrompt,
                modelKind: requestedModelKind,
                thinkingMode: .suppressed
            )
            let cleaned = result.rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || cleaned == "..." {
                debugLogger?(
                    .cleanup,
                    """
                    Discarded local cleanup output from \(descriptor(for: requestedModelKind).displayName) because it was unusable:
                    \(result.rawOutput)
                    """
                )
                throw CleanupBackendError.unusableOutput(rawOutput: result.rawOutput)
            }
            return cleaned
        } catch let error as CleanupBackendError {
            throw error
        } catch let error as CleanupModelProbeError {
            switch error {
            case .modelUnavailable:
                throw CleanupBackendError.unavailable
            }
        } catch {
            debugLogger?(
                .cleanup,
                "Local cleanup probe failed before producing usable output: \(error.localizedDescription)"
            )
            throw CleanupBackendError.unavailable
        }
    }

    /// Streams raw completion tokens from a local Qwen model using a
    /// fully-formed prompt string. The caller is responsible for any
    /// chat-template framing (e.g. Qwen3's `<|im_start|>` markers); this method
    /// passes the prompt straight to the model and yields tokens as they
    /// arrive. Used by `LocalLLMProvider` to drive the agent loop.
    ///
    /// Acquires the same probe gate as `clean()` so concurrent local cleanup
    /// and agent runs don't share KV-cache state.
    func streamCompletion(
        prompt: String,
        modelKind: LocalCleanupModelKind? = nil,
        thinkingMode: ThinkingMode = .suppressed
    ) async throws -> AsyncStream<String> {
        let requestedModelKind = modelKind ?? selectedCleanupModelKind
        await loadModel(kind: requestedModelKind)
        let requestedDescriptor = descriptor(for: requestedModelKind)

        if case .mlxRepository = requestedDescriptor.runtime {
            throw CleanupBackendError.unsupportedRuntime(
                "\(requestedDescriptor.displayName) is downloaded/selectable, but MLX inference is not wired into AF Flow yet. Choose a GGUF model such as Qwen 3.5 4B, or wire the MLX provider next."
            )
        }

        // Ledger 27, Codex round 3 finding 2: the model must be looked up AFTER
        // the lease is held. Looking it up first lets a queued stream retain an
        // `LLM` that teardown then releases, and resume on a freed instance.
        let ticket: LLMLease.Ticket
        do {
            ticket = try await llmLease.acquire()
        } catch {
            throw CleanupBackendError.unavailable
        }

        guard let llm = model(for: requestedModelKind) else {
            debugLogger?(
                .cleanup,
                "Skipped local stream completion because model \(requestedModelKind.rawValue) was not ready."
            )
            await llmLease.release(ticket)
            throw CleanupBackendError.unavailable
        }

        await llm.core.resetContext()

        let (stream, continuation) = AsyncStream<String>.makeStream()
        let lease = llmLease
        // Consumers stopping early must NOT cancel the generation: cancelling
        // an in-flight llama.cpp run is the abort trigger this whole change
        // exists to remove. They set a flag; the generation runs to completion
        // and its remaining tokens are simply not yielded.
        let stopped = StreamStopFlag()
        Task { @MainActor in
            let response = await llm.core.generateResponseStream(
                from: prompt,
                thinking: thinkingMode
            )
            for await token in response {
                if stopped.value { continue }
                continuation.yield(token)
            }
            // The lease is released only when the generation genuinely ends,
            // never when the consumer walks away.
            await lease.release(ticket)
            continuation.finish()
        }
        continuation.onTermination = { _ in
            stopped.value = true
        }
        return stream
    }

    func startPromptPrefill(systemPromptPrefix: String, modelKind: LocalCleanupModelKind? = nil) {
        let requestedModelKind = modelKind ?? selectedCleanupModelKind
        guard systemPromptPrefix.isEmpty == false else {
            preparedPromptContext = nil
            promptPrefillTask?.cancel()
            promptPrefillTask = nil
            return
        }

        if let preparedPromptContext,
           preparedPromptContext.modelKind == requestedModelKind,
           preparedPromptContext.plan.systemPromptPrefix == systemPromptPrefix {
            return
        }

        promptPrefillTask?.cancel()
        promptPrefillTask = Task { @MainActor [weak self] in
            await self?.prefillPromptContext(
                systemPromptPrefix: systemPromptPrefix,
                modelKind: requestedModelKind
            )
        }
    }

    func cancelPromptPrefill() {
        promptPrefillTask?.cancel()
        promptPrefillTask = nil
        preparedPromptContext = nil
    }

    func probe(
        text: String,
        prompt: String,
        modelKind: LocalCleanupModelKind,
        thinkingMode: CleanupModelProbeThinkingMode
    ) async throws -> CleanupModelProbeRawResult {
        // The deadline covers acquiring the model AND generating with it.
        // Charging the full timeout twice would let a queued cleanup wait
        // nearly thirty seconds, which is the latency this budget exists to cap.
        let probeStarted = Date()
        let probeTicket: LLMLease.Ticket
        do {
            probeTicket = try await llmLease.acquire(within: Self.timeoutSeconds)
        } catch {
            debugLogger?(.cleanup, "Skipped local cleanup probe: the model was busy or being unloaded.")
            throw CleanupModelProbeError.modelUnavailable(modelKind)
        }

        do {
            if let probeExecutionOverride {
                // Codex finding 2: a throwing override used to jump past the
                // release and leave the lease held forever, which would then
                // block every later cleanup, stream, prefill and teardown.
                do {
                    let result = try await probeExecutionOverride(text, prompt, modelKind, thinkingMode)
                    await llmLease.release(probeTicket)
                    return result
                } catch {
                    await llmLease.release(probeTicket)
                    throw error
                }
            }

            guard let llm = model(for: modelKind) else {
                debugLogger?(
                    .cleanup,
                    "Skipped local cleanup probe because model \(modelKind) was not ready."
                )
                await llmLease.release(probeTicket)
                throw CleanupModelProbeError.modelUnavailable(modelKind)
            }

            let start = Date()
            do {
                let preparedCompletionInput: String?
                if let preparedPromptContext,
                   preparedPromptContext.modelKind == modelKind,
                   let completionInput = preparedPromptContext.plan.completionInput(
                    for: prompt,
                    userInput: text
                   ) {
                    preparedCompletionInput = completionInput
                    self.preparedPromptContext = nil
                } else {
                    preparedCompletionInput = nil
                }

                // Codex found a self-deadlock here: this used to call
                // `withTimeout`, which acquires the lease, while `probe` was
                // already holding it. The lease is not re-entrant, so every real
                // cleanup would have waited out the full deadline against itself
                // and failed without ever reaching the model. The tests missed
                // it because they either drive the lease directly or use
                // `probeExecutionOverride`.
                //
                // `run(holding:)` takes ownership of the ticket and releases it
                // when the generation actually finishes, so nothing below may
                // release it.
                let rawOutput: String
                if let preparedCompletionInput {
                    rawOutput = try await llmLease.run(
                        holding: probeTicket,
                        deadline: Self.timeoutSeconds - Date().timeIntervalSince(probeStarted)
                    ) { [self] in
                        await generateFromPreparedContext(
                            llm: llm,
                            completionInput: preparedCompletionInput,
                            thinkingMode: thinkingMode
                        )
                    }
                } else {
                    rawOutput = try await llmLease.run(
                        holding: probeTicket,
                        deadline: Self.timeoutSeconds - Date().timeIntervalSince(probeStarted)
                    ) {
                        llm.useResolvedTemplate(systemPrompt: prompt)
                        llm.history = []
                        await llm.respond(to: text, thinking: thinkingMode.llmThinkingMode)
                        return llm.output
                    }
                }
                let elapsed = Date().timeIntervalSince(start)
                debugLogger?(
                    .cleanup,
                    "Local cleanup finished in \(String(format: "%.2f", elapsed))s using \(descriptor(for: modelKind).displayName)."
                )
                // Ownership of the ticket passed to `run(holding:)`.
                return CleanupModelProbeRawResult(
                    modelKind: modelKind,
                    modelDisplayName: descriptor(for: modelKind).displayName,
                    rawOutput: rawOutput,
                    elapsed: elapsed
                )
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                debugLogger?(
                    .cleanup,
                    "Local cleanup failed after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)"
                )
                // Ownership of the ticket passed to `run(holding:)`, which
                // releases it when the generation ends. Releasing here would
                // free a lease that work still holds.
                throw error
            }
        } catch {
            throw error
        }
    }

    func loadModel() async {
        await loadModel(kind: selectedCleanupModelKind)
    }

    func downloadMissingModels() async {
        guard state == .idle || state == .error || state == .ready else { return }

        errorMessage = nil
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        for descriptor in Self.cleanupModels {
            guard descriptor.runtime == .gguf else {
                continue
            }
            let path = modelPath(for: descriptor.fileName)
            guard !Self.isVerifiedModelFile(path, descriptor: descriptor) else {
                continue
            }
            try? FileManager.default.removeItem(at: path)

            do {
                try await downloadModel(kind: descriptor.kind, url: descriptor.url, to: path)
            } catch {
                self.errorMessage = "Failed to download cleanup model: \(error.localizedDescription)"
                self.state = .error
                debugLogger?(.model, self.errorMessage ?? "Failed to download cleanup model.")
                return
            }
        }

        state = .idle
        await loadModel()
    }

    func loadModel(kind: LocalCleanupModelKind) async {
        if activeLoadedModelKind == kind && activeLLM != nil {
            state = .ready
            errorMessage = nil
            return
        }

        if case .loadingModel = state {
            await waitForActiveLoad()
            if activeLoadedModelKind == kind && activeLLM != nil {
                state = .ready
                errorMessage = nil
                return
            }
        }

        guard state == .idle || state == .error || state == .ready else { return }

        // AN AVAILABILITY OVERRIDE IS ANSWERED HERE IN BOTH DIRECTIONS, and the
        // asymmetry it replaces cost 4.02 GB of downloads on 2026-07-26.
        //
        // This used to read `if let override = ..., !override`, so only FALSE
        // was handled. A test that said "this model is available" therefore fell
        // straight through to the disk check below and then to `downloadModel`,
        // which opens a real URLSession to huggingface.co. Three tests in
        // TextCleanupManagerTests do exactly that, and between them they pull
        // Qwen 3.5 2B and 4B. It was invisible for a month because the suite ran
        // inside the app's own container, where those files already existed: a
        // warm cache was standing in for a gate, and separating the test host's
        // container removed the disguise rather than the defect.
        //
        // An override is a test saying "pretend this model is loaded", so it is
        // honoured as stated. `activeLoadedModelKind` and `activeLLM` are
        // deliberately NOT set: the override is a claim about availability, not
        // a real model, and manufacturing a fake `LLM` would put a lie somewhere
        // production code could read it.
        if let override = availabilityOverride(for: kind) {
            if override {
                state = .ready
                errorMessage = nil
            } else {
                errorMessage = "Failed to load the selected cleanup model."
                state = .error
            }
            return
        }

        errorMessage = nil
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let descriptor = descriptor(for: kind)
        let path = modelPath(for: descriptor.fileName)
        debugLogger?(.model, "Loading local cleanup model \(descriptor.displayName).")

        if FileManager.default.fileExists(atPath: path.path), !Self.isVerifiedModelFile(path, descriptor: descriptor) {
            try? FileManager.default.removeItem(at: path)
            debugLogger?(.model, "Removed local cleanup model with failed integrity check: \(descriptor.displayName).")
        }

        if !FileManager.default.fileExists(atPath: path.path) {
            do {
                try await downloadModel(kind: kind, url: descriptor.url, to: path)
            } catch {
                // User-initiated cancellation should drop the row back to
                // "not downloaded" without surfacing a scary red error.
                let nsError = error as NSError
                let isCancelled = error is CancellationError
                    || nsError.code == NSURLErrorCancelled
                    || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
                if isCancelled {
                    self.state = .idle
                    self.errorMessage = nil
                    debugLogger?(.model, "Cleanup model download cancelled: \(descriptor.displayName).")
                } else {
                    self.errorMessage = "Failed to download cleanup model: \(error.localizedDescription)"
                    self.state = .error
                    debugLogger?(.model, self.errorMessage ?? "Failed to download cleanup model.")
                }
                return
            }
        }

        if case .mlxRepository = descriptor.runtime {
            errorMessage = "Downloaded \(descriptor.displayName). MLX inference is not wired into AF Flow yet."
            state = .error
            debugLogger?(.model, errorMessage ?? "MLX model downloaded but runtime unavailable.")
            return
        }

        state = .loadingModel(kind: kind)
        // Ledger 27: swapping models releases the previous one, which is the
        // same hazard as unloading it. Hold the barrier while it is released.
        await beginGenerationBarrier()
        activeLLM = nil
        activeLoadedModelKind = nil
        await endGenerationBarrier()

        let loadedModel = await Task.detached { () -> LLM? in
            guard let llm = LLM(from: path, maxTokenCount: descriptor.maxTokenCount) else {
                return nil
            }
            llm.useResolvedTemplate(systemPrompt: TextCleaner.defaultPrompt)
            return llm
        }.value

        guard let loadedModel else {
            errorMessage = "Failed to load the selected cleanup model."
            state = .error
            debugLogger?(.model, "Local cleanup model unavailable: \(descriptor.displayName).")
            return
        }

        loadedModel.temp = 0.1
        loadedModel.update = { (_: String?) in }
        loadedModel.postprocess = { (_: String) in }
        activeLLM = loadedModel
        activeLoadedModelKind = kind
        state = .ready
        errorMessage = nil
        debugLogger?(.model, "Local cleanup model ready: \(descriptor.displayName).")
    }

    /// Kicks off a tracked `loadModel(kind:)` so callers can later cancel it
    /// via `cancelActiveLoad()`. If a load Task is already in flight for the
    /// same kind, returns without starting a duplicate; otherwise the prior
    /// Task is cancelled and replaced.
    func startLoad(kind: LocalCleanupModelKind) {
        if let activeLoadTask, !activeLoadTask.isCancelled,
           case let .downloading(activeKind, _) = state, activeKind == kind {
            return
        }
        if let activeLoadTask, !activeLoadTask.isCancelled,
           case let .loadingModel(activeKind) = state, activeKind == kind {
            return
        }
        activeLoadTask?.cancel()
        activeLoadTask = Task { @MainActor [weak self] in
            await self?.loadModel(kind: kind)
            self?.activeLoadTask = nil
        }
    }

    /// Cancels whatever the manager is currently downloading or loading.
    /// `URLSession.download(from:)` is cancellation-aware, so the in-flight
    /// transfer aborts at the next suspension point.
    func cancelActiveLoad() {
        activeLoadTask?.cancel()
        activeLoadTask = nil
    }

    /// Surface for UI: is there an active load Task we can cancel? Used to
    /// decide whether to render the cancel affordance — passively-displayed
    /// progress (e.g. a stale `.downloading` from a prior session) shouldn't
    /// show one.
    var isLoadCancellable: Bool {
        guard let activeLoadTask else { return false }
        return !activeLoadTask.isCancelled
    }

    /// Ledger 27: async because it must wait for any in-flight generation
    /// before releasing the model. Freeing GGML resources under a running
    /// generation calls `ggml_abort`, which kills the process.
    func unloadModel() async {
        await beginGenerationBarrier()
        activeLLM = nil
        activeLoadedModelKind = nil
        state = .idle
        errorMessage = nil
        await endGenerationBarrier()
        debugLogger?(.model, "Unloaded local cleanup models.")
    }

    /// Synchronous shutdown for app termination only.
    ///
    /// `willTerminateNotification` arrives on the main thread while the process
    /// is already going away, so there is no opportunity to await a drain: a
    /// Task spawned there is unlikely to run, and blocking the main thread would
    /// deadlock any @MainActor work it waited on.
    ///
    /// So the choice is made synchronously. With no generation running, the
    /// backend shuts down exactly as it always did. With one running, the
    /// shutdown is SKIPPED, because freeing GGML resources under a live
    /// generation calls `ggml_abort` (ledger 27) and would turn a clean quit
    /// into a crash report. Skipping costs nothing: the process is exiting and
    /// the OS reclaims everything anyway.
    func shutdownBackendForTermination() {
        guard !llmLease.isHeldSynchronously else {
            debugLogger?(
                .model,
                "Skipped llama backend shutdown at termination: a cleanup generation is still running, and releasing the model under one aborts the process."
            )
            return
        }

        activeLLM = nil
        activeLoadedModelKind = nil
        state = .idle
        errorMessage = nil

        if let backendShutdownOverride {
            backendShutdownOverride()
        } else {
            LLM.shutdownBackend()
        }
        debugLogger?(.model, "Shutdown llama backend.")
    }

    /// Codex round 3 finding 3: this used to call `unloadModel()`, which
    /// released the barrier before `LLM.shutdownBackend()` ran, leaving a window
    /// in which new work could start on a backend about to be torn down. The
    /// barrier is now held across the whole sequence rather than reacquired.
    func shutdownBackend() async {
        await beginGenerationBarrier()

        activeLLM = nil
        activeLoadedModelKind = nil
        state = .idle
        errorMessage = nil

        if let backendShutdownOverride {
            backendShutdownOverride()
        } else {
            LLM.shutdownBackend()
        }

        await endGenerationBarrier()
        debugLogger?(.model, "Shutdown llama backend.")
    }

    var cachedModelKinds: Set<LocalCleanupModelKind> {
        Set(Self.cleanupModels.compactMap { descriptor in
            if let override = availabilityOverride(for: descriptor.kind) {
                return override ? descriptor.kind : nil
            }

            return Self.isPlausibleCachedModelFile(modelPath(for: descriptor.fileName), descriptor: descriptor)
                ? descriptor.kind
                : nil
        })
    }

    /// True when this process was launched by XCTest.
    ///
    /// Anchored to what XCTest itself sets, not to a flag anyone must remember
    /// to pass, and not to a list of tests someone has to keep up to date.
    static let isRunningUnderTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    private func downloadModel(kind: LocalCleanupModelKind, url urlString: String, to destination: URL) async throws {
        // THE TEST SUITE NEVER REACHES THE NETWORK. This is the single choke
        // point where a cleanup model is fetched, so the rule lives here rather
        // than at each of the call sites that can arrive at it.
        //
        // The earlier fix, on this same day, made an availability override
        // honoured in both directions. That closed the tests that SET an
        // override and left open every test that sets none at all: with an
        // empty overrides dictionary `availabilityOverride` returns nil, the
        // guard does not fire, and the download proceeds. A cold test container
        // then fetched 188 MB of Qwen 3.5 0.8B before the run ended and killed
        // it, which is how this was found: the app's own debug log, written by
        // the test host, says "Loading local cleanup model Qwen 3.5 0.8B".
        //
        // That is the second time today I fixed the reported instance and left
        // the class open, which is this project's signature error. So the rule
        // is stated over the capability rather than over the callers: under
        // XCTest, this method does not exist.
        if Self.isRunningUnderTests {
            debugLogger?(
                .model,
                "Refused to download \(kind.rawValue): the test suite must never reach the network."
            )
            state = .error
            errorMessage = "Cleanup model is not cached, and tests never download."
            throw CleanupBackendError.unavailable
        }

        let descriptor = descriptor(for: kind)
        if case .mlxRepository(let repoID) = descriptor.runtime {
            try await downloadHuggingFaceRepository(kind: kind, repoID: repoID, to: destination)
            return
        }

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        state = .downloading(kind: kind, progress: 0)

        let delegate = DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor in
                self?.state = .downloading(kind: kind, progress: progress)
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tempURL, _) = try await session.download(from: url)
        guard Self.isVerifiedModelFile(tempURL, descriptor: descriptor) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw URLError(.cannotDecodeContentData)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func model(for modelKind: LocalCleanupModelKind) -> LLM? {
        activeLoadedModelKind == modelKind ? activeLLM : nil
    }

    /// Looks up the descriptor for a model kind. Falls back to `compactModel`
    /// (the smallest/safest default) instead of force-unwrapping when the
    /// kind isn't in `cleanupModels` — e.g. a stale stored selection like
    /// `.gemma4_12b_it_optiq_4bit_mlx` that predates its descriptor removal
    /// and reaches this function through a path that bypasses the migration
    /// in `AppState.init`.
    private func descriptor(for modelKind: LocalCleanupModelKind) -> CleanupModelDescriptor {
        Self.cleanupModels.first(where: { $0.kind == modelKind }) ?? Self.compactModel
    }

    private func availabilityOverride(for modelKind: LocalCleanupModelKind) -> Bool? {
        guard !cleanupModelAvailabilityOverrides.isEmpty else {
            return nil
        }

        return cleanupModelAvailabilityOverrides[modelKind] ?? false
    }

    private func waitForActiveLoad() async {
        while case .loadingModel = state {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Waits up to `seconds` for a generation WITHOUT cancelling it.
    ///
    /// Ledger 27: the previous implementation raced generation against a sleep
    /// in a task group and called `group.cancelAll()` on timeout. Cancelling an
    /// in-flight llama.cpp generation trips `GGML_ASSERT` in
    /// `ggml_metal_device_free`, and llama.cpp answers that with `ggml_abort`,
    /// which kills the process rather than throwing. See
    /// `CleanupGenerationTracker` for the full account.
    ///
    /// The deadline now bounds only how long the caller waits. Every site that
    /// releases `activeLLM` calls `awaitGenerationDrain()` first, so the model
    /// is never freed under a running generation.
    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T) async throws -> T {
        try await llmLease.run(deadline: seconds, operation: operation)
    }

    /// Blocks new LLM work and waits for live work to finish. Must be called
    /// before releasing the model, and balanced with `endGenerationBarrier()`.
    ///
    /// Codex round 2 finding 2: merely waiting was not enough, because a second
    /// caller can enter while the first drains and then be running when the
    /// model is released.
    private func beginGenerationBarrier() async {
        await llmLease.beginTeardown()
    }

    private func endGenerationBarrier() async {
        await llmLease.endTeardown()
    }

    private func prefillPromptContext(
        systemPromptPrefix: String,
        modelKind: LocalCleanupModelKind
    ) async {
        await loadModel(kind: modelKind)

        // Prefill is background warm-up with no latency budget of its own, so
        // it waits rather than racing a deadline. The lease is acquired before
        // the model is looked up, so it cannot retain an instance teardown is
        // about to release.
        let ticket: LLMLease.Ticket
        do {
            ticket = try await llmLease.acquire()
        } catch {
            preparedPromptContext = nil
            return
        }

        guard let llm = model(for: modelKind) else {
            preparedPromptContext = nil
            await llmLease.release(ticket)
            return
        }

        let sentinelPrompt = systemPromptPrefix + Self.systemPromptSentinel
        llm.useResolvedTemplate(systemPrompt: sentinelPrompt)
        llm.history = []
        let processedPrompt = llm.preprocess(
            Self.userInputSentinel,
            [],
            .suppressed
        )
        guard let plan = CleanupPromptPrefillPlan(
            systemPromptPrefix: systemPromptPrefix,
            processedPrompt: processedPrompt,
            systemPromptSentinel: Self.systemPromptSentinel,
            userInputSentinel: Self.userInputSentinel
        ) else {
            preparedPromptContext = nil
            await llmLease.release(ticket)
            return
        }

        await llm.core.resetContext()
        let prepared = await llm.core.prepareContext(for: plan.contextPrefix)
        preparedPromptContext = prepared
            ? PreparedPromptContext(modelKind: modelKind, plan: plan)
            : nil
        await llmLease.release(ticket)
    }

    private func generateFromPreparedContext(
        llm: LLM,
        completionInput: String,
        thinkingMode: CleanupModelProbeThinkingMode
    ) async -> String {
        llm.setOutput(to: "")
        llm.setThinking(to: "")

        let response = await llm.core.generateResponseStream(
            from: completionInput,
            thinking: thinkingMode.llmThinkingMode
        )

        var output = ""
        for await content in response {
            output += content
        }

        llm.setOutput(to: output)
        return output
    }

    private func isModelAvailable(_ modelKind: LocalCleanupModelKind) -> Bool {
        if let override = availabilityOverride(for: modelKind) {
            return override
        }

        if activeLoadedModelKind == modelKind && activeLLM != nil {
            return true
        }

        let descriptor = descriptor(for: modelKind)
        return Self.isVerifiedModelFile(modelPath(for: descriptor.fileName), descriptor: descriptor)
    }

    private static func isVerifiedModelFile(_ url: URL, descriptor: CleanupModelDescriptor) -> Bool {
        if case .mlxRepository = descriptor.runtime {
            return isVerifiedRepository(url)
        }

        guard isPlausibleCachedModelFile(url, descriptor: descriptor) else { return false }
        return (try? sha256Hex(of: url)) == descriptor.expectedSHA256
    }

    private static func isPlausibleCachedModelFile(_ url: URL, descriptor: CleanupModelDescriptor) -> Bool {
        if case .mlxRepository = descriptor.runtime {
            return isVerifiedRepository(url)
        }

        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              Int64(values.fileSize ?? -1) == descriptor.expectedByteCount else {
            return false
        }
        return true
    }

    private static func isVerifiedRepository(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent(repositoryDownloadMarkerFileName).path
        )
    }

    private func downloadHuggingFaceRepository(kind: LocalCleanupModelKind, repoID: String, to destination: URL) async throws {
        guard let apiURL = URL(string: "https://huggingface.co/api/models/\(repoID)") else {
            throw URLError(.badURL)
        }

        state = .downloading(kind: kind, progress: 0)
        let (infoData, _) = try await URLSession.shared.data(from: apiURL)
        let info = try JSONDecoder().decode(HuggingFaceModelInfo.self, from: infoData)
        let files = info.siblings.filter { sibling in
            !sibling.rfilename.hasPrefix(".") && !sibling.rfilename.hasSuffix(".md")
        }

        guard !files.isEmpty else {
            throw URLError(.fileDoesNotExist)
        }

        let tempDirectory = modelsDirectory.appendingPathComponent("\(destination.lastPathComponent).download", isDirectory: true)
        try? FileManager.default.removeItem(at: tempDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        do {
            let knownTotalBytes = files.compactMap(\.size).reduce(Int64(0), +)
            var completedBytes: Int64 = 0

            for file in files {
                try Task.checkCancellation()
                guard let encodedFile = file.rfilename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let fileURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(encodedFile)") else {
                    throw URLError(.badURL)
                }
                let localURL = tempDirectory.appendingPathComponent(file.rfilename)
                try FileManager.default.createDirectory(
                    at: localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let (downloadedURL, _) = try await URLSession.shared.download(from: fileURL)
                try? FileManager.default.removeItem(at: localURL)
                try FileManager.default.moveItem(at: downloadedURL, to: localURL)
                completedBytes += file.size ?? 0
                if knownTotalBytes > 0 {
                    state = .downloading(kind: kind, progress: min(0.99, Double(completedBytes) / Double(knownTotalBytes)))
                }
            }

            let marker = tempDirectory.appendingPathComponent(Self.repositoryDownloadMarkerFileName)
            try Data("repo=\(repoID)\ndownloadedAt=\(ISO8601DateFormatter().string(from: Date()))\n".utf8).write(to: marker)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempDirectory, to: destination)
            state = .downloading(kind: kind, progress: 1)
        } catch {
            try? FileManager.default.removeItem(at: tempDirectory)
            throw error
        }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Download Progress

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by the async download(from:) call
    }
}
