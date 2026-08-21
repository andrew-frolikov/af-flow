import AVFoundation
import XCTest
import WhisperKit
@testable import GhostPepper

/// Why a 43-second Russian dictation came back half missing.
///
/// He reported it live on 2026-08-05: "I was saying something in Russian and it
/// cut like 30% of my transcript." The evidence, from his own archive:
///
/// - `3E577796…wav`, 43.5 s, **continuous speech from 0 s to 42 s** — RMS 500 to
///   1100 across every 2-second slice, no silence anywhere.
/// - Raw ASR: **193 characters**, ending mid-phrase on "при самой легкой".
/// - His measured rate that same evening is 9 to 11 chars/sec, so 43.5 s should
///   have produced 390 to 480. He got under half.
/// - **The log records no error.** Language detection succeeded (`ru` at 99.9%),
///   transcription returned, the text was pasted. Nothing said anything was lost.
///
/// Two hypotheses were killed before this file existed. It is not a token cap
/// and not a Russian problem: a 74.6-second Russian dictation the same evening
/// transcribed completely at 8.9 chars/sec. It is not duration either, for the
/// same reason.
///
/// So this stops theorising about WhisperKit's internals and MEASURES instead:
/// decode his actual file under several `DecodingOptions` and report how much
/// text each recovers. The app currently passes a bare `DecodingOptions()`,
/// every value default, which is the first row.
///
/// **SKIPPED unless `TEST_RUNNER_AF_FLOW_DECODE_BAKEOFF=1`** — xcodebuild strips
/// the prefix, and set without it the test skips while the run still reports
/// success. Needs `scripts/stage-language-replay.sh` first.
final class DecodeOptionsBakeOffTests: XCTestCase {
    /// The recording he lost half of.
    private static let subject = "3E577796-F9EB-485A-A810-F1BA35AA0B34.wav"
    /// What the app produced on the day, so a run can be compared against it.
    private static let shippedCharacterCount = 193

