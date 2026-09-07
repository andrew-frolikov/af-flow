import XCTest
@testable import AFFlow

/// A tier is a list of pinned files, installed or reported. Nothing here
/// invents what a tier contains: it asks `QualityTier`, which is the one place
/// that says what a rung runs.
final class TierInstallerTests: XCTestCase {
    private var workspace: URL!
    private var root: URL!

    override func setUpWithError() throws {
        workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tier-\(UUID().uuidString)", isDirectory: true)
        root = workspace.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func installer(_ fetcher: Fetching) -> TierInstaller {
        TierInstaller(downloader: ModelDownloader(fetcher: fetcher, root: root), root: root)
    }

    /// Refuses every fetch, so a test can ask what happens when the machine is
    /// offline or the kernel denies the service.
    private final class Refusing: Fetching {
        var calls = 0
        func fetch(_ url: URL, into handle: FileHandle, resumingFrom offset: Int64,
                   progress: @escaping (Int64) -> Void) async throws -> Int64 {
            calls += 1
            throw ModelDownloadError.transport("offline")
        }
    }

    // MARK: - What a tier is

    @MainActor
    func testFullTierPinsFollowTheLadder() throws {
        let pins = TierInstaller.pins(for: .full, physicalMemory: 32 << 30)
        let speech = try XCTUnwrap(
            SpeechModelCatalog.model(named: QualityTier.full.speechModelID)?.pinnedFiles)
        for pin in speech {
            XCTAssertTrue(pins.contains(pin), "the ladder's speech file is missing: \(pin.relativePath)")
        }
        let cleanupKind = QualityTier.full.cleanupModel(physicalMemory: 32 << 30)
        let cleanup = try XCTUnwrap(TextCleanupManager.descriptor(for: cleanupKind))
        XCTAssertTrue(pins.contains(cleanup.pinnedFile),
                      "the ladder's cleanup model is missing: \(cleanup.fileName)")
    }

    /// The cleanup model depends on RAM, and the tier list has to follow that
    /// rather than hard-coding one of the two.
    @MainActor
    func testTheCleanupModelFollowsTheMachine() throws {
        let small = TierInstaller.pins(for: .full, physicalMemory: 8 << 30)
        let large = TierInstaller.pins(for: .full, physicalMemory: 32 << 30)
        let smallKind = QualityTier.full.cleanupModel(physicalMemory: 8 << 30)
        let largeKind = QualityTier.full.cleanupModel(physicalMemory: 32 << 30)
        XCTAssertNotEqual(smallKind, largeKind, "the fixture no longer spans the threshold")
        XCTAssertTrue(small.contains(try XCTUnwrap(TextCleanupManager.descriptor(for: smallKind)).pinnedFile))
        XCTAssertFalse(large.contains(try XCTUnwrap(TextCleanupManager.descriptor(for: smallKind)).pinnedFile))
    }

    @MainActor
    func testStarterIsAlsoADescribableTier() {
        let pins = TierInstaller.pins(for: .starter, physicalMemory: 8 << 30)
        XCTAssertFalse(pins.isEmpty, "Starter has no pins, so its retry path can do nothing")
        XCTAssertTrue(pins.contains { $0.relativePath.hasSuffix(".gguf") })
    }

    // MARK: - What happens when it cannot

    /// A failure stops the tier, names the file, and leaves the caller able to
    /// say WHY the app is still on Starter. Silence here would be a friend
    /// staring at an app that quietly never improved.
    func testAFailureIsReportedNamedAndStopsTheTier() async throws {
        let fetcher = Refusing()
        let report = await installer(fetcher).install(.full, physicalMemory: 32 << 30) { _, _, _ in }
        XCTAssertEqual(report.installed, [])
        let failure = try XCTUnwrap(report.failure, "an offline install reported no failure")
        XCTAssertTrue(failure.contains("offline"), failure)
        XCTAssertNotNil(report.failedPath, "the failure does not say which file")
        XCTAssertEqual(fetcher.calls, 1, "it kept trying after the first failure")
    }

    /// Everything already present is a tier that is already installed, and
    /// that has to be distinguishable from one that installed nothing because
    /// it failed.
    @MainActor
    func testAnAlreadyInstalledTierReportsPresentNotInstalled() async throws {
        let fetcher = Refusing()
        for pin in TierInstaller.pins(for: .starter, physicalMemory: 8 << 30) {
            let destination = root.appendingPathComponent(pin.relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(count: Int(pin.byteCount)).write(to: destination)
        }
        let report = await installer(fetcher).install(.starter, physicalMemory: 8 << 30) { _, _, _ in }
        XCTAssertNil(report.failure, report.failure ?? "")
        XCTAssertEqual(report.installed, [])
        XCTAssertFalse(report.alreadyPresent.isEmpty)
        XCTAssertEqual(fetcher.calls, 0, "it re-fetched files that were already there")
        XCTAssertTrue(report.isComplete)
    }

    /// Progress names the file being fetched, so a friend watching a 4 GB
    /// download sees which of several it is on.
    func testProgressNamesTheFileAndItsTotal() async throws {
        final class Serving: Fetching {
            func fetch(_ url: URL, into handle: FileHandle, resumingFrom offset: Int64,
                       progress: @escaping (Int64) -> Void) async throws -> Int64 {
                throw ModelDownloadError.transport("not reached in this test")
            }
        }
        var seen: [String] = []
        _ = await installer(Serving()).install(.starter, physicalMemory: 8 << 30) { path, _, _ in
            seen.append(path)
        }
        XCTAssertFalse(seen.isEmpty, "no progress named any file")
    }
}
