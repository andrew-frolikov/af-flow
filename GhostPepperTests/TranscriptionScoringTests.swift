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

        // Persisted hypotheses first. Transcription needs the app quit and a
        // model loaded; scoring is pure text arithmetic and needs neither. So
        // any fixture whose transcripts were already captured is scored here
        // without touching a model at all, which is what lets the reference
        // text arrive after the transcription run rather than before it.
        var needingLiveTranscription: [Fixture] = []
        for fixture in fixtures {
            let persisted = persistedHypotheses(for: fixture.name)
            if persisted.isEmpty {
                needingLiveTranscription.append(fixture)
                continue
            }
            for entry in persisted {
                rows.append(ScoreRow(
                    model: entry.model,
                    modelID: entry.modelID,
                    language: entry.language,
                    fixture: fixture.name,
                    hypothesis: entry.hypothesis,
                    wer: TextScoring.wordErrorRate(hypothesis: entry.hypothesis, reference: fixture.reference),
                    cer: TextScoring.characterErrorRate(hypothesis: entry.hypothesis, reference: fixture.reference),
                    punctuation: TextScoring.punctuationErrorRate(hypothesis: entry.hypothesis, reference: fixture.reference),
                    boundaries: TextScoring.sentenceBoundaries(hypothesis: entry.hypothesis, reference: fixture.reference),
                    missingSpaces: TextScoring.missingSpaceAfterPeriod(in: entry.hypothesis),
                    latinTerms: TextScoring.latinTermsPreserved(hypothesis: entry.hypothesis, reference: fixture.reference),
                    seconds: entry.seconds,
                    audioDuration: entry.audioDuration
                ))
            }
        }

        guard !needingLiveTranscription.isEmpty else {
            try finish(rows: rows, skipped: skipped, fixtures: fixtures)
            return
        }

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

                for fixture in needingLiveTranscription {
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

        try finish(rows: rows, skipped: skipped, fixtures: fixtures)
    }

    private func finish(rows: [ScoreRow], skipped: [String], fixtures: [Fixture]) throws {
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

    // MARK: - Deliberate model prefetch

    /// Downloads one named model, on purpose, when explicitly asked to.
    ///
    /// Two jobs, and the second is why it exists at all:
    ///
    /// 1. C2 needs three models that are not on disk. Fetching them ahead of a
    ///    scoring run keeps download time out of the measured latency numbers.
    /// 2. It is the **observation target for de-risk checklist item 7**. That
    ///    item wants the destination hosts of a model download observed, and the
    ///    window has been missed three times: LuLu was not installed for the
    ///    first download, the rule it later wrote was `any address:any port` and
    ///    recorded no hostname, and the third went unwatched during a test run.
    ///    Run under `scripts/observe-egress.sh` this produces the evidence
    ///    directly, from the app's own networking stack rather than a firewall's
    ///    bookkeeping.
    ///
    /// Doubly gated, and deliberately so: it needs both the download permission
    /// and an explicit model name, so no ordinary test run can ever trigger a
    /// download by accident. That is the exact failure this project just had.
    @MainActor
    func testPrefetchNamedModel() async throws {
        try XCTSkipUnless(
            downloadsAllowed,
            "Set AF_FLOW_ALLOW_MODEL_DOWNLOAD=1 to permit a download."
        )

        let requested = try XCTUnwrap(
            ProcessInfo.processInfo.environment["AF_FLOW_PREFETCH_MODEL"],
            "Set AF_FLOW_PREFETCH_MODEL to the model name to fetch."
        )

        let descriptor = try XCTUnwrap(
            SpeechModelCatalog.model(named: requested),
            "\(requested) is not in the catalog on this OS."
        )

        let manager = ModelManager(modelName: requested)
        if manager.cachedModelNames.contains(requested) {
            print("\(descriptor.pickerTitle) is already cached; nothing to download.")
            return
        }

        print("downloading \(descriptor.pickerTitle) (\(descriptor.sizeDescription))...")
        let started = Date()
        await manager.loadModel(name: requested, language: "ru")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(
            manager.isReady,
            "\(requested) failed to load: \(manager.error?.localizedDescription ?? "unknown")"
        )
        print(String(format: "loaded in %.1fs", elapsed))
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

    // MARK: - Capture every candidate in one run

    /// A transcript produced by one engine on one clip, persisted so it can be
    /// scored later without re-running the engine.
    struct PersistedHypothesis: Codable {
        let model: String
        let modelID: String
        let language: String
        let hypothesis: String
        let seconds: Double
        let audioDuration: Double
        /// `local` for a model this app runs, `incumbent` for a transcript
        /// carried in from the app being replaced. Only `local` entries are
        /// rewritten by a capture run, so an incumbent row survives re-capture.
        let source: String
    }

    /// Runs every candidate model against every clip that has no reference yet,
    /// and writes the transcripts beside the audio.
    ///
    /// **Why this exists, and it is a scheduling fix rather than a technical
    /// one.** Transcribing requires the app to be quit, because the test host
    /// launches a second copy that competes for the microphone, and Andrew
    /// dictates with this app all day. Scoring requires only the reference text
    /// and some arithmetic. Those two facts were previously welded together:
    /// `testScoreCandidateModelsOnFixtures` transcribed and scored in one pass,
    /// so the reference had to exist *before* the models ran, which forced two
    /// separate interruptions of his day, one to produce a draft and another to
    /// score the corrected version.
    ///
    /// Capturing every hypothesis once decouples them. He gives up the machine
    /// once, corrects the reference whenever he likes, and every score after
    /// that is free. It also makes re-scoring free for the rest of the project:
    /// when C3 changes the cleanup prompt, the ASR transcripts are unchanged
    /// and do not need regenerating.
    @MainActor
    func testCaptureAllCandidateTranscriptsForUnreferencedAudio() async throws {
        let pending = try audioWithoutReference()

        try XCTSkipIf(
            pending.isEmpty,
            "No audio awaiting a reference. Nothing to capture."
        )

        var captured: [String: [PersistedHypothesis]] = [:]
        var skipped: [String] = []
        let clips = try pending.map { (url: $0, audio: try AudioFixtureLoader.load($0)) }

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

                for clip in clips {
                    let stem = clip.url.deletingPathExtension().lastPathComponent
                    let started = Date()
                    let hypothesis = await manager.transcribe(audioBuffer: clip.audio.samples, language: language)
                    let elapsed = Date().timeIntervalSince(started)

                    guard let hypothesis, !hypothesis.isEmpty else {
                        skipped.append("\(descriptor.pickerTitle) [\(label)] on \(stem): returned no text")
                        continue
                    }

                    captured[stem, default: []].append(PersistedHypothesis(
                        model: descriptor.pickerTitle,
                        modelID: modelName,
                        language: label,
                        hypothesis: hypothesis,
                        seconds: elapsed,
                        audioDuration: clip.audio.duration,
                        source: "local"
                    ))
                    print(String(format: "captured %@ [%@] on %@ in %.2fs", descriptor.pickerTitle, label, stem, elapsed))
                }
            }
        }

        for (stem, entries) in captured {
            // Merge rather than overwrite, so an incumbent transcript written
            // in from the Wispr archive is not destroyed by a re-capture.
            let preserved = persistedHypotheses(for: stem).filter { $0.source != "local" }
            try writeHypotheses(preserved + entries, for: stem)
            print("wrote \(preserved.count + entries.count) transcripts to \(stem).hypotheses.json")
        }

        if !skipped.isEmpty {
            print("\nnot captured:\n" + skipped.map { "  - \($0)" }.joined(separator: "\n"))
        }

        XCTAssertFalse(
            captured.isEmpty,
            "No transcript was captured for any clip:\n" + skipped.map { "  - \($0)" }.joined(separator: "\n")
        )
    }

    private func hypothesesURL(for stem: String) -> URL {
        fixturesDirectory.appendingPathComponent("\(stem).hypotheses.json")
    }

    func persistedHypotheses(for stem: String) -> [PersistedHypothesis] {
        guard let data = try? Data(contentsOf: hypothesesURL(for: stem)) else { return [] }
        return (try? JSONDecoder().decode([PersistedHypothesis].self, from: data)) ?? []
    }

    private func writeHypotheses(_ entries: [PersistedHypothesis], for stem: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: hypothesesURL(for: stem), options: .atomic)
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

    /// The persistence layer that lets capture and scoring happen on different
    /// days is new logic sitting underneath the only objective verifier this
    /// project has, so per LOOP.md it gets its own test in the same command.
    ///
    /// The failure that matters is not arithmetic, it is silent substitution: a
    /// hypotheses file that fails to decode must fall back to live
    /// transcription rather than report a fixture as scored with zero rows, and
    /// a re-capture must not delete the incumbent transcript that makes the
    /// Wispr comparison possible.
    func testPersistedHypothesesRoundTripAndPreserveIncumbent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("af-flow-hyp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let previous = ProcessInfo.processInfo.environment["AF_FLOW_FIXTURES"]
        setenv("AF_FLOW_FIXTURES", directory.path, 1)
        defer {
            if let previous { setenv("AF_FLOW_FIXTURES", previous, 1) } else { unsetenv("AF_FLOW_FIXTURES") }
        }

        XCTAssertEqual(persistedHypotheses(for: "absent").count, 0, "a missing file must read as empty, not throw")

        let incumbent = PersistedHypothesis(
            model: "Wispr Flow", modelID: "wispr-qwen-http", language: "ru",
            hypothesis: "one", seconds: 0.6, audioDuration: 30, source: "incumbent"
        )
        let local = PersistedHypothesis(
            model: "Turbo", modelID: "turbo", language: "ru",
            hypothesis: "two", seconds: 1.2, audioDuration: 30, source: "local"
        )
        try writeHypotheses([incumbent, local], for: "clip")

        let restored = persistedHypotheses(for: "clip")
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first { $0.source == "incumbent" }?.hypothesis, "one")
        XCTAssertEqual(restored.first { $0.source == "local" }?.seconds, 1.2)

        // The merge a capture run performs: local entries are replaced, the
        // incumbent survives. Losing it would silently drop the baseline and
        // the comparison would still look complete.
        let preserved = restored.filter { $0.source != "local" }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(preserved.first?.modelID, "wispr-qwen-http")

        // A corrupt file must degrade to live transcription, never to a
        // confident zero. This is the project's recurring failure shape: a
        // check that cannot fail reports success.
        try Data("not json".utf8).write(to: directory.appendingPathComponent("clip.hypotheses.json"))
        XCTAssertEqual(persistedHypotheses(for: "clip").count, 0, "undecodable must read as empty so the fixture falls through to live transcription")
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
