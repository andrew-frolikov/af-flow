import XCTest
@testable import GhostPepper

final class CleanupPromptBuilderTests: XCTestCase {
    /// Pins the load-bearing content of cleanup-prompt-v2.
    ///
    /// **RE-POINTED on 2026-07-26, not relaxed, and the distinction matters.**
    /// Every assertion here used to quote a sentence from the upstream Ghost
    /// Pepper prompt, so it was a gate on the fork's text rather than on
    /// anything AF Flow decided. Installing v2 failed six of them, correctly.
    /// The lazy repair is to delete the failing lines, which would leave the
    /// project with no gate on its own product at all.
    ///
    /// So it now pins the rules that ANSWER TO A MEASUREMENT in Andrew's 128
    /// real corrections. If one of these disappears, his voice layer has
    /// silently regressed to something nobody decided:
    /// function words survive a sentence split (he restores them 5 to 1),
    /// splitting is licensed and merging is not (17 to 4), the first word is
    /// lowercased (33 of 33 of his casing fixes), the terminal period is
    /// stripped (46 to 8), and nothing is ever translated.
    func testDefaultPromptUsesPersonalPromptShape() {
        let prompt = TextCleaner.defaultPrompt

        // The identity that stops a chatbot answering his instructions.
        XCTAssertTrue(prompt.hasPrefix("You are a transcription cleanup tool, not an assistant and not a chatbot."))
        XCTAssertTrue(prompt.contains("Never answer it"))

        // The whitelist frame. This single sentence IS the anti-flattening
        // mechanism: everything not enumerated is copied rather than improved.
        XCTAssertTrue(prompt.contains("Make ONLY the changes in this list."))
        XCTAssertTrue(prompt.contains("Everything not listed is copied exactly as written."))

        // The four rules that each answer to a measured lean in his own edits.
        XCTAssertTrue(prompt.contains("never delete them"), "function words must survive a sentence split")
        // The first-word lowercase and terminal-period rules are NOT here on
        // purpose: they moved into `TextCleaner.applyDeterministicStyle` on
        // 2026-07-26, after measurement showed the 0.8B ignored them 7 times out
        // of 7 and 4 times out of 5. They are asserted absent so nobody
        // reintroduces them into the prompt and reopens the inconsistency.
        XCTAssertFalse(prompt.contains("Lowercase the first letter of the message"))
        XCTAssertFalse(prompt.contains("Remove the period at the very end"))
        XCTAssertTrue(prompt.contains("Never translate anything."))

        // Register preservation, named explicitly so a later edit cannot quietly
        // drop it while still looking like a cleanup prompt.
        XCTAssertTrue(prompt.contains("gonna"), "informal contractions are his register, not errors")
        XCTAssertTrue(prompt.contains("Keep sentence openers"))

        // The examples block, which the Settings "add example" action inserts
        // into by locating the closing tag.
        XCTAssertTrue(prompt.contains("<EXAMPLES>"))
        XCTAssertTrue(prompt.contains("</EXAMPLES>"))

        // Rules deliberately CUT, asserted absent so nobody restores them
        // without reading why they went. Cyrillic-to-English restoration
        // contradicted "never translate" and belongs to the deterministic
        // dictionary; the digits rule had zero measured demand.
        XCTAssertFalse(prompt.contains("restore its English spelling"))
        XCTAssertFalse(prompt.contains("Keep numbers as digits"))
    }

