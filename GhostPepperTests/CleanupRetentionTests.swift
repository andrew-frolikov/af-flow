import XCTest
@testable import GhostPepper

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
