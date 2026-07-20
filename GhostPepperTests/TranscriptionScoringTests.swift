import AVFoundation
import XCTest
@testable import GhostPepper

/// LOOP.md Tier C, the objective verifier for transcription quality.
///
/// Built at C2 start on 2026-07-20 because it did not exist. The Lab stored
/// audio and transcriptions but had no reference text and no scoring, so it was
/// a manual review tool, and C1 consequently closed with no machine rubric line
/// at all. Until this runs, the only C2 verifier is Andrew's ear.
///
/// **Why this lives in the test target rather than in its own tool.** The first
/// attempt was a standalone command-line target following the CleanupModelProbe
/// pattern, which is what LOOP.md suggests. It does not work here, and the
/// reason is worth recording: `ModelManager` is entangled with the recording,
/// diarization and Lab surfaces, so a standalone binary needs a hand-maintained
/// list of app sources. That list would drift from the app silently, and a
/// verifier that scores something subtly different from what ships is the exact
/// failure mode this project has hit repeatedly. The test target already
/// compiles the real app, so scoring here measures what Andrew actually uses.
///
/// **Not a pass/fail test.** It is a measurement harness that happens to be run
/// by xcodebuild. It never asserts a quality threshold, because LOOP.md is
/// explicit that a threshold picked by guesswork must not gate anything, and no
/// empirical floor exists yet. It skips loudly rather than passing quietly when
/// its inputs are missing.
final class TranscriptionScoringTests: XCTestCase {

    /// Downloads are opt-in. Three of the four candidate models are not on
    /// disk, and each download is what makes LuLu prompt with a real hostname.
    /// That prompt is the evidence closing the last C0 waiver, so it must be
    /// spent while Andrew is watching for it, not as a side effect of a run
    /// started for another reason.
    private var downloadsAllowed: Bool {
        ProcessInfo.processInfo.environment["AF_FLOW_ALLOW_MODEL_DOWNLOAD"] == "1"
    }

