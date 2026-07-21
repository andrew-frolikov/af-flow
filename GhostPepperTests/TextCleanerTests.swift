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

/// Tests at the layer of the actual claim: "Andrew can minimize the window".
///
/// The previous tests here verified a helper function that encoded my model of
/// macOS window behavior, and the defect was in the model, so 456 green tests
/// said nothing about his click. These read the built app and a real window
/// instead. They still cannot click the button over a fullscreen game; only
/// Andrew can. That limit is stated rather than papered over.
@MainActor
final class WindowFoldabilityTests: XCTestCase {

    /// The test host IS the app, so Bundle.main is the shipped Info.plist.
    /// LSUIElement makes macOS treat the app as an agent and disable Dock
    /// behaviors; Andrew chose a permanent Dock app on 2026-07-21.
    func testAppIsNotAnAgentApp() {
        let value = Bundle.main.object(forInfoDictionaryKey: "LSUIElement")
        XCTAssertNil(value, "LSUIElement is back in Info.plist; the app must be a normal Dock app")
    }

    /// A window configured the way the main window is shipped must have a
    /// live miniaturize button in a regular-policy app.
    func testMainStyleWindowCanMiniaturize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        XCTAssertTrue(
            window.standardWindowButton(.miniaturizeButton)?.isEnabled ?? false,
            "the yellow button is disabled on the shipped window configuration"
        )
    }

    /// PROBE, printed not asserted: does the old all-Spaces collection
    /// behavior disable the miniaturize button? This is the leading hypothesis
    /// for why fold was greyed out before 2026-07-21, and recording the answer
    /// mechanically beats guessing. No assertion because the answer is an OS
    /// behavior being measured, not a requirement being enforced.
    func testProbeAllSpacesEffectOnMiniaturize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let enabled = window.standardWindowButton(.miniaturizeButton)?.isEnabled ?? false
        print("PROBE allSpaces+fullScreenAuxiliary miniaturize enabled = \(enabled)")
    }
}
