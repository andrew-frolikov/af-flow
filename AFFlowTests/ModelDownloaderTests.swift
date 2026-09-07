import CryptoKit
import XCTest
@testable import AFFlow

/// The app side of the downloader, which owns the destination and therefore
/// owns verification. The service only ever sees a descriptor.
///
/// Every guarantee below was bought by an earlier failure in this project:
/// bytes are checked where they LAND (`download-model.sh`), a partial is never
/// visible as a model (`StarterModelInstaller`), a path that escapes the models
/// root is refused on RESOLVED paths (ledger 21/22, and the 2026-09-06 review
/// that found a string compare wearing a comment about real paths).
final class ModelDownloaderTests: XCTestCase {
    /// Serves a body in chunks, honours a resume offset, and can be told to
    /// drop mid-stream. Standing in for the XPC service, which is exercised
    /// for real by `scripts/xpc-smoke.sh`.
    final class FakeFetcher: Fetching {
        var body: Data
        var chunk = 4
        var calls: [(URL, Int64)] = []
        var failAfterBytes: Int64?
        init(_ body: Data) { self.body = body }

        func fetch(_ url: URL, into handle: FileHandle, resumingFrom offset: Int64,
                   progress: @escaping (Int64) -> Void) async throws -> Int64 {
            calls.append((url, offset))
            var written: Int64 = 0
            var index = Int(offset)
            while index < body.count {
                if let cap = failAfterBytes, written >= cap {
                    throw ModelDownloadError.transport("simulated drop")
                }
                let end = min(index + chunk, body.count)
                try handle.write(contentsOf: body[index..<end])
                written += Int64(end - index)
                index = end
                progress(written)
            }
            return written
        }
    }

    /// `root` stands in for Application Support and `outside` for anywhere
    /// else on disk. They are SIBLINGS: an earlier version of this file put the
    /// escape target inside the root, so writing through the symlink stayed
    /// contained and the containment tests failed for a reason that had nothing
    /// to do with the code under test.
    private var workspace: URL!
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
        root = workspace.appendingPathComponent("AppSupport", isDirectory: true)
        outside = workspace.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func pin(_ body: Data, path: String = "models/a.gguf",
                     sha: String? = nil, size: Int64? = nil) -> PinnedFile {
        PinnedFile(relativePath: path,
                   url: URL(string: "https://example.invalid/a")!,
                   sha256: sha ?? SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
                   byteCount: size ?? Int64(body.count))
    }

    // MARK: - The happy path

    func testGoodBytesLandAtTheDestinationAndNowhereElse() async throws {
        let body = Data("twenty bytes of model".utf8)
        let fetcher = FakeFetcher(body)
        try await ModelDownloader(fetcher: fetcher, root: root).download(pin(body)) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("models/a.gguf")), body)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("models/a.gguf.partial").path),
                       "a partial was left beside the finished file")
    }

    // MARK: - Verified where they land

    func testATamperedHashRefusesAndLeavesNothingBehind() async throws {
        let body = Data("tampered".utf8)
        let fetcher = FakeFetcher(body)
        do {
            try await ModelDownloader(fetcher: fetcher, root: root)
                .download(pin(body, sha: String(repeating: "0", count: 64))) { _, _ in }
            XCTFail("accepted bytes that do not match their pinned hash")
        } catch let error as ModelDownloadError {
            guard case .hashMismatch = error else { return XCTFail("wrong error: \(error)") }
        }
        let left = (try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("models").path)) ?? []
        XCTAssertEqual(left, [], "left behind: \(left)")
    }

    func testAShortBodyIsASizeMismatchNotASuccess() async throws {
        let body = Data("short".utf8)
        let fetcher = FakeFetcher(body)
        do {
            try await ModelDownloader(fetcher: fetcher, root: root)
                .download(pin(body, size: 999)) { _, _ in }
            XCTFail("accepted a file shorter than its pinned size")
        } catch let error as ModelDownloadError {
            guard case .sizeMismatch = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("models/a.gguf").path))
    }

    // MARK: - A dropped download costs the bytes already fetched, and nothing more

    func testADroppedConnectionResumesFromThePartial() async throws {
        let body = Data((0..<40).map { UInt8($0) })
        let fetcher = FakeFetcher(body)
        fetcher.failAfterBytes = 12
        let downloader = ModelDownloader(fetcher: fetcher, root: root)
        do {
            try await downloader.download(pin(body)) { _, _ in }
            XCTFail("the first attempt should have dropped")
        } catch {}

        let partial = root.appendingPathComponent("models/a.gguf.partial")
        XCTAssertEqual((try? Data(contentsOf: partial))?.count, 12,
                       "the partial was discarded, so a 4 GB download would start again")
        fetcher.failAfterBytes = nil
        try await downloader.download(pin(body)) { _, _ in }
        XCTAssertEqual(fetcher.calls.last?.1, 12, "the second attempt did not resume")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("models/a.gguf")), body)
    }

    // MARK: - His 6.8 GB

    func testAnExistingMatchingFileIsNotFetchedAgain() async throws {
        let body = Data("already here".utf8)
        let destination = root.appendingPathComponent("models/a.gguf")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try body.write(to: destination)
        let fetcher = FakeFetcher(body)
        try await ModelDownloader(fetcher: fetcher, root: root).download(pin(body)) { _, _ in }
        XCTAssertEqual(fetcher.calls.count, 0, "re-downloaded a file already present and the right size")
        XCTAssertEqual(try Data(contentsOf: destination), body)
    }

    // MARK: - Containment

    func testAPathThatEscapesTheRootIsRefusedBeforeAnyFetch() async throws {
        let body = Data("x".utf8)
        let fetcher = FakeFetcher(body)
        let elsewhere = outside.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("models"), withDestinationURL: elsewhere)
        do {
            try await ModelDownloader(fetcher: fetcher, root: root).download(pin(body)) { _, _ in }
            XCTFail("wrote through a symlinked models folder")
        } catch let error as ModelDownloadError {
            guard case .containment = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(fetcher.calls.count, 0, "fetched bytes before deciding they could be stored")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    /// The nested case, which is the one a string prefix passes: the missing
    /// levels are created THROUGH the link.
    func testANestedPathUnderASymlinkedAncestorIsRefused() async throws {
        let body = Data("x".utf8)
        let fetcher = FakeFetcher(body)
        let elsewhere = outside.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("whisper-models"), withDestinationURL: elsewhere)
        do {
            try await ModelDownloader(fetcher: fetcher, root: root)
                .download(pin(body, path: "whisper-models/models/deep/a.bin")) { _, _ in }
            XCTFail("wrote through a symlinked ancestor")
        } catch let error as ModelDownloadError {
            guard case .containment = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [],
                       "directories were created outside the root")
    }

    // MARK: - Progress

    func testProgressReportsBytesAgainstTheTotal() async throws {
        let body = Data(repeating: 7, count: 10)
        let fetcher = FakeFetcher(body)
        fetcher.chunk = 5
        var seen: [(Int64, Int64)] = []
        try await ModelDownloader(fetcher: fetcher, root: root).download(pin(body)) { seen.append(($0, $1)) }
        XCTAssertFalse(seen.isEmpty, "no progress was reported at all")
        XCTAssertEqual(Set(seen.map(\.1)), [10], "the total moved while the download ran")
        XCTAssertEqual(seen.last?.0, 10, "the last report was not the finished size")
    }
}
