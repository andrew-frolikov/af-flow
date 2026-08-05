import XCTest
@testable import GhostPepper

/// The check that would have caught the 2026-08-05 paste outage on day one.
///
/// For three days the flag said `accessibility:true` while every real query
/// returned nothing, and 235 dictations reached the clipboard instead of the
/// field Andrew was looking at. These pin the distinction the old check could
/// not express: trusted is not the same as working.
final class AccessibilityFunctionCheckTests: XCTestCase {
    // MARK: - The verdict

    /// The case the whole type exists for. A flag saying yes and a query saying
    /// nothing is a STALE GRANT, and it must not read as healthy.
    func testTrustedFlagWithAFailingQueryIsBrokenNotWorking() {
        let verdict = AccessibilityFunctionCheck.verdict(
            isTrusted: true,
            hasTargetProcess: true,
            queryError: -25211
        )

        XCTAssertEqual(verdict, .broken(rawAXError: -25211))
        XCTAssertNotEqual(verdict, .working)
    }

    func testTrustedFlagWithAnAnsweringQueryIsWorking() {
        XCTAssertEqual(
            AccessibilityFunctionCheck.verdict(
                isTrusted: true,
                hasTargetProcess: true,
                queryError: nil
            ),
            .working
        )
    }

    /// An untrusted process is honest about itself, and that is a different
    /// problem with a different message. It must not be reported as a stale
    /// grant, or the fix he is told to apply is the wrong one.
    func testAnUntrustedProcessIsNotReportedAsAStaleGrant() {
        let verdict = AccessibilityFunctionCheck.verdict(
            isTrusted: false,
            hasTargetProcess: true,
            queryError: -25211
        )

        XCTAssertEqual(verdict, .notTrusted)
        XCTAssertFalse(AccessibilityFunctionCheck.isStaleGrant(verdict))
    }

    /// NOTHING TO ASK IS NOT AN ANSWER. If no other process is running there is
    /// no evidence either way, and inventing a failure here would fire the loud
    /// warning at a moment that proves nothing.
    func testNoProcessToQueryIsInconclusiveRatherThanBroken() {
        let verdict = AccessibilityFunctionCheck.verdict(
            isTrusted: true,
            hasTargetProcess: false,
            queryError: nil
        )

        XCTAssertEqual(verdict, .inconclusive)
        XCTAssertFalse(AccessibilityFunctionCheck.isStaleGrant(verdict))
    }

    func testOnlyABrokenVerdictCountsAsAStaleGrant() {
        XCTAssertTrue(AccessibilityFunctionCheck.isStaleGrant(.broken(rawAXError: -25204)))
        XCTAssertFalse(AccessibilityFunctionCheck.isStaleGrant(.working))
        XCTAssertFalse(AccessibilityFunctionCheck.isStaleGrant(.notTrusted))
        XCTAssertFalse(AccessibilityFunctionCheck.isStaleGrant(.inconclusive))
    }

    // MARK: - What the log and the warning say

    /// The raw AXError is carried into the log because on 2026-08-05 nobody
    /// could say WHICH failure it was: no code had ever been recorded.
    func testTheDescriptionCarriesTheRawErrorCode() {
        let text = AccessibilityFunctionCheck.description(of: .broken(rawAXError: -25211))

        XCTAssertTrue(text.contains("-25211"), text)
        XCTAssertTrue(text.contains("broken"), text)
    }

    func testEachVerdictHasAStableParseableDescription() {
        XCTAssertEqual(AccessibilityFunctionCheck.description(of: .working), "working")
        XCTAssertEqual(AccessibilityFunctionCheck.description(of: .notTrusted), "notTrusted")
        XCTAssertEqual(AccessibilityFunctionCheck.description(of: .inconclusive), "inconclusive")
    }

    /// The warning has to name the action, because the state is not one he can
    /// guess a fix for: the toggle looks on and the app looks fine.
    func testTheWarningTellsHimToRemoveAndReAddTheGrant() {
        let warning = AccessibilityFunctionCheck.staleGrantWarning

        XCTAssertTrue(warning.contains("Accessibility"), warning)
        XCTAssertTrue(warning.lowercased().contains("remove"), warning)
        XCTAssertTrue(warning.lowercased().contains("add it back"), warning)
    }

    // MARK: - The live probe

    /// The probe must never query our OWN process. A self-query succeeds with no
    /// grant at all, so a check built that way can never fail and would have
    /// reported "working" straight through the outage, exactly like the flag it
    /// replaces. Under the test host Accessibility is not granted, so the only
    /// verdict a self-query could not produce is `.working`.
    func testTheLiveProbeNeverReportsWorkingWithoutARealGrant() {
        let verdict = AccessibilityFunctionCheck.run()

        XCTAssertNotEqual(verdict, .working, "A self-query would pass here. It must not.")
    }
}
