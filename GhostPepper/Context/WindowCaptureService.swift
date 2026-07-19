import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

protocol WindowCaptureServing {
    func captureFrontmostWindowImage() async throws -> CGImage?
}

final class WindowCaptureService: WindowCaptureServing {
    /// AF Flow hard rule: never request Screen Recording. This is a stub that
    /// returns nil before touching any ScreenCaptureKit API (SCShareableContent,
    /// SCScreenshotManager) so macOS never auto-prompts for the permission.
    /// Frontmost-window-OCR context capture is disabled in this build.
    func captureFrontmostWindowImage() async throws -> CGImage? {
        return nil

        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              let windowID = frontmostWindowID(for: frontmostApplication.processIdentifier) else {
            return nil
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(window.frame.width * 2), 1)
        configuration.height = max(Int(window.frame.height * 2), 1)
        configuration.scalesToFit = false
        configuration.showsCursor = false

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    private func frontmostWindowID(for processID: pid_t) -> UInt32? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let ownerProcessID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerProcessID == processID else {
                continue
            }

            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            let alpha = windowInfo[kCGWindowAlpha as String] as? Double ?? 1
            guard layer == 0, alpha > 0 else {
                continue
            }

            if let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber {
                return windowNumber.uint32Value
            }
        }

        return nil
    }
}
