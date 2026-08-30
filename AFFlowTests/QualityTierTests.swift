import XCTest
@testable import AFFlow

/// One quality ladder, two rungs, and every claim on it checkable.
///
/// `docs/launch-v1-plan.md`, settled 2026-08-29: the model screen offers
/// **Starter** (works the moment the app opens, bundled in the DMG) and
/// **Full** (the best this machine handles). Per-model control stays in
/// Settings for anyone who wants it.
///
/// The tests below exist because every mistake this ladder can make has
/// already been made once in this project:
///
///   - **an English-only default.** The fork shipped `whisper-small.en`, and
///     until 2026-07-19 a fresh install silently failed roughly a quarter of
///     Andrew's real dictation, because a quarter of it is Russian. Starter is
///     the tier a stranger gets before they have chosen anything, so an
///     English-only Starter would ship that regression to every friend.
///   - **assuming bigger is better.** Ledger item 16: `large-v3-turbo` at
///     954 MB fails Russian language identification where the 632 MB build
///     does not. A ladder that sorts by file size would put the worse model on
///     the top rung.
///   - **a model the downloader cannot verify.** The DMG bundles Starter, so
///     Starter's cleanup model must be one `model_catalogue.py` can pin by
///     hash and byte count.
final class QualityTierTests: XCTestCase {
    private let gigabyte: UInt64 = 1024 * 1024 * 1024

    // MARK: - The rungs exist and are distinct

    func testBothTiersAreNamedAndDistinct() {
        XCTAssertEqual(QualityTier.allCases.count, 2, "the ladder is two rungs")
        let names = QualityTier.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "two rungs share a name")
        for tier in QualityTier.allCases {
            XCTAssertFalse(tier.displayName.isEmpty, "\(tier) has no name")
            XCTAssertFalse(tier.oneLine.isEmpty, "\(tier) has no one-line description")
        }
    }

    // MARK: - Speech

    func testEveryTierNamesASpeechModelThatExists() {
        for tier in QualityTier.allCases {
            XCTAssertNotNil(SpeechModelCatalog.model(named: tier.speechModelID),
                            "\(tier) names '\(tier.speechModelID)', which is not in the catalogue")
        }
    }

    /// The 2026-07-19 regression, pinned so it cannot ship to a stranger.
    func testNoTierIsEnglishOnly() {
        for tier in QualityTier.allCases {
            XCTAssertNotEqual(tier.speechModelID,
                              SpeechModelCatalog.whisperSmallEnglish.id,
                              "\(tier) is English-only, and a quarter of his "
                              + "dictation is Russian")
        }
    }

    /// Ledger 16. A bigger file is not a better model.
    func testFullDoesNotUseTheBuildThatFailsRussianIdentification() {
        XCTAssertNotEqual(QualityTier.full.speechModelID,
                          SpeechModelCatalog.whisperLargeV3TurboLarge.id,
                          "Full uses the 954 MB build, which fails Russian "
                          + "language ID (ledger 16)")
    }

    func testFullIsNotWeakerThanStarter() {
        XCTAssertNotEqual(QualityTier.full.speechModelID,
                          QualityTier.starter.speechModelID,
                          "the two rungs run the same speech model, so the "
                          + "ladder offers no choice")
    }

    // MARK: - Cleanup, which is the part that depends on the machine

    func testStarterCleanupIsTheSameOnEveryMachine() {
        for ram in [UInt64(4), 8, 16, 32, 64, 128] {
            XCTAssertEqual(QualityTier.starter.cleanupModel(physicalMemory: ram * gigabyte),
                           QualityTier.starterCleanupModel,
                           "Starter changed with \(ram) GB of RAM. It is the tier "
                           + "that ships in the DMG, so it is the same everywhere.")
        }
    }

    @MainActor
    func testFullCleanupGrowsWithMemoryAndNeverShrinks() {
        var previousSize: Int64 = 0
        for ram in [UInt64(4), 8, 16, 32, 64, 128] {
            let kind = QualityTier.full.cleanupModel(physicalMemory: ram * gigabyte)
            let size = TextCleanupManager.descriptor(for: kind)?.expectedByteCount ?? 0
            XCTAssertGreaterThan(size, 0, "\(kind) has no pinned byte count")
            XCTAssertGreaterThanOrEqual(size, previousSize,
                                        "more RAM picked a SMALLER model at \(ram) GB")
            previousSize = size
        }
    }

    /// The threshold is a real boundary and is tested on both sides of itself,
    /// not somewhere convenient in the middle.
    func testTheMemoryThresholdIsABoundary() {
        let threshold = QualityTier.fullTierLargeModelMinimumMemory
        XCTAssertNotEqual(QualityTier.full.cleanupModel(physicalMemory: threshold - 1),
                          QualityTier.full.cleanupModel(physicalMemory: threshold),
                          "one byte either side of the threshold picks the same "
                          + "model, so the threshold does nothing")
    }

    /// A machine so small that nothing fits must still get an answer rather
    /// than an empty screen. Starter is that answer.
    func testAVerySmallMachineStillGetsAWorkingTier() {
        let tiny = QualityTier.recommended(physicalMemory: 4 * gigabyte)
        XCTAssertEqual(tiny, .starter)
        XCTAssertNotNil(SpeechModelCatalog.model(named: tiny.speechModelID))
    }

    func testARoomyMachineIsRecommendedFull() {
        XCTAssertEqual(QualityTier.recommended(physicalMemory: 32 * gigabyte), .full)
    }

    // MARK: - What the DMG has to carry

    /// The DMG bundles Starter, so Starter's cleanup model has to be one the
    /// downloader can verify: a pinned URL, SHA-256 and exact byte count.
    @MainActor
    func testStarterCleanupModelIsHashPinned() throws {
        let descriptor = try XCTUnwrap(
            TextCleanupManager.descriptor(for: QualityTier.starterCleanupModel),
            "Starter names a cleanup model the catalogue does not describe")
        XCTAssertEqual(descriptor.expectedSHA256.count, 64,
                       "Starter's model has no SHA-256, so the DMG would ship "
                       + "bytes nothing can check")
        XCTAssertGreaterThan(descriptor.expectedByteCount, 0)
    }

    /// Stated rather than discovered on the day the DMG is built. Roughly a
    /// gigabyte goes into the disk image, and a friend downloads all of it.
    @MainActor
    func testTheBundledStarterPayloadIsUnderTheGitHubReleaseLimit() throws {
        let cleanup = try XCTUnwrap(
            TextCleanupManager.descriptor(for: QualityTier.starterCleanupModel))
        // GitHub refuses a release asset over 2 GB. The speech model is not
        // hash-pinned and is measured on disk rather than declared, so this
        // bounds only the part the catalogue knows exactly.
        XCTAssertLessThan(cleanup.expectedByteCount, 2_000_000_000,
                          "Starter's cleanup model alone exceeds the GitHub "
                          + "release asset limit")
    }
}
