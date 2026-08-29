import XCTest
import SwiftUI
@testable import AFFlow

/// v1 ships dictation only, and meetings must be invisible to everyone who is
/// not Andrew.
///
/// WHY THIS EXISTS. `docs/launch-v1-plan.md`, settled 2026-08-29: "Meetings
/// hidden behind an internal flag; tests keep running. Meetings return in
/// v1.x." The reason is not that meetings are broken. It is that a friend
/// installing a dictation app should not meet a half-finished second product,
/// and STATE.md records three meeting bugs still open: sessions that stay
/// `status: active` for days, wrong end times, and a summary that timed out on
/// a 2h52m recording while the transcript saved.
///
/// THE FLAG IS `meetingTranscriptEnabled`, WHICH ALREADY EXISTED, and reusing
/// it rather than adding a second key is deliberate. It already defaults to
/// false, so a fresh install already hides everything; Andrew's own stored
/// value is true, so his meetings keep working with no migration and no
/// `defaults write`. What changes for v1 is that the only control that WROTE
/// it, the Settings toggle, is gone. That is what "internal flag, no UI to
/// enable it" means here.
///
/// Turning it back on by hand, which is the documented internal route:
///
///     defaults write com.frolikov.afflow meetingTranscriptEnabled -bool true
///
/// Every test below runs against a saved and restored value, because the suite
/// shares this app's defaults domain and 2026-07-20 is what happens when it
/// does not.
/// WHAT EACH TEST HERE ACTUALLY PINS, because a count of green tests has meant
/// nothing in this project more than once. Reviewed 2026-08-30 by installing the
/// revert and asking which tests go red:
///
///   - the four "when the flag is on" tests would pass against a revert. They
///     are kept anyway, and they are not decoration: they kill the DIFFERENT
///     mutation of deleting meetings instead of hiding them, which is the one
///     way v1.x never gets them back.
///   - `testAbsentKeyMeansHidden` restates a Foundation contract. It is kept as
///     the written record of what a friend's fresh install does, and it is
///     honest to say it pins nothing about this change.
///   - everything else goes red against the revert, and three of them do so
///     because they scan CALL SITES rather than the one-line helpers. The first
///     draft tested the helpers, which restates them; review found all three.
final class MeetingsHiddenInV1Tests: XCTestCase {
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: MeetingsVisibility.defaultsKey)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: MeetingsVisibility.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: MeetingsVisibility.defaultsKey)
        }
        super.tearDown()
    }

    private func withFlag(_ on: Bool?, _ body: () throws -> Void) rethrows {
        if let on {
            UserDefaults.standard.set(on, forKey: MeetingsVisibility.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: MeetingsVisibility.defaultsKey)
        }
        try body()
    }

    // MARK: - The flag itself

    /// A fresh install has never written this key, and "absent" must mean
    /// hidden. This is the state every friend downloads into.
    func testAbsentKeyMeansHidden() {
        withFlag(nil) {
            XCTAssertFalse(MeetingsVisibility.isOn,
                           "a key that was never written must read as hidden")
        }
    }

    /// The name of this test used to be a claim it did not check: it wrote the
    /// key and read it back, which tests `UserDefaults`. Rewritten 2026-08-30
    /// after review to assert the thing it is named for, which is the same
    /// discipline `AppSupportPathOwnershipTests` applies to the data folder:
    /// one file spells the key, everything else asks that file.
    func testOnlyMeetingsVisibilitySpellsTheKey() throws {
        let owner = "MeetingsVisibility.swift"
        var offenders: [String] = []
        for file in try swiftFiles(under: "AFFlow") where file.lastPathComponent != owner {
            for line in try codeLines(of: file)
            where line.text.contains("\"meetingTranscriptEnabled\"") {
                offenders.append("\(file.lastPathComponent):\(line.number)")
            }
        }
        XCTAssertEqual(offenders, [],
                       "the v1 scope gate's key is spelled outside "
                       + "\(owner), so the two can drift: "
                       + offenders.joined(separator: ", "))
    }

    // MARK: - The settings sidebar

    func testSettingsSidebarHasNoMeetingSectionWhenHidden() {
        withFlag(false) {
            XCTAssertFalse(AFFlowSection.visible.contains(.meetingTranscript),
                           "the meeting section is reachable with the flag off")
        }
    }

    func testSettingsSidebarHasTheMeetingSectionWhenOn() {
        withFlag(true) {
            XCTAssertTrue(AFFlowSection.visible.contains(.meetingTranscript),
                          "the flag is on and the section is still missing, so "
                          + "turning it on does nothing")
        }
    }

    /// Hiding the section is not enough if the words survive somewhere else in
    /// the same sidebar. A dictation-only user reads titles and subtitles.
    func testNoVisibleSectionMentionsMeetingsWhenHidden() {
        withFlag(false) {
            for section in AFFlowSection.visible {
                XCTAssertFalse(section.title.lowercased().contains("meeting"),
                               "\(section.rawValue) title says: \(section.title)")
                XCTAssertFalse(section.subtitle.lowercased().contains("meeting"),
                               "\(section.rawValue) subtitle says: \(section.subtitle)")
            }
        }
    }

    /// A stored selection can name a section the flag has just hidden. Falling
    /// through to a blank pane, or worse to the hidden one, is how a scope gate
    /// leaks.
    func testAHiddenSelectionFallsBackToAVisibleSection() {
        withFlag(false) {
            let resolved = AFFlowSection.resolvingHidden(.meetingTranscript)
            XCTAssertNotEqual(resolved, .meetingTranscript)
            XCTAssertTrue(AFFlowSection.visible.contains(resolved),
                          "fell back to \(resolved.rawValue), which is not visible either")
        }
        withFlag(true) {
            XCTAssertEqual(AFFlowSection.resolvingHidden(.meetingTranscript),
                           .meetingTranscript,
                           "the fallback fires even when the section is visible")
        }
    }

    /// **The test above would pass with both call sites deleted**, because
    /// `resolvingHidden` is one line and asserting it restates it. Review found
    /// that on 2026-08-30 and it is the shape this project has a rule about: a
    /// helper extracted, the helper tested, the risk left at the call site.
    ///
    /// So this pins the call sites. Every place that sets the selected section
    /// from a value that is not a literal must route through the fallback;
    /// otherwise a restored or notified `.meetingTranscript` renders the hidden
    /// pane in a build that hides it.
    func testEverySelectionPathRoutesThroughTheFallback() throws {
        let file = try repositoryRoot()
            .appendingPathComponent("AFFlow/UI/SettingsWindow.swift")
        var assignments = 0
        var offenders: [String] = []
        for line in try codeLines(of: file) {
            let text = line.text
            // `selectedSection ==` is a comparison and matched the naive
            // check, which made this scan report two offenders that were not
            // assignments at all. Simulated before it ever ran.
            let assigns = text.contains("selectedSection = ")
                && !text.contains("selectedSection ==")
            let initialises = text.contains("_selectedSection = State(initialValue:")
            guard assigns || initialises else { continue }
            // A literal destination is a decision the code is making, not a
            // value arriving from outside: `selectedSection = .home` cannot be
            // the hidden section.
            if text.contains("= .") { continue }
            assignments += 1
            if !text.contains("resolvingHidden") {
                offenders.append("\(line.number): "
                                 + text.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertGreaterThan(assignments, 0,
                             "found no non-literal assignment to selectedSection, so "
                             + "this scan verified nothing")
        XCTAssertEqual(offenders, [],
                       "a selection arrives from outside without the fallback:\n"
                       + offenders.joined(separator: "\n"))
    }

    // MARK: - Every door into the meeting window

    /// Three methods open that window and they are reached from the menu bar,
    /// from a saved transcript row, and from the summary writer. A gate on the
    /// sidebar alone would leave all three open.
    @MainActor
    func testNoDoorIntoTheMeetingWindowOpensWhenHidden() {
        withFlag(false) {
            let state = AppState()
            XCTAssertFalse(state.meetingSurfacesAreVisible)
            XCTAssertFalse(state.showMeetingTranscriptWindow(),
                           "the menu-bar door opened the window with meetings hidden")
            XCTAssertFalse(state.showOrCreateMeetingWindow(),
                           "the create door opened the window with meetings hidden")
            XCTAssertFalse(state.openMeetingFile(URL(fileURLWithPath: "/tmp/none.md")),
                           "a saved transcript opened the window with meetings hidden")
        }
    }

    /// **The door production actually uses.** The three methods above have no
    /// live caller; this one is reached from the menu bar and is what opens the
    /// microphone and the system-audio tap. Review on 2026-08-30 found it was
    /// the one method that did not get a guard, so the whole scope gate rested
    /// on a SwiftUI `if` in a single view.
    @MainActor
    func testStartingAMeetingIsRefusedWhenHidden() {
        withFlag(false) {
            let state = AppState()
            XCTAssertFalse(state.startMeetingTranscription(meetingName: "test"),
                           "a meeting started with meetings hidden")
            XCTAssertFalse(state.startMeetingTranscriptionFromMenu(),
                           "the menu-bar path started a meeting with meetings hidden")
        }
    }

    /// Deliberately asserts the PREDICATE rather than opening the window. A
    /// window opened here survives in `NSApp.windows` after it closes and makes
    /// an unrelated test fail later in a full run, which STATE.md records as a
    /// real failure mode of this suite.
    @MainActor
    func testTheDoorsAreOpenWhenTheFlagIsOn() {
        withFlag(true) {
            XCTAssertTrue(AppState().meetingSurfacesAreVisible,
                          "the flag is on and the app still considers meetings hidden")
        }
    }

    // MARK: - No control may write the flag in v1

    /// The scope gate is only a gate while nothing in the shipped UI can flip
    /// it. A SwiftUI `Toggle` binds with `$`, so a `$`-prefixed reference to
    /// this key's property is a control that writes it.
    func testNoShippedControlBindsTheFlag() throws {
        var offenders: [String] = []
        for file in try swiftFiles(under: "AFFlow") {
            for line in try codeLines(of: file)
            where line.text.contains("$appState.meetingTranscriptEnabled")
                || line.text.contains("$meetingTranscriptEnabled") {
                offenders.append("\(file.lastPathComponent):\(line.number)")
            }
        }
        XCTAssertEqual(offenders, [],
                       "a control writes the v1 scope gate, so it is not internal: "
                       + offenders.joined(separator: ", "))
    }

    // MARK: - Words a dictation-only user would read

    /// First-run copy and the walkthrough are read by everyone, flag or no
    /// flag: they are not inside any gated view. Promising meeting
    /// transcription to someone who cannot reach it is a claim the app does not
    /// keep, which is the standard `docs/launch-v1-plan.md` sets for v1.
    func testFirstRunCopyPromisesNoMeetings() throws {
        let surfaces = ["UI/OnboardingWindow.swift", "UI/HomeWalkthrough.swift"]
        var offenders: [String] = []
        for relative in surfaces {
            let file = try repositoryRoot().appendingPathComponent("AFFlow").appendingPathComponent(relative)
            for line in try codeLines(of: file) where line.text.lowercased().contains("meeting") {
                offenders.append("\(file.lastPathComponent):\(line.number): "
                                 + line.text.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertEqual(offenders, [],
                       "first-run copy names meetings, which v1 does not ship:\n"
                       + offenders.joined(separator: "\n"))
    }

    /// A sweep of every user-visible string literal on 2026-08-30 found three
    /// outside any meeting view that still named meetings to a dictation-only
    /// user: the History search box and two labels in the Models sidebar. Both
    /// of those sections are ones every dictation user opens, so the words
    /// would have put the feature back on screen after the sidebar entry was
    /// taken away.
    func testCopyOutsideMeetingViewsNamesNoMeetingsWhenHidden() {
        withFlag(false) {
            XCTAssertFalse(MeetingsVisibility.historySearchPlaceholder.lowercased().contains("meeting"),
                           "the History search box says: "
                           + MeetingsVisibility.historySearchPlaceholder)
            for capability in MeetingsVisibility.cleanupModelCapabilities {
                XCTAssertFalse(capability.lowercased().contains("meeting"),
                               "a model card advertises: \(capability)")
            }
        }
    }

    /// **Same correction as the fallback above.** Asserting the two ternaries
    /// in `MeetingsVisibility` restates them; revert either call site to its
    /// hardcoded string and the test above still passes. This pins the call
    /// sites by requiring that nothing outside `MeetingsVisibility.swift`
    /// spells the copy, and that the one row which is gated by an `if` rather
    /// than by a string is still inside that `if`.
    func testNothingElseSpellsTheMeetingCopy() throws {
        let owner = "MeetingsVisibility.swift"
        var offenders: [String] = []
        for file in try swiftFiles(under: "AFFlow") where file.lastPathComponent != owner {
            for line in try codeLines(of: file)
            where line.text.contains("Search dictations and meetings")
                || line.text.contains("\"meeting summary\"") {
                offenders.append("\(file.lastPathComponent):\(line.number)")
            }
        }
        XCTAssertEqual(offenders, [],
                       "copy that has to change with the flag is hardcoded at a "
                       + "call site: " + offenders.joined(separator: ", "))
    }

    /// The third place the sweep found is a whole row rather than a string, so
    /// it is gated by an `if` and no value test can reach it.
    func testTheMeetingSummaryRowStaysBehindTheGate() throws {
        let file = try repositoryRoot()
            .appendingPathComponent("AFFlow/UI/ModelsSidebarView.swift")
        let lines = try codeLines(of: file)
        guard let row = lines.first(where: { $0.text.contains("title: \"Meeting summary\"") }) else {
            XCTFail("the Meeting summary row is gone, so this scan verified nothing")
            return
        }
        let preceding = lines.filter { $0.number < row.number && $0.number >= row.number - 8 }
        XCTAssertTrue(preceding.contains { $0.text.contains("MeetingsVisibility.isOn") },
                      "the Meeting summary row at line \(row.number) is not inside a "
                      + "MeetingsVisibility gate, so every dictation user sees it")
    }

    /// And they must come back, or hiding them was a deletion wearing a flag.
    func testThatCopyReturnsWhenTheFlagIsOn() {
        withFlag(true) {
            XCTAssertTrue(MeetingsVisibility.historySearchPlaceholder.lowercased().contains("meeting"))
            XCTAssertTrue(MeetingsVisibility.cleanupModelCapabilities.contains { $0.contains("meeting") })
        }
    }

    /// The section's own subtitle claimed auto-detection that was deleted on
    /// 2026-07-27 along with the five-second browser poll. Andrew reads this
    /// line every time he opens the section.
    func testTheMeetingSectionDoesNotClaimAutoDetection() {
        XCTAssertFalse(AFFlowSection.meetingTranscript.subtitle.lowercased().contains("auto-detect"),
                       "the subtitle promises auto-detection the app removed: "
                       + AFFlowSection.meetingTranscript.subtitle)
    }

    // MARK: - Source scanning helpers, same shape as AppSupportPathOwnershipTests

    private func repositoryRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("AFFlow").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("could not find the repository root from \(#filePath), so this scan verified nothing")
        throw NSError(domain: "MeetingsHiddenInV1", code: 1)
    }

    private func codeLines(of file: URL) throws -> [(number: Int, text: String)] {
        let source = try String(contentsOf: file, encoding: .utf8)
        return source.components(separatedBy: .newlines).enumerated().compactMap { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") else { return nil }
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
}
