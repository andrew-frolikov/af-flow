import XCTest
@testable import AFFlow

/// Words he said that the cleanup model removed outright.
///
/// He noticed one on 2026-08-05: he dictated
/// "проанализируя их задай вопросы" and the cleaned text read "задай вопросы".
///
/// **The existing guard could not have caught it, and no tuning of it would.**
/// `droppedTooMuch` compares total word counts, so two words gone from a
/// 31-word sentence is a 0.94 ratio against a 0.75 floor. A global ratio
/// cannot see a local deletion; it needs an alignment.
///
/// Measuring his archive rather than fixing only the one he noticed found
/// **9 of 50 dictations had content words deleted**, including four-word runs:
///
///     "and talent acquisition specialists"
///     "какие то сервисы которым"
///
/// Every fixture below is one of his real cases.
final class CleanupDeletionTests: XCTestCase {

    // MARK: - His real losses

    func testTheDeletionHeNoticedIsCaught() {
        let spoken = "ниже мои заметки про боли моего брата в компании проанализируя их "
            + "задай вопросы если что то непонятно и я хочу чтобы ты мне дал топ 3 решение"
        let cleaned = "ниже мои заметки про боли моего брата в компании "
            + "задай вопросы если что то непонятно и я хочу чтобы ты мне дал топ 3 решение"

        let runs = TextCleaner.deletedSpokenRuns(input: spoken, output: cleaned)

        XCTAssertEqual(runs, ["проанализируя их"])
    }

    func testTheEnglishFourWordDeletionIsCaught() {
        let spoken = "we need to hire more recruiters and talent acquisition specialists "
            + "before the end of the quarter to keep up with the plan"
        let cleaned = "we need to hire more recruiters "
            + "before the end of the quarter to keep up with the plan"

        let runs = TextCleaner.deletedSpokenRuns(input: spoken, output: cleaned)

        XCTAssertEqual(runs, ["and talent acquisition specialists"])
    }

    func testTheRussianFourWordDeletionIsCaught() {
        let spoken = "нам нужно посмотреть какие то сервисы которым можно доверять "
            + "и которые не будут стоить слишком дорого для нас"
        let cleaned = "нам нужно посмотреть можно доверять "
            + "и которые не будут стоить слишком дорого для нас"

        let runs = TextCleaner.deletedSpokenRuns(input: spoken, output: cleaned)

        XCTAssertEqual(runs, ["какие то сервисы которым"])
    }

    // MARK: - What must NOT be flagged

    /// Removing a filler is the cleanup doing its job, and flagging it would
    /// send him raw text constantly.
    func testRemovingFillersIsNotADeletion() {
        let spoken = "um so I think we should just ship it well maybe tomorrow okay"
        let cleaned = "I think we should ship it maybe tomorrow"

        XCTAssertEqual(TextCleaner.deletedSpokenRuns(input: spoken, output: cleaned), [])
    }

    /// Four of his nine cases were a single word — a stutter or a function word.
    /// Runs of one are deliberately allowed.
    func testASingleDeletedWordIsAllowed() {
        let spoken = "и я думаю что что нам надо сделать это прямо сейчас без задержек"
        let cleaned = "и я думаю что нам надо сделать это прямо сейчас без задержек"

        XCTAssertEqual(TextCleaner.deletedSpokenRuns(input: spoken, output: cleaned), [])
    }

    func testAnUntouchedCleanupFlagsNothing() {
        let spoken = "this sentence comes back with nothing removed at all from it today"

        XCTAssertEqual(TextCleaner.deletedSpokenRuns(input: spoken, output: spoken), [])
    }

    /// Punctuation and capitalisation are the cleanup's whole purpose.
    func testPunctuationAndCaseChangesAreNotDeletions() {
        let spoken = "however if you already understood it implement it but ask me questions first"
        let cleaned = "However, if you already understood it, implement it, but ask me questions first."

        XCTAssertEqual(TextCleaner.deletedSpokenRuns(input: spoken, output: cleaned), [])
    }

