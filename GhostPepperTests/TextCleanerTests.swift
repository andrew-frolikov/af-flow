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
        correctionStore.preferredTranscriptionsText = "AF Flow"
        let localBackend = SpyCleanupBackend(nextResult: .success("ghost pepper is ready"))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "AF Flow is ready", prompt: "unused prompt")

        XCTAssertEqual(result, "ghost pepper is ready")
        XCTAssertEqual(
            localBackend.cleanedInputs.map(\.text),
            [TextCleaner.formatCleanupInput(userInput: "AF Flow is ready")]
        )
    }

    /// RETARGETED 2026-07-21, and the reason matters more than the change.
    ///
    /// This test pinned upstream's design, in which corrections are prompt
    /// hints and never touch the text. Upstream deleted its
    /// DeterministicCorrectionEngine in e262c40, "fold corrections into cleanup
    /// prompt", and four tests were left guarding that decision.
    ///
    /// AF Flow's contract asks for something different, in as many words:
    /// "deterministic post-ASR replacement layer PLUS the glossary injected
    /// into the cleanup prompt". Both, not either. Only the prompt half had
    /// shipped. CLAUDE.md wins over inherited fork behaviour by its own rule.
    ///
    /// The evidence is Andrew's, not theoretical: "prompt" survived correctly
    /// once and became Cyrillic elsewhere IN THE SAME utterance, and his brand
    /// name has been mangled five different ways in five sessions, never twice
    /// alike. A prompt is a request, and the same request produced different
    /// answers inside one clip. Prompt tuning cannot make a sampled model
    /// deterministic; a lookup table is deterministic by construction.
    ///
    /// What is still guarded: the glossary must REMAIN in the prompt, so this
    /// is additive rather than a swap.
    func testCommonlyMisheardReplacementRewritesModelInputPerTheDictionarySpec() async throws {
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
            [TextCleaner.formatCleanupInput(userInput: "ChatGPT fixes text")],
            "the cleanup model must receive text whose terminology is already correct"
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

    /// RETARGETED 2026-07-21. The fallback is exactly where corrections matter
    /// MOST: when the cleanup model is unavailable, the raw transcription is
    /// what lands at Andrew's cursor, so leaving it uncorrected would mean the
    /// dictionary silently stops working on the worst day. Corrections are
    /// applied before the model is called, so all three fallback paths inherit
    /// them for free.
    func testCleanerFallbackCarriesDictionaryCorrections() async throws {
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

        XCTAssertEqual(
            result,
            "Jesse approved it",
            "a cleanup failure must not also disable the dictionary"
        )
    }

    func testPreferredTranscriptionsDoNotRewriteCleanupOutput() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.preferredTranscriptionsText = "AF Flow"
        let localBackend = SpyCleanupBackend(nextResult: .success("ghost-pepper is ready"))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "AF Flow is ready", prompt: "unused prompt")

        XCTAssertEqual(result, "ghost-pepper is ready")
    }

    /// RETARGETED 2026-07-21 alongside the test above, but the concern it
    /// raises is real and is now guarded harder rather than dropped: a
    /// replacement VALUE containing `$` or a backslash must be inserted
    /// literally and never interpreted as a regex template. Getting that wrong
    /// would corrupt Andrew's text while claiming to correct it. The layer
    /// restores through literal string replacement precisely for this reason.
    func testCommonlyMisheardReplacementSpecialCharactersAreInsertedLiterally() async throws {
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
            [TextCleaner.formatCleanupInput(userInput: #"$HOME C:\\temp"#)],
            "special characters in a replacement must survive verbatim, not be read as a template"
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
        correctionStore.preferredTranscriptionsText = "AF Flow"
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

/// The deterministic dictionary layer, tested against the REAL failures from
/// voice-observations.md rather than invented strings.
///
/// Every case below is a defect actually observed in Andrew's dictation and
/// logged with a date. That is the point: a table of made-up terms would prove
/// the regex works, and these prove the layer fixes the things that have been
/// costing him one mis-transcription per message for five sessions.
final class DeterministicCorrectionsTests: XCTestCase {

    private func corrections(
        preferred: [String] = [],
        misheard: [(String, String)] = []
    ) -> DeterministicCorrections {
        DeterministicCorrections(
            preferredTranscriptions: preferred,
            commonlyMisheard: misheard.map { MisheardReplacement(wrong: $0.0, right: $0.1) }
        )
    }

    /// The shipped seed list is EMPTY on purpose, per the 2026-07-20 decision
    /// to seed only after the C2 model scoring, so deterministic replacement
    /// cannot contaminate the comparison. An empty layer must be a no-op, not
    /// a silent mangler.
    func testEmptyCorrectionsChangeNothing() {
        let input = "Wispr Flow and AF Flow, unchanged."
        XCTAssertEqual(corrections().apply(to: input), input)
    }

    /// Casing was 30 percent of his real Wispr edits, the single most common
    /// mechanical fix, and the safest, because case cannot change meaning.
    func testCasingIsNormalisedToThePreferredForm() {
        let layer = corrections(preferred: ["AF Flow", "LuLu", "Wispr Flow"])
        XCTAssertEqual(layer.apply(to: "af flow crashed"), "AF Flow crashed")
        XCTAssertEqual(layer.apply(to: "I opened Lulu"), "I opened LuLu")
        // Observed 2026-07-19: the same term cased two ways in ONE message.
        XCTAssertEqual(
            layer.apply(to: "AF flow and AF FLOW"),
            "AF Flow and AF Flow",
            "inconsistency inside one utterance is noise, not preference"
        )
    }

    /// Five different manglings of one brand across five sessions, never the
    /// same twice, which is why a prompt cannot fix this and a table can.
    func testTheBrandNameManglingsAreRepaired() {
        let layer = corrections(
            preferred: ["Wispr Flow"],
            misheard: [("Visper Flow", "Wispr Flow"), ("whisper flow", "Wispr Flow")]
        )
        XCTAssertEqual(layer.apply(to: "retire Visper Flow now"), "retire Wispr Flow now")
        XCTAssertEqual(layer.apply(to: "remove whisper flow"), "remove Wispr Flow")
    }

    /// Observed 2026-07-20: "Hugging Face" arrived as two different wrong
    /// spellings inside a single message, and it changed the MEANING of a
    /// question he was asking, which is what escalated it from annoyance.
    func testTheHuggingFaceCaseThatCorruptedAQuestion() {
        let layer = corrections(
            preferred: ["Hugging Face"],
            misheard: [("fighting face", "Hugging Face"), ("Hagging face", "Hugging Face")]
        )
        XCTAssertEqual(
            layer.apply(to: "is fighting face in my setup, the Hagging face thing"),
            "is Hugging Face in my setup, the Hugging Face thing"
        )
    }

    /// His register borrows English technical vocabulary into Russian
    /// sentences, and the seed list must cover INFLECTED forms, not just the
    /// nominative. Both observed 2026-07-20.
    func testRussianInflectedBorrowingsAreRepaired() {
        let layer = corrections(misheard: [
            ("\u{043F}\u{0440}\u{043E}\u{043C}\u{0442}\u{043E}\u{0432}", "\u{043F}\u{0440}\u{043E}\u{043C}\u{043F}\u{0442}\u{043E}\u{0432}"),
            ("\u{043F}\u{0440}\u{043E}\u{043C}\u{043F}\u{0443}\u{0442}", "prompt"),
        ])
        XCTAssertEqual(
            layer.apply(to: "\u{043F}\u{0430}\u{0440}\u{0443} \u{043F}\u{0440}\u{043E}\u{043C}\u{0442}\u{043E}\u{0432} \u{043D}\u{0430}\u{0437}\u{0430}\u{0434}"),
            "\u{043F}\u{0430}\u{0440}\u{0443} \u{043F}\u{0440}\u{043E}\u{043C}\u{043F}\u{0442}\u{043E}\u{0432} \u{043D}\u{0430}\u{0437}\u{0430}\u{0434}"
        )
        XCTAssertEqual(
            layer.apply(to: "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C} \u{043F}\u{0440}\u{043E}\u{043C}\u{043F}\u{0443}\u{0442}"),
            "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C} prompt"
        )
    }

    /// A term must never match inside a longer word. Without this the layer
    /// would corrupt ordinary text while claiming to fix it, which is worse
    /// than the defect.
    func testTermsDoNotMatchInsideLongerWords() {
        let layer = corrections(preferred: ["Claude"], misheard: [("cat", "dog")])
        XCTAssertEqual(layer.apply(to: "concatenate the catalog"), "concatenate the catalog")
        XCTAssertEqual(layer.apply(to: "Claudette left"), "Claudette left")
    }

    /// Protected terms are placeholder-substituted before the misheard rules
    /// run, so a broad misheard rule cannot chew through a term the user
    /// explicitly protected. Upstream's ordering, and it was right.
    func testAProtectedTermSurvivesABroadMisheardRule() {
        let layer = corrections(
            preferred: ["Wispr Flow"],
            misheard: [("Flow", "Stream")]
        )
        XCTAssertEqual(
            layer.apply(to: "Wispr Flow and the Flow state"),
            "Wispr Flow and the Stream state",
            "the protected brand keeps its Flow; the unprotected word is replaced"
        )
    }

    /// Longest rule wins, so a specific phrase is not pre-empted by a rule for
    /// one of its words.
    func testLongerRulesTakePrecedence() {
        let layer = corrections(misheard: [("face", "FACE"), ("fighting face", "Hugging Face")])
        XCTAssertEqual(layer.apply(to: "the fighting face"), "the Hugging Face")
    }
}

/// Regression tests for the two real defects Codex found on 2026-07-21.
final class CodexRound1RegressionTests: XCTestCase {

    /// Finding 6: without the underscore in the boundary class, a rule fires
    /// inside snake_case identifiers and path components. Andrew dictates
    /// technical vocabulary constantly, so corrupting code-shaped text is a
    /// live risk, not a theoretical one.
    func testRulesDoNotFireInsideSnakeCaseOrPaths() {
        let layer = DeterministicCorrections(
            preferredTranscriptions: ["Claude"],
            commonlyMisheard: [MisheardReplacement(wrong: "face", right: "Hugging Face")]
        )
        XCTAssertEqual(layer.apply(to: "my_face_thing"), "my_face_thing")
        XCTAssertEqual(layer.apply(to: "src/face_detect.py"), "src/face_detect.py")
        XCTAssertEqual(layer.apply(to: "claude_config"), "claude_config")
        // Still fires on a genuine standalone word.
        XCTAssertEqual(layer.apply(to: "the face of it"), "the Hugging Face of it")
    }
}
