import XCTest
@testable import GhostPepper

final class MeetingWindowHeuristicsTests: XCTestCase {
    func testBestAutoUpdateTitleIgnoresTitlesFromDifferentAppBundle() {
        XCTAssertNil(
            MeetingWindowHeuristics.bestAutoUpdateTitle(
                in: ["AF Flow Settings"],
                appName: "Zoom",
                observedBundleIdentifier: "com.github.matthartman.ghostpepper",
                monitoredBundleIdentifier: "us.zoom.xos"
            )
        )
    }

    func testBestMeetingTitlePrefersNamedZoomMeetingOverUtilityWindows() {
        XCTAssertEqual(
            MeetingWindowHeuristics.bestMeetingTitle(
                in: ["Settings", "Zoom Meeting", "Team Weekly Standup - Zoom"],
                appName: "Zoom"
            ),
            "Team Weekly Standup"
        )
    }

    func testZoomMeetingStillAppearsActiveForGenericMeetingWindow() {
        XCTAssertTrue(
            MeetingWindowHeuristics.indicatesActiveMeeting(
                in: ["Zoom Meeting", "Settings"],
                appName: "Zoom"
            )
        )
    }

    func testZoomMeetingAppearsEndedWhenOnlyUtilityWindowsRemain() {
        XCTAssertFalse(
            MeetingWindowHeuristics.indicatesActiveMeeting(
                in: ["Settings", "Home", "Zoom Workplace"],
                appName: "Zoom"
            )
        )
    }
}

/// A REGRESSION I INTRODUCED ON 2026-07-27, which ended a real meeting of his
/// after 76 seconds.
///
/// The window-title check moved from every 5 seconds to every 60 seconds, and in
/// the same edit its threshold moved from two consecutive misses to one. Two
/// strikes at 5 seconds was about ten seconds of tolerance. One strike at 60
/// seconds is none, so a single failed Accessibility read of Zoom's window tree
/// ends the recording. His log for 2026-07-29: meeting started 10:03:49,
/// auto-stopped 10:05:05.
///
/// Changing an interval and a threshold together changes the thing they jointly
/// control, and I reasoned about only one of them.
final class MeetingAutoStopToleranceTests: XCTestCase {

    func testOneBadWindowReadDoesNotEndTheMeeting() {
        XCTAssertFalse(
            MeetingSession.shouldAutomaticallyStop(afterConsecutiveInactivePolls: 1),
            "One failed read of Zoom's window titles ended his meeting after 76 seconds."
        )
    }

    func testTwoConsecutiveBadReadsDoEndTheMeeting() {
        XCTAssertTrue(
            MeetingSession.shouldAutomaticallyStop(afterConsecutiveInactivePolls: 2),
            "A call that really has ended must still stop, or the app records and transcribes over nothing."
        )
    }

    func testZeroMissesNeverEndsTheMeeting() {
        XCTAssertFalse(MeetingSession.shouldAutomaticallyStop(afterConsecutiveInactivePolls: 0))
    }
}
