import Foundation

/// Captures system audio output (what other call participants say) for the
/// "Others" channel of meeting transcription.
///
/// AF Flow hard rule 1: never grant or request Screen Recording. System
/// audio capture required the system screen-capture APIs to observe audio
/// output; this app never touches them, so the capability is permanently
/// disabled here. `startRecording()` always throws before any such API
/// would be reached. `DualStreamCapture` already falls back to
/// microphone-only capture when this throws, so meeting transcription
/// still works, just without the separate "Others" channel.
final class SystemAudioRecorder {
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?
    var onConvertedAudioChunk: (([Float]) -> Void)?

    /// Always throws. System audio capture is not available in AF Flow.
    func startRecording() async throws {
        throw SystemAudioRecorderError.screenRecordingDisabledForThisBuild
    }

    /// Always returns an empty buffer; recording never actually starts.
    func stopRecording() async -> [Float] {
        return []
    }
}

// MARK: - Errors

enum SystemAudioRecorderError: Error, LocalizedError {
    /// AF Flow never requests Screen Recording (hard rule 1). System audio
    /// capture is structurally disabled in this build regardless of any
    /// toggle state.
    case screenRecordingDisabledForThisBuild

    var errorDescription: String? {
        switch self {
        case .screenRecordingDisabledForThisBuild:
            return "System audio capture is not available in AF Flow. Meeting transcription will use the microphone only."
        }
    }
}
