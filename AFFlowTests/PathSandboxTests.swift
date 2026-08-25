import XCTest
@testable import AFFlow

final class PathSandboxTests: XCTestCase {
    private var rootDir: URL!

    override func setUpWithError() throws {
        rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("PathSandboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("2025-01-29"), withIntermediateDirectories: true)
        try "hello".write(to: rootDir.appendingPathComponent("2025-01-29/note.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDir)
    }

    func testResolvesRootForEmptyAndDot() throws {
        XCTAssertEqual(try PathSandbox.resolveSafe("", root: rootDir).path, rootDir.resolvingSymlinksInPath().path)
        XCTAssertEqual(try PathSandbox.resolveSafe(".", root: rootDir).path, rootDir.resolvingSymlinksInPath().path)
    }

    func testResolvesValidRelativePath() throws {
        let url = try PathSandbox.resolveSafe("2025-01-29/note.md", root: rootDir)
        XCTAssertTrue(url.path.hasSuffix("/2025-01-29/note.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRejectsParentEscape() {
        XCTAssertThrowsError(try PathSandbox.resolveSafe("../outside.md", root: rootDir)) { error in
            guard case PathSandboxError.pathOutsideRoot = error else {
                XCTFail("Expected pathOutsideRoot, got \(error)")
                return
            }
        }
    }

    func testRejectsAbsolutePath() {
        XCTAssertThrowsError(try PathSandbox.resolveSafe("/etc/passwd", root: rootDir)) { error in
            guard case PathSandboxError.pathOutsideRoot = error else {
                XCTFail("Expected pathOutsideRoot, got \(error)")
                return
            }
        }
    }

    func testRejectsSymlinkOutsideRoot() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("PathSandboxTests-outside-\(UUID().uuidString).md")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let symlinkPath = rootDir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: outside)

        XCTAssertThrowsError(try PathSandbox.resolveSafe("link.md", root: rootDir)) { error in
            guard case PathSandboxError.pathOutsideRoot = error else {
                XCTFail("Expected pathOutsideRoot, got \(error)")
                return
            }
        }
    }

    func testAllowsSymlinkInsideRoot() throws {
        let target = rootDir.appendingPathComponent("2025-01-29/note.md")
        let symlink = rootDir.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertNoThrow(try PathSandbox.resolveSafe("alias.md", root: rootDir))
    }
}
