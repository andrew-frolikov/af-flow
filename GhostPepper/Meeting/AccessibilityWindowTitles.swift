import AppKit
import Foundation

enum AccessibilityWindowTitles {
    /// Reads another app's window titles.
    ///
    /// These are SYNCHRONOUS cross-process calls made from the main actor, and
    /// the default accessibility messaging timeout is six seconds. An
    /// unresponsive Zoom would therefore stall the main thread, and the thing
    /// that stalls with it is his dictation. Half a second is far longer than a
    /// healthy app needs and short enough that a hung one costs a hiccup rather
    /// than a freeze.
    /// Returns nil when the Accessibility call itself failed, and an array when
    /// it succeeded — which may legitimately be empty.
    ///
    /// THE DISTINCTION IS LOAD-BEARING. This used to return `[]` for both, and on
    /// 2026-08-19 that ended his Zoom call after 2 minutes 13 seconds: AF Flow's
    /// Accessibility grant was broken by an install, every read failed, and
    /// `MeetingSession.checkForMeetingEnd()` read the empty list as "Zoom has no
    /// meeting window" and stopped recording. A signal the app cannot read is
    /// not evidence about the world.
    static func reading(for app: NSRunningApplication) -> (titles: [String], failed: Bool) {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return ([], true)
        }

        var titles: [String] = []
        var failed = false
        for window in windows {
            var titleValue: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)

            // Codex, 2026-08-19: a FAILED title query used to be dropped exactly
            // like a window that simply has no title. So enumeration could
            // succeed, every individual title could error, and this would hand
            // back an innocent-looking empty list — which `checkForMeetingEnd()`
            // reads as "the call is over". The same auto-stop, one layer down.
            // Codex round 2: the failure is RECORDED rather than thrown away,
            // but the titles that did read are kept. Auto-stop needs the strict
            // answer; detection and title-updating are best-effort and would
            // regress if one bad window blanked a list containing a good one.
            if isReadFailure(status) {
                failed = true
                continue
            }

            if let title = titleValue as? String, !title.isEmpty {
                titles.append(title)
            }
        }

        return (titles, failed)
    }

    /// Whether an `AXError` means the read failed, as opposed to the window
    /// legitimately having no title.
    static func isReadFailure(_ status: AXError) -> Bool {
        switch status {
        case .success, .attributeUnsupported, .noValue:
            return false
        default:
            return true
        }
    }

    /// Best effort: every title that could be read, whether or not others
    /// failed. `MeetingDetector` and the title auto-update want this — a single
    /// unreadable window must not hide a good one from them.
    static func all(for app: NSRunningApplication) -> [String] {
        reading(for: app).titles
    }
}