    /// A rewrite that ADDS words must not read as a deletion.
    func testAddedWordsAreNotDeletions() {
        let spoken = "send the report to the team before the meeting starts this afternoon"
        let cleaned = "Please send the report to the whole team before the meeting starts this afternoon."

        XCTAssertEqual(TextCleaner.deletedSpokenRuns(input: spoken, output: cleaned), [])
    }

    /// Short utterances are exempt: "um yes" to "yes" is a correct cleanup and
    /// the ratio is meaningless at that length.
    func testShortUtterancesAreExempt() {
        XCTAssertEqual(TextCleaner.deletedSpokenRuns(input: "um yes okay", output: "yes"), [])
    }

    /// Two separate deletions in one dictation are both reported, so the log
    /// says what was actually lost rather than only the first thing.
    func testTwoSeparateDeletionsAreBothReported() {
        let spoken = "first we remove the old system and then we install the new one "
            + "and after that we tell the whole team about it"
        let cleaned = "first we and then we install the new one "
            + "and after that we tell about it"

        let runs = TextCleaner.deletedSpokenRuns(input: spoken, output: cleaned)

        XCTAssertEqual(runs.count, 2, "got \(runs)")
        XCTAssertTrue(runs.contains { $0.contains("remove the old system") }, "got \(runs)")
        XCTAssertTrue(runs.contains { $0.contains("whole team") }, "got \(runs)")
    }

    /// The guard this replaces still cannot see the case, which is why both
    /// exist rather than one being tuned.
    func testTheOldRatioGuardStillMissesIt() {
        let spoken = "ниже мои заметки про боли моего брата в компании проанализируя их "
            + "задай вопросы если что то непонятно и я хочу чтобы ты мне дал топ 3 решение"
        let cleaned = "ниже мои заметки про боли моего брата в компании "
            + "задай вопросы если что то непонятно и я хочу чтобы ты мне дал топ 3 решение"

        XCTAssertFalse(
            TextCleaner.droppedTooMuch(input: spoken, output: cleaned),
            "if the ratio guard ever catches this, the two guards have converged and one is redundant"
        )
        XCTAssertFalse(TextCleaner.deletedSpokenRuns(input: spoken, output: cleaned).isEmpty)
    }

