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
    static func all(for app: NSRunningApplication) -> [String] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return []
        }

        return windows.compactMap { window in
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String, !title.isEmpty else {
                return nil
            }
            return title
        }
    }
}
