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
/// Unrestricted detection chooses among 99 languages when two are possible. His
/// own history is the argument: 1220 dictations, 887 English, 332 Russian, and
/// one Bulgarian.
@MainActor
final class LanguageChoiceTests: XCTestCase {
    func testClearEnglishStaysEnglish() {
        XCTAssertEqual(ModelManager.chooseLanguage(from: ["en": 0.92, "ru": 0.05]), "en")
    }

    func testClearRussianStaysRussian() {
        XCTAssertEqual(ModelManager.chooseLanguage(from: ["ru": 0.88, "en": 0.07]), "ru")
    }

    /// The case he actually hit. Accented English scores close to Russian, and
    /// unrestricted detection tips to Russian. His prior says English is right
    /// more than twice as often, so a near-tie must resolve to English.
    func testNearTieResolvesToEnglish() {
        XCTAssertEqual(ModelManager.chooseLanguage(from: ["en": 0.40, "ru": 0.45]), "en")
    }

    /// But the prior must not be able to overturn real acoustic evidence. If it
    /// could, his Russian would start coming back as English, which is the same
    /// bug pointing the other way.
    func testStrongRussianBeatsThePrior() {
        XCTAssertEqual(ModelManager.chooseLanguage(from: ["en": 0.20, "ru": 0.75]), "ru")
    }

    /// A third language is never selectable, however confident the model is.
    /// Andrew's history contains exactly one Bulgarian detection and zero
    /// Bulgarian dictations.
    func testAThirdLanguageCanNeverWin() {
        let chosen = ModelManager.chooseLanguage(from: ["bg": 0.97, "en": 0.02, "ru": 0.01])
        XCTAssertEqual(chosen, "en", "only en and ru are selectable")
    }

    /// Ukrainian is out of v1 by his decision, so it must not become selectable
    /// by accident through this path.
    func testUkrainianIsNotSelectable() {
        XCTAssertFalse(ModelManager.supportedAutoDetectLanguages.contains("uk"))
        XCTAssertEqual(ModelManager.chooseLanguage(from: ["uk": 0.9, "ru": 0.05, "en": 0.03]), "en")
    }

    /// With no usable evidence it must decline rather than guess, so the caller
    /// falls back to Whisper's own detection instead of forcing a language.
    func testNoEvidenceDeclinesRatherThanGuessing() {
        XCTAssertNil(ModelManager.chooseLanguage(from: [:]))
        XCTAssertNil(ModelManager.chooseLanguage(from: ["bg": 0.99]))
    }
}
