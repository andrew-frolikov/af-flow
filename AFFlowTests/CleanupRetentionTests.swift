import XCTest
@testable import AFFlow

/// Pins the guard against the cleanup model deleting what Andrew said.
///
/// On 2026-07-27 he dictated "Я проверил, и это работает хорошо, если вы нужны
/// мой вердикт" and what landed was "Я проверил, и это работает хорошо." The
/// model deleted the clause in which he was offering his verdict, presumably
/// reading garbled Russian as noise.
///
/// The prompt already forbids deleting his words in plain language, and the
/// model did it anyway. That is the argument for enforcing it in code: a
/// request is not a guarantee, and this project's standing ranking is that
/// uncleaned text is an annoyance while missing text is unrecoverable.
final class CleanupRetentionTests: XCTestCase {

    // MARK: - The symmetric hole: the model repeating itself

    /// THE DOUBLE PASTE, diagnosed 2026-08-02 and reported by Andrew as "it pasted
    /// the text two times".
    ///
    /// It was never the paste path. His transcription lab holds 47 dictations with
    /// text: 46 came back at a length ratio of 1.00 and one came back at 1.97. That
    /// one is 2026-08-02 14:40, 111.5 seconds of audio and 937 characters, the
    /// longest input in the sample by a factor of 1.8. The cleanup model produced a
    /// correctly cleaned version, then started again and produced the whole thing a
    /// second time, and the paste faithfully pasted what it was handed.
    ///
    /// There was already a guard for the model deleting his words and none for it
    /// repeating them, which is the same hole facing the other way.
    func testAnOutputThatRestartsItselfIsTruncatedToOneCopy() {
        let once = "However, I want Opus 5 to act as an evaluator whenever you're going to be "
            + "spawning some sub-agents. And that evaluator needs to understand for what exact "
            + "tasks what model is required. I want you to rely on Codex, whenever you can. The "
            + "reason why I'm asking that because I want to save tokens as much as possible."
        let doubled = once + " " + once

        XCTAssertEqual(
            TextCleaner.withoutRepeatedCopy(doubled),
            once,
            "The model emitted his passage twice and the second copy reached his document."
        )
    }

    /// A second copy that the model cut short must still be removed.
    func testATruncatedSecondCopyIsAlsoRemoved() {
        let once = "So the plan is to fix the language decision first, because that one is on the "
            + "path of every word I dictate and it has never actually worked. Then the cleanup "
            + "guard, then a runtime probe script that reads the log at session start, then the "
            + "paste and hotkey instrumentation. After that the three remaining meeting bugs, "
            + "in the order sixteen, fifteen, fourteen, because the first two are mechanical "
            + "and the third one needs a design decision about voice activity detection."
        let doubled = once + " " + String(once.prefix(160))

        XCTAssertEqual(TextCleaner.withoutRepeatedCopy(doubled), once)
    }

    /// AND IT MUST NOT OVER-TRIM, which writing the test above is what caught.
    ///
    /// A passage built from one sentence repeated matches its own opening every few
    /// characters, and a guard that trimmed at the first match would cut it down to a
    /// single sentence. Losing his words to a guard against duplicated words would be
    /// the same defect wearing the opposite coat.
    func testALongRepetitivePassageIsNotCutDown() {
        let periodic = String(repeating: "I want to be smart about my tokens and not overpay for any of this. ", count: 12)
            .trimmingCharacters(in: .whitespaces)
        XCTAssertGreaterThan(periodic.count, TextCleaner.repetitionCheckMinimumCharacters)
        XCTAssertEqual(
            TextCleaner.withoutRepeatedCopy(periodic),
            periodic,
            "A legitimately repetitive passage was trimmed, which loses his words."
        )
    }

    /// And it must not touch ordinary text, including text that legitimately repeats a
    /// phrase. Damaging a correct cleanup would be worse than the bug.
    func testOrdinaryOutputIsLeftCompletelyAlone() {
        let normal = "I want to be smart about my tokens. I want to be smart about my tokens in "
            + "meetings too, and I want the transcript to be readable afterwards, which is a "
            + "different thing from being short."
        XCTAssertEqual(TextCleaner.withoutRepeatedCopy(normal), normal)

        let short = "Yes, that works."
        XCTAssertEqual(TextCleaner.withoutRepeatedCopy(short), short)

        // Deliberately repetitive but not a restart.
        let listy = "First the language gate. Then the cleanup guard. Then the runtime probe. "
            + "Then the paste instrumentation. Then bugs sixteen, fifteen and fourteen."
        XCTAssertEqual(TextCleaner.withoutRepeatedCopy(listy), listy)
    }

    /// The real numbers from his lab, so the threshold is measured rather than chosen.
    func testTheGuardOnlyEngagesOnLongOutputs() {
        // 46 of 47 dictations came back at ratio 1.00; the longest legitimate one was
        // 567 characters. The doubled one was 1849. A short repeated phrase must not
        // trip the guard.
        let shortRepeat = "okay okay"
        XCTAssertEqual(TextCleaner.withoutRepeatedCopy(shortRepeat), shortRepeat)
    }

