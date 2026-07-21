import XCTest
@testable import GhostPepper

private final class SpyCleanupBackend: CleanupBackend {
    var cleanedInputs: [(text: String, prompt: String, modelKind: LocalCleanupModelKind?)] = []
    var nextResult: Result<String, Error>

    init(nextResult: Result<String, Error>) {
        self.nextResult = nextResult
    }

    func clean(text: String, prompt: String, modelKind: LocalCleanupModelKind?) async throws -> String {
        cleanedInputs.append((text: text, prompt: prompt, modelKind: modelKind))
        return try nextResult.get()
    }
}

@MainActor
final class TextCleanerTests: XCTestCase {
    func testPreferredTranscriptionsDoNotRewriteModelInput() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.preferredTranscriptionsText = "Ghost Pepper"
        let localBackend = SpyCleanupBackend(nextResult: .success("ghost pepper is ready"))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "Ghost Pepper is ready", prompt: "unused prompt")

        XCTAssertEqual(result, "ghost pepper is ready")
        XCTAssertEqual(
            localBackend.cleanedInputs.map(\.text),
            [TextCleaner.formatCleanupInput(userInput: "Ghost Pepper is ready")]
        )
    }

    func testCommonlyMisheardReplacementStaysInPromptAndDoesNotRewriteModelInput() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "chat gbt -> ChatGPT"
        let localBackend = SpyCleanupBackend(nextResult: .success("ChatGPT fixes text"))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "chat gbt fixes text", prompt: "unused prompt")

        XCTAssertEqual(result, "ChatGPT fixes text")
        XCTAssertEqual(
            localBackend.cleanedInputs.map(\.text),
            [TextCleaner.formatCleanupInput(userInput: "chat gbt fixes text")]
        )
    }

    func testCleanerFallsBackToCorrectedRawTextWhenBackendFails() async {
        let localBackend = SpyCleanupBackend(nextResult: .failure(CleanupBackendError.unavailable))
        let cleaner = TextCleaner(
            localBackend: localBackend
        )
        let text = "Keep this exactly as spoken."

        let result = await cleaner.clean(text: text, prompt: "unused prompt")

        XCTAssertEqual(result, text)
        XCTAssertEqual(
            localBackend.cleanedInputs.map(\.text),
            [TextCleaner.formatCleanupInput(userInput: text)]
        )
    }

    func testCleanupInputWrapsNormalizedUserInput() {
        let formatted = TextCleaner.formatCleanupInput(userInput: "ChatGPT fixes text")

        XCTAssertTrue(formatted.contains("<USER-INPUT>"))
        XCTAssertTrue(formatted.contains("ChatGPT fixes text"))
        XCTAssertTrue(formatted.contains("</USER-INPUT>"))
        XCTAssertFalse(formatted.contains("<RAW_TRANSCRIPTION>"))
        XCTAssertFalse(formatted.contains("<NORMALIZED_TRANSCRIPTION>"))
    }

    func testCleanerReturnsRawInputWhenCleanupBackendIsUnavailable() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "just see -> Jesse"
        let localBackend = SpyCleanupBackend(nextResult: .failure(CleanupBackendError.unavailable))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "just see approved it", prompt: "unused prompt")

        XCTAssertEqual(result, "just see approved it")
    }

    func testPreferredTranscriptionsDoNotRewriteCleanupOutput() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.preferredTranscriptionsText = "Ghost Pepper"
        let localBackend = SpyCleanupBackend(nextResult: .success("ghost-pepper is ready"))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "Ghost Pepper is ready", prompt: "unused prompt")

        XCTAssertEqual(result, "ghost-pepper is ready")
    }

    func testCommonlyMisheardReplacementSpecialCharactersArePromptHintsOnly() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "environment -> $HOME C:\\\\temp"
        let localBackend = SpyCleanupBackend(nextResult: .success(#"$HOME C:\\temp"#))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "environment", prompt: "unused prompt")

        XCTAssertEqual(result, #"$HOME C:\\temp"#)
        XCTAssertEqual(
            localBackend.cleanedInputs.map(\.text),
            [TextCleaner.formatCleanupInput(userInput: "environment")]
        )
    }

    func testCleanerStripsThinkBlocksFromCleanupOutput() async {
        let localBackend = SpyCleanupBackend(
            nextResult: .success(
                """
                <think>
                internal reasoning
                </think>

                Final cleaned text
                """
            )
        )
        let cleaner = TextCleaner(
            localBackend: localBackend
        )

        let result = await cleaner.clean(text: "raw text", prompt: "unused prompt")

        XCTAssertEqual(result, "Final cleaned text")
    }

    /// Renamed and re-pointed on 2026-07-20. It previously asserted the result
    /// was `""` and so encoded a data-loss bug as intended behaviour: an
    /// unterminated `<think>` block consumed the whole response, the empty
    /// string was returned as a success, and the user's dictation vanished with
    /// no clipboard fallback and no error. The stripping is still correct; what
    /// was wrong is what happens when stripping leaves nothing behind.
    func testCleanerFallsBackToRawTextWhenAnUnterminatedThinkBlockConsumesTheOutput() async {
        let localBackend = SpyCleanupBackend(
            nextResult: .success(
                """
                <think>
                internal reasoning that never closes
                """
            )
        )
        let cleaner = TextCleaner(
            localBackend: localBackend
        )

        let result = await cleaner.clean(text: "raw text", prompt: "unused prompt")

        XCTAssertEqual(
            result,
            "raw text",
            "losing the user's words is never an acceptable outcome; uncleaned text is"
        )
    }

    /// The closed-tag sibling of the case above. A model that replies with only
    /// a complete `<think>...</think>` block is the realistic shape for a
    /// reasoning model such as DeepSeek R1, whose descriptor states it always
    /// emits reasoning before answers.
    func testCleanerFallsBackToRawTextWhenTheOutputIsOnlyAClosedThinkBlock() async {
        let localBackend = SpyCleanupBackend(
            nextResult: .success("<think>all reasoning, no answer</think>")
        )
        let cleaner = TextCleaner(
            localBackend: localBackend
        )

        let result = await cleaner.clean(text: "raw text", prompt: "unused prompt")

        XCTAssertEqual(result, "raw text")
    }

    /// Guards the fallback from becoming over-eager: when sanitizing leaves
    /// real content, that content must still win over the raw input.
    func testCleanerKeepsSanitizedContentWhenStrippingLeavesSomethingBehind() async {
        let localBackend = SpyCleanupBackend(
            nextResult: .success("<think>reasoning</think>Cleaned sentence.")
        )
        let cleaner = TextCleaner(
            localBackend: localBackend
        )

        let result = await cleaner.clean(text: "raw text", prompt: "unused prompt")

        XCTAssertEqual(result, "Cleaned sentence.")
    }

    func testCleanerLogsPromptInputToSensitiveLogger() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "chat gbt -> ChatGPT"
        correctionStore.preferredTranscriptionsText = "Ghost Pepper"
        let localBackend = SpyCleanupBackend(nextResult: .success("ghost-pepper is ready"))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )
        var sensitiveMessages: [String] = []
        cleaner.sensitiveDebugLogger = { _, message in
            sensitiveMessages.append(message)
        }

        let result = await cleaner.clean(
            text: "chat gbt is ready",
            prompt: "Use OCR context if present."
        )

        XCTAssertEqual(result, "ghost-pepper is ready")
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Cleanup LLM transcript") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("System prompt") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("<USER-INPUT>") }))
        XCTAssertFalse(sensitiveMessages.contains(where: { $0.contains("User input:\n<USER-INPUT>") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Raw model output") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Final cleaned output") }))
        XCTAssertFalse(sensitiveMessages.contains(where: { $0.contains("Pre-cleanup corrections") }))
        XCTAssertFalse(sensitiveMessages.contains(where: { $0.contains("Post-cleanup corrections") }))
    }

    func testCleanerReportsModelAndPostProcessingDurations() async {
        let localBackend = SpyCleanupBackend(
            nextResult: .success(
                """
                <think>
                internal reasoning
                </think>

                Final cleaned text
                """
            )
        )
        let cleaner = TextCleaner(localBackend: localBackend)

        let result = await cleaner.cleanWithPerformance(text: "raw text", prompt: "unused prompt")

        XCTAssertEqual(result.text, "Final cleaned text")
        XCTAssertNotNil(result.performance.modelCallDuration)
        XCTAssertNotNil(result.performance.postProcessDuration)
    }

    func testCleanerCanForceSpecificCleanupModelKind() async {
        let localBackend = SpyCleanupBackend(nextResult: .success("cleaned"))
        let cleaner = TextCleaner(localBackend: localBackend)

        _ = await cleaner.cleanWithPerformance(
            text: "raw text",
            prompt: "unused prompt",
            modelKind: .fast
        )

        XCTAssertEqual(localBackend.cleanedInputs.map(\.modelKind), [.fast])
    }

    func testCleanerLeavesPromptUnchangedForCompactCleanupModel() async throws {
        let localBackend = SpyCleanupBackend(nextResult: .success("cleaned"))
        let cleaner = TextCleaner(localBackend: localBackend)

        _ = await cleaner.cleanWithPerformance(
            text: "raw text",
            prompt: "Base prompt",
            modelKind: .qwen35_0_8b_q4_k_m
        )

        let prompt = try XCTUnwrap(localBackend.cleanedInputs.first?.prompt)
        XCTAssertEqual(localBackend.cleanedInputs.map(\.modelKind), [.qwen35_0_8b_q4_k_m])
        XCTAssertEqual(prompt, "Base prompt")
    }

    func testCleanerLeavesPromptUnchangedForRecommendedFastModel() async {
        let localBackend = SpyCleanupBackend(nextResult: .success("cleaned"))
        let cleaner = TextCleaner(localBackend: localBackend)

        _ = await cleaner.cleanWithPerformance(
            text: "raw text",
            prompt: "Base prompt",
            modelKind: .qwen35_2b_q4_k_m
        )

        XCTAssertEqual(localBackend.cleanedInputs.map(\.modelKind), [.qwen35_2b_q4_k_m])
        XCTAssertEqual(localBackend.cleanedInputs.first?.prompt, "Base prompt")
    }

    func testCleanerMarksFallbackAndPreservesTranscriptForUnusableModelOutput() async {
        let localBackend = SpyCleanupBackend(
            nextResult: .failure(CleanupBackendError.unusableOutput(rawOutput: "..."))
        )
        let cleaner = TextCleaner(localBackend: localBackend)

        let result = await cleaner.cleanWithPerformance(text: "raw text", prompt: "unused prompt")

        XCTAssertEqual(result.text, "raw text")
        XCTAssertTrue(result.usedFallback)
        XCTAssertNotNil(result.performance.modelCallDuration)
        XCTAssertEqual(result.transcript?.prompt, "unused prompt")
        XCTAssertEqual(
            result.transcript?.inputText,
            TextCleaner.formatCleanupInput(userInput: "raw text")
        )
        XCTAssertEqual(result.transcript?.rawOutput, "...")
    }
}

