import XCTest
@testable import AFFlow

/// **AF Flow is one window.**
///
/// Andrew, 2026-08-24: "I do not want history and other menu options to pop up
/// in the different window, let it be in one."
///
/// Home, Settings, History and the Debug log were four separate `NSWindow`s
/// reached from a row of three words across the top of Home. They are one window
/// with a sidebar now, and Home is its first section.
///
/// **The meeting transcript viewer is deliberately still its own window.** He
/// chose that, because he reads a transcript alongside other things. A later
/// tidy-up that folds it in would be undoing a decision, not finishing one, so
/// it is pinned here rather than left to memory.
@MainActor
final class OneWindowTests: XCTestCase {

    /// Counts the windows THIS test opened, rather than every window in the
    /// process carrying the title.
    ///
    /// The first version asserted a global count of one and passed alone while
    /// failing in a full run. `closeWindows` sets `isReleasedWhenClosed = false`
    /// windows invisible but leaves them in `NSApp.windows`, and now that Home,
    /// Settings and the debug log all share the title "AF Flow", fourteen other
    /// tests leave residue under it. `WindowFoldabilityTests` has had the same
    /// shape for weeks. A global count was measuring the suite, not the change.
    func testHomeSettingsAndTheDebugLogAllLandOnTheSameWindow() throws {
        closeAFFlowWindows()
        defer { closeAFFlowWindows() }
        let appState = try makeAppState(suite: #function)
        let before = visibleAFFlowWindowIDs()

        appState.showHomeWindow()
        appState.showSettings()
        appState.showSettings(section: .transcriptionLab)
        appState.showDebugLog()

        let opened = visibleAFFlowWindowIDs().subtracting(before)
        XCTAssertEqual(opened.count, 1, "four destinations opened \(opened.count) windows")

        // The old titles must not come back. A second window carrying one of
        // these is the exact thing he asked to stop happening.
        for retired in ["AF Flow Settings", "AF Flow Debug Log"] {
            XCTAssertTrue(
                NSApp.windows.filter { $0.title == retired }.isEmpty,
                "\(retired) opened as a separate window again"
            )
        }
    }

    func testTheSidebarLeadsWithHomeAndEndsWithTheDebugLog() {
        let visible = AFFlowSection.visible

        XCTAssertEqual(visible.first, .home, "Home is the front door and must lead the sidebar")
        XCTAssertEqual(visible.last, .debugLog, "the debug log is a diagnostic, not somewhere he works")
        XCTAssertTrue(visible.contains(.transcriptionLab), "History fell out of the sidebar")
    }

    /// Every row the sidebar draws needs a label, a description and an icon.
    /// A new section reachable but unlabelled is a blank row he cannot identify.
    func testEveryVisibleSectionIsLabelled() {
        for section in AFFlowSection.visible {
            XCTAssertFalse(section.title.isEmpty, "\(section) has no title")
            XCTAssertFalse(section.subtitle.isEmpty, "\(section) has no subtitle")
            XCTAssertFalse(section.systemImageName.isEmpty, "\(section) has no icon")
        }
    }

    /// Only Home draws its own pane. If another section claims this, the shell
    /// stops drawing its title and the section had better be drawing one itself.
    func testOnlyHomeDrawsItsOwnHeader() {
        for section in AFFlowSection.allCases {
            XCTAssertEqual(
                section.drawsItsOwnHeader,
                section == .home,
                "\(section) disagrees with the shell about who draws the header"
            )
        }
    }

    /// HIS DECISION, pinned so a later tidy-up cannot quietly reverse it.
    func testTheMeetingTranscriptViewerIsStillItsOwnWindow() throws {
        let source = try appStateSource()
        XCTAssertTrue(
            source.contains("meetingTranscriptWindowController.show()"),
            "the meeting transcript viewer stopped opening its own window; he asked for it to stay separate"
        )
    }

    // MARK: - What Codex found in the window work

    /// **The debug log must stop keeping his raw text when he closes the window.**
    ///
    /// `DebugLogStore.recordSensitive` writes his RAW transcriptions and OCR
    /// context only while a viewer is live. As a floating panel, closing it was
    /// the signal. As a SECTION, `orderOut` leaves the SwiftUI view mounted, so
    /// `onDisappear` never fires and the viewer count stays above zero: every
    /// later dictation would be persisted to disk with nothing on screen. Codex,
    /// 2026-08-24, P1. The window's own lifecycle is the signal now.
    func testClosingTheWindowAnnouncesThatNobodyIsViewingTheDebugLog() throws {
        closeAFFlowWindows()
        defer { closeAFFlowWindows() }
        let appState = try makeAppState(suite: #function)
        let controller = HomeWindowController()
        controller.show(appState: appState, section: .debugLog)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "AF Flow" && $0.isVisible })

        let announcements = VisibilityRecorder()
        _ = window.delegate?.windowShouldClose?(window)

        XCTAssertEqual(
            announcements.received,
            [false],
            "closing the window did not announce that the debug log has no viewer, so his raw text keeps being written"
        )
    }

