import AVFoundation
import XCTest
import WhisperKit
@testable import GhostPepper

/// Replays his 50 saved dictations through WhisperKit's language detector and
/// records the RAW return for each.
///
/// Observability item 4. `PROGRESS.md` has called this "the best remaining
/// verification" of the 2026-08-02 language fix since the day it landed, and it
/// went unrun because it looked like it needed a full re-transcription of every
/// recording under two rule sets.
///
/// It does not. **The old rule and the new rule differ only inside
/// `restrictedLanguage`, which is a pure function of the detector's output.** So
/// the expensive half runs ONCE — one model load, one detection per recording —
/// and both rules are applied to that record afterwards, offline and for free,
/// by `scripts/language-replay.py`. Re-running the comparison after a future
/// rule change then costs nothing.
///
/// **SKIPPED unless `AF_FLOW_LANGUAGE_REPLAY=1` reaches the test PROCESS.**
/// `xcodebuild` does not pass the shell environment through, so it has to be set
/// as `TEST_RUNNER_AF_FLOW_LANGUAGE_REPLAY=1`; xcodebuild strips the prefix. Set
/// without the prefix, this test skips and the run still reports success, which
/// is the same silent-green shape as an unregistered test file.
/// It loads a 632 MB model and
/// takes minutes, so it must never join an ordinary suite run. It also needs its
/// inputs staged into this test host's own container first, because the host is
/// sandboxed and cannot read his real archive:
///
///     scripts/stage-language-replay.sh
///
/// It only ever READS his recordings, and writes one JSONL file.
final class LanguageReplayTests: XCTestCase {
    private var containerRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhostPepper", isDirectory: true)
    }

    private struct Entry: Decodable {
        let audioFileName: String
        let audioDuration: Double
        let createdAt: Double
        let rawTranscription: String?
    }

    /// WhisperKit wants 16 kHz mono floats, which is how the app records, so in
    /// the normal case this is a straight read.
    private func samples(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return [] }
        try file.read(into: buffer)

        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let raw = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard file.processingFormat.sampleRate != 16_000 else { return raw }

        // Nearest-neighbour is enough: this feeds a language detector, not a
        // transcript, and every file he has is already 16 kHz. Resampling exists
        // so an odd one cannot silently skew the run.
        let ratio = file.processingFormat.sampleRate / 16_000
        let count = Int(Double(raw.count) / ratio)
        return (0..<count).map { raw[min(raw.count - 1, Int(Double($0) * ratio))] }
    }

    private func jsonLine(
        file: String, duration: Double, createdAt: Double, hadText: Bool,
        language: String?, probabilities: [String: Float], error: String?
    ) -> String {
        let keys = probabilities.keys.sorted()
        let probs = keys.map { "\"\($0)\":\(probabilities[$0]!)" }.joined(separator: ",")
        let reported = language.map { "\"\($0)\"" } ?? "null"
        let failure = error.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? "null"
        return "{\"file\":\"\(file)\",\"duration\":\(duration),\"createdAt\":\(createdAt),"
            + "\"hadText\":\(hadText),\"language\":\(reported),"
            + "\"n\":\(probabilities.count),\"probs\":{\(probs)},\"error\":\(failure)}"
    }

    func testReplayHisDictationsThroughLanguageDetection() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AF_FLOW_LANGUAGE_REPLAY"] == "1",
            "set TEST_RUNNER_AF_FLOW_LANGUAGE_REPLAY=1 (xcodebuild strips the prefix) and run scripts/stage-language-replay.sh first"
        )

        let replay = containerRoot.appendingPathComponent("replay", isDirectory: true)
        let indexURL = replay.appendingPathComponent("transcription-lab-index.json")
        let data = try Data(contentsOf: indexURL)
        let entries = try JSONDecoder().decode([Entry].self, from: data)
            .sorted { $0.createdAt < $1.createdAt }
        XCTAssertFalse(entries.isEmpty, "nothing staged at \(replay.path)")

        // `modelFolder` and not `downloadBase` + `model`. With `download: false`
        // WhisperKit does not resolve a variant name against the download base,
        // and fails with "Model folder is not set." The staged copy is at an
        // exact path, so point at it.
        let modelFolder = containerRoot
            .appendingPathComponent("whisper-models/models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-large-v3-v20240930_turbo_632MB", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: modelFolder.path),
            "no staged model at \(modelFolder.path); run scripts/stage-language-replay.sh"
        )

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        let whisper = try await WhisperKit(config)

        var lines: [String] = []
        for (index, entry) in entries.enumerated() {
            let audio = replay.appendingPathComponent("audio")
                .appendingPathComponent(entry.audioFileName)
            let hadText = !((entry.rawTranscription ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            print("[\(index + 1)/\(entries.count)] \(entry.audioFileName)")

            do {
                let buffer = try samples(at: audio)
                // Recording the refusal is the point rather than a nuisance:
                // 8 of his 10 empty dictations are under a second long.
                guard buffer.count >= 1_600 else {
                    lines.append(jsonLine(file: entry.audioFileName, duration: entry.audioDuration,
                                          createdAt: entry.createdAt, hadText: hadText,
                                          language: nil, probabilities: [:],
                                          error: "under 0.1s of audio"))
                    continue
                }
                let detection = try await whisper.detectLangauge(audioArray: buffer)
                lines.append(jsonLine(file: entry.audioFileName, duration: entry.audioDuration,
                                      createdAt: entry.createdAt, hadText: hadText,
                                      language: detection.language,
                                      probabilities: detection.langProbs, error: nil))
            } catch {
                lines.append(jsonLine(file: entry.audioFileName, duration: entry.audioDuration,
                                      createdAt: entry.createdAt, hadText: hadText,
                                      language: nil, probabilities: [:], error: "\(error)"))
            }
        }

        let out = replay.appendingPathComponent("detections.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        print("REPLAY WROTE \(lines.count) detections to \(out.path)")
        XCTAssertEqual(lines.count, entries.count)
    }
}
