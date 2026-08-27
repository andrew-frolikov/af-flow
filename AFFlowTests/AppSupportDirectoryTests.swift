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

    // MARK: - The folder the rename's find and replace created

    /// A model downloaded AFTER the rename and BEFORE this fix is the only copy
    /// there is. Measured on his test host on 2026-08-26: 65 files, 153.7 MB,
    /// none of them present under the real folder. Cutting the path over
    /// without absorbing that would have made the suite skip every model-backed
    /// eval and exit 0, which is this project's signature failure.
    func testAbsorbsAModelLeftInTheFolderTheRenameCreated() throws {
        try makeFolder(AppSupportDirectory.folderName, containing: "debug-log.jsonl")
        let interim = base.appendingPathComponent(AppSupportDirectory.interimFolderName, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: interim, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: interim.appendingPathComponent("Qwen.gguf"))

        AppSupportDirectory.absorbInterimFolder(in: base)

        let landed = base.appendingPathComponent(AppSupportDirectory.folderName)
            .appendingPathComponent("models/Qwen.gguf")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: landed.path),
            "the only copy of a model must move into the folder the app reads"
        )
    }

    /// Never overwrite, never delete. A file that exists in both is left in
    /// both: the one the app reads is untouched, and his copy is still there to
    /// look at.
    func testLeavesACollidingFileAloneRatherThanOverwritingIt() throws {
        try makeFolder(AppSupportDirectory.folderName)
        let current = base.appendingPathComponent(AppSupportDirectory.folderName, isDirectory: true)
        try Data("the one the app reads".utf8).write(to: current.appendingPathComponent("models.json"))

        let interim = base.appendingPathComponent(AppSupportDirectory.interimFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: interim, withIntermediateDirectories: true)
        try Data("the stray".utf8).write(to: interim.appendingPathComponent("models.json"))

        AppSupportDirectory.absorbInterimFolder(in: base)

        XCTAssertEqual(
            try String(contentsOf: current.appendingPathComponent("models.json"), encoding: .utf8),
            "the one the app reads"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: interim.appendingPathComponent("models.json").path),
            "a colliding file is left where it is, never deleted"
        )
    }

    /// The pre-rename folder is a different case and keeps its own rule: an old
    /// install sitting beside a live one is left completely alone.
    func testDoesNotAbsorbThePreRenameFolder() throws {
        try makeFolder(AppSupportDirectory.folderName)
        try makeFolder(AppSupportDirectory.legacyFolderName, containing: "old.json")

        AppSupportDirectory.absorbInterimFolder(in: base)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: base.appendingPathComponent(AppSupportDirectory.legacyFolderName)
                    .appendingPathComponent("old.json").path
            )
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
