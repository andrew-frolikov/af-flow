import CoreGraphics

protocol WindowCaptureServing {
    func captureFrontmostWindowImage() async throws -> CGImage?
}

/// AF Flow hard rule 1: never grant or request Screen Recording. Capturing a
/// screenshot of the frontmost window (used for OCR window-context and the
/// Context Bundler's screenshot preview) required the system screen-capture
/// APIs; this app never touches them, so the capability is permanently
/// disabled here. Callers already handle a nil result gracefully.
final class WindowCaptureService: WindowCaptureServing {
    func captureFrontmostWindowImage() async throws -> CGImage? {
        return nil
    }
}
