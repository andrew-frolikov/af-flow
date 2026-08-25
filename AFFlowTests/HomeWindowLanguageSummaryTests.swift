import XCTest
@testable import AFFlow

/// The language line on the front page of his app.
///
/// It read "English, Russian, auto" as a hardcoded string until 2026-08-02.
/// "auto" stopped being true the moment `detectLanguage = true` was deleted and
/// en/ru became the only possible answers, and nothing made the label notice.
@MainActor
final class HomeWindowLanguageSummaryTests: XCTestCase {
    func testTheLanguageLineNamesEveryAllowedLanguage() {
        let summary = AFFlowHomeView.languageSummary

        XCTAssertTrue(summary.contains("English"), summary)
        XCTAssertTrue(summary.contains("Russian"), summary)
    }

    /// The point of the whole change: the app must not tell him it detects
    /// language automatically, because since 2026-08-02 it does not. It cannot
    /// return anything outside the allowlist.
    func testTheLanguageLineDoesNotClaimAutomaticDetection() {
        let summary = AFFlowHomeView.languageSummary.lowercased()

        XCTAssertFalse(summary.contains("auto"), AFFlowHomeView.languageSummary)
        XCTAssertFalse(summary.contains("detect"), AFFlowHomeView.languageSummary)
    }

    /// It is derived, not restated. If the allowlist ever gains or loses a
    /// language the label follows without anyone remembering to edit it, which
    /// is the property the old string literal did not have.
    func testTheLanguageLineHasOneEntryPerAllowedLanguage() {
        let parts = AFFlowHomeView.languageSummary
            .components(separatedBy: ", ")
            .filter { !$0.isEmpty }

        XCTAssertEqual(parts.count, ModelManager.supportedAutoDetectLanguages.count)
    }

    /// Ukrainian is out of v1 and must not appear. This pins the actual list
    /// rather than only its length, so a wrong-but-same-sized allowlist fails.
    func testUkrainianIsNotOffered() {
        XCTAssertFalse(AFFlowHomeView.languageSummary.contains("Ukrainian"))
        XCTAssertEqual(ModelManager.supportedAutoDetectLanguages, ["en", "ru"])
    }
}