    private var containerRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhostPepper", isDirectory: true)
    }

    private func samples(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func candidates() -> [(name: String, options: DecodingOptions)] {
        var rows: [(String, DecodingOptions)] = []

        rows.append(("shipped default", { var o = DecodingOptions(); o.language = "ru"; return o }()))

        rows.append(("vad chunking", {
            var o = DecodingOptions(); o.language = "ru"; o.chunkingStrategy = .vad; return o
        }()))

        rows.append(("word timestamps", {
            var o = DecodingOptions(); o.language = "ru"; o.wordTimestamps = true; return o
        }()))

        rows.append(("no prefill prompt", {
            var o = DecodingOptions(); o.language = "ru"; o.usePrefillPrompt = false; return o
        }()))

        rows.append(("with timestamps", {
            var o = DecodingOptions(); o.language = "ru"; o.withoutTimestamps = false; return o
        }()))

        rows.append(("vad + word timestamps", {
            var o = DecodingOptions()
            o.language = "ru"; o.chunkingStrategy = .vad; o.wordTimestamps = true
            return o
        }()))

        return rows
    }

    private struct Entry: Decodable {
        let audioFileName: String
        let audioDuration: Double
        let rawTranscription: String?
    }

    /// Does the winning option help ACROSS his archive, or only on one file?
    ///
    /// A fix validated on the single recording that motivated it is the mistake
    /// this project keeps making: a lean over the cases where an edit happened
    /// is not a lean over behaviour. So this decodes every staged recording over
    /// five seconds under the shipped options and the two candidates, and reports
    /// both the gains AND any recording a candidate makes WORSE.
    func testTheWinningOptionsAcrossHisWholeArchive() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AF_FLOW_DECODE_SWEEP"] == "1",
            "set TEST_RUNNER_AF_FLOW_DECODE_SWEEP=1"
        )

        let replay = containerRoot.appendingPathComponent("replay", isDirectory: true)
        let entries = try JSONDecoder()
            .decode([Entry].self, from: Data(contentsOf:
                replay.appendingPathComponent("transcription-lab-index.json")))
            .filter { $0.audioDuration > 5 && !(($0.rawTranscription ?? "").isEmpty) }

        let modelFolder = containerRoot
            .appendingPathComponent("whisper-models/models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-large-v3-v20240930_turbo_632MB", isDirectory: true)
        let whisper = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelFolder.path, verbose: false, logLevel: .error,
            prewarm: false, load: true, download: false
        ))

        func decode(_ buffer: [Float], _ make: () -> DecodingOptions) async -> String {
            (try? await whisper.transcribe(audioArray: buffer, decodeOptions: make()))?
                .map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        var vadWins = 0, prefillWins = 0, vadLosses = 0, prefillLosses = 0, unchanged = 0
        print("SWEEP \(entries.count) recordings over 5s")
        for entry in entries {
            let audio = replay.appendingPathComponent("audio")
                .appendingPathComponent(entry.audioFileName)
            guard let buffer = try? samples(at: audio), buffer.count > 16_000 else { continue }

            let base = await decode(buffer) { var o = DecodingOptions(); return o }
            let vad = await decode(buffer) { var o = DecodingOptions(); o.chunkingStrategy = .vad; return o }
            let prefill = await decode(buffer) { var o = DecodingOptions(); o.usePrefillPrompt = false; return o }

            let vadDelta = vad.count - base.count
            let prefillDelta = prefill.count - base.count
            if vadDelta > base.count / 10 { vadWins += 1 }
            if prefillDelta > base.count / 10 { prefillWins += 1 }
            if vadDelta < -base.count / 10 { vadLosses += 1 }
            if prefillDelta < -base.count / 10 { prefillLosses += 1 }
            if abs(vadDelta) <= base.count / 10 && abs(prefillDelta) <= base.count / 10 { unchanged += 1 }

            if abs(vadDelta) > base.count / 10 || abs(prefillDelta) > base.count / 10 {
                print("SWEEP \(String(format: "%5.1f", entry.audioDuration))s base=\(base.count) "
                      + "vad=\(vad.count)(\(vadDelta >= 0 ? "+" : "")\(vadDelta)) "
                      + "prefill=\(prefill.count)(\(prefillDelta >= 0 ? "+" : "")\(prefillDelta))")
            }
        }
        print("SWEEP RESULT vad: \(vadWins) better, \(vadLosses) WORSE | "
              + "prefill: \(prefillWins) better, \(prefillLosses) WORSE | "
              + "\(unchanged) unchanged")
    }

    func testWhichDecodeOptionsRecoverTheLostHalf() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AF_FLOW_DECODE_BAKEOFF"] == "1",
            "set TEST_RUNNER_AF_FLOW_DECODE_BAKEOFF=1 and run scripts/stage-language-replay.sh first"
        )

        let audio = containerRoot
            .appendingPathComponent("replay/audio", isDirectory: true)
            .appendingPathComponent(Self.subject)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path),
                      "no staged recording at \(audio.path)")

        let modelFolder = containerRoot
            .appendingPathComponent("whisper-models/models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-large-v3-v20240930_turbo_632MB", isDirectory: true)
        let whisper = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelFolder.path, verbose: false, logLevel: .error,
            prewarm: false, load: true, download: false
        ))

        let buffer = try samples(at: audio)
        print("BAKEOFF audio \(String(format: "%.1f", Double(buffer.count) / 16_000))s, "
              + "shipped result was \(Self.shippedCharacterCount) characters")

        var best = (name: "", count: 0)
        for candidate in candidates() {
            do {
                let results = try await whisper.transcribe(
                    audioArray: buffer, decodeOptions: candidate.options
                )
                let text = results.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                print("BAKEOFF \(candidate.name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                      + "\(text.count) chars | \(text.suffix(70))")
                if text.count > best.count { best = (candidate.name, text.count) }
            } catch {
                print("BAKEOFF \(candidate.name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                      + "FAILED: \(error)")
            }
        }

        print("BAKEOFF BEST: \(best.name) at \(best.count) characters")
        // Not an assertion about which option wins — that is what the run is for.
        // This only pins that the experiment actually decoded something, so a
        // silent zero cannot be mistaken for a result.
        XCTAssertGreaterThan(best.count, 0, "no candidate produced any text at all")
    }

    // MARK: - Meeting chunks
    //
    // 2026-08-19. `applyDictationChunking` sets `chunkingStrategy = .vad` on
    // EVERY transcription. Its own documentation says it was chosen by measuring
    // "all 39 of his recordings over five seconds" — every one of them a
    // DICTATION. Meeting chunks are a different workload: fixed 30-second
    // windows, one per channel, with long stretches where that channel's speaker
    // is silent because the other one is talking.
    //
    // On his 2026-08-19 Zoom, a 30-second mic chunk measured 79% voiced produced
    // TEN CHARACTERS, while Whisper reported Russian at 99.9% confidence on the
    // same audio. 192 of the 202 truncation warnings in his log are exactly
    // 30.0-second chunks, on the three days he had meetings.
    //
    // This measures rather than argues: decode his real meeting chunks with and
    // without vad and print both. Same method that chose vad in the first place,
    // pointed at the workload it was never pointed at.
    //
    // Point AF_FLOW_FIXTURES at a directory of chunk WAVs and AF_FLOW_MODELS at
    // the whisper model folder.
    func testVadChunkingOnHisRealMeetingChunks() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AF_FLOW_MEETING_BAKEOFF"] == "1",
            "set TEST_RUNNER_AF_FLOW_MEETING_BAKEOFF=1"
        )
        let fixtures = try XCTUnwrap(
            ProcessInfo.processInfo.environment["AF_FLOW_FIXTURES"],
            "AF_FLOW_FIXTURES must point at a directory of meeting chunk WAVs"
        )
        let modelPath = try XCTUnwrap(
            ProcessInfo.processInfo.environment["AF_FLOW_MODELS"],
            "AF_FLOW_MODELS must point at the whisper model folder"
        )

        let whisper = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelPath, verbose: false, logLevel: .error,
            prewarm: false, load: true, download: false
        ))

        // A THROWN DECODE IS NOT AN EMPTY TRANSCRIPT. Codex, 2026-08-21: `try?`
        // turned a failure into "" while the chunk still counted, so the run
        // could report vad better or worse when one side had never decoded at
        // all. The error propagates and fails the test instead.
        func decode(_ buffer: [Float], vad: Bool) async throws -> String {
            var o = DecodingOptions()
            o.language = "ru"
            if vad { o.chunkingStrategy = .vad }
            return try await whisper.transcribe(audioArray: buffer, decodeOptions: o)
                .map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let dir = URL(fileURLWithPath: fixtures, isDirectory: true)
        let wavs = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(
            wavs.isEmpty,
            "AF_FLOW_FIXTURES held no .wav files, so this run measured nothing. Codex: a bake-off that decodes zero chunks must not pass."
        )

        var vadWorse = 0, vadBetter = 0, same = 0
        var decoded = 0, skipped: [String] = []
        print("MEETING-BAKEOFF \(wavs.count) chunks")
        for wav in wavs {
            guard let buffer = try? samples(at: wav), buffer.count > 16_000 else {
                skipped.append(wav.lastPathComponent)
                continue
            }
            let base = try await decode(buffer, vad: false)
            let vad = try await decode(buffer, vad: true)
            // Counted only once BOTH sides are in hand.
            decoded += 1
            let delta = vad.count - base.count
            if delta < -base.count / 10 { vadWorse += 1 }
            else if delta > base.count / 10 { vadBetter += 1 }
            else { same += 1 }
            print("MEETING-BAKEOFF \(wav.lastPathComponent) "
                  + "secs=\(String(format: "%.1f", Double(buffer.count) / 16_000)) "
                  + "base=\(base.count) vad=\(vad.count) delta=\(delta >= 0 ? "+" : "")\(delta)")
        }
        print("MEETING-BAKEOFF RESULT vad better on \(vadBetter), WORSE on \(vadWorse), unchanged \(same)")
        if !skipped.isEmpty {
            print("MEETING-BAKEOFF SKIPPED \(skipped.count): \(skipped.joined(separator: ", "))")
        }
        // A silently biased subset is worse than no measurement, because it
        // looks like one. Codex, 2026-08-21.
        XCTAssertEqual(
            decoded,
            wavs.count,
            "\(wavs.count - decoded) of \(wavs.count) chunks were never decoded, so this result covers a subset the caller did not choose: \(skipped.joined(separator: ", "))"
        )
    }
}
