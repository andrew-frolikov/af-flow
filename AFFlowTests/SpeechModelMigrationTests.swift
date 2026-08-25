import XCTest
@testable import AFFlow

/// Covers the one-time migration off an English-only speech model.
///
/// This test exists because the bug it guards actually reached Andrew on
/// 2026-07-20: his `speechModel` key was left holding `openai_whisper-small.en`,
/// he dictated Russian, and got English back. An English-only Whisper model
/// cannot produce Cyrillic at all, so the failure is silent and total for the
/// 27 percent of his dictation that is Russian.
///
/// Every case uses its own throwaway defaults suite. These tests run inside the
/// app host and therefore share its real UserDefaults domain, so touching
/// `.standard` here would rewrite the settings of the app he dictates with.
/// That is not hypothetical; it is what caused the incident above.
final class SpeechModelMigrationTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "af-flow-migration-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// The exact state Andrew's machine was in.
    func testMigratesEnglishOnlyModelToTheMultilingualDefault() {
        defaults.set("openai_whisper-small.en", forKey: "speechModel")

        AppState.migrateEnglishOnlySpeechModel(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: "speechModel"),
            SpeechModelCatalog.defaultModelID,
            "an English-only model must be migrated: it cannot transcribe Russian at all"
        )
    }

    /// A migration that overrides a real preference is its own bug, so the
    /// narrowness matters as much as the fix.
    func testLeavesAValidMultilingualChoiceAlone() {
        let deliberate = SpeechModelCatalog.whisperLargeV3TurboLarge.name
        defaults.set(deliberate, forKey: "speechModel")

        AppState.migrateEnglishOnlySpeechModel(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: "speechModel"),
            deliberate,
            "a deliberate multilingual choice must survive the migration untouched"
        )
    }

    /// A model that has fallen out of the catalog, for instance one removed on
    /// this OS version, would otherwise leave the app pointing at nothing.
    func testMigratesAModelThatIsNoLongerInTheCatalog() {
        defaults.set("openai_whisper-does-not-exist", forKey: "speechModel")

        AppState.migrateEnglishOnlySpeechModel(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "speechModel"), SpeechModelCatalog.defaultModelID)
    }

    /// Absent key means a fresh install, where `@AppStorage`'s own default
    /// already supplies the right model. The migration must not write a key
    /// that was deliberately left unset.
    func testDoesNotWriteTheKeyOnAFreshInstall() {
        AppState.migrateEnglishOnlySpeechModel(defaults: defaults)

        XCTAssertNil(
            defaults.string(forKey: "speechModel"),
            "a fresh install must keep the key absent so the code default applies"
        )
    }

    /// The guard that stops this becoming a permanent override. If the user
    /// genuinely wants an English-only model after the migration has run, that
    /// choice has to stick.
    func testRunsOnlyOnce() {
        defaults.set("openai_whisper-small.en", forKey: "speechModel")
        AppState.migrateEnglishOnlySpeechModel(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "speechModel"), SpeechModelCatalog.defaultModelID)

        // The user then chooses English-only on purpose.
        defaults.set("openai_whisper-small.en", forKey: "speechModel")
        AppState.migrateEnglishOnlySpeechModel(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: "speechModel"),
            "openai_whisper-small.en",
            "a second run must not override a choice the user made after the migration"
        )
    }

    /// The property the whole thing protects, asserted directly so a future
    /// change to the catalog default cannot quietly reintroduce the bug.
    func testTheShippedDefaultIsNotAnEnglishOnlyModel() {
        XCTAssertFalse(
            SpeechModelCatalog.defaultModelID.hasSuffix(".en"),
            """
            The default speech model must never be English-only. \
            27 percent of Andrew's measured dictation is Russian, and an \
            English-only model fails it silently by producing confident \
            nonsense rather than an error.
            """
        )
    }
}
