import XCTest
@testable import GhostPepper

/// Pins the fix for the defect Andrew described as translation.
///
/// "Sometimes it translates whatever I'm saying. I notice that when I speak
/// English sometimes it translates it into Russian. Looks correct in Russian,
/// but there was no point to translate it."
///
/// Nothing translates. Whisper decodes in the language it is told, so a
/// mis-detection renders his meaning fluently in the wrong language, which is
/// why it looks correct and why reading the output can never catch it.
///
/// REWRITTEN 2026-08-02, because the tests below used to pin a data shape that
/// production has never once produced. They fed linear probabilities such as
/// `["en": 0.92, "ru": 0.05]`. His machine returns LOG probabilities, one entry
/// at a time: `["en": -0.00074]`. Across all 23 language decisions in his live
/// log there were zero positive values, 23 negative and 23 absent, so the old
/// guard `english > 0 || russian > 0` failed every single time and the measured
/// prior never decided anything. The suite was green throughout.
///
/// That is this project's signature defect, so the values below are copied from
/// his actual log rather than invented.
@MainActor
final class LanguageChoiceTests: XCTestCase {

    // MARK: - The real shape, taken from his log

    func testTheLogProbabilitiesHisMachineActuallyReturnsAreUnderstood() {
        // p(en)=-0.00074300944 means 99.9 per cent English, not "less than zero".
        XCTAssertEqual(ModelManager.normalisedProbability(-0.00074300944), 0.999, accuracy: 0.001)
        XCTAssertEqual(ModelManager.normalisedProbability(-2.1541884), 0.116, accuracy: 0.002)
        XCTAssertEqual(ModelManager.normalisedProbability(-0.02031345), 0.980, accuracy: 0.002)
        // A linear probability, if WhisperKit ever returns one, is left alone.
        XCTAssertEqual(ModelManager.normalisedProbability(0.92), 0.92, accuracy: 0.001)
    }

    func testAConfidentEnglishDetectionStaysEnglish() {
        XCTAssertEqual(
            ModelManager.restrictedLanguage(probabilities: ["en": -0.00074300944], reportedLanguage: "en"),
            "en"
        )
    }

    func testAConfidentRussianDetectionStaysRussian() {
        XCTAssertEqual(
            ModelManager.restrictedLanguage(probabilities: ["ru": -0.02031345], reportedLanguage: "ru"),
            "ru"
        )
    }

    /// A LOW-CONFIDENCE WINNER IS STILL THE WINNER, and this test replaces one that
    /// asserted the opposite.
    ///
    /// The first version applied his prior below a confidence floor, so Russian at 12
    /// per cent became English. Codex showed that unsound: the map holds one entry, so
    /// an absent English score is NO score, not a low one, and the missing mass may sit
    /// entirely on a third language. Weighing a number against a number that does not
    /// exist is how the deleted code justified itself for a year.
    func testAWeakButSupportedWinnerIsStillTrusted() {
        XCTAssertEqual(
            ModelManager.restrictedLanguage(probabilities: ["ru": -2.15], reportedLanguage: "ru"),
            "ru",
            "There is no English score to weigh this against, so inventing one is not a rescue."
        )
        XCTAssertEqual(
            ModelManager.restrictedLanguage(probabilities: ["en": -2.1541884], reportedLanguage: "en"),
            "en"
        )
    }

    /// A value that is not a probability at all is treated as no evidence, not as
    /// certainty.
    func testInvalidProbabilityValuesAreNotReadAsCertainty() {
        XCTAssertEqual(ModelManager.normalisedProbability(1.5), 0, accuracy: 0.0001)
        XCTAssertEqual(ModelManager.normalisedProbability(.infinity), 0, accuracy: 0.0001)
        XCTAssertEqual(ModelManager.normalisedProbability(.nan), 0, accuracy: 0.0001)
        // Exactly zero is a log probability of 1.0, which is what the winner carries.
        XCTAssertEqual(ModelManager.normalisedProbability(0), 1, accuracy: 0.0001)
    }

    /// THE URDU CASE, 2026-07-31 21:46. Whisper called his English "ur" and the gate
    /// handed the decode to all 99 languages, which pasted Arabic script into his
    /// document. Andrew ratified on 2026-08-02 that this must never fall open again.
    func testAThirdLanguageNeverFallsThroughToNinetyNineLanguages() {
        XCTAssertEqual(
            ModelManager.restrictedLanguage(probabilities: ["ur": -0.5], reportedLanguage: "ur"),
            "en",
            "This is the exact detection that pasted Urdu into his document."
        )
        XCTAssertEqual(
            ModelManager.restrictedLanguage(probabilities: ["de": -0.1], reportedLanguage: "de"),
            "en"
        )
    }

    /// Ukrainian is out of v1 by his decision, so it must not become selectable by
    /// accident through the reported-language door either.
    func testUkrainianIsNotSelectable() {
        XCTAssertFalse(ModelManager.supportedAutoDetectLanguages.contains("uk"))
        XCTAssertEqual(
            ModelManager.restrictedLanguage(probabilities: ["uk": -0.01], reportedLanguage: "uk"),
            "en"
        )
    }

    /// With nothing at all, it still answers. Returning nil is what used to hand the
    /// decode to 99 languages.
    func testNoEvidenceStillAnswersRatherThanFallingOpen() {
        XCTAssertEqual(ModelManager.restrictedLanguage(probabilities: [:], reportedLanguage: nil), "en")
        XCTAssertEqual(ModelManager.restrictedLanguage(probabilities: [:], reportedLanguage: "ru"), "ru")
    }

    // MARK: - The two-language shape, kept in case WhisperKit ever returns it

    func testClearEnglishStaysEnglishWhenBothAreScored() {
        XCTAssertEqual(
            ModelManager.restrictedLanguage(probabilities: ["en": 0.92, "ru": 0.05], reportedLanguage: "en"),
            "en"
        )
    }

    func testClearRussianStaysRussianWhenBothAreScored() {
        XCTAssertEqual(
            ModelManager.restrictedLanguage(probabilities: ["ru": 0.88, "en": 0.07], reportedLanguage: "ru"),
            "ru"
        )
    }

    /// Accented English scores close to Russian, and unrestricted detection tips to
    /// Russian. His prior says English is right more than twice as often, so a near
    /// tie must resolve to English.
    func testNearTieResolvesToEnglish() {
        XCTAssertEqual(
            ModelManager.restrictedLanguage(probabilities: ["en": 0.40, "ru": 0.45], reportedLanguage: "ru"),
            "en"
        )
    }

    /// But the prior must not overturn real acoustic evidence, or his Russian starts
    /// coming back as English, which is the same bug pointing the other way.
    func testStrongRussianBeatsThePrior() {
        XCTAssertEqual(
            ModelManager.restrictedLanguage(probabilities: ["en": 0.20, "ru": 0.75], reportedLanguage: "ru"),
            "ru"
        )
    }

    func testAThirdLanguageCanNeverWinWhenBothAreScored() {
        XCTAssertEqual(
            ModelManager.restrictedLanguage(probabilities: ["bg": 0.97, "en": 0.02, "ru": 0.01], reportedLanguage: "bg"),
            "en",
            "only en and ru are selectable"
        )
    }
}
