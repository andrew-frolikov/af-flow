import XCTest
@testable import AFFlow

/// One folder, one place that names it.
///
/// WHY THIS EXISTS. `AppSupportDirectory` was written so the 2026-08-25 rename
/// could not orphan his data, and it worked for the five call sites that used
/// it. Two others computed the path themselves, so the rename's find and
/// replace turned `GhostPepper/models` into `AFFlow/models` while the
/// migration moved the real folder to `AF Flow`. Nothing crashed. The app
/// simply started downloading models into a second directory while 4.9 GB of
/// already downloaded models sat in the first one, invisible to it.
///
/// A test over the two directories would only pin the instance. The scan below
/// pins the CLASS: no file except `AppSupportDirectory.swift` may ask the file
/// system where Application Support is.
final class AppSupportPathOwnershipTests: XCTestCase {
    private func repositoryRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("AFFlow").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("could not find the repository root from \(#filePath), so this scan verified nothing")
        throw NSError(domain: "AppSupportPathOwnership", code: 1)
    }

    /// Code only, with `//` comments stripped, carrying the real line number.
    /// The comment above `AppSupportDirectory.url` necessarily names the API
    /// this test bans everywhere else.
    private func codeLines(of file: URL) throws -> [(number: Int, text: String)] {
        let source = try String(contentsOf: file, encoding: .utf8)
        return source.components(separatedBy: .newlines).enumerated().compactMap { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return nil }
            return (index + 1, raw)
        }
    }

    private func swiftFiles(under relative: String) throws -> [URL] {
        let root = try repositoryRoot().appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate \(relative)")
            return []
        }
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "found no Swift files under \(relative), so this verified nothing")
        return files
    }

    func testOnlyAppSupportDirectoryAsksWhereApplicationSupportIs() throws {
        let owner = "AppSupportDirectory.swift"
        var offenders: [String] = []

        for file in try swiftFiles(under: "AFFlow") where file.lastPathComponent != owner {
            for line in try codeLines(of: file) where line.text.contains(".applicationSupportDirectory") {
                offenders.append("\(file.lastPathComponent):\(line.number)")
            }
        }

        XCTAssertEqual(
            offenders, [],
            "these files build their own Application Support path, so a rename can point them at an empty folder while \(owner) migrates the real one: \(offenders.joined(separator: ", "))"
        )
    }

    @MainActor
    func testCleanupModelsLiveInsideTheFolderTheMigrationMoves() {
        let actual = TextCleanupManager.modelsDirectory.standardizedFileURL
        XCTAssertEqual(
            actual,
            AppSupportDirectory.url.appendingPathComponent("models", isDirectory: true).standardizedFileURL,
            "the cleanup models must sit in the folder AppSupportDirectory owns, or a rename hides every downloaded model"
        )
    }

    @MainActor
    func testWhisperModelsLiveInsideTheFolderTheMigrationMoves() {
        let actual = ModelManager.whisperModelsDirectory.standardizedFileURL
        XCTAssertEqual(
            actual,
            AppSupportDirectory.url.appendingPathComponent("whisper-models", isDirectory: true).standardizedFileURL,
            "the speech models must sit in the folder AppSupportDirectory owns, or a rename re-downloads every one of them"
        )
    }
}