    /// Minimising hides it just as thoroughly as closing does.
    func testMinimisingTheWindowAlsoAnnouncesIt() throws {
        closeAFFlowWindows()
        defer { closeAFFlowWindows() }
        let appState = try makeAppState(suite: #function)
        let controller = HomeWindowController()
        controller.show(appState: appState, section: .debugLog)

        let announcements = VisibilityRecorder()
        controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))

        XCTAssertEqual(announcements.received, [false], "minimising left the debug log streaming")
    }

    /// The store side of the same property, tested directly: once the claim is
    /// released, his raw text stops being kept.
    func testTheStoreStopsKeepingHisRawTextOnceTheClaimIsReleased() {
        let store = DebugLogStore(storageURL: temporaryLogURL())

        store.beginLiveViewing()
        store.recordSensitive(category: .cleanup, message: "what he actually said")
        XCTAssertTrue(store.entries.contains { $0.message == "what he actually said" })

        store.endLiveViewing()
        store.recordSensitive(category: .cleanup, message: "said after he closed the window")
        XCTAssertFalse(
            store.entries.contains { $0.message == "said after he closed the window" },
            "his raw text was still being written with nobody looking"
        )
    }

    /// **Settings and the debug log must come to the front.**
    ///
    /// He reaches them from the menu bar while another app is frontmost. The two
    /// deleted controllers both activated; the unified one defaults to not
    /// activating, because Home opens on launch and activating there is what put
    /// it over his game on 2026-07-21. Without the split, those menu items look
    /// like they do nothing. Codex, 2026-08-24, P1.
    func testMenuBarDestinationsComeToTheFrontButHomeDoesNot() throws {
        let source = try appStateSource()

        XCTAssertTrue(
            source.contains("section: section ?? .general, activating: true"),
            "Settings stopped coming to the front"
        )
        XCTAssertTrue(
            source.contains("section: .debugLog, activating: true"),
            "the debug log stopped coming to the front"
        )
        XCTAssertTrue(
            source.contains("section: .home)"),
            "Home started activating, which is the 2026-07-21 over-the-game bug"
        )
    }

    /// Balance is the whole mechanism: `DebugLogStore` COUNTS viewers, so one
    /// stray `beginLiveViewing` leaks his raw text forever.
    func testOnlyOnePlaceClaimsAndReleasesTheDebugLogViewer() throws {
        let source = try settingsWindowSource()

        XCTAssertEqual(
            source.components(separatedBy: "beginLiveViewing()").count - 1, 1,
            "beginLiveViewing is called from more than one place, so the count can fall out of balance"
        )
        XCTAssertEqual(
            source.components(separatedBy: "endLiveViewing()").count - 1, 1,
            "endLiveViewing is called from more than one place, so the count can fall out of balance"
        )
    }

    // MARK: - What Codex found in round 2

    /// **Nothing may keep running because the window was merely hidden.**
    ///
    /// `orderOut` does not unmount the view, so every `onDisappear` cleanup in
    /// this shell is unreachable when he closes the window. The debug log stream
    /// was the privacy half of that; the 2-second permission timer is the other
    /// half, and it became newly reachable because an ordinary Home launch now
    /// mounts the whole shell rather than Home alone. Codex, 2026-08-24, round 2.
    ///
    /// A structural assertion, and deliberately so: mounting SwiftUI and waiting
    /// on a real timer would test AppKit rather than this decision.
    func testHidingTheWindowStopsThePermissionPoll() throws {
        let source = try settingsWindowSource()
        let handler = try XCTUnwrap(
            source.components(separatedBy: "afFlowWindowVisibilityChanged").last,
            "the window-visibility handler is gone"
        )
        let body = String(handler.prefix(1200))

        XCTAssertTrue(
            body.contains("stopPermissionPolling()"),
            "hiding the window no longer stops the permission poll, so it runs for the rest of the process"
        )
        XCTAssertTrue(
            body.contains("startPermissionPollingIfNeeded()"),
            "showing the window again no longer resumes the poll, so a granted permission would never be noticed"
        )
    }

    /// The debug log used to be a 640-point floating panel. The detail pane is
    /// about 630 points at the default window width and 530 at the minimum, and
    /// it scrolls only vertically, so the inherited floor clipped every line.
    func testTheDebugLogNoLongerDemandsItsOldPanelWidth() throws {
        let source = try debugLogSource()

        XCTAssertFalse(
            source.contains("minWidth: 640"),
            "the debug log still demands its standalone panel width and will clip inside the pane"
        )
    }

    // MARK: - What Codex found in round 3

    /// `@ViewBuilder` belongs to `detailContent`. An edit that inserts a helper
    /// just above a declaration can quietly steal the attribute above it, which
    /// is what happened here: the shell's builder ended up on a `Void` function.
    /// It still compiled, because the switch sits inside a `VStack` closure that
    /// is a builder context anyway — so nothing caught it. Codex, round 3.
    func testTheViewBuilderAttributeStaysOnTheDetailPane() throws {
        let source = try settingsWindowSource()

        XCTAssertTrue(
            source.contains("@ViewBuilder\n    private var detailContent: some View {"),
            "detailContent lost its @ViewBuilder attribute"
        )
        XCTAssertFalse(
            source.contains("@ViewBuilder\n    /// The ONLY place"),
            "@ViewBuilder is attached to a Void helper again"
        )
    }

    /// Home is his front door and now shares a pane with the sidebar. If it does
    /// not fill that pane, its paper background stops at its content height and
    /// the rest shows through in the shell's colour — a seam across the first
    /// thing he sees. Codex, round 3.
    func testHomeIsAllowedToFillThePane() throws {
        let source = try homeWindowSource()

        XCTAssertTrue(
            source.contains("maxWidth: .infinity, minHeight: 420, maxHeight: .infinity"),
            "Home can no longer grow to fill the detail pane, so its background will stop short"
        )
    }

    // MARK: - What Codex found in round 4

    /// **A minimised window is not a visible one.**
    ///
    /// `makeKeyAndOrderFront` does not restore a minimised window. Choosing
    /// Debug log from the menu bar while AF Flow sat in the Dock would announce
    /// the window as visible and take a live-viewing claim on the log with
    /// nothing on screen — the round 1 privacy leak by another route.
    func testRestoringFromTheDockActuallyRestoresTheWindow() throws {
        closeAFFlowWindows()
        defer { closeAFFlowWindows() }
        let appState = try makeAppState(suite: #function)
        let controller = HomeWindowController()
        controller.show(appState: appState, section: .home)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "AF Flow" && $0.isVisible })

        window.miniaturize(nil)
        controller.show(appState: appState, section: .debugLog, activating: true)

        XCTAssertFalse(
            window.isMiniaturized,
            "the window stayed in the Dock while the debug log took a viewer claim"
        )
    }

    /// **An ordinary launch must not pay for sections he did not open.**
    ///
    /// One unconditional `onAppear` enumerated audio devices, decoded the whole
    /// transcription index and its timings, and scanned every speaker-profile
    /// file. That was fine while it only ran when he opened Settings. Home mounts
    /// this shell now, so it ran on EVERY launch — the same grows-with-a-year-of-
    /// history cost that came off the paste path the same day, landing on the
    /// launch path instead.
    func testLaunchingIntoHomeDoesNotDoEveryOtherSectionsWork() throws {
        let source = try settingsWindowSource()
        let loader = try XCTUnwrap(
            source.components(separatedBy: "private func loadDataFor(").last,
            "the per-section loader is gone, so onAppear is doing everything again"
        )
        let body = String(loader.prefix(900))

        XCTAssertTrue(body.contains("case .general:"), "the loader no longer distinguishes sections")
        XCTAssertTrue(
            body.contains("case .home, .cleanup, .models, .modelExperiment, .meetingTranscript, .debugLog:"),
            "Home is no longer explicitly a section that loads nothing"
        )
        XCTAssertFalse(
            source.contains("""
        .onAppear {
            inputDevices = AudioDeviceManager.listInputDevices()
"""),
            "onAppear enumerates audio devices unconditionally again"
        )
    }

    /// He leaves the window open, so "poll while visible" was not enough. The
    /// permission rows only exist in General.
    func testPermissionPollingOnlyHappensWhereThePermissionsAre() throws {
        let source = try settingsWindowSource()
        let start = try XCTUnwrap(
            source.components(separatedBy: "private func startPermissionPollingIfNeeded() {").last
        )
        let body = String(start.prefix(500))

        XCTAssertTrue(
            body.contains("guard selectedSection == .general else { return }"),
            "the app polls AX and IOHID every two seconds from Home, History and the debug log"
        )
    }

    // MARK: - Helpers
    private func homeWindowSource() throws -> String {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryURL
                .appendingPathComponent("AFFlow")
                .appendingPathComponent("UI")
                .appendingPathComponent("HomeWindow.swift"),
            encoding: .utf8
        )
    }

    private func debugLogSource() throws -> String {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryURL
                .appendingPathComponent("AFFlow")
                .appendingPathComponent("UI")
                .appendingPathComponent("DebugLogWindow.swift"),
            encoding: .utf8
        )
    }

    /// Collects visibility announcements synchronously. `queue: nil` matters:
    /// on `.main` the notification would arrive after the assertion.
    private final class VisibilityRecorder {
        private(set) var received: [Bool] = []
        private var token: NSObjectProtocol?

        init() {
            token = NotificationCenter.default.addObserver(
                forName: .afFlowWindowVisibilityChanged,
                object: nil,
                queue: nil
            ) { [self] note in
                received.append((note.object as? Bool) ?? true)
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    private func temporaryLogURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("debug-log.json")
    }

    private func settingsWindowSource() throws -> String {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryURL
                .appendingPathComponent("AFFlow")
                .appendingPathComponent("UI")
                .appendingPathComponent("SettingsWindow.swift"),
            encoding: .utf8
        )
    }


    private func makeAppState(suite: String) throws -> AppState {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
    }

    private func visibleAFFlowWindowIDs() -> Set<ObjectIdentifier> {
        Set(
            NSApp.windows
                .filter { $0.title == "AF Flow" && $0.isVisible }
                .map(ObjectIdentifier.init)
        )
    }

    private func closeAFFlowWindows() {
        for window in NSApp.windows where ["AF Flow", "AF Flow Settings", "AF Flow Debug Log"].contains(window.title) {
            window.close()
        }
    }

    private func appStateSource() throws -> String {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryURL
                .appendingPathComponent("AFFlow")
                .appendingPathComponent("AppState.swift"),
            encoding: .utf8
        )
    }
}
