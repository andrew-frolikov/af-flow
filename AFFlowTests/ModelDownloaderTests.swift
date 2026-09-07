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

    // MARK: - A partial that is already big enough

    /// **A finished partial must never be asked to resume past its own end.**
    /// If the last byte arrives and the connection drops before the reply
    /// does, the partial is exactly the pinned size. Asking for
    /// `Range: bytes=<size>-` is unsatisfiable, the server answers 416, the
    /// partial is kept for a retry that asks the same impossible question, and
    /// a 2.8 GB model can never install again. Independent review, 2026-09-07.
    func testAPartialAlreadyAtTheFullSizeIsVerifiedRatherThanResumed() async throws {
        let body = Data("the whole model, already fetched".utf8)
        let partial = root.appendingPathComponent("models/a.gguf.partial")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try body.write(to: partial)

        let fetcher = FakeFetcher(body)
        try await ModelDownloader(fetcher: fetcher, root: root).download(pin(body)) { _, _ in }
        XCTAssertEqual(fetcher.calls.count, 0, "it asked for bytes past the end of a finished partial")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("models/a.gguf")), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    /// The same trap from the other side: a partial LONGER than the pin, which
    /// a regenerated catalogue or a server that ignored a Range can produce.
    /// It is junk, not a resume point, and must be discarded rather than
    /// extended.
    func testAPartialLongerThanThePinIsDiscardedAndFetchedAgain() async throws {
        let body = Data("the real model".utf8)
        let partial = root.appendingPathComponent("models/a.gguf.partial")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 9, count: body.count + 500).write(to: partial)

        let fetcher = FakeFetcher(body)
        try await ModelDownloader(fetcher: fetcher, root: root).download(pin(body)) { _, _ in }
        XCTAssertEqual(fetcher.calls.first?.1, 0, "it resumed from inside a partial that was already too long")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("models/a.gguf")), body)
    }

    /// A full-size partial whose BYTES are wrong is discarded, and the retry
    /// after it succeeds. Without this the wrong bytes would be verified,
    /// rejected, and left in place to be verified and rejected forever.
    func testAFullSizePartialWithWrongBytesIsDiscardedAndTheRetryWorks() async throws {
        let body = Data("the real model".utf8)
        let partial = root.appendingPathComponent("models/a.gguf.partial")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 3, count: body.count).write(to: partial)

        let fetcher = FakeFetcher(body)
        let downloader = ModelDownloader(fetcher: fetcher, root: root)
        do {
            try await downloader.download(pin(body)) { _, _ in }
            XCTFail("accepted a full-size partial whose bytes are wrong")
        } catch let error as ModelDownloadError {
            guard case .hashMismatch = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path),
                       "the bad partial was kept, so every retry will reject it again")
        try await downloader.download(pin(body)) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("models/a.gguf")), body)
    }

    /// A server that IGNORES `Range` sends the whole body, which lands after
    /// the bytes already there. Verified against `python3 -m http.server`,
    /// which does exactly this. The app must not install that, and must not
    /// keep it either, or the next attempt resumes from junk.
    func testAFetcherThatIgnoresTheResumeOffsetLeavesNothingToResumeFrom() async throws {
        final class IgnoresOffset: Fetching {
            let body: Data
            init(_ body: Data) { self.body = body }
            func fetch(_ url: URL, into handle: FileHandle, resumingFrom offset: Int64,
                       progress: @escaping (Int64) -> Void) async throws -> Int64 {
                try handle.write(contentsOf: body)      // the WHOLE body, ignoring offset
                return Int64(body.count)
            }
        }
        let body = Data("the real model".utf8)
        let partial = root.appendingPathComponent("models/a.gguf.partial")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4).write(to: partial)

        do {
            try await ModelDownloader(fetcher: IgnoresOffset(body), root: root)
                .download(pin(body)) { _, _ in }
            XCTFail("installed a file built from a body appended after a partial")
        } catch let error as ModelDownloadError {
            guard case .sizeMismatch = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path),
                       "an oversized partial was kept, so the next attempt resumes from junk")
    }

    // MARK: - Cancellation

    /// **Cancellation must survive the trip.** `TextCleanupManager` decides
    /// between "cancelled, go quiet" and "failed, show an error" by asking
    /// whether the error is a `CancellationError`. Wrapping it in a transport
    /// error turns a user pressing Cancel into a red failure message, and the
    /// partial has to stay so the retry resumes.
    func testCancellationIsNotDisguisedAsATransportFailure() async throws {
        final class Cancels: Fetching {
            func fetch(_ url: URL, into handle: FileHandle, resumingFrom offset: Int64,
                       progress: @escaping (Int64) -> Void) async throws -> Int64 {
                try handle.write(contentsOf: Data("some".utf8))
                throw CancellationError()
            }
        }
        let body = Data("the real model".utf8)
        do {
            try await ModelDownloader(fetcher: Cancels(), root: root).download(pin(body)) { _, _ in }
            XCTFail("a cancelled download reported success")
        } catch is CancellationError {
            // what the caller has to be able to recognise
        } catch {
            XCTFail("cancellation arrived as \(error), so the UI would show a red error")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("models/a.gguf.partial").path),
                      "the partial was discarded, so cancelling costs the whole download")
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