/// The window-filtering judgement behind the Dock presence fix.
///
/// Tested as a pure function rather than through AppKit, because the part that
/// can be wrong is which windows count, not the notification plumbing. The
/// specific failure worth guarding against is the recording overlay: it is a
/// borderless panel that appears every single time Andrew speaks, so counting
/// it would flash a Dock icon in and out on every dictation. That would be a
/// more annoying bug than the missing minimize button this fixes.
@MainActor
final class DockPresenceControllerTests: XCTestCase {

    private func window(visible: Bool = true, titled: Bool = true, panel: Bool = false)
        -> DockPresenceController.WindowFacts {
        .init(isVisible: visible, isTitled: titled, isPanel: panel)
    }

    func testNoWindowsMeansNoDockIcon() {
        XCTAssertFalse(DockPresenceController.shouldShowInDock([]))
    }

    func testAnOpenTitledWindowShowsTheDockIcon() {
        XCTAssertTrue(DockPresenceController.shouldShowInDock([window()]))
    }

    func testTheRecordingOverlayMustNotShowTheDockIcon() {
        // Borderless, and a panel. This fires on every dictation.
        let overlay = window(titled: false, panel: true)
        XCTAssertFalse(
            DockPresenceController.shouldShowInDock([overlay]),
            "a dictation overlay must not put AF Flow in the Dock, or the icon flashes on every utterance"
        )
    }

    func testAHiddenWindowDoesNotCount() {
        XCTAssertFalse(DockPresenceController.shouldShowInDock([window(visible: false)]))
    }

    func testATitledPanelStillDoesNotCount() {
        // The debug log is a titled utility panel. macOS will not miniaturize
        // it whatever the policy, so it should not drive the Dock icon either.
        XCTAssertFalse(DockPresenceController.shouldShowInDock([window(panel: true)]))
    }

    func testOneRealWindowAmongOverlaysIsEnough() {
        let windows = [
            window(titled: false, panel: true),
            window(visible: false),
            window(),
        ]
        XCTAssertTrue(DockPresenceController.shouldShowInDock(windows))
    }
}
