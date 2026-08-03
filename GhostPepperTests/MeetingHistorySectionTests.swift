import XCTest
@testable import GhostPepper

/// What the Meetings list in the History window actually shows.
final class MeetingHistorySectionTests: XCTestCase {
    private func entry(
        _ name: String,
        date: String = "2026-08-02",
        kind: MeetingHistoryEntry.SourceKind = .meeting
    ) -> MeetingHistoryEntry {
        let url = URL(fileURLWithPath: "/tmp/\(date)/\(name).md")
        return MeetingHistoryEntry(
            id: url,
            name: name,
            dateFolder: date,
            fileURL: url,
            sourceKind: kind
        )
    }

    private func group(_ date: String, _ entries: [MeetingHistoryEntry]) -> MeetingHistoryGroup {
        MeetingHistoryGroup(date: date, entries: entries)
    }

    /// Airtable rows are CSV data tables that live under the meetings folder
    /// because the meeting window's sidebar lists them. They are not meetings.
    func testAirtableRowsAreNotListedAsMeetings() {
        let groups = [
            group("2026-08-02", [
                entry("Standup"),
                entry("Contacts", kind: .airtable(baseName: "CRM"))
            ])
        ]

        let filtered = MeetingHistoryGroup.filter(groups, matching: "")

        XCTAssertEqual(filtered.flatMap(\.entries).map(\.name), ["Standup"])
    }

    /// A group whose only entry was Airtable must vanish, not survive as a bare
    /// date header with nothing under it.
    func testAGroupOfOnlyAirtableRowsDisappearsEntirely() {
        let groups = [
            group("Airtable: CRM", [entry("Contacts", kind: .airtable(baseName: "CRM"))]),
            group("2026-08-02", [entry("Standup")])
        ]

        let filtered = MeetingHistoryGroup.filter(groups, matching: "")

        XCTAssertEqual(filtered.map(\.date), ["2026-08-02"])
    }

    func testAnEmptySearchKeepsEveryMeeting() {
        let groups = [
            group("2026-08-02", [entry("Standup"), entry("Design review")]),
            group("2026-08-01", [entry("One to one")])
        ]

        let filtered = MeetingHistoryGroup.filter(groups, matching: "")

        XCTAssertEqual(filtered.flatMap(\.entries).count, 3)
    }

    func testSearchingMatchesTheMeetingNameCaseInsensitively() {
        let groups = [group("2026-08-02", [entry("Design Review"), entry("Standup")])]

        let filtered = MeetingHistoryGroup.filter(groups, matching: "design")

        XCTAssertEqual(filtered.flatMap(\.entries).map(\.name), ["Design Review"])
    }

    /// The date is in the row's group header rather than its name, so searching
    /// a date has to reach the folder or "what did I record on the first" finds
    /// nothing.
    func testSearchingMatchesTheDateFolder() {
        let groups = [
            group("2026-08-02", [entry("Standup", date: "2026-08-02")]),
            group("2026-08-01", [entry("Retro", date: "2026-08-01")])
        ]

        let filtered = MeetingHistoryGroup.filter(groups, matching: "2026-08-01")

        XCTAssertEqual(filtered.flatMap(\.entries).map(\.name), ["Retro"])
    }

    /// A search that matches nothing returns nothing, rather than falling open
    /// to the full list. This project has shipped two gates that failed open.
    func testASearchMatchingNothingReturnsNothing() {
        let groups = [group("2026-08-02", [entry("Standup"), entry("Retro")])]

        let filtered = MeetingHistoryGroup.filter(groups, matching: "zzzz")

        XCTAssertTrue(filtered.isEmpty)
    }

    /// Whitespace is trimmed, so a stray space from dictation does not empty
    /// the list.
    func testASearchOfOnlyWhitespaceIsTreatedAsNoSearch() {
        let groups = [group("2026-08-02", [entry("Standup"), entry("Retro")])]

        let filtered = MeetingHistoryGroup.filter(groups, matching: "   ")

        XCTAssertEqual(filtered.flatMap(\.entries).count, 2)
    }

    /// Granola imports are meetings and stay in the list; only their icon
    /// differs.
    func testGranolaImportsAreStillListed() {
        let groups = [group("2026-08-02", [entry("Imported call", kind: .granola)])]

        let filtered = MeetingHistoryGroup.filter(groups, matching: "")

        XCTAssertEqual(filtered.flatMap(\.entries).map(\.name), ["Imported call"])
    }
}
