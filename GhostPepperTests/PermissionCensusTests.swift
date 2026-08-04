import XCTest
@testable import GhostPepper

/// The launch-time record of what the app can actually do.
///
/// Ledger item 23: the app reports itself ready while it is deaf. These pin the
/// two things that made 2026-08-02 unanswerable — whether a grant was missing,
/// and whether that grant was the one that mattered — without changing what
/// `.ready` permits.
final class PermissionCensusTests: XCTestCase {
    private func line(
        inputMonitoring: Bool = true,
        accessibility: Bool = true,
        microphone: Bool = true,
        reason: String = "launch"
    ) -> String {
        PermissionCensus.line(
            inputMonitoring: inputMonitoring,
            accessibility: accessibility,
            microphone: microphone,
            reason: reason
        )
    }

    private func parse(_ text: String) throws -> [String: Any] {
        let json = String(text.dropFirst(PermissionCensus.prefix.count))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
    }

    func testTheLineIsParseableJSONAfterItsPrefix() throws {
        let parsed = try parse(line(inputMonitoring: false, reason: "launch"))

        XCTAssertEqual(parsed["inputMonitoring"] as? Bool, false)
        XCTAssertEqual(parsed["accessibility"] as? Bool, true)
        XCTAssertEqual(parsed["microphone"] as? Bool, true)
        XCTAssertEqual(parsed["reason"] as? String, "launch")
    }

    /// Either grant can carry the event tap, so the question that matters is
    /// whether BOTH are missing. Computed in the census rather than left to a
    /// reader who could derive it wrongly.
    func testEitherGrantAloneStillCountsAsAbleToHearTheHotkey() throws {
        let onlyInputMonitoring = try parse(line(inputMonitoring: true, accessibility: false))
        let onlyAccessibility = try parse(line(inputMonitoring: false, accessibility: true))

        XCTAssertEqual(onlyInputMonitoring["canHearHotkey"] as? Bool, true)
        XCTAssertEqual(onlyAccessibility["canHearHotkey"] as? Bool, true)
    }

    func testLosingBothGrantsMeansTheHotkeyCannotBeHeard() throws {
        let parsed = try parse(line(inputMonitoring: false, accessibility: false))

        XCTAssertEqual(parsed["canHearHotkey"] as? Bool, false)
    }

    /// A missing microphone is the worst case and must win the message, because
    /// a granted hotkey that records silence looks like a working app.
    func testAMissingMicrophoneIsWhatTheWarningSays() {
        let warning = PermissionCensus.warning(
            inputMonitoring: false,
            accessibility: false,
            microphone: false
        )

        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.lowercased().contains("microphone"), warning!)
    }

    func testLosingBothHotkeyGrantsIsReportedAsCannotSeeYourHotkey() {
        let warning = PermissionCensus.warning(
            inputMonitoring: false,
            accessibility: false,
            microphone: true
        )

        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("cannot see your hotkey"), warning!)
    }

    /// Input Monitoring alone missing is NOT fatal and must not be phrased as
    /// though it is: the tap may still work through Accessibility. Overstating
    /// it would train him to ignore the warning that does matter.
    func testInputMonitoringAloneMissingIsWarnedAboutWithoutClaimingFailure() {
        let warning = PermissionCensus.warning(
            inputMonitoring: false,
            accessibility: true,
            microphone: true
        )

        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("may still work"), warning!)
        XCTAssertFalse(warning!.contains("cannot see your hotkey"), warning!)
    }

    /// Nothing to say when nothing is wrong. A warning that is always present is
    /// a warning nobody reads.
    func testEverythingGrantedProducesNoWarning() {
        XCTAssertNil(
            PermissionCensus.warning(inputMonitoring: true, accessibility: true, microphone: true)
        )
    }

    /// The reason distinguishes a launch census from one taken when a recording
    /// was attempted, which is what makes "was he deaf on Wednesday" answerable
    /// rather than just "was he deaf at some point".
    func testTheReasonIsCarriedThrough() throws {
        let parsed = try parse(line(reason: "recording-attempt"))

        XCTAssertEqual(parsed["reason"] as? String, "recording-attempt")
    }
}
