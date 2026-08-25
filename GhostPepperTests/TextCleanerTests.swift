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
        // The stub answers with a plausible cleanup of the input rather than
        // unrelated words. THE SUBJECT OF THIS TEST IS THE INPUT SIDE — that
        // preferred terms reach the model canonicalised — and that assertion is
        // untouched. The output side is covered by
        // testPreferredTranscriptionsRewriteInputButNeverOutput.
        let localBackend = SpyCleanupBackend(nextResult: .success("AF Flow is ready."))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "AF Flow is ready", prompt: "unused prompt")

        XCTAssertEqual(result, "AF Flow is ready.")
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

    /// Two guarantees in one test, and Codex round 2 caught that it was only
    /// proving one of them: the input it fed was ALREADY canonical, so it could
    /// not tell whether preferred terms rewrite the input at all. Now the input
    /// is lower-case, so the canonicalisation is actually exercised.
    ///
    /// The original guarantee is kept and still matters: preferred terms must
    /// normalise what goes IN to the model, and must never rewrite what comes
    /// OUT. Rewriting the output would let the dictionary silently edit the
    /// model's finished text, which is a different and worse power than fixing
    /// terminology before it is read.
    func testPreferredTranscriptionsRewriteInputButNeverOutput() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.preferredTranscriptionsText = "AF Flow"
        let localBackend = SpyCleanupBackend(nextResult: .success("af flow is ready"))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "af flow is ready", prompt: "unused prompt")

        XCTAssertEqual(
            localBackend.cleanedInputs.map(\.text),
            [TextCleaner.formatCleanupInput(userInput: "AF Flow is ready")],
            "the model must receive the canonical spelling"
        )
        XCTAssertEqual(
            result, "af flow is ready",
            "the model's own output must be returned untouched by the dictionary"
        )
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

        // FIXTURE UPDATED 2026-08-24, and the subject of this test is unchanged.
        // The stub used to answer with words the input never contained, which
        // predates any fidelity guard. `inventedRuns` now rejects a cleanup that
        // returns words he never said, so an unrelated stub makes the pipeline
        // fall back to the raw text and this test would be measuring the guard
        // rather than its own subject. The input now contains the words the stub
        // returns; nothing else about the assertion changed.
        let result = await cleaner.clean(text: "final cleaned text", prompt: "unused prompt")

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

        // FIXTURE UPDATED 2026-08-24, and the subject of this test is unchanged.
        // The stub used to answer with words the input never contained, which
        // predates any fidelity guard. `inventedRuns` now rejects a cleanup that
        // returns words he never said, so an unrelated stub makes the pipeline
        // fall back to the raw text and this test would be measuring the guard
        // rather than its own subject. The input now contains the words the stub
        // returns; nothing else about the assertion changed.
        let result = await cleaner.clean(text: "cleaned sentence", prompt: "unused prompt")

        XCTAssertEqual(result, "Cleaned sentence.")
    }

    func testCleanerLogsPromptInputToSensitiveLogger() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "chat gbt -> ChatGPT"
        correctionStore.preferredTranscriptionsText = "AF Flow"
        // See the fixture note above. The stub answers with a plausible cleanup
        // of the DICTIONARY-CORRECTED input, "chat gbt" having become "ChatGPT",
        // rather than unrelated words. The subject here is the sensitive log.
        let localBackend = SpyCleanupBackend(nextResult: .success("ChatGPT is ready."))
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

        XCTAssertEqual(result, "ChatGPT is ready.")
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Cleanup LLM transcript") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("System prompt") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("<USER-INPUT>") }))
        XCTAssertFalse(sensitiveMessages.contains(where: { $0.contains("User input:\n<USER-INPUT>") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Raw model output") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Final cleaned output") }))
        XCTAssertFalse(sensitiveMessages.contains(where: { $0.contains("Pre-cleanup corrections") }))
        XCTAssertFalse(sensitiveMessages.contains(where: { $0.contains("Post-cleanup corrections") }))
    }

    /// THE TEST THAT WOULD HAVE CAUGHT IT.
    ///
    /// The first version of the repetition guard computed the trimmed text, logged
    /// "Kept the first copy", and then returned the untrimmed value anyway, so the
    /// double paste was entirely unfixed while every focused test passed. They all
    /// exercised the helper in isolation. Codex found it in review.
    ///
    /// This one goes through the real cleanup path and asserts on what the caller
    /// actually receives.
    func testACleanupThatRepeatsItselfReachesTheCallerAsOneCopy() async {
        let once = "So the plan is to fix the language decision first, because that one is on the "
            + "path of every word I dictate and it has never actually worked. Then the cleanup "
            + "guard, then a runtime probe script that reads the log at session start, then the "
            + "paste and hotkey instrumentation. After that the three remaining meeting bugs, "
            + "in the order sixteen, fifteen, fourteen, because the first two are mechanical."
        let localBackend = SpyCleanupBackend(nextResult: .success(once + " " + once))
        let cleaner = TextCleaner(localBackend: localBackend)

        let result = await cleaner.cleanWithPerformance(text: once, prompt: "unused prompt")

        XCTAssertEqual(
            result.text,
            once,
            "The caller received the passage twice, which is exactly what landed in his document."
        )
    }

    /// And an ordinary cleanup must arrive untouched through the same path.
    func testAnOrdinaryCleanupIsUnchangedByTheRepetitionGuard() async {
        let cleaned = "So the plan is to fix the language decision first, because that one sits on "
            + "the path of every word I dictate. Then the cleanup guard, then a runtime probe "
            + "script, then the paste and hotkey instrumentation, and after that the three "
            + "remaining meeting bugs in the order sixteen, fifteen and fourteen."
        let localBackend = SpyCleanupBackend(nextResult: .success(cleaned))
        let cleaner = TextCleaner(localBackend: localBackend)

        let result = await cleaner.cleanWithPerformance(text: cleaned, prompt: "unused prompt")

        XCTAssertEqual(result.text, cleaned)
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

        // See the fixture note above: the input carries the stub's words so this
        // test measures durations rather than the fidelity guard.
        let result = await cleaner.cleanWithPerformance(text: "final cleaned text", prompt: "unused prompt")

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

    /// **His preferred spelling must survive.** With ASR `AF FLOW` and a
    /// preferred transcription of `AF Flow`, the dictionary lowers those
    /// capitals ON PURPOSE before the model sees them. A guard that reads only
    /// the raw transcription sees a lost capital and hands back `AF FLOW`,
    /// undoing the spelling he configured. Codex, 2026-08-24.
    func testAPreferredSpellingIsNeverUndone() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "AF Flow is ready",
                spokenInput: "AF FLOW is ready",
                afterDictionary: "AF Flow is ready"
            ),
            "AF Flow is ready"
        )
    }

    /// **A DELIBERATE limitation, pinned so it cannot be "fixed" by accident.**
    ///
    /// Where the dictionary rewrote only SOME occurrences of a word, the guard
    /// stands down for all of them and that occurrence goes unrepaired. Codex
    /// raised it in round 2 and it was declined on purpose: the alternative,
    /// per-occurrence alignment, would restore the occurrence the dictionary
    /// deliberately rewrote and destroy his configured spelling. Missing a
    /// repair is recoverable; undoing his settings is not.
    func testAWordTheDictionaryOnlyPartlyOwnsIsLeftAloneOnPurpose() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "AF Flow and flow",
                spokenInput: "AF FLOW and FLOW",
                afterDictionary: "AF Flow and FLOW"
            ),
            "AF Flow and flow",
            "the guard must not repair here, because doing so would undo his preferred spelling"
        )
    }

    /// Sentence-casing a word he writes mixed-case is not a capital worth
    /// keeping. The first version merged them and produced `MacOS` and
    /// `IPhone` — spellings neither he nor the model wrote, on his clipboard.
    /// An independent reviewer caught both, 2026-08-24.
    func testSentenceCasingAWordHeWritesMixedCaseIsUndone() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "on Macos today",
                spokenInput: "on macOS today",
                afterDictionary: "on macOS today"
            ),
            "on macOS today"
        )
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "my Iphone died",
                spokenInput: "my iPhone died",
                afterDictionary: "my iPhone died"
            ),
            "my iPhone died"
        )
    }

    /// **The capital Whisper puts on every sentence start is NOT evidence.**
    ///
    /// The model may split sentences; when it does the mirror and MERGES two,
    /// the demoted word arrives lower case and the first version dragged its
    /// positional capital into the middle of the new sentence. Found by an
    /// independent reviewer on 2026-08-24, after Codex passed the same code
    /// twice.
    func testAMergedSentenceDoesNotDragItsCapitalIntoTheMiddle() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "We should ship the fix today, then I will write the release notes.",
                spokenInput: "We should ship the fix today. Then I will write the release notes.",
                afterDictionary: "We should ship the fix today. Then I will write the release notes."
            ),
            "We should ship the fix today, then I will write the release notes."
        )
    }

    func testAMergedRussianSentenceIsAlsoLeftAlone() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "Я проверил это вчера вечером, потом я отправлю тебе результат.",
                spokenInput: "Я проверил это вчера вечером. Потом я отправлю тебе результат.",
                afterDictionary: "Я проверил это вчера вечером. Потом я отправлю тебе результат."
            ),
            "Я проверил это вчера вечером, потом я отправлю тебе результат."
        )
    }

    /// **Punctuation between the full stop and the word must not hide it.**
    ///
    /// The first version looked back only as far as the previous non-whitespace
    /// character, so a closing quote, a bracket, a guillemet or a dash sat in
    /// that slot and masked the terminator behind it. `Then` was then classified
    /// mid-sentence and its purely positional capital became EVIDENCE, which is
    /// the one input the sentence rule has to be able to trust. Found by an
    /// independent reviewer, 2026-08-24.
    ///
    /// It has never fired on his own data: across the 50 archived dictations the
    /// raw punctuation inventory is `. , ? ' - %` with no quotes, brackets,
    /// dashes or newlines. All 50 are Whisper turbo, and Settings steers him to
    /// Parakeet v3 for non-English, which punctuates differently.
    func testPunctuationBetweenTheFullStopAndTheWordDoesNotHideIt() {
        let cases: [(spoken: String, cleaned: String)] = [
            ("He said \"no.\" Then he left the room and shut the door",
             "He said \"no,\" then he left the room and shut the door"),
            ("He agreed. (Then he left the room and shut the door)",
             "He agreed, (then he left the room and shut the door)"),
            ("Он сказал. \u{00AB}Потом он ушёл из комнаты и закрыл дверь\u{00BB}",
             "Он сказал, \u{00AB}потом он ушёл из комнаты и закрыл дверь\u{00BB}"),
            ("He agreed. \u{2014} Then he left the room and shut the door",
             "He agreed, \u{2014} then he left the room and shut the door")
        ]
        for (spoken, cleaned) in cases {
            XCTAssertEqual(
                TextCleaner.restoringCapitalsLoweredFromSpeech(
                    cleaned,
                    spokenInput: spoken,
                    afterDictionary: spoken
                ),
                cleaned,
                "a capital was dragged mid-sentence past intervening punctuation: \(spoken)"
            )
        }
    }

    /// **A comma after a full stop means the sentence is still running.**
    ///
    /// A regression introduced by the fix above: the flag was set by a
    /// terminator and cleared only by emitting a word, so nothing in between
    /// could clear it. An abbreviation followed by a comma — `и т.д.,` — left
    /// the next word classified as a sentence start, which skips the
    /// mid-sentence check and lets the whole of the merge defect back in.
    /// Caught by a reviewer as a v2 to v3 regression, 2026-08-24.
    func testAClauseCommaAfterAnAbbreviationKeepsTheSentenceRunning() {
        let cases: [(spoken: String, cleaned: String)] = [
            ("Купи молоко хлеб и т.д. Потом заедь к маме и забери документы",
             "Купи молоко, хлеб и т.д., потом заедь к маме и забери документы"),
            ("Get milk bread eggs etc. Then go home and check the post box",
             "Get milk, bread, eggs etc., then go home and check the post box"),
            ("Он занят сегодня т.е. Позже я позвоню ему насчёт документов",
             "Он занят сегодня, т.е., позже я позвоню ему насчёт документов")
        ]
        for (spoken, cleaned) in cases {
            XCTAssertEqual(
                TextCleaner.restoringCapitalsLoweredFromSpeech(
                    cleaned,
                    spokenInput: spoken,
                    afterDictionary: spoken
                ),
                cleaned,
                "a comma failed to clear the sentence flag: \(spoken)"
            )
        }
    }

    /// A newline ends a sentence on its own; nothing else marks the boundary.
    func testANewlineEndsASentence() {
        let spoken = "Meeting notes\nThen we discussed the budget for next quarter"
        let cleaned = "Meeting notes, then we discussed the budget for next quarter"
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                cleaned,
                spokenInput: spoken,
                afterDictionary: spoken
            ),
            cleaned
        )
    }

    /// A word moved to the front must not keep a capital it never earned.
    func testAReorderedOpenerIsNotCapitalisedMidSentence() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "Please send it to him tomorrow, I think that works",
                spokenInput: "Send it to him tomorrow please, I think that works",
                afterDictionary: "Send it to him tomorrow please, I think that works"
            ),
            "Please send it to him tomorrow, I think that works"
        )
    }

    /// The repair he actually needs still happens: these are attested
    /// mid-sentence, so the capital is his spelling and not the sentence's.
    func testACapitalAttestedMidSentenceIsStillRestored() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "I don't need a pdf of my cv on google doc",
                spokenInput: "I don't need a PDF of my CV on Google Doc",
                afterDictionary: "I don't need a PDF of my CV on Google Doc"
            ),
            "I don't need a PDF of my CV on Google Doc"
        )
    }

    /// End to end, through the real pipeline, because a helper that works in
    /// isolation and is never called is the shape this project keeps hitting.
    func testTheCleanupPipelinePutsBackACapitalTheModelLowercased() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        let localBackend = SpyCleanupBackend(nextResult: .success("I need a pdf of my cv"))
        let cleaner = TextCleaner(localBackend: localBackend, correctionStore: correctionStore)

        let result = await cleaner.clean(text: "I need a PDF of my CV", prompt: "unused prompt")

        XCTAssertEqual(result, "I need a PDF of my CV")
    }

    // MARK: - What the independent reviewer found in the two guards

    /// **The worst defect this session, and it CORRUPTED his text.**
    ///
    /// `contentTokens` splits on every non-alphanumeric, so `I'm` is `I` and
    /// `m`. When the model expands the contraction — which the prompt forbids,
    /// so it will happen — `m` against `am` is a one-for-one swap and the first
    /// version wrote the fragment back. He would have received "I m going to".
    /// 30% of his dictations contain an apostrophe.
    func testExpandingAContractionNeverSplicesAFragmentIntoHisText() {
        let cases: [(spoken: String, delivered: String)] = [
            ("I'm going to send you the file tomorrow morning",
             "I am going to send you the file tomorrow morning"),
            ("it's ready for review whenever you have a moment",
             "it is ready for review whenever you have a moment"),
            ("let's look at the document together tomorrow afternoon",
             "let us look at the document together tomorrow afternoon"),
            ("I am going to send you the file tomorrow morning",
             "I'm going to send you the file tomorrow morning")
        ]
        for (spoken, delivered) in cases {
            XCTAssertEqual(
                TextCleaner.restoringWordsSwappedFromSpeech(delivered, spokenInput: spoken),
                delivered,
                "a contraction fragment was spliced into his text: \(spoken)"
            )
        }

        // Every case above asserts that NOTHING changed, so all of them pass
        // against a pass that does nothing. A reviewer caught that. One positive
        // case makes the test stand on its own.
        XCTAssertEqual(
            TextCleaner.restoringWordsSwappedFromSpeech(
                "I'm going to send you the document tomorrow morning",
                spokenInput: "I'm going to send you the file tomorrow morning"
            ),
            "I'm going to send you the file tomorrow morning",
            "the swap next to a contraction was not repaired"
        )
    }

    /// **A capital the model added MID-SENTENCE is not licensed**, and copying it
    /// onto his restored word put one in `я Получил это письмо` that appears in
    /// neither his speech nor the transcription. The casing pass cannot remove
    /// it, because that pass only restores capitals he said.
    func testACapitalTheModelAddedMidSentenceIsNotCopiedOntoHisWord() {
        XCTAssertEqual(
            TextCleaner.restoringWordsSwappedFromSpeech(
                "я Получал это письмо вчера вечером и сразу ответил ему",
                spokenInput: "я получил это письмо вчера вечером и сразу ответил ему"
            ),
            "я получил это письмо вчера вечером и сразу ответил ему"
        )
        XCTAssertEqual(
            TextCleaner.restoringWordsSwappedFromSpeech(
                "When you have a moment, please check the Codecs limits for me.",
                spokenInput: "when you have a moment please check the codex limits for me"
            ),
            "When you have a moment, please check the codex limits for me."
        )
    }

    /// An ALL-CAPS delivered word must not sentence-case his into a third form
    /// neither of them wrote: `PDF` against `pdfs` gave `Pdfs`.
    func testAShoutingDeliveredWordDoesNotSentenceCaseHisWord() {
        XCTAssertEqual(
            TextCleaner.restoringWordsSwappedFromSpeech(
                "PDF of my cv before tomorrow morning please send it over",
                spokenInput: "pdfs of my cv before tomorrow morning please send it over"
            ),
            "pdfs of my cv before tomorrow morning please send it over"
        )
    }

    /// A capital the split-sentence rule put there must survive his word coming
    /// back. The casing pass runs afterwards and only restores capitals HE said,
    /// so nothing else would repair it.
    func testRestoringHisWordKeepsACapitalTheModelWasAllowedToAdd() {
        XCTAssertEqual(
            TextCleaner.restoringWordsSwappedFromSpeech(
                "He called me yesterday. Reckon about it tomorrow morning, please.",
                spokenInput: "he called me yesterday think about it tomorrow morning please"
            ),
            "He called me yesterday. Think about it tomorrow morning, please."
        )
    }

    /// **No length gate.** The gate on the other guards exists because a RATIO is
    /// meaningless on a short utterance. Two consecutive words he never said are
    /// not a ratio. Measured free: gating on input, on output, or not at all all
    /// reject the same two dictations of 307, and dropping it brings 64 short
    /// ones under the check without adding a rejection.
    func testAShortDictationIsStillProtectedFromFabrication() {
        XCTAssertFalse(
            TextCleaner.inventedRuns(
                input: "напиши рекрутеру",
                output: "напиши рекрутеру письмо с благодарностью за уделённое время сегодня"
            ).isEmpty,
            "a fabricated clause on a short dictation was not reported"
        )
    }

    /// **No filler forgiveness either.** Reusing the deletion guard's filter
    /// forgave the model for ADDING fillers, and that list contains ordinary
    /// Russian words, so an invented clause made of them scored zero.
    func testInventedFillerWordsAreStillReported() {
        XCTAssertFalse(
            TextCleaner.inventedRuns(
                input: "посмотри документ и скажи что ты думаешь об этом сегодня",
                output: "посмотри документ и скажи что ты думаешь об этом сегодня ну вот это там типа значит"
            ).isEmpty,
            "an invented run made of filler words was forgiven"
        )
    }

    // MARK: - The model must not swap one of his words for another

    /// `получил` came back `получал` — the tense change he reported. Seven of
    /// the eight measured swaps damage his words, and no rule separates them
    /// from the one that repairs, so his decision was to block them all.
    func testHisWordIsPutBackWhenTheModelSwapsIt() {
        XCTAssertEqual(
            TextCleaner.restoringWordsSwappedFromSpeech(
                "я получал это письмо вчера вечером и сразу ответил",
                spokenInput: "я получил это письмо вчера вечером и сразу ответил"
            ),
            "я получил это письмо вчера вечером и сразу ответил"
        )
    }

    /// Punctuation the cleanup added around a restored word must survive.
    func testPunctuationAroundASwappedWordSurvives() {
        XCTAssertEqual(
            TextCleaner.restoringWordsSwappedFromSpeech(
                "Please look at the document, and tell me what you reckon about it.",
                spokenInput: "please look at the document and tell me what you think about it"
            ),
            "Please look at the document, and tell me what you think about it."
        )
    }

    /// A deletion is not a swap, and must be left to the pass that handles it.
    func testADeletionIsNotTreatedAsASwap() {
        XCTAssertEqual(
            TextCleaner.swappedSpokenWords(
                input: "please look at the document and tell me what you think about it",
                output: "please look at the document and tell me what you think about"
            ).count,
            0
        )
    }

    /// Two words for two is a rewrite this cannot place unambiguously, so it is
    /// left alone. `применитируй это` to `применить ты` is that shape, and the
    /// fabrication guard is what rejects it.
    func testATwoForTwoRewriteIsNotTreatedAsASwap() {
        XCTAssertEqual(
            TextCleaner.swappedSpokenWords(
                input: "просто применитируй это но когда ты это сделаешь делай это так",
                output: "просто применить ты но когда ты это сделаешь делай это так"
            ).count,
            0
        )
    }

    /// A clean cleanup must not be told it swapped anything.
    func testACleanCleanupSwapsNothing() {
        XCTAssertEqual(
            TextCleaner.swappedSpokenWords(
                input: "um so please look at the document and tell me what you think about it",
                output: "Please look at the document and tell me what you think about it."
            ).count,
            0
        )
    }

    /// End to end: his word reaches the clipboard, not the model's.
    func testTheCleanupPipelinePutsHisSwappedWordBack() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let spoken = "please look at the document and tell me what you think about it"
        let localBackend = SpyCleanupBackend(
            nextResult: .success("please look at the document and tell me what you reckon about it")
        )
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: CorrectionStore(defaults: defaults)
        )

        let result = await cleaner.clean(text: spoken, prompt: "unused prompt")

        XCTAssertEqual(result, spoken, "the model's word was delivered instead of his")
    }

    // MARK: - The model must not invent words he never said

    /// **On one real dictation the model invented a sixteen-word clause and
    /// dropped the end of his sentence to make room**, and it reached his
    /// clipboard. Nothing in this file checked for insertions at all.
    func testAnInventedClauseIsReported() {
        let spoken = "please look at the document and tell me what you think about it today"
        let cleaned = "please look at the document and tell me what you think about it today, so that we can decide together tomorrow"

        XCTAssertFalse(
            TextCleaner.inventedRuns(input: spoken, output: cleaned).isEmpty,
            "a clause he never said was not reported"
        )
    }

    /// A clean cleanup must not be accused of inventing anything, or the guard
    /// would hand him the raw transcript on every dictation.
    func testACleanCleanupInventsNothing() {
        let spoken = "um so please look at the document and tell me what you think about it"
        let cleaned = "Please look at the document and tell me what you think about it."

        XCTAssertEqual(TextCleaner.inventedRuns(input: spoken, output: cleaned), [])
    }

    /// **The floor is two content words, measured with a clean gap.** Over 289
    /// real dictations, runs of two or more occur once at fourteen words; runs
    /// of exactly one occur twelve times and are the substitution defect, which
    /// is repaired rather than rejected.
    func testASingleSwappedWordIsNotAFabrication() {
        let spoken = "please look at the document and tell me what you think about it"
        let cleaned = "please look at the document and tell me what you reckon about it"

        XCTAssertEqual(
            TextCleaner.inventedRuns(input: spoken, output: cleaned), [],
            "a one-word swap must not trigger the fabrication fallback"
        )
    }

    /// End to end: a fabricated clause must cost him the polish, not his words.
    func testAFabricatedClauseFallsBackToHisRawTranscription() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let spoken = "please look at the document and tell me what you think about it today"
        let localBackend = SpyCleanupBackend(
            nextResult: .success("Please look at the document and tell me what you think about it today, so that we can decide together tomorrow.")
        )
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: CorrectionStore(defaults: defaults)
        )

        let result = await cleaner.clean(text: spoken, prompt: "unused prompt")

        XCTAssertEqual(
            result, spoken,
            "an invented clause was delivered instead of falling back to what he actually said"
        )
    }

    // MARK: - The model must not lowercase what he said with a capital

    /// **Measured 2026-08-24 over his live archive: 9 mid-text downcases across
    /// 4 of 204 dictations.** `PDF` came back `pdf`, `CV` came back `cv`,
    /// `Google` came back `google`, `Ikea` came back `ikea`, and `I` came back
    /// `i`. The RAW transcription was right every time; the corrected text is
    /// what reaches his clipboard.
    ///
    /// **This is NOT the check removed on 2026-07-26.** That one scored the
    /// FIRST WORD's capital and encoded a backwards lean about his own editing
    /// (he lowercases the first word 28 times against 692 where he keeps it).
    /// This is the MODEL lowercasing proper nouns mid-sentence, and the
    /// measurement found zero first-word downcases.
    ///
    /// The guard is deliberately ASYMMETRIC. Capitals the model ADDS are left
    /// alone, because every added capital measured over the same archive was
    /// either licensed by the split-sentence rule or wanted: `сколько` to
    /// `Сколько` after a new period, `AF flow` to `AF Flow`, `codex` to `Codex`.

    func testACapitalHeSaidIsPutBackWhenTheModelLowercasesIt() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "I need a pdf of my cv",
                spokenInput: "I need a PDF of my CV",
                afterDictionary: "I need a PDF of my CV"
            ),
            "I need a PDF of my CV"
        )
    }

    func testAnAcronymKeepsEveryLetterItHad() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "put it in md format",
                spokenInput: "put it in MD format",
                afterDictionary: "put it in MD format"
            ),
            "put it in MD format"
        )
    }

    /// First letter lowercase in BOTH, so a first-letter test would miss it.
    /// The guard counts capitals instead.
    func testInternalCapitalsSurviveToo() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "my iphone died",
                spokenInput: "my iPhone died",
                afterDictionary: "my iPhone died"
            ),
            "my iPhone died"
        )
    }

    func testTheFirstWordIsCoveredAsWell() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "google says otherwise",
                spokenInput: "Google says otherwise",
                afterDictionary: "Google says otherwise"
            ),
            "Google says otherwise"
        )
    }

    /// The split-sentence rule capitalizes the word after a new period. Undoing
    /// that would break the one casing change the prompt licenses.
    func testACapitalTheModelAddedIsLeftAlone() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "Keychain. Сколько это стоит",
                spokenInput: "Keychain, сколько это стоит",
                afterDictionary: "Keychain, сколько это стоит"
            ),
            "Keychain. Сколько это стоит"
        )
    }

    /// `codex` to `Codex` and `AF flow` to `AF Flow` are both improvements he
    /// wants. The guard only ever restores capitals, never removes them.
    func testAProperNounTheModelCapitalisedStaysCapitalised() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "working with the Codex limits",
                spokenInput: "working with the codex limits",
                afterDictionary: "working with the codex limits"
            ),
            "working with the Codex limits"
        )
    }

    /// When he said the same word BOTH ways there is no single right answer, so
    /// the guard does nothing rather than guess. Copying when unsure is the
    /// prompt's own rule.
    func testAWordHeSaidBothWaysIsLeftAlone() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "flow and flow",
                spokenInput: "Flow and flow",
                afterDictionary: "Flow and flow"
            ),
            "flow and flow"
        )
    }

    func testAWordHeNeverSaidIsLeftAlone() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "something entirely different",
                spokenInput: "I need a PDF",
                afterDictionary: "I need a PDF"
            ),
            "something entirely different"
        )
    }

    func testTextTheModelDidNotTouchComesBackIdentical() {
        let spoken = "I need a PDF of my CV on Google Doc"
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(spoken, spokenInput: spoken, afterDictionary: spoken),
            spoken
        )
    }

    /// Punctuation the model added around a restored word must survive.
    func testPunctuationAroundARestoredWordSurvives() {
        XCTAssertEqual(
            TextCleaner.restoringCapitalsLoweredFromSpeech(
                "Send the pdf, please.",
                spokenInput: "Send the PDF please",
                afterDictionary: "Send the PDF please"
            ),
            "Send the PDF, please."
        )
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

/// Codex round 2, finding 6: path and dotted contexts.
extension CodexRound1RegressionTests {

    func testRulesDoNotFireInsidePathsOrDottedTokens() {
        let layer = DeterministicCorrections(
            preferredTranscriptions: [],
            commonlyMisheard: [MisheardReplacement(wrong: "face", right: "Hugging Face")]
        )
        XCTAssertEqual(layer.apply(to: "src/face/detect.py"), "src/face/detect.py")
        XCTAssertEqual(layer.apply(to: "face.py"), "face.py")
        XCTAssertEqual(layer.apply(to: "face-detect"), "face-detect")
        XCTAssertEqual(layer.apply(to: "detect-face"), "detect-face")
    }

    /// The other half of the asymmetry: a term at the end of a sentence is
    /// followed by a full stop and must STILL be corrected. Getting this
    /// backwards would silently stop the dictionary working on the last word
    /// of every sentence, which is a large blind spot in dictated text.
    func testRulesStillFireAtSentenceEnd() {
        let layer = DeterministicCorrections(
            preferredTranscriptions: [],
            commonlyMisheard: [MisheardReplacement(wrong: "face", right: "Hugging Face")]
        )
        XCTAssertEqual(layer.apply(to: "I looked at face."), "I looked at Hugging Face.")
        XCTAssertEqual(layer.apply(to: "face"), "Hugging Face")
        XCTAssertEqual(layer.apply(to: "about face, then"), "about Hugging Face, then")
    }
}

/// Codex round 3, finding 4: the last open finding from the review.
extension CodexRound1RegressionTests {

    func testRulesDoNotFireBeforeNumericOrUnderscoreSuffixes() {
        let layer = DeterministicCorrections(
            preferredTranscriptions: [],
            commonlyMisheard: [MisheardReplacement(wrong: "face", right: "Hugging Face")]
        )
        XCTAssertEqual(layer.apply(to: "face.1"), "face.1")
        XCTAssertEqual(layer.apply(to: "face.2xml"), "face.2xml")
        XCTAssertEqual(layer.apply(to: "face._internal"), "face._internal")
    }

    /// Unicode separators that LOOK like a slash but are not. Text arriving
    /// from other apps carries these, and a boundary class that only knows
    /// ASCII has a hole exactly the width of a copy and paste.
    func testRulesDoNotFireInsideUnicodeLookalikePaths() {
        let layer = DeterministicCorrections(
            preferredTranscriptions: [],
            commonlyMisheard: [MisheardReplacement(wrong: "face", right: "Hugging Face")]
        )
        XCTAssertEqual(layer.apply(to: "src\u{2215}face\u{2215}detect.py"), "src\u{2215}face\u{2215}detect.py")
        XCTAssertEqual(layer.apply(to: "a\u{2044}face\u{2044}b"), "a\u{2044}face\u{2044}b")
        XCTAssertEqual(layer.apply(to: "x\u{FF0F}face\u{FF0F}y"), "x\u{FF0F}face\u{FF0F}y")
        XCTAssertEqual(layer.apply(to: "face\u{FF0E}py"), "face\u{FF0E}py")
    }

    /// And the other half again: ordinary sentences must still be corrected,
    /// including at a sentence end and before ordinary punctuation.
    func testOrdinarySentencesAreStillCorrectedAfterTheHardening() {
        let layer = DeterministicCorrections(
            preferredTranscriptions: ["AF Flow"],
            commonlyMisheard: [MisheardReplacement(wrong: "face", right: "Hugging Face")]
        )
        XCTAssertEqual(layer.apply(to: "I checked face."), "I checked Hugging Face.")
        XCTAssertEqual(layer.apply(to: "face, then more"), "Hugging Face, then more")
        XCTAssertEqual(layer.apply(to: "(face)"), "(Hugging Face)")
        XCTAssertEqual(layer.apply(to: "af flow works"), "AF Flow works")
    }
}