    /// How often this will actually send him raw text, measured on his archive.
    ///
    /// A guard that fires constantly is worse than the bug: he would lose the
    /// punctuation and casing the cleanup exists for, on every dictation, and
    /// stop trusting it. So the rate is measured rather than assumed.
    ///
    /// SKIPPED unless `TEST_RUNNER_AF_FLOW_DELETION_RATE=1`; needs
    /// `scripts/stage-language-replay.sh` first.
    func testHowOftenThisFiresAcrossHisArchive() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AF_FLOW_DELETION_RATE"] == "1",
            "set TEST_RUNNER_AF_FLOW_DELETION_RATE=1 and stage first"
        )

        struct Entry: Decodable {
            let rawTranscription: String?
            let correctedTranscription: String?
        }

        let staged = AppSupportDirectory.url
            .appendingPathComponent("replay/transcription-lab-index.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: staged.path), "nothing staged")

        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: staged))
        var considered = 0, fired = 0, rescued = 0
        for entry in entries {
            guard let raw = entry.rawTranscription, let cleaned = entry.correctedTranscription,
                  !raw.isEmpty, !cleaned.isEmpty else { continue }
            considered += 1
            let runs = TextCleaner.deletedSpokenRuns(input: raw, output: cleaned)
            if !runs.isEmpty {
                fired += 1
                let restored = TextCleaner.restoringWordsDeletedFromSpeech(cleaned, spokenInput: raw)
                let placed = restored.map {
                    TextCleaner.deletedSpokenRuns(input: raw, output: $0).isEmpty
                } ?? false
                if placed { rescued += 1 }
                print("DELETION \(placed ? "RESTORED" : "raw text  ") \(runs.map { "\"\($0)\"" }.joined(separator: ", "))")
            }
        }
        let rate = considered > 0 ? Double(fired) / Double(considered) : 0
        print("DELETION RATE \(fired) of \(considered) dictations, \(Int(rate * 100))%")
        print("DELETION RESTORED \(rescued) of \(fired); raw text only for \(fired - rescued)")

        // If this ever fires on most of his dictations the guard has become the
        // problem. Not a tuning knob: a tripwire on the design.
        XCTAssertLessThan(rate, 0.5, "the guard fires on half his dictations; it is too aggressive")
    }

    // MARK: - Putting the words back

    /// The one he noticed, restored WITH the punctuation kept.
    func testTheDeletionHeNoticedIsPutBack() {
        let spoken = "ниже мои заметки про боли моего брата в компании проанализируя их "
            + "задай вопросы если что то непонятно"
        let cleaned = "Ниже мои заметки про боли моего брата в компании, "
            + "задай вопросы, если что-то непонятно."

        let restored = TextCleaner.restoringWordsDeletedFromSpeech(cleaned, spokenInput: spoken)

        XCTAssertNotNil(restored)
        XCTAssertTrue(restored!.contains("проанализируя их"), restored ?? "nil")
        XCTAssertTrue(restored!.contains("Ниже"), "the cleanup's capitalisation must survive")
        XCTAssertTrue(restored!.contains("что-то непонятно."), "its punctuation must survive")
        XCTAssertEqual(TextCleaner.deletedSpokenRuns(input: spoken, output: restored!), [])
    }

    func testTheEnglishRunIsPutBack() {
        let spoken = "we need to hire more recruiters and talent acquisition specialists "
            + "before the end of the quarter"
        let cleaned = "We need to hire more recruiters before the end of the quarter."

        let restored = TextCleaner.restoringWordsDeletedFromSpeech(cleaned, spokenInput: spoken)

        XCTAssertNotNil(restored)
        XCTAssertTrue(restored!.contains("and talent acquisition specialists"), restored ?? "nil")
        XCTAssertEqual(TextCleaner.deletedSpokenRuns(input: spoken, output: restored!), [])
    }

    /// **The safety rule.** If the cleanup restructured the sentence, the words
    /// that flanked the deletion are no longer neighbours, there is no
    /// unambiguous place to put the run, and nothing is guessed. nil tells the
    /// caller to fall back to raw text.
    func testARestructuredSentenceIsNotGuessedAt() {
        let spoken = "we need to hire more recruiters and talent acquisition specialists "
            + "before the end of the quarter"
        let cleaned = "Before the quarter ends, more recruiters are needed."

        XCTAssertNil(
            TextCleaner.restoringWordsDeletedFromSpeech(cleaned, spokenInput: spoken),
            "a heavy rewrite has no unambiguous slot; guessing one produces text he never said"
        )
    }

    /// A cleanup that deleted nothing is returned untouched, so restoration
    /// never becomes a rewrite of its own.
    func testACleanCleanupPassesThroughUnchanged() {
        let spoken = "send the report to the team before the meeting starts this afternoon"
        let cleaned = "Send the report to the team before the meeting starts this afternoon."

        XCTAssertEqual(
            TextCleaner.restoringWordsDeletedFromSpeech(cleaned, spokenInput: spoken),
            cleaned
        )
    }

    /// Both runs come back when the model made two separate cuts.
    func testTwoSeparateDeletionsAreBothPutBack() {
        let spoken = "first we remove the old system and then we install the new one "
            + "and after that we tell the whole team about it"
        let cleaned = "First we and then we install the new one, "
            + "and after that we tell about it."

        let restored = TextCleaner.restoringWordsDeletedFromSpeech(cleaned, spokenInput: spoken)

        XCTAssertNotNil(restored)
        XCTAssertEqual(TextCleaner.deletedSpokenRuns(input: spoken, output: restored!), [],
                       "got \(restored ?? "nil")")
    }
}