import Foundation

/// What the app can actually do right now, recorded rather than assumed.
///
/// Observability item 6, and ledger item 23: **the app reports itself ready
/// while it is deaf.** `AppState` logs one line when Input Monitoring is missing
/// and then sets `status = .ready` anyway, so the only trace of being unable to
/// hear his hotkey is a sentence nobody reads.
///
/// **This deliberately does NOT gate `.ready`.** The comment at that call site
/// says Accessibility alone may be sufficient for the event tap, and it may well
/// be; refusing to become ready on a check that turns out to be too strict would
/// stop his dictation altogether, which is far worse than the problem. Making
/// the app honest is separable from making it fussier, and only the first is
/// safe to do while he is not at the machine. (Decision recorded 2026-08-03
/// under his standing instruction to proceed and write the assumption down.)
///
/// So this records a census line instead. It exists to answer questions that
/// were unanswerable on 2026-08-02, when about ten of his hotkey presses did
/// nothing and there was no way to tell a denied grant from a bad chord:
///
/// - Was he deaf on Wednesday, and from when?
/// - Did a rebuild silently reset a grant? Replacing the binary invalidates
///   Input Monitoring, and this app is rebuilt and rsynced constantly, so this
///   is a scheduled failure rather than a hypothetical one.
///
/// Every value comes from an API that asks the system, not from a stored flag.
enum PermissionCensus {
    /// One line, deterministic key order, parseable after its prefix.
    /// Matches the `RAW ` convention of `ModelManager.rawDetectionCensus` so the
    /// probe can find both the same way.
    static let prefix = "RAW permissions "

    static func line(
        inputMonitoring: Bool,
        accessibility: Bool,
        microphone: Bool,
        reason: String,
        accessibilityFunction: AccessibilityFunctionCheck.Verdict = .inconclusive
    ) -> String {
        // `canHearHotkey` is the pair that decides whether push-to-talk can work
        // at all. It is computed here rather than left to whoever reads the log,
        // because a reader deriving it is a reader who can derive it wrongly.
        let canHearHotkey = inputMonitoring || accessibility
        // `accessibility` is the FLAG and `accessibilityFunction` is the
        // CAPABILITY, and 2026-08-05 proved they are two different facts: the
        // flag read true through a three-day total outage. Both are recorded,
        // with the disagreement itself computed here so the probe does not have
        // to know how to spot it.
        return prefix + "{"
            + "\"accessibility\":\(accessibility),"
            + "\"accessibilityFunction\":\"\(AccessibilityFunctionCheck.description(of: accessibilityFunction))\","
            + "\"accessibilityStale\":\(AccessibilityFunctionCheck.isStaleGrant(accessibilityFunction)),"
            // Says WHY it is broken, durably and without a UI banner. Codex,
            // 2026-08-21: the sandbox explanation was unreachable through
            // `warning()`, which only speaks when Input Monitoring is off. And a
            // permanent limitation is not something to nag him about forever —
            // it belongs in the log, where the next person debugging this looks.
            + "\"accessibilityBlockedBySandbox\":\(AccessibilityFunctionCheck.isBlockedBySandbox(accessibilityFunction)),"
            + "\"canHearHotkey\":\(canHearHotkey),"
            + "\"inputMonitoring\":\(inputMonitoring),"
            + "\"microphone\":\(microphone),"
            + "\"reason\":\"\(reason)\"}"
    }

    /// A short human sentence for the cases worth saying out loud, or nil when
    /// nothing is wrong. Separate from `line` so the log always records the full
    /// state while the UI only speaks up when it matters.
    static func warning(
        inputMonitoring: Bool,
        accessibility: Bool,
        microphone: Bool,
        accessibilityFunction: AccessibilityFunctionCheck.Verdict = .inconclusive
    ) -> String? {
        if !microphone {
            return "AF Flow cannot use the microphone. Dictation will record silence until you grant it in System Settings, Privacy and Security, Microphone."
        }
        if !inputMonitoring && !accessibility {
            return "AF Flow cannot see your hotkey. Grant Input Monitoring in System Settings, Privacy and Security."
        }
        // AFTER the two that stop dictation working, and only when Accessibility
        // is the grant actually carrying the hotkey. Codex, 2026-08-05: putting
        // this first outranked the microphone warning, which is fatal, with one
        // that may not matter at all. A single failed AX query does not prove a
        // stale grant either, so this is worded as a suspicion, not a verdict.
        if AccessibilityFunctionCheck.isStaleGrant(accessibilityFunction), !inputMonitoring {
            return AccessibilityFunctionCheck.staleGrantWarning
        }
        if !inputMonitoring {
            // Not fatal, and deliberately not phrased as though it is: the event
            // tap may still work through Accessibility. It is worth saying
            // because a rebuild resets this grant and the symptom is a hotkey
            // that silently does nothing.
            return "Input Monitoring is off. The hotkey may still work through Accessibility, but if presses stop registering, grant it in System Settings."
        }
        return nil
    }
}
