import Foundation

/// Identifies the source of an audio chunk in dual-stream capture.
enum AudioStreamSource {
    case mic
    case system
}

/// A timestamped audio chunk from one of the two capture streams.
struct TaggedAudioChunk {
    let source: AudioStreamSource
    let samples: [Float]
    let timestamp: TimeInterval // seconds since capture start
}

protocol MeetingAudioCapturing: AnyObject {
    var onAudioChunk: ((TaggedAudioChunk) -> Void)? { get set }
    /// Reports that the "Others" channel stopped on its own mid-meeting, for
    /// example because the audio output device changed. The microphone channel
    /// keeps running, so the meeting is degraded rather than over, and saying so
    /// is better than a transcript that quietly contains only one voice.
    var onCaptureDegraded: ((String) -> Void)? { get set }
    func start() async throws
    func stop() async -> (micBuffer: [Float], systemBuffer: [Float])
    var elapsed: TimeInterval { get }
}

/// Coordinates simultaneous mic + system audio capture for meeting transcription.
/// Mic audio = "Me", system audio = "Others" — provides free basic diarization.
final class DualStreamCapture: MeetingAudioCapturing {
    var onAudioChunk: ((TaggedAudioChunk) -> Void)?
    var onCaptureDegraded: ((String) -> Void)?

    private let micRecorder = AudioRecorder()
    private let systemRecorder = SystemAudioRecorder()
    private var startTime: Date?
    private var isActive = false

    /// Starts both mic and system audio capture simultaneously.
    func start() async throws {
        guard !isActive else { return }

        startTime = Date()

        micRecorder.onConvertedAudioChunk = { [weak self] samples in
            guard let self = self, let start = self.startTime else { return }
            let chunk = TaggedAudioChunk(
                source: .mic,
                samples: samples,
                timestamp: Date().timeIntervalSince(start)
            )
            self.onAudioChunk?(chunk)
        }

        systemRecorder.onConvertedAudioChunk = { [weak self] samples in
            guard let self = self, let start = self.startTime else { return }
            let chunk = TaggedAudioChunk(
                source: .system,
                samples: samples,
                timestamp: Date().timeIntervalSince(start)
            )
            self.onAudioChunk?(chunk)
        }

        do {
            try micRecorder.startRecording()
        } catch {
            startTime = nil
            micRecorder.onConvertedAudioChunk = nil
            systemRecorder.onConvertedAudioChunk = nil
        systemRecorder.onCaptureInterrupted = nil
            throw error
        }

        isActive = true

        systemRecorder.onCaptureInterrupted = { [weak self] message in
            self?.onCaptureDegraded?(message)
        }

        do {
            try await systemRecorder.startRecording()
        } catch {
            print("DualStreamCapture: system audio unavailable; continuing with microphone-only capture: \(error.localizedDescription)")
        }
    }

    /// Stops both capture streams and returns the full buffers.
    func stop() async -> (micBuffer: [Float], systemBuffer: [Float]) {
        guard isActive else { return ([], []) }
        isActive = false

        let micBuffer = await micRecorder.stopRecording()
        let systemBuffer = await systemRecorder.stopRecording()

        micRecorder.onConvertedAudioChunk = nil
        systemRecorder.onConvertedAudioChunk = nil
        systemRecorder.onCaptureInterrupted = nil
        startTime = nil

        return (micBuffer, systemBuffer)
    }

    /// Whether dual-stream capture is currently active.
    var capturing: Bool { isActive }

    /// Elapsed time since capture started, or 0 if not active.
    var elapsed: TimeInterval {
        guard let start = startTime else { return 0 }
        return Date().timeIntervalSince(start)
    }
}