    // MARK: - The commas it takes out of his long sentences

    /// HIS OWN WORDS, 2026-08-02 17:41, taken from the transcription lab.
    ///
    /// Whisper punctuated this correctly and the 2B cleanup model stripped three commas
    /// out of one sentence, the three that were carrying the grammar. He noticed and
    /// said so: "look at the punctuation here".
    func testTheThreeCommasItTookOutOfHisInstructionAreRestored() {
        let spoken = "So help me think through that and help me understand what I want. "
            + "However, if you already understood it, implement it, but ask me questions before you do that."
        let returned = "So help me think through that and help me understand what I want. "
            + "However, if you already understood it implement it but ask me questions before you do that."

        XCTAssertEqual(
            TextCleaner.restoringCommasRemovedFromSpeech(returned, spokenInput: spoken),
            spoken,
            "The commas he actually said were not put back."
        )
    }

    /// The second real case from the same afternoon.
    func testACommaBeforeAConditionalIsRestored() {
        let spoken = "for you to evaluate where to look, if you have to get information somewhere"
        let returned = "for you to evaluate where to look if you have to get information somewhere"
        XCTAssertEqual(TextCleaner.restoringCommasRemovedFromSpeech(returned, spokenInput: spoken), spoken)
    }

    /// IT MUST NOT INVENT PUNCTUATION. It only ever puts back a comma he actually said.
    func testACommaHeNeverSaidIsNeverAdded() {
        let spoken = "this is a sentence with no commas in it at all"
        let returned = "this is a sentence with no commas in it at all"
        XCTAssertEqual(TextCleaner.restoringCommasRemovedFromSpeech(returned, spokenInput: spoken), returned)
    }

    /// And it must not fight a legitimate rewrite. If the cleanup restructured that part
    /// of the sentence, the two words are no longer next to each other and nothing is
    /// put back. This is what stops it undoing correct work.
    func testNothingIsRestoredWhereTheCleanupRestructuredTheSentence() {
        let spoken = "so basically, umm, the thing is broken"
        let returned = "The thing is broken."
        XCTAssertEqual(
            TextCleaner.restoringCommasRemovedFromSpeech(returned, spokenInput: spoken),
            returned,
            "It overrode a rewrite instead of leaving it alone."
        )
    }

    /// A cleanup that ADDED commas is left completely alone, which is the common case:
    /// across his 46 dictations the net change was plus four commas.
    func testAnOutputWithMoreCommasThanHeSaidIsUntouched() {
        let spoken = "so I went to the store and then I came back"
        let returned = "So I went to the store, and then I came back."
        XCTAssertEqual(TextCleaner.restoringCommasRemovedFromSpeech(returned, spokenInput: spoken), returned)
    }

    /// Full stops are deliberately NOT restored: he adds them far more often than he
    /// loses them, net plus seven across the population, so a moved sentence boundary is
    /// a change worth keeping.
    func testFullStopsAreNotRestored() {
        let spoken = "first thing. second thing."
        let returned = "First thing, second thing."
        XCTAssertEqual(TextCleaner.restoringCommasRemovedFromSpeech(returned, spokenInput: spoken), returned)
    }

    // MARK: - The original guard: the model deleting what he said

    /// The real case, in his own words.
    func testTheClauseDeletionHeHitIsRejected() {
        let said = "Я проверил, и это работает хорошо, если вы нужны мой вердикт"
        let returned = "Я проверил, и это работает хорошо."
        XCTAssertTrue(TextCleaner.droppedTooMuch(input: said, output: returned))
    }

    /// The worst LEGITIMATE cleanup in his recorded history keeps 0.87 of the
    /// words. It must survive, or the guard trades one failure for another.
    func testAHeavyButLegitimateCleanupSurvives() {
        let said = String(repeating: "word ", count: 100)
        let returned = String(repeating: "word ", count: 87)
        XCTAssertFalse(TextCleaner.droppedTooMuch(input: said, output: returned))
    }

    /// Short utterances are exempt, because there the ratio means nothing.
    func testShortUtterancesAreExemptBecauseTheRatioIsMeaningless() {
        XCTAssertFalse(TextCleaner.droppedTooMuch(input: "um yes", output: "yes"))
        XCTAssertFalse(TextCleaner.droppedTooMuch(input: "uh okay then", output: "okay then"))
    }

    /// Punctuation must not move the number. The prompt explicitly permits the
    /// model to add and remove punctuation, so a guard that counted characters
    /// would fire on correct behaviour.
    func testPunctuationChangesDoNotCountAsLoss() {
        let said = "so i went to the store and then i came back home again today"
        let returned = "So I went to the store. And then I came back home again today."
        XCTAssertFalse(TextCleaner.droppedTooMuch(input: said, output: returned))
    }

    /// Total loss is caught here too, not only by the empty-output guard.
    func testAnEmptyOutputCountsAsDroppingEverything() {
        let said = "this is a sentence with more than eight words in it"
        XCTAssertTrue(TextCleaner.droppedTooMuch(input: said, output: ""))
    }
}
