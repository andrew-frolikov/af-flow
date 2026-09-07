import XCTest
@testable import AFFlow

/// One shape for every downloadable byte.
///
/// The downloader must have ONE verification path, so both catalogues produce
/// the same struct: the cleanup GGUFs, which have carried a URL, a SHA-256 and
/// a byte count since the beginning, and the speech models, which carried none
/// until Phase 4 (launch plan open item 2). A second shape would be a second
/// verification, and the one that got less attention would be the one that
/// shipped unpinned bytes.
final class PinnedFileTests: XCTestCase {
    /// `models/<fileName>` is not a new decision: it is where
    /// `TextCleanupManager` reads and where `StarterModelInstaller`
    /// mirrors the bundled payload. This test pins that they agree.
    func testEveryCleanupModelBecomesAPinnedFileUnderModels() {
        for descriptor in TextCleanupManager.cleanupModels {
            let pin = descriptor.pinnedFile
            XCTAssertEqual(pin.relativePath, "models/" + descriptor.fileName)
            XCTAssertEqual(pin.sha256, descriptor.expectedSHA256.lowercased())
            XCTAssertEqual(pin.byteCount, descriptor.expectedByteCount)
            XCTAssertEqual(pin.url.absoluteString, descriptor.url)
            XCTAssertEqual(pin.sha256.count, 64,
                           "\(descriptor.fileName) has a hash that is not 64 hex characters")
        }
    }

    /// The same relative path the installer uses, resolved against the one
    /// folder that names itself.
    func testDestinationIsUnderAppSupport() {
        let pin = PinnedFile(relativePath: "models/x.gguf",
                             url: URL(string: "https://example.invalid/x")!,
                             sha256: String(repeating: "a", count: 64),
                             byteCount: 1)
        XCTAssertEqual(pin.destination, AppSupportDirectory.url.appendingPathComponent("models/x.gguf"))
    }
}
