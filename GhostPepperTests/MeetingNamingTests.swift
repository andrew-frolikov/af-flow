import XCTest
@testable import GhostPepper

/// What a recording is called when nothing better is known.
///
/// His complaint on 2026-07-29 was that `zoom-10-21-am.md` "tells me nothing".
/// The name was app-first and used a 12-hour clock, which cost two separate
/// things: it does not say when, and it does not sort.
final class MeetingNamingTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Edmonton")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: iso)!
    }

    func testTheNameLeadsWithTheDateAndTimeThenTheApp() {
        let name = MeetingDetector.meetingName(
            appName: "Zoom",
            at: date("2026-08-02 14:30"),
            timeZone: TimeZone(identifier: "America/Edmonton")!
        )

        XCTAssertEqual(name, "2026-08-02 14:30 Zoom")
    }

    /// The clock has to be 24-hour, and this is the reason rather than taste:
    /// as text, "10-21-am" sorts after "02-30-pm", so a 12-hour name orders an
    /// afternoon call before a morning one.
    func testAnAfternoonMeetingSortsAfterAMorningOneOnTheSameDay() {
        // 09:00 and not 10:21 deliberately. Under the old 12-hour name these
        // slug to "9-00-am" and "2-30-pm", and "9" > "2", so the morning call
        // sorts last. A 10:21 example would have passed WITH the bug present,
        // which is what the first version of this test did.
        let morning = MeetingMarkdownWriter.slugify(
            MeetingDetector.meetingName(
                appName: "Zoom",
                at: date("2026-08-02 09:00"),
                timeZone: TimeZone(identifier: "America/Edmonton")!
            )
        )
        let afternoon = MeetingMarkdownWriter.slugify(
            MeetingDetector.meetingName(
                appName: "Zoom",
                at: date("2026-08-02 14:30"),
                timeZone: TimeZone(identifier: "America/Edmonton")!
            )
        )

        XCTAssertLessThan(morning, afternoon)
    }

    /// `MeetingHistory` sorts a day's files by filename, descending, to get
    /// newest first. With an app-first name that sorted by app: a 09:00 Teams
    /// call was listed above a 14:30 Zoom one because "t" beats "z" backwards.
    /// Leading with the time is what makes that existing sort correct.
    func testTwoMeetingsOnOneDaySortByTimeRatherThanByAppName() {
        // Zoom in the morning and Teams in the afternoon, so alphabetical and
        // chronological order DISAGREE. With Teams first this test passed even
        // with the app-first name in place, because "zoom" sorts above "teams"
        // regardless of the time, which made it prove nothing.
        let zoomAtNine = MeetingMarkdownWriter.slugify(
            MeetingDetector.meetingName(
                appName: "Zoom",
                at: date("2026-08-02 09:00"),
                timeZone: TimeZone(identifier: "America/Edmonton")!
            )
        )
        let teamsAtHalfTwo = MeetingMarkdownWriter.slugify(
            MeetingDetector.meetingName(
                appName: "Teams",
                at: date("2026-08-02 14:30"),
                timeZone: TimeZone(identifier: "America/Edmonton")!
            )
        )

        let newestFirst = [zoomAtNine, teamsAtHalfTwo].sorted(by: >)
        XCTAssertEqual(newestFirst, [teamsAtHalfTwo, zoomAtNine])
    }

    func testTheSlugKeepsTheDateAndTimeReadable() {
        let slug = MeetingMarkdownWriter.slugify(
            MeetingDetector.meetingName(
                appName: "Zoom",
                at: date("2026-08-02 14:30"),
                timeZone: TimeZone(identifier: "America/Edmonton")!
            )
        )

        XCTAssertEqual(slug, "2026-08-02-14-30-zoom")
    }

    /// With no app in front the name is still a timestamp, not the word
    /// "Meeting" and a clock time.
    func testTheNameWithNoRecognisedAppIsStillTimestampFirst() {
        let name = MeetingDetector.meetingName(
            appName: "Meeting",
            at: date("2026-08-02 14:30"),
            timeZone: TimeZone(identifier: "America/Edmonton")!
        )

        XCTAssertEqual(name, "2026-08-02 14:30 Meeting")
    }

    /// The clock is 24-hour and the date is ISO-ordered no matter what the
    /// machine's region is set to. A name that ends up in a filename must not
    /// move when the locale does, and the old `timeStyle = .short` formatter
    /// followed it: on a US region it emitted "10:21 AM", which is where
    /// `zoom-10-21-am.md` came from.
    func testAnAfternoonTimeIsRenderedOnATwentyFourHourClock() {
        let name = MeetingDetector.meetingName(
            appName: "Zoom",
            at: date("2026-08-02 22:05"),
            timeZone: TimeZone(identifier: "America/Edmonton")!
        )

        XCTAssertEqual(name, "2026-08-02 22:05 Zoom")
        XCTAssertFalse(name.lowercased().contains("pm"))
    }
}
