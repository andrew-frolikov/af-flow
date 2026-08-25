import XCTest
@testable import AFFlow

final class MeetingQAToolsWriteFileTests: XCTestCase {
    private var rootDir: URL!
    private var tools: MeetingQATools!

    override func setUpWithError() throws {
        rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("WriteFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        tools = MeetingQATools(root: rootDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDir)
    }

    func testWritesFileInsideRoot() async throws {
        let result = try await tools.writeFile(path: "john-smith.md", content: "# John\n")
        XCTAssertTrue(result.contains("Wrote"))
        let written = try String(contentsOf: rootDir.appendingPathComponent("john-smith.md"), encoding: .utf8)
        XCTAssertEqual(written, "# John\n")
    }

    func testOverwritesExistingFile() async throws {
        _ = try await tools.writeFile(path: "x.md", content: "old")
        _ = try await tools.writeFile(path: "x.md", content: "new")
        let written = try String(contentsOf: rootDir.appendingPathComponent("x.md"), encoding: .utf8)
        XCTAssertEqual(written, "new")
    }

    func testRejectsParentEscape() async {
        do {
            _ = try await tools.writeFile(path: "../escape.md", content: "x")
            XCTFail("Expected sandbox rejection")
        } catch {
            // PathSandbox raises pathOutsideRoot before write_file's content checks
            // because "../escape.md" contains "/" and would also fail that guard.
            // Either error is acceptable; what matters is no file gets written.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootDir.deletingLastPathComponent().appendingPathComponent("escape.md").path))
    }

    func testRejectsAbsolutePath() async {
        do {
            _ = try await tools.writeFile(path: "/tmp/totally-bad.md", content: "x")
            XCTFail("Expected rejection")
        } catch {
            // Either invalidArguments (contains /) or pathOutsideRoot — both are correct.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/totally-bad.md"))
    }

    func testRejectsNonMarkdownExtension() async {
        do {
            _ = try await tools.writeFile(path: "notes.txt", content: "x")
            XCTFail("Expected rejection")
        } catch let error as MeetingQAToolError {
            guard case .invalidArguments = error else {
                XCTFail("Expected invalidArguments, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected MeetingQAToolError, got \(error)")
        }
    }

    func testRejectsManifestPath() async {
        do {
            _ = try await tools.writeFile(path: "_manifest.json", content: "{}")
            XCTFail("Expected rejection")
        } catch let error as MeetingQAToolError {
            guard case .invalidArguments = error else {
                XCTFail("Expected invalidArguments, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected MeetingQAToolError, got \(error)")
        }
    }

    func testRejectsHiddenFile() async {
        do {
            _ = try await tools.writeFile(path: ".secret.md", content: "x")
            XCTFail("Expected rejection")
        } catch let error as MeetingQAToolError {
            guard case .invalidArguments = error else {
                XCTFail("Expected invalidArguments, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected MeetingQAToolError, got \(error)")
        }
    }

    func testRejectsSubdirectoryPath() async {
        do {
            _ = try await tools.writeFile(path: "sub/file.md", content: "x")
            XCTFail("Expected rejection")
        } catch let error as MeetingQAToolError {
            guard case .invalidArguments = error else {
                XCTFail("Expected invalidArguments, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected MeetingQAToolError, got \(error)")
        }
    }
}
