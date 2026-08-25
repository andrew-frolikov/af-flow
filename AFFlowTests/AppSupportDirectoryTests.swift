import XCTest
@testable import AFFlow

/// The rename moved AF Flow's Application Support folder. These tests exist
/// because that migration fails SILENTLY: a wrong answer here does not crash,
/// it just points the app at an empty directory and every recording, debug log
/// and recognised voice already on disk stops existing as far as the app knows.
final class AppSupportDirectoryTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("af-flow-appsupport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeFolder(_ name: String, containing file: String? = nil) throws {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let file {
            try Data("marker".utf8).write(to: url.appendingPathComponent(file))
        }
    }

    func testUsesCurrentFolderNameWhenNothingExistsYet() {
        let resolved = AppSupportDirectory.resolve(in: base)
        XCTAssertEqual(resolved.lastPathComponent, AppSupportDirectory.folderName)
    }

    func testMovesLegacyFolderAndKeepsItsContents() throws {
        try makeFolder(AppSupportDirectory.legacyFolderName, containing: "debug-log.jsonl")

        let resolved = AppSupportDirectory.resolve(in: base)

        XCTAssertEqual(resolved.lastPathComponent, AppSupportDirectory.folderName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resolved.appendingPathComponent("debug-log.jsonl").path),
            "the migration must carry the data across, not just create an empty folder"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: base.appendingPathComponent(AppSupportDirectory.legacyFolderName).path
            ),
            "the legacy folder should be gone once it has been moved"
        )
    }

    func testPrefersTheCurrentFolderAndLeavesALegacyFolderUntouched() throws {
        try makeFolder(AppSupportDirectory.folderName, containing: "current.json")
        try makeFolder(AppSupportDirectory.legacyFolderName, containing: "old.json")

        let resolved = AppSupportDirectory.resolve(in: base)

        XCTAssertEqual(resolved.lastPathComponent, AppSupportDirectory.folderName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.appendingPathComponent("current.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: base.appendingPathComponent(AppSupportDirectory.legacyFolderName)
                    .appendingPathComponent("old.json").path
            ),
            "a legacy folder that is not needed must be left alone, never merged or deleted"
        )
    }

    func testFallsBackToTheLegacyFolderWhenTheMoveCannotHappen() throws {
        // A plain FILE where the new folder should go makes moveItem throw. The
        // app must then keep reading the old folder rather than inventing a new
        // empty one, because reaching the data under its old name always beats
        // not reaching it.
        try makeFolder(AppSupportDirectory.legacyFolderName, containing: "meeting.wav")
        try Data("not a directory".utf8)
            .write(to: base.appendingPathComponent(AppSupportDirectory.folderName))

        let resolved = AppSupportDirectory.resolve(in: base)

        XCTAssertEqual(resolved.lastPathComponent, AppSupportDirectory.legacyFolderName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.appendingPathComponent("meeting.wav").path))
    }
}