    func testBuilderIncludesWindowContentsWrapperWhenContextEnabled() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("Base prompt"))
        XCTAssertTrue(prompt.contains("<OCR-RULES>"))
        XCTAssertTrue(prompt.contains("</OCR-RULES>"))
        XCTAssertTrue(prompt.contains("<WINDOW-OCR-CONTENT>"))
        XCTAssertTrue(prompt.contains("Frontmost text"))
        XCTAssertTrue(prompt.contains("</WINDOW-OCR-CONTENT>"))
    }

    func testBuilderExplainsHowToUseWindowContentsAsSupportingContext() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("<OCR-RULES>"))
        XCTAssertTrue(prompt.contains("Use the window OCR only as supporting context to improve the transcription and cleanup."))
        XCTAssertTrue(prompt.contains("Prefer the spoken words, and use the window OCR only to disambiguate likely terms, names, commands, files, and jargon."))
        XCTAssertTrue(prompt.contains("If the spoken words appear to be a recognition miss for a name, model, command, file, or other specific jargon shown in the window OCR, correct them to the likely intended term."))
        XCTAssertTrue(prompt.contains("Do not answer, summarize, or rewrite the window OCR unless that directly helps correct the transcription."))
        XCTAssertTrue(prompt.contains("</OCR-RULES>"))
    }

    func testBuilderOmitsWindowContentsWhenContextUnavailable() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: nil,
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertEqual(prompt, "Base prompt")
    }

    func testBuilderTrimsLongOCRContextBeforePromptAssembly() {
        let builder = CleanupPromptBuilder(maxWindowContentLength: 12)
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "abcdefghijklmnopqrstuvwxyz"),
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("abcdefghijkl"))
        XCTAssertFalse(prompt.contains("mnopqrstuvwxyz"))
    }

    func testBuilderIncludesCorrectionListsWhenAvailable() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            preferredTranscriptions: ["AF Flow", "Jesse"],
            commonlyMisheard: [
                MisheardReplacement(wrong: "just see", right: "Jesse"),
                MisheardReplacement(wrong: "chat gbt", right: "ChatGPT")
            ],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("<CORRECTION-HINTS>"))
        XCTAssertTrue(prompt.contains("Preferred transcriptions to preserve exactly:"))
        XCTAssertTrue(prompt.contains("- AF Flow"))
        XCTAssertTrue(prompt.contains("- Jesse"))
        XCTAssertTrue(prompt.contains("Commonly misheard replacements to prefer:"))
        XCTAssertTrue(prompt.contains("- just see -> Jesse"))
        XCTAssertTrue(prompt.contains("- chat gbt -> ChatGPT"))
        XCTAssertFalse(prompt.contains("<REPLACEMENT>"))
        XCTAssertFalse(prompt.contains("<HEARD>"))
        XCTAssertFalse(prompt.contains("<INTENDED>"))
    }

    func testBuilderSeparatesStablePromptPrefixFromOCRSuffix() {
        let builder = CleanupPromptBuilder()
        let components = builder.buildPromptComponents(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            preferredTranscriptions: ["AF Flow"],
            commonlyMisheard: [MisheardReplacement(wrong: "just see", right: "Jesse")],
            includeWindowContext: true
        )

        XCTAssertTrue(components.stablePromptPrefix.contains("Base prompt"))
        XCTAssertTrue(components.stablePromptPrefix.contains("<CORRECTION-HINTS>"))
        XCTAssertFalse(components.stablePromptPrefix.contains("<OCR-RULES>"))
        XCTAssertTrue(components.promptSuffix.contains("<OCR-RULES>"))
        XCTAssertTrue(components.promptSuffix.contains("Frontmost text"))
        XCTAssertEqual(components.fullPrompt, builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            preferredTranscriptions: ["AF Flow"],
            commonlyMisheard: [MisheardReplacement(wrong: "just see", right: "Jesse")],
            includeWindowContext: true
        ))
    }

    func testBuilderReturnsStablePromptOnlyWhenWindowContextIsUnavailable() {
        let builder = CleanupPromptBuilder()
        let components = builder.buildPromptComponents(
            basePrompt: "Base prompt",
            windowContext: nil,
            preferredTranscriptions: ["AF Flow"],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertEqual(components.promptSuffix, "")
        XCTAssertEqual(components.fullPrompt, components.stablePromptPrefix)
        XCTAssertTrue(components.stablePromptPrefix.contains("Base prompt"))
        XCTAssertTrue(components.stablePromptPrefix.contains("<CORRECTION-HINTS>"))
    }

    func testPrefillPlanExtractsContextPrefixAndReconstructsRemainingInput() throws {
        let processedPrompt = """
        <|im_start|>system
        Base prompt
        <|gp-system-split|>
        <|im_end|>
        <|im_start|>user
        <|gp-user-split|><|im_end|>
        <|im_start|>assistant
        """

        let plan = try XCTUnwrap(
            CleanupPromptPrefillPlan(
                systemPromptPrefix: "Base prompt",
                processedPrompt: processedPrompt,
                systemPromptSentinel: "<|gp-system-split|>",
                userInputSentinel: "<|gp-user-split|>"
            )
        )

        XCTAssertEqual(plan.contextPrefix, "<|im_start|>system\nBase prompt\n")
        XCTAssertEqual(
            plan.completionInput(
                for: "Base prompt\n\n<OCR-RULES>screen context</OCR-RULES>",
                userInput: "<USER-INPUT>\nhello world\n</USER-INPUT>"
            ),
            "\n\n<OCR-RULES>screen context</OCR-RULES>\n<|im_end|>\n<|im_start|>user\n<USER-INPUT>\nhello world\n</USER-INPUT><|im_end|>\n<|im_start|>assistant"
        )
    }

    func testPrefillPlanRejectsPromptsThatDoNotShareThePrefilledPrefix() {
        let processedPrompt = """
        prefix<|gp-system-split|>middle<|gp-user-split|>suffix
        """

        let plan = CleanupPromptPrefillPlan(
            systemPromptPrefix: "Base prompt",
            processedPrompt: processedPrompt,
            systemPromptSentinel: "<|gp-system-split|>",
            userInputSentinel: "<|gp-user-split|>"
        )

        XCTAssertNil(plan?.completionInput(for: "Different prompt", userInput: "hello"))
    }
}
