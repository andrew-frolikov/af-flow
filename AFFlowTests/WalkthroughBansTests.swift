import XCTest
@testable import AFFlow

/// **Two bans the app has already broken, repeatedly.**
///
/// Source-level guards, which is unusual and deliberate: both rules are about
/// what a STRING says or where a BUTTON leads, both were live defects, and both
/// compiled and ran perfectly while telling the user something untrue or
/// sending him somewhere that cannot help.
///
/// The first version of this file could pass without checking anything: it
/// threw `XCTSkip` when it could not find the sources, scanned two files, and
/// only looked at lines containing a quote. A reviewer caught all three. It
/// FAILS on a missing tree now, because a guard that cannot find what it guards
/// has not verified anything.
final class WalkthroughBansTests: XCTestCase {

    /// The repository root, found by walking up from this file until the app
    /// directory appears. A failure here is a failure, never a skip.
    private func repositoryRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("AFFlow").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("could not find the repository root from \(#filePath), so these bans verified nothing")
        throw NSError(domain: "WalkthroughBans", code: 1)
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

    /// Code only, with comments stripped, and carrying the REAL line number.
    /// The comments explaining these bans necessarily quote the banned words.
    private func codeLines(of file: URL) throws -> [(number: Int, text: String)] {
        let source = try String(contentsOf: file, encoding: .utf8)
        var inBlockComment = false
        var result: [(Int, String)] = []
        for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(raw)
            if inBlockComment {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                inBlockComment = false
            }
            if let start = line.range(of: "/*") {
                if let end = line.range(of: "*/"), end.lowerBound > start.upperBound {
                    line.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    line = String(line[..<start.lowerBound])
                    inBlockComment = true
                }
            }
            if let comment = line.range(of: "//") {
                line = String(line[..<comment.lowerBound])
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append((index + 1, line))
            }
        }
        return result
    }

    /// **No chord may be named literally in the first run.**
    ///
    /// The onboarding this replaces hardcoded "Right Command + Right Option" in
    /// its instruction, in two keycaps and in its waiting message, and bound the
    /// factory default in its monitor, so it could instruct one chord and listen
    /// for another. Home was fixed for this class on 2026-07-26: the screen has
    /// to say what is actually bound.
    func testTheFirstRunNamesNoChordLiterally() throws {
        let banned = ["Right Command", "Left Control", "Right Option", "Right Shift", "⌘ right", "⌥ right"]
        let files = ["HomeWalkthrough.swift", "OnboardingWindow.swift", "HomeWindow.swift"]
        let root = try repositoryRoot().appendingPathComponent("AFFlow/UI")
        for name in files {
            let url = root.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(name) is missing, so this verified nothing")
            for line in try codeLines(of: url) where line.text.contains("\"") {
                for literal in banned where line.text.contains(literal) {
                    XCTFail("\(name):\(line.number) names a chord literally: \(line.text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    /// **Nothing may send the user to the Accessibility pane, anywhere.**
    ///
    /// Proven 2026-08-21: sandboxed builds return AXError -25204 on all 28
    /// queries, on every build, after every grant, and the sandbox stays. Every
    /// such button is a trip that cannot help, and he has taken three. Scoped to
    /// the CALLS, and to the whole app rather than two files, because the last
    /// two survivors were in `AppState` and the menu bar, which the first
    /// version of this test did not look at.
    func testNothingSendsHimToTheAccessibilityPane() throws {
        for file in try swiftFiles(under: "AFFlow") {
            for line in try codeLines(of: file) {
                for call in ["openAccessibilitySettings", "promptAccessibility"] where line.text.contains(call) {
                    // The checker itself may define them; only callers are banned.
                    guard file.lastPathComponent != "PermissionChecker.swift" else { continue }
                    XCTFail("\(file.lastPathComponent):\(line.number) calls \(call), which leads to a pane that cannot help")
                }
            }
        }
    }

    /// And no user-facing string in the interface may name it either, since a
    /// message that says "Accessibility" sends him there just as effectively.
    func testTheInterfaceNeverAsksTheUserForAccessibility() throws {
        for file in try swiftFiles(under: "AFFlow/UI") {
            for line in try codeLines(of: file) where line.text.contains("\"") {
                XCTAssertFalse(
                    line.text.contains("Accessibility"),
                    "\(file.lastPathComponent):\(line.number) says Accessibility to the user: \(line.text.trimmingCharacters(in: .whitespaces))"
                )
            }
        }
    }

    /// A collision has to name the shortcut it clashed with, in the INTERFACE
    /// and not only in the error enum. A previous commit claimed this and was
    /// wrong: `spokenName` existed with no caller.
    func testAChordCollisionNamesItsOwnerToTheUser() throws {
        let defaults = UserDefaults(suiteName: "walkthrough-bans-\(UUID().uuidString)")!
        let store = ChordBindingStore(defaults: defaults)
        let chord = AppState.defaultPushToTalkChord
        try store.setBinding(chord, for: .toggleToTalk)

        XCTAssertThrowsError(try store.setBinding(chord, for: .pushToTalk)) { error in
            guard case ChordBindingStore.StoreError.duplicateBinding(let owner) = error else {
                return XCTFail("expected a duplicate binding error, got \(error)")
            }
            XCTAssertEqual(owner, .toggleToTalk)
            XCTAssertFalse(owner.spokenName.isEmpty)
        }

        // And the name must actually reach a user-facing string.
        let appState = try repositoryRoot().appendingPathComponent("AFFlow/AppState.swift")
        let source = try String(contentsOf: appState, encoding: .utf8)
        XCTAssertTrue(
            source.contains("owner.spokenName"),
            "the collision owner is never rendered, so the interface still cannot say whose shortcut it is"
        )
    }
}
