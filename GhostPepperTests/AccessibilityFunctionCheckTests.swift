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

    /// `isSandboxed` is passed explicitly rather than left to the default, which
    /// reads the environment: this test asserts what a broken verdict MEANS, and
    /// it should not change answer depending on where it runs. Since 2026-08-21
    /// the default is environment-dependent, and inside the sandboxed test host
    /// the default is `true`.
    func testOnlyABrokenVerdictCountsAsAStaleGrant() {
        XCTAssertTrue(AccessibilityFunctionCheck.isStaleGrant(.broken(rawAXError: -25204), isSandboxed: false))
        XCTAssertFalse(AccessibilityFunctionCheck.isStaleGrant(.working, isSandboxed: false))
        XCTAssertFalse(AccessibilityFunctionCheck.isStaleGrant(.notTrusted, isSandboxed: false))
        XCTAssertFalse(AccessibilityFunctionCheck.isStaleGrant(.inconclusive, isSandboxed: false))
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

    // MARK: - The sandbox

    // PROVEN 2026-08-21. Accessibility has never worked in this app, and it is
    // not a stale grant: a diagnostic build identical except for
    // `ENABLE_APP_SANDBOX=NO` reported `working` on its first launch, while the
    // shipping build has reported `broken(AXError -25204)` 28 times out of 28
    // across every build and three separate grants. App Sandbox blocks the
    // Accessibility API against other processes; `AXIsProcessTrusted()` still
    // answers true because the TCC row exists, which is the split in the log.
    //
    // Andrew decided to KEEP the sandbox, because dropping it means migrating
    // 15 GB out of the container and removing a real boundary on an app that
    // records his microphone. So `.broken` inside a sandbox is expected, and
    // must never be reported as something a permission grant can fix. He was
    // sent to System Settings three times for it.
    func testABrokenQueryInsideTheSandboxIsNotAStaleGrant() {
        XCTAssertFalse(
            AccessibilityFunctionCheck.isStaleGrant(.broken(rawAXError: -25204), isSandboxed: true),
            "The sandbox blocks this by design. Calling it stale sends him to System Settings for nothing."
        )
    }

    func testABrokenQueryOutsideTheSandboxIsStillAStaleGrant() {
        XCTAssertTrue(
            AccessibilityFunctionCheck.isStaleGrant(.broken(rawAXError: -25204), isSandboxed: false),
            "Unsandboxed, a granted-but-refusing AX server is the 2026-08-05 outage and must still be reported."
        )
    }

    // Post-paste learning reads the focused text field through Accessibility, so
    // in the sandbox it cannot work AT ALL. His log holds ~1,200 polls across
    // every day it has ever run and not one of them ever read a field. Six polls
    // a second per dictation, all guaranteed to fail, plus seven log lines each.
    func testPostPasteLearningIsSkippedWhenAccessibilityCannotWork() {
        XCTAssertFalse(
            PostPasteLearningCoordinator.canObserveFocusedField(accessibility: .broken(rawAXError: -25204)),
            "Polling a field the app can never read is pure noise."
        )
        XCTAssertFalse(
            PostPasteLearningCoordinator.canObserveFocusedField(accessibility: .notTrusted)
        )
    }

    func testPostPasteLearningStillRunsWhenAccessibilityWorks() {
        XCTAssertTrue(PostPasteLearningCoordinator.canObserveFocusedField(accessibility: .working))
        XCTAssertTrue(
            PostPasteLearningCoordinator.canObserveFocusedField(accessibility: .inconclusive),
            "An unanswered question is not a no. Nothing was established, so do not disable the feature on it."
        )
    }

    func testABrokenQueryInsideTheSandboxIsRecordedAsSandboxBlocked() {
        XCTAssertTrue(
            AccessibilityFunctionCheck.isBlockedBySandbox(.broken(rawAXError: -25204), isSandboxed: true)
        )
    }

    func testABrokenQueryOutsideTheSandboxIsNotBlamedOnTheSandbox() {
        XCTAssertFalse(
            AccessibilityFunctionCheck.isBlockedBySandbox(.broken(rawAXError: -25204), isSandboxed: false)
        )
    }

    func testAWorkingQueryIsNeverBlamedOnTheSandbox() {
        XCTAssertFalse(AccessibilityFunctionCheck.isBlockedBySandbox(.working, isSandboxed: true))
        XCTAssertFalse(AccessibilityFunctionCheck.isBlockedBySandbox(.inconclusive, isSandboxed: true))
    }
}
