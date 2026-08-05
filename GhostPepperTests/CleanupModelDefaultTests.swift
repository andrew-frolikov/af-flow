import XCTest
@testable import GhostPepper

/// The cleanup model default, and why it could never change.
///
/// `scripts/defaults-diff.py` found this on 2026-08-03: `TextCleanupManager.init`
/// wrote `selectedCleanupModelKind` on EVERY construction, including the first
/// launch when nothing had been chosen. So the code default was consumed once,
/// ever, and then frozen into his plist permanently — in the code that cleans up
/// everything he writes. Every later improvement to it was invisible to him, and
/// invisible to the tests, which start from an empty domain.
///
/// He asked for the 0.8B back on 2026-08-05. The migration REMOVES his frozen
/// value rather than setting it to 0.8B: setting it would re-freeze him at
/// whatever happens to be current today, and removing it means he follows the
/// code default now and after the next change too.
@MainActor
final class CleanupModelDefaultTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "af-flow-cleanup-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private var key: String { TextCleanupManager.selectedCleanupModelDefaultsKey }
    private var marker: String { TextCleanupManager.twoBillionMigrationDefaultsKey }

    /// The thing he asked for: his frozen 2B goes away.
    func testHisFrozenTwoBillionSelectionIsRemoved() {
        let defaults = makeDefaults()
        defaults.set(LocalCleanupModelKind.qwen35_2b_q4_k_m.rawValue, forKey: key)

        TextCleanupManager.migrateAwayFromTheTwoBillionDefault(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: key),
                     "the key must be REMOVED, not set: setting it re-freezes him")
    }

    /// Removing it, rather than writing 0.8B, is what makes the NEXT default
    /// change reach him too. This is the property the whole fix exists for.
    func testAnAbsentKeyMeansHeFollowsTheCodeDefault() {
        let defaults = makeDefaults()
        defaults.set(LocalCleanupModelKind.qwen35_2b_q4_k_m.rawValue, forKey: key)
        TextCleanupManager.migrateAwayFromTheTwoBillionDefault(defaults: defaults)

        let manager = TextCleanupManager(defaults: defaults)

        XCTAssertEqual(manager.selectedCleanupModelKind, LocalCleanupModelKind.qwen35_0_8b_q4_k_m)
        XCTAssertNil(defaults.string(forKey: key),
                     "constructing the manager must not write the key back")
    }

    /// The freeze itself. Building the manager must never persist a choice he
    /// did not make, or the default is dead text again from that moment on.
    func testConstructingTheManagerNeverWritesTheKey() {
        let defaults = makeDefaults()

        _ = TextCleanupManager(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: key))
    }

    /// It must not fight him. If he picks 2B again tomorrow, the next launch has
    /// to leave it alone — which is what the marker is for, and why the guard is
    /// not the stored value on its own.
    func testPickingTwoBillionAgainLaterIsRespected() {
        let defaults = makeDefaults()
        defaults.set(LocalCleanupModelKind.qwen35_2b_q4_k_m.rawValue, forKey: key)
        TextCleanupManager.migrateAwayFromTheTwoBillionDefault(defaults: defaults)

        // He chooses it again, deliberately.
        defaults.set(LocalCleanupModelKind.qwen35_2b_q4_k_m.rawValue, forKey: key)
        TextCleanupManager.migrateAwayFromTheTwoBillionDefault(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: key),
                       LocalCleanupModelKind.qwen35_2b_q4_k_m.rawValue,
                       "the migration undid a choice he made after it ran")
    }

    /// A different explicit choice is not this migration's business.
    func testADifferentStoredChoiceIsLeftAlone() {
        let defaults = makeDefaults()
        defaults.set(LocalCleanupModelKind.qwen35_4b_q4_k_m.rawValue, forKey: key)

        TextCleanupManager.migrateAwayFromTheTwoBillionDefault(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: key),
                       LocalCleanupModelKind.qwen35_4b_q4_k_m.rawValue)
    }

    func testTheMigrationRunsOnlyOnce() {
        let defaults = makeDefaults()

        TextCleanupManager.migrateAwayFromTheTwoBillionDefault(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: marker))
    }

    /// An explicit selection still persists, or he could not change models at
    /// all.
    func testAnExplicitSelectionIsStillHonoured() {
        let defaults = makeDefaults()

        let manager = TextCleanupManager(
            defaults: defaults, selectedCleanupModelKind: .qwen35_4b_q4_k_m
        )

        XCTAssertEqual(manager.selectedCleanupModelKind, LocalCleanupModelKind.qwen35_4b_q4_k_m)
    }
}