    private var fixturesDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AF_FLOW_FIXTURES"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures")
    }

    private var candidateModels: [String] {
        if let override = ProcessInfo.processInfo.environment["AF_FLOW_MODELS"] {
            return override.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return [
            SpeechModelCatalog.whisperLargeV3Turbo.name,
            SpeechModelCatalog.whisperLargeV3TurboLarge.name,
            SpeechModelCatalog.parakeetV3.name,
            SpeechModelCatalog.qwen3AsrInt8.name,
        ]
    }

    /// Auto-detect and forced Russian, because the force-language control is
    /// itself a C2 deliverable and its value is an open question. If forcing
    /// `ru` does not beat auto-detect on these clips, that is a finding.
    private let languages: [String?] = [nil, "ru"]

    // MARK: - The scoring run

    @MainActor
    func testScoreCandidateModelsOnFixtures() async throws {
        let fixtures = try loadFixtures()

        try XCTSkipIf(
            fixtures.isEmpty,
            """
            cannot verify: no fixtures in \(fixturesDirectory.path).
            Expected pairs such as T2-russian.m4a plus T2-russian.reference.txt.
            Nothing was scored, and this is explicitly not a pass.
            """
        )

        var rows: [ScoreRow] = []
        var skipped: [String] = []

        for modelName in candidateModels {
            guard let descriptor = SpeechModelCatalog.model(named: modelName) else {
                skipped.append("\(modelName): not in the catalog on this OS")
                continue
            }

            let manager = ModelManager(modelName: modelName)
            if !manager.cachedModelNames.contains(modelName) && !downloadsAllowed {
                skipped.append("\(descriptor.pickerTitle): not cached, and AF_FLOW_ALLOW_MODEL_DOWNLOAD is not set")
                continue
            }

            for language in languages {
                let label = language ?? "auto"
                await manager.loadModel(name: modelName, language: language)

                guard manager.isReady else {
                    skipped.append("\(descriptor.pickerTitle) [\(label)]: load failed, \(manager.error?.localizedDescription ?? "unknown")")
                    continue
                }

                for fixture in fixtures {
                    let started = Date()
                    let hypothesis = await manager.transcribe(
                        audioBuffer: fixture.samples,
                        language: language
                    )
                    let elapsed = Date().timeIntervalSince(started)

                    guard let hypothesis, !hypothesis.isEmpty else {
                        skipped.append("\(descriptor.pickerTitle) [\(label)] on \(fixture.name): returned no text")
                        continue
                    }

                    rows.append(ScoreRow(
                        model: descriptor.pickerTitle,
                        modelID: modelName,
                        language: label,
                        fixture: fixture.name,
                        hypothesis: hypothesis,
                        wer: TextScoring.wordErrorRate(hypothesis: hypothesis, reference: fixture.reference),
                        cer: TextScoring.characterErrorRate(hypothesis: hypothesis, reference: fixture.reference),
                        punctuation: TextScoring.punctuationErrorRate(hypothesis: hypothesis, reference: fixture.reference),
                        boundaries: TextScoring.sentenceBoundaries(hypothesis: hypothesis, reference: fixture.reference),
                        missingSpaces: TextScoring.missingSpaceAfterPeriod(in: hypothesis),
                        latinTerms: TextScoring.latinTermsPreserved(hypothesis: hypothesis, reference: fixture.reference),
                        seconds: elapsed,
                        audioDuration: fixture.duration
                    ))
                }
            }
        }

        let report = Self.render(rows: rows, skipped: skipped, fixtures: fixtures)
        print(report)

        let reportURL = fixturesDirectory.appendingPathComponent("scores.md")
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)

        try XCTSkipIf(
            rows.isEmpty,
            """
            cannot verify: no model produced a score.
            \(skipped.map { "  - \($0)" }.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Draft reference generation

    /// Step 2 of the fixture workflow: transcribe unscripted audio so Andrew has
    /// something to correct, rather than asking him to type out what he just said.
    ///
    /// The fixtures are deliberately his real speech rather than a script, so
    /// there is no reference text until he makes one. This produces a first draft
    /// with the current default model and writes it beside the audio as
    /// `<stem>.draft-reference.txt`.
    ///
    /// **The correction step is not optional and cannot be automated.** A
    /// reference produced by a model and never corrected measures agreement with
    /// that model, not accuracy, and would quietly rig the comparison in favour
    /// of whichever engine wrote it. The draft is a typing aid. The extension
    /// stays `.draft-reference.txt` until Andrew has fixed it and renamed it, so
    /// an uncorrected draft can never be picked up as ground truth by accident.
    @MainActor
    func testGenerateDraftReferencesForUnreferencedAudio() async throws {
        let pending = try audioWithoutReference()

        try XCTSkipIf(
            pending.isEmpty,
            "No audio awaiting a reference. Nothing to draft."
        )

        let modelName = SpeechModelCatalog.defaultModelID
        let manager = ModelManager(modelName: modelName)

        try XCTSkipIf(
            !manager.cachedModelNames.contains(modelName) && !downloadsAllowed,
            "\(modelName) is not cached and AF_FLOW_ALLOW_MODEL_DOWNLOAD is not set."
        )

        await manager.loadModel(name: modelName, language: "ru")
        guard manager.isReady else {
            throw XCTSkip("Could not load \(modelName): \(manager.error?.localizedDescription ?? "unknown")")
        }

        for url in pending {
            let audio = try AudioFixtureLoader.load(url)
            guard let draft = await manager.transcribe(audioBuffer: audio.samples, language: "ru") else {
                print("no text produced for \(url.lastPathComponent)")
                continue
            }

            let stem = url.deletingPathExtension().lastPathComponent
            let draftURL = fixturesDirectory.appendingPathComponent("\(stem).draft-reference.txt")
            try draft.write(to: draftURL, atomically: true, encoding: .utf8)

            print("""

            === \(stem) (\(String(format: "%.1fs", audio.duration))) ===
            \(draft)

            Draft written to \(draftURL.lastPathComponent)
            Correct it to exactly what you said, fillers included, then rename it
            to \(stem).reference.txt
            """)
        }
    }

    private func audioWithoutReference() throws -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fixturesDirectory.path) else { return [] }
        let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aiff", "caf"]
        return try manager.contentsOfDirectory(at: fixturesDirectory, includingPropertiesForKeys: nil)
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .filter {
                let stem = $0.deletingPathExtension().lastPathComponent
                return !manager.fileExists(
                    atPath: fixturesDirectory.appendingPathComponent("\(stem).reference.txt").path
                )
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - The scorer's own correctness

    /// The rule from LOOP.md, learned the hard way across three review rounds:
    /// if a check depends on logic of its own, that logic needs its own test in
    /// the same command. Otherwise the first thing to break silently is the
    /// thing meant to notice breakage. These cases are chosen to be the ones a
    /// Russian transcript would actually exercise.
    func testScoringPrimitives() {
        XCTAssertEqual(TextScoring.editDistance(Array("kitten"), Array("sitting")), 3)
        XCTAssertEqual(TextScoring.editDistance([String](), ["a", "b"]), 2)

        // Identical input must score zero, or every other number is meaningless.
        let identical = "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}?"
        XCTAssertEqual(TextScoring.wordErrorRate(hypothesis: identical, reference: identical).value, 0)
        XCTAssertEqual(TextScoring.characterErrorRate(hypothesis: identical, reference: identical).value, 0)
        XCTAssertEqual(TextScoring.punctuationErrorRate(hypothesis: identical, reference: identical).value, 0)

        // Casing and punctuation must not leak into WER, because they are
        // reported separately and double-counting them would misrank models.
        XCTAssertEqual(
            TextScoring.wordErrorRate(hypothesis: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}", reference: "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043C}\u{0438}\u{0440}!").value,
            0,
            "WER must be blind to case and punctuation"
        )

        // The yo fold. Russians write these interchangeably and engines
        // disagree, so scoring them as different reports an orthographic
        // convention as a transcription error.
        XCTAssertEqual(
            TextScoring.wordErrorRate(hypothesis: "\u{0435}\u{0449}\u{0451}", reference: "\u{0435}\u{0449}\u{0435}").value,
            0,
            "yo and ye must fold together"
        )

        // A wrong ending must cost far less in CER than in WER. This is the
        // signal that separates "wrong ending" from "wrong word", which is the
        // whole reason both are reported.
        let endingWER = TextScoring.wordErrorRate(hypothesis: "\u{043A}\u{0440}\u{0430}\u{0441}\u{0438}\u{0432}\u{0430}\u{044F} \u{0434}\u{043E}\u{043C}\u{0430}", reference: "\u{043A}\u{0440}\u{0430}\u{0441}\u{0438}\u{0432}\u{044B}\u{0439} \u{0434}\u{043E}\u{043C}").value
        let endingCER = TextScoring.characterErrorRate(hypothesis: "\u{043A}\u{0440}\u{0430}\u{0441}\u{0438}\u{0432}\u{0430}\u{044F} \u{0434}\u{043E}\u{043C}\u{0430}", reference: "\u{043A}\u{0440}\u{0430}\u{0441}\u{0438}\u{0432}\u{044B}\u{0439} \u{0434}\u{043E}\u{043C}").value
        XCTAssertGreaterThan(endingWER, endingCER, "inflection errors must read as small in CER and large in WER")

        // Sentence merging, the project's most confirmed defect, with the
        // direction named rather than left to the reader.
        let merged = TextScoring.sentenceBoundaries(hypothesis: "\u{0410} \u{0411} \u{0412}.", reference: "\u{0410}. \u{0411}. \u{0412}.")
        XCTAssertEqual(merged.delta, -2)
        XCTAssertEqual(merged.verdict, "merged 2")

        // The exact artifact seen in the C1 Russian clip.
        XCTAssertEqual(TextScoring.missingSpaceAfterPeriod(in: "\u{043F}\u{0440}\u{0438}\u{043B}\u{043E}\u{0436}\u{0435}\u{043D}\u{0438}\u{044F}.\u{0422}\u{0430}\u{043A}\u{0436}\u{0435}"), 1)
        XCTAssertEqual(TextScoring.missingSpaceAfterPeriod(in: "\u{043F}\u{0440}\u{0438}\u{043B}\u{043E}\u{0436}\u{0435}\u{043D}\u{0438}\u{044F}. \u{0422}\u{0430}\u{043A}\u{0436}\u{0435}"), 0)

        // Code-switching: the real failing example from the C1 mixed clip.
        let preserved = TextScoring.latinTermsPreserved(
            hypothesis: "\u{044F} \u{0445}\u{043E}\u{0447}\u{0443} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C} \u{043F}\u{0440}\u{043E}\u{043C}\u{043F}\u{0443}\u{0442}",
            reference: "\u{044F} \u{0445}\u{043E}\u{0447}\u{0443} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C} prompt"
        )
        XCTAssertEqual(preserved.missing, ["prompt"])
        XCTAssertEqual(preserved.preserved, 0)
    }

    /// Proves the loader actually resamples, rather than trusting that it does.
    /// A silent tail truncation here would look like a transcription error, and
    /// would be attributed to whichever model happened to run.
    func testFixtureLoaderResamplesToSixteenKilohertz() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("af-flow-loader-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceRate: Double = 48_000
        let seconds: Double = 2
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 1,
            interleaved: false
        ))
        let frames = AVAudioFrameCount(sourceRate * seconds)

        // Scoped so the writer deinitialises, which is what flushes the header
        // and sample data to disk. Without this the loader reads a half-written
        // file and AVFoundation returns a bare -50, which looks like a loader
        // bug and is not one. Found by this test on its first run.
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            for index in 0..<Int(frames) {
                buffer.floatChannelData?[0][index] = sinf(Float(index) * 0.01) * 0.25
            }
            try file.write(from: buffer)
        }

        let fixture = try AudioFixtureLoader.load(url)
        XCTAssertEqual(fixture.sourceSampleRate, sourceRate)
        XCTAssertEqual(fixture.duration, seconds, accuracy: 0.05, "resampling must preserve duration")
        XCTAssertEqual(Double(fixture.samples.count), 16_000 * seconds, accuracy: 16_000 * 0.05)
        XCTAssertFalse(fixture.sha256.isEmpty)
    }

    // MARK: - Support

    struct Fixture {
        let name: String
        let samples: [Float]
        let reference: String
        let duration: TimeInterval
        let sha256: String
        let sourceSampleRate: Double
    }

    struct ScoreRow {
        let model: String
        let modelID: String
        let language: String
        let fixture: String
        let hypothesis: String
        let wer: TextScoring.Rate
        let cer: TextScoring.Rate
        let punctuation: TextScoring.Rate
        let boundaries: TextScoring.BoundaryCount
        let missingSpaces: Int
        let latinTerms: TextScoring.TermPreservation
        let seconds: Double
        let audioDuration: Double

        var realtimeFactor: Double { audioDuration == 0 ? 0 : seconds / audioDuration }
    }

    private func loadFixtures() throws -> [Fixture] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fixturesDirectory.path) else { return [] }

        let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aiff", "caf"]
        let contents = try manager.contentsOfDirectory(at: fixturesDirectory, includingPropertiesForKeys: nil)

        return try contents
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> Fixture? in
                let stem = url.deletingPathExtension().lastPathComponent
                let referenceURL = fixturesDirectory.appendingPathComponent("\(stem).reference.txt")
                guard manager.fileExists(atPath: referenceURL.path) else { return nil }

                let audio = try AudioFixtureLoader.load(url)
                let reference = try String(contentsOf: referenceURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                return Fixture(
                    name: stem,
                    samples: audio.samples,
                    reference: reference,
                    duration: audio.duration,
                    sha256: audio.sha256,
                    sourceSampleRate: audio.sourceSampleRate
                )
            }
    }

    static func render(rows: [ScoreRow], skipped: [String], fixtures: [Fixture]) -> String {
        var out = "# C2 model scores\n\n"
        out += "Generated by TranscriptionScoringTests. WER and CER are punctuation-blind\n"
        out += "and case-folded; punctuation and boundaries are measured separately, because\n"
        out += "averaging them into one number hides exactly the defects C2 exists to fix.\n\n"

        out += "## Fixture manifest\n\n"
        out += "| Fixture | Duration | Source rate | SHA256 |\n|---|---|---|---|\n"
        for fixture in fixtures {
            out += "| \(fixture.name) | \(String(format: "%.1fs", fixture.duration)) | \(String(format: "%.0f Hz", fixture.sourceSampleRate)) | `\(fixture.sha256.prefix(16))` |\n"
        }

        if !rows.isEmpty {
            out += "\n## Scores\n\n"
            out += "| Model | Lang | Fixture | WER | CER | Punct | Boundaries | No-space | Latin terms | Time | RTF |\n"
            out += "|---|---|---|---|---|---|---|---|---|---|---|\n"
            for row in rows {
                out += "| \(row.model) | \(row.language) | \(row.fixture) | \(row.wer.percent) | \(row.cer.percent) | \(row.punctuation.percent) | \(row.boundaries.hypothesis)/\(row.boundaries.reference) \(row.boundaries.verdict) | \(row.missingSpaces) | \(row.latinTerms.summary) | \(String(format: "%.2fs", row.seconds)) | \(String(format: "%.2fx", row.realtimeFactor)) |\n"
            }

            out += "\n### How to read this\n\n"
            out += "- **WER minus CER gap.** A large gap means the model hears the right words\n"
            out += "  with wrong endings, which is the Russian inflection problem and is fixed\n"
            out += "  by a better model. A small gap means it mishears words outright, which a\n"
            out += "  dictionary layer fixes far more cheaply.\n"
            out += "- **Boundaries** is hypothesis over reference. \"merged N\" is the predicted\n"
            out += "  defect, already confirmed three independent ways.\n"
            out += "- **Latin terms** is the code-switching test. Lost terms mean the model\n"
            out += "  Cyrillicised English vocabulary, the failure his register hits hardest\n"
            out += "  however good WER looks.\n"
            out += "- **RTF** is transcription time over audio duration, and it feeds the empty\n"
            out += "  latency actuals table. Under 1.0 is faster than real time.\n"

            out += "\n## Transcripts\n\n"
            for row in rows {
                out += "**\(row.model) [\(row.language)] on \(row.fixture)**\n\n> \(row.hypothesis)\n\n"
            }
        }

        if !skipped.isEmpty {
            // Printed rather than swallowed: a bounded run must say what it
            // dropped, or silent truncation reads as full coverage.
            out += "\n## Not scored\n\n"
            for entry in skipped { out += "- \(entry)\n" }
        }

        return out
    }
}
