import AppKit
import ApplicationServices
import Foundation

/// Whether Accessibility ACTUALLY WORKS, as opposed to whether the flag says so.
///
/// Ledger item 23, and the root cause of the 2026-08-05 paste outage. For three
/// days `AXIsProcessTrusted()` returned true while every real Accessibility
/// query against another process returned nothing, so `PermissionCensus` logged
/// `accessibility:true` throughout a total outage and 235 of Andrew's dictations
/// reached the clipboard instead of the field he was looking at.
///
/// The cause is structural rather than a one-off: this app is ad-hoc signed, its
/// signature changes on every build, about ten builds were installed on 08-04
/// and 08-05, and macOS keeps the TCC row keyed to the old signature. The row
/// still answers "granted" and the AX server still refuses to talk. So the flag
/// and the capability are two different facts and only one of them was measured.
///
/// **Check the claim, not the intent.** A permission check that cannot fail the
/// way the permission fails is not a check.
enum AccessibilityFunctionCheck {
    /// What a real query established. `broken` is the case that did not exist
    /// before and is the whole point of this type.
    enum Verdict: Equatable {
        /// A real Accessibility query against another process succeeded.
        case working
        /// `AXIsProcessTrusted()` itself says no. Honest, and not the bug.
        case notTrusted
        /// The flag says trusted and a real query failed. The stale grant.
        /// Carries the raw `AXError` so the log says which failure it was;
        /// on 2026-08-05 nobody could tell because nobody had recorded one.
        case broken(rawAXError: Int32)
        /// No other process to ask, so nothing was established either way.
        /// Never treated as a failure: an unanswered question is not a no.
        case inconclusive
    }

    /// Short, stable, and parseable. Goes into the census line and the probe.
    static func description(of verdict: Verdict) -> String {
        switch verdict {
        case .working:
            return "working"
        case .notTrusted:
            return "notTrusted"
        case .broken(let rawAXError):
            return "broken(AXError \(rawAXError))"
        case .inconclusive:
            return "inconclusive"
        }
    }

    /// True only for the case that needs him to re-add the grant. Deliberately
    /// NOT true for `.notTrusted`, which the existing warning already covers,
    /// and NOT true for `.inconclusive`.
    static func isStaleGrant(_ verdict: Verdict) -> Bool {
        if case .broken = verdict {
            return true
        }
        return false
    }

    /// The sentence he sees. Named for the action rather than the state,
    /// because the person reading it is trying to fix something.
    /// Worded as a SUSPICION, not a verdict. One failed query against one app
    /// does not prove the grant is stale: the target may have quit, hung, or
    /// answered `kAXErrorCannotComplete` for its own reasons. It also no longer
    /// mentions text reaching a field, because since 2026-08-05 AF Flow does not
    /// put text in fields; Accessibility here is only about hearing the hotkey.
    static let staleGrantWarning = """
        AF Flow's Accessibility permission may have stopped working: it is \
        granted but not answering. If your hotkey stops responding, remove AF \
        Flow from System Settings, Privacy and Security, Accessibility, then add \
        it back and relaunch. Rebuilding the app is what breaks it.
        """

    // MARK: - The decision, separated from the system calls

    /// Pure, so it can be tested both ways without a TCC grant. `queryError` is
    /// the `AXError` raw value from a real query, or nil when the query returned
    /// a usable value.
    ///
    /// - Parameter isTrusted: what `AXIsProcessTrusted()` said.
    /// - Parameter hasTargetProcess: whether there was another process to ask.
    /// - Parameter queryError: nil means the query answered.
    static func verdict(
        isTrusted: Bool,
        hasTargetProcess: Bool,
        queryError: Int32?
    ) -> Verdict {
        guard isTrusted else {
            return .notTrusted
        }
        guard hasTargetProcess else {
            return .inconclusive
        }
        guard let queryError else {
            return .working
        }
        return .broken(rawAXError: queryError)
    }

    // MARK: - The live probe

    /// Asks the system. One attribute read against one other process.
    ///
    /// It must be another process: querying our own AX tree succeeds without any
    /// grant at all, so a self-query is a check that can never fail and would
    /// have reported "working" straight through the outage, exactly like the
    /// flag it replaces.
    static func run() -> Verdict {
        let isTrusted = AXIsProcessTrusted()
        guard isTrusted else {
            return .notTrusted
        }

        guard let processID = targetProcessID() else {
            return .inconclusive
        }

        let application = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            application,
            kAXRoleAttribute as CFString,
            &value
        )

        if status == .success, value as? String != nil {
            return .working
        }

        return .broken(rawAXError: status.rawValue)
    }

    /// Any running app that is not us. The frontmost one first, because it is
    /// the one a paste would target; Finder and friends as the fallback so a
    /// menu-bar-only foreground state does not make this inconclusive.
    private static func targetProcessID() -> pid_t? {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownProcessID {
            return frontmost.processIdentifier
        }

        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular
                && $0.processIdentifier != ownProcessID
                && !$0.isTerminated
        }?.processIdentifier
    }
}
