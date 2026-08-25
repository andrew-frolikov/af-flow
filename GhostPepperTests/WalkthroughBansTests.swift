import XCTest
@testable import GhostPepper

/// **Two bans that the first run has already broken once each.**
///
/// These are source-level guards, which is unusual here and deliberate. Both
/// rules are about what a STRING says, and both were live defects that no unit
/// test could have caught because the code compiled and ran perfectly while
/// telling a new user something untrue.
final class WalkthroughBansTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        // The tests run from the built bundle, so walk up to the repo. The file
        // is found by searching rather than by a fixed relative path, which
        // would break the moment the scheme's working directory changed.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("GhostPepper/UI/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("could not locate \(name) from \(#filePath)")
    }

    /// Lines that are code, with comments and doc comments stripped, because
    /// the bans are about what the INTERFACE says, and the comments explaining
    /// the bans necessarily quote the words being banned.
    private func codeLines(_ source: String) -> [String] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// **No chord literal, anywhere in the first run.**
    ///
    /// The onboarding this replaces hardcoded "Right Command + Right Option" in
    /// its instruction, in two keycaps and in its waiting message, and bound
    /// `defaultPushToTalkChord` in its monitor, so it could instruct one chord
    /// and listen for another. Home was fixed for this exact class on
    /// 2026-07-26: the screen has to say what is actually bound.
    func testTheFirstRunNamesNoChordLiterally() throws {
        let banned = [
            "Right Command", "Left Control", "Right Option", "Right Shift",
            "⌘ right", "⌥ right", "Globe", "fn "
        ]
        for file in ["HomeWalkthrough.swift", "OnboardingWindow.swift", "HomeWindow.swift"] {
            let lines = codeLines(try source(file))
            for (index, line) in lines.enumerated() {
                // Only string literals can reach a user.
                guard line.contains("\"") else { continue }
                for literal in banned where line.contains(literal) {
                    XCTFail("\(file):\(index + 1) names a chord literally: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    /// **No Accessibility, anywhere in the first run.**
    ///
    /// Proven 2026-08-21: sandboxed builds return AXError -25204 on all 28
    /// queries, on every build, after every grant, and the sandbox stays.
    /// Andrew has been sent to System Settings three times for a permission
    /// that can never take effect. Asking for it in onboarding would be the
    /// fourth, to the one audience least able to tell it is futile.
    func testTheFirstRunNeverAsksForAccessibility() throws {
        for file in ["HomeWalkthrough.swift", "OnboardingWindow.swift"] {
            let lines = codeLines(try source(file))
            for (index, line) in lines.enumerated() where line.contains("\"") {
                XCTAssertFalse(
                    line.contains("Accessibility"),
                    "\(file):\(index + 1) mentions Accessibility to the user: \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
            for (index, line) in lines.enumerated() {
                XCTAssertFalse(
                    line.contains("openAccessibilitySettings"),
                    "\(file):\(index + 1) sends the user to the Accessibility pane"
                )
            }
        }
    }

    /// The collision report has to name the shortcut it clashed with, or the
    /// capture field can only say that something is wrong.
    func testAChordCollisionNamesItsOwner() throws {
        let defaults = UserDefaults(suiteName: "walkthrough-bans-\(UUID().uuidString)")!
        let store = ChordBindingStore(defaults: defaults)
        let chord = AppState.defaultPushToTalkChord
        try store.setBinding(chord, for: .toggleToTalk)

        XCTAssertThrowsError(try store.setBinding(chord, for: .pushToTalk)) { error in
            guard case ChordBindingStore.StoreError.duplicateBinding(let owner) = error else {
                return XCTFail("expected a duplicate binding error, got \(error)")
            }
            XCTAssertEqual(owner, .toggleToTalk)
            XCTAssertFalse(owner.spokenName.isEmpty, "the owner must be nameable to the user")
        }
    }
}
