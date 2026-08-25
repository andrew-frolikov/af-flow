import AVFoundation
import XCTest
@testable import AFFlow

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

    /// Where results are written, which is NOT where the audio is read from.
    ///
    /// The test host is the app, and the app is sandboxed. It can read fixture
    /// audio from an arbitrary folder but it cannot write back into one:
    /// attempting it fails with a bare `NSPOSIXErrorDomain Code=1`, which reads
    /// like a file-permissions mistake rather than what it is. Results
    /// therefore go somewhere inside the container, and `run-tests.sh` copies
    /// them out afterwards. Defaults to the fixtures directory so the ordinary
    /// in-repo case still behaves as before.
    private var outputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AF_FLOW_OUTPUT"] {
            return URL(fileURLWithPath: override)
        }
        return fixturesDirectory
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

    // MARK: - One definition of "complete", shared by capture and scoring

    /// The `(modelID, language)` pairs a complete capture must contain for one
    /// clip.
    ///
    /// **Why this exists, and it is the same class of bug this project keeps
    /// paying for.** Capture and scoring each carried their OWN definition of
    /// done, and the two disagreed. Capture asked "does a `.reference.txt`
    /// exist for this clip"; scoring asked "did every model and language
    /// produce a row". Neither predicate is wrong on its own. Together they
    /// left a hole with no floor: on 2026-07-22 the clip `ru-20260712-73d9fbc1`
    /// held 7 of its 8 required local rows, because
    /// `openai_whisper-large-v3_turbo_954MB` in `auto` returned no text, and
    /// **the repair window closed at the exact moment the input arrived.** The
    /// moment Andrew saved the references, capture would skip every clip and
    /// the missing row could never be filled, so scoring would fail forever on
    /// an incompleteness nothing could repair.
    ///
    /// The fix is not to widen one predicate. It is to delete one of them: both
    /// sides now read coverage from here, so they cannot drift apart again.
    /// The accompanying test asserts that they agree, which is what makes this
    /// a control rather than a convention.
    func requiredCoverage() -> [(modelID: String, language: String?)] {
        candidateModels
            .filter { SpeechModelCatalog.model(named: $0) != nil }
            .flatMap { name in languages.map { (modelID: name, language: $0) } }
    }

    /// The stable key for one `(modelID, language)` pair. Written once so the
    /// two sides cannot format it differently, which is exactly how the last
    /// pair of predicates drifted.
    static func coverageKey(modelID: String, language: String?) -> String {
        "\(modelID)|\(language ?? "auto")"
    }

    /// Which required pairs are absent for this clip, against THIS audio.
    ///
    /// Scoped by `audioSHA` deliberately: a transcript captured from different
    /// audio under the same name is not coverage, it is a stale row that would
    /// be scored against the new reference. Treating it as missing degrades to
    /// re-transcription rather than to a confident wrong number.
    func missingCoverage(for stem: String, audioSHA: String) -> [(modelID: String, language: String?)] {
        Self.missingCoverage(
            required: requiredCoverage(),
            present: persistedHypotheses(for: stem, audioSHA: audioSHA)
        )
    }

    /// The set arithmetic, split out with no filesystem and no environment so
    /// it can be tested directly. `fixturesDirectory` is resolved from an
    /// environment variable, so the instance method above cannot be pointed at
    /// a temporary directory from within a test, and an untested gate is how
    /// this project got here.
    static func missingCoverage(
        required: [(modelID: String, language: String?)],
        present: [PersistedHypothesis]
    ) -> [(modelID: String, language: String?)] {
        let keys = Set(present.map { coverageKey(modelID: $0.modelID, language: $0.language) })
        return required.filter { !keys.contains(coverageKey(modelID: $0.modelID, language: $0.language)) }
    }

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
        //
        // **Missing coverage is per PAIR, not per clip.** This used to read
        // `if persisted.isEmpty`, which treats a clip holding 7 of its 8
        // required rows as fully captured, scores it, and then fails the
        // completeness assertion at the end with nothing able to repair it.
        // A clip now contributes live work for exactly the pairs it lacks.
        var missingByFixture: [(fixture: Fixture, pairs: [(modelID: String, language: String?)])] = []
        for fixture in fixtures {
            let missing = missingCoverage(for: fixture.name, audioSHA: fixture.sha256)
            if !missing.isEmpty {
                missingByFixture.append((fixture: fixture, pairs: missing))
            }
            for entry in persistedHypotheses(for: fixture.name, audioSHA: fixture.sha256) {
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

        guard !missingByFixture.isEmpty else {
            try finish(rows: rows, skipped: skipped, fixtures: fixtures)
            return
        }

        for modelName in candidateModels {
            guard let descriptor = SpeechModelCatalog.model(named: modelName) else {
                skipped.append("\(modelName): not in the catalog on this OS")
                continue
            }

            // Do not pay for a model load nothing needs. Loading is the
            // expensive step, so the filter goes above it, not below.
            guard missingByFixture.contains(where: { $0.pairs.contains { $0.modelID == modelName } }) else {
                continue
            }

            let manager = ModelManager(modelName: modelName)
            if !manager.cachedModelNames.contains(modelName) && !downloadsAllowed {
                skipped.append("\(descriptor.pickerTitle): not cached, and AF_FLOW_ALLOW_MODEL_DOWNLOAD is not set")
                continue
            }

            for language in languages {
                let label = language ?? "auto"

                let needing = missingByFixture
                    .filter { entry in
                        entry.pairs.contains { $0.modelID == modelName && $0.language == language }
                    }
                    .map(\.fixture)
                guard !needing.isEmpty else { continue }

                await manager.loadModel(name: modelName, language: language)

                guard manager.isReady else {
                    skipped.append("\(descriptor.pickerTitle) [\(label)]: load failed, \(manager.error?.localizedDescription ?? "unknown")")
                    continue
                }

                for fixture in needing {
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

    /// Everything that makes this run a NARROWER comparison than it appears.
    ///
    /// These were all stdout `print` lines, and `run-tests.sh` filters stdout
    /// through a grep tuned to the happy path, so every one of them was
    /// invisible in practice. That is the same failure this project has now hit
    /// four times: a filter matching success turns a warning into silence.
    /// They go into `scores.md` itself, which survives any filter, and into the
    /// report a future session will read instead of the terminal.
    private func runCaveats(fixtures: [Fixture], rows: [ScoreRow]) -> [String] {
        var caveats: [String] = []

        // Clips with audio but no corrected reference are dropped from the
        // comparison entirely. Legitimate mid-correction, and invisible: the
        // report would look complete while covering two clips of five.
        if let unreferenced = try? audioWithoutReference(), !unreferenced.isEmpty {
            let names = unreferenced.map { $0.deletingPathExtension().lastPathComponent }
            caveats.append(
                "\(names.count) clip(s) have audio but NO corrected reference, so they are "
                + "not in this comparison at all: \(names.joined(separator: ", ")). "
                + "Scored \(fixtures.count) of \(fixtures.count + names.count) clips."
            )
        }

        // An override narrows the candidate set, and the completeness gate is
        // derived from that same set, so the gate narrows with it and a
        // one-model run passes as a full comparison.
        if let override = ProcessInfo.processInfo.environment["AF_FLOW_MODELS"] {
            caveats.append(
                "AF_FLOW_MODELS was set to \"\(override)\", so this run compared only those "
                + "models AND the completeness check was narrowed to match. This is not the "
                + "full four-model comparison C2 needs."
            )
        }

        // The incumbent answers the only question that decides whether Wispr
        // can be retired. Its absence must be stated, per clip.
        let incumbentFixtures = Set(
            rows.filter { $0.modelID == Self.incumbentModelID }.map(\.fixture)
        )
        let withoutIncumbent = fixtures.map(\.name).filter { !incumbentFixtures.contains($0) }
        if !withoutIncumbent.isEmpty {
            caveats.append(
                "No incumbent row for: \(withoutIncumbent.joined(separator: ", ")). "
                + "For those clips the beat-the-incumbent question is UNANSWERED, which is "
                + "the question that decides whether the paid app can be retired."
            )
        }

        return caveats
    }

    /// The incumbent's modelID, written once. It was a bare string literal at
    /// its only comparison site, which is how a rename becomes a silently
    /// missing baseline rather than a compile error.
    static let incumbentModelID = "wispr-qwen-http"

    /// Writes the report, then checks that the run actually MEASURED what it
    /// set out to measure.
    ///
    /// **The class of bug this closes, named because it produced two separate
    /// HIGH findings in one review.** Every guard added to this scorer defends
    /// against bad data: a mismatched hash is discarded, an undecodable file
    /// reads as empty, a failed transcription is skipped. All correct, and all
    /// silent. Nothing asserted that the data expected to be there WAS there,
    /// so a run could drop the incumbent baseline, or produce no rows at all,
    /// write a `scores.md` and exit green. Discarding is safe; discarding
    /// silently is not.
    ///
    /// So this declares what a complete run looks like and fails when it is
    /// not, rather than reporting whatever survived.
    private func finish(rows: [ScoreRow], skipped: [String], fixtures: [Fixture]) throws {
        // **Computed HERE, not passed in, and the parameter is deliberately
        // gone.** It was `caveats: [String] = []` with the value supplied at
        // the call sites, and there are two call sites: the normal one passed
        // `runCaveats(...)`, and the early return taken when every clip already
        // has full coverage passed nothing and silently defaulted to empty.
        //
        // That early return is the branch Andrew's REAL scoring run takes,
        // because coverage was completed on 2026-07-25. So the run that decides
        // which model AF Flow ships would have produced a `scores.md` with no
        // caveats block at all, and a report missing its warnings does not look
        // degraded, it looks clean. The specific warning being dropped is the
        // missing-incumbent line, which is the one that says whether the
        // "does AF Flow beat the app we are paying for" question was answered.
        //
        // Two call sites coordinating on a value is the same defect as two
        // predicates coordinating on a definition, which is what
        // `requiredCoverage()` exists to prevent. The fix is the same shape:
        // delete one of them. There is now nowhere to pass this from, so a
        // third exit path cannot forget to.
        let caveats = runCaveats(fixtures: fixtures, rows: rows)
        let report = Self.render(rows: rows, skipped: skipped, fixtures: fixtures, caveats: caveats)
        print(report)

        let reportURL = outputDirectory.appendingPathComponent("scores.md")
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)

        // The verbatim transcripts, written beside the scores rather than
        // inside them. See the note in `render()`: the scores file is read
        // whole by anyone who wants a number, and his speech should not be
        // carried along with it by default.
        if !rows.isEmpty {
            var transcripts = "# C2 transcripts\n\n"
            transcripts += "Verbatim engine output on Andrew's own recordings. This is raw personal\n"
            transcripts += "speech: it stays in this folder, which is outside every git repository\n"
            transcripts += "and outside the vault, per fixtures/README.md. Read it when comparing\n"
            transcripts += "what the engines heard; do not paste it anywhere.\n\n"
            for row in rows {
                transcripts += "**\(row.model) [\(row.language)] on \(row.fixture)**\n\n> \(row.hypothesis)\n\n"
            }
            let transcriptsURL = outputDirectory.appendingPathComponent("transcripts.md")
            try? transcripts.write(to: transcriptsURL, atomically: true, encoding: .utf8)
        }

        // No fixtures at all is a legitimate skip: Andrew has not written the
        // reference text yet. Fixtures WITH no scores is a failure.
        try XCTSkipIf(fixtures.isEmpty, "cannot verify: no fixtures with a corrected reference yet.")

        // **A narrowed run must not be able to PASS as a C2 verdict.**
        //
        // `AF_FLOW_MODELS` overrides the candidate list, and the completeness
        // gate is derived from that same list, so the gate narrows with it: a
        // one-model run satisfied "every required pair is present" trivially
        // and exited green with three of the four C2 models absent. Writing the
        // narrowing into the report as a caveat was the first fix and Codex was
        // right that it is not enough, because a caveat is prose and a green
        // exit is a verdict.
        //
        // Skip rather than fail: a narrowed run is a legitimate debugging tool.
        // It just cannot be the thing that closes C2. The report is already
        // written above, so the numbers survive; only the verdict is withheld.
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["AF_FLOW_MODELS"] != nil,
            """
            cannot verify full C2 coverage: AF_FLOW_MODELS narrowed the candidate set,
            and it narrows the completeness gate with it. scores.md was still written.
            Re-run without AF_FLOW_MODELS for a result that can close the chunk.
            """
        )

        XCTAssertFalse(
            rows.isEmpty,
            """
            FIXTURES EXIST BUT NOTHING WAS SCORED. This is a failed measurement, not a skip.
            \(skipped.map { "  - \($0)" }.joined(separator: "\n"))
            """
        )

        // Per fixture, name every engine that produced no row. A missing engine
        // is not a smaller table, it is a different comparison.
        for fixture in fixtures {
            let present = Set(
                rows.filter { $0.fixture == fixture.name }
                    .map { Self.coverageKey(modelID: $0.modelID, language: $0.language) }
            )
            // Read from the SAME definition the capture harness uses. These
            // were two hand-rolled loops that agreed by coincidence until they
            // did not; see `requiredCoverage()` for what that cost.
            let absent = requiredCoverage()
                .map { Self.coverageKey(modelID: $0.modelID, language: $0.language) }
                .filter { !present.contains($0) }
            XCTAssertTrue(
                absent.isEmpty,
                """
                \(fixture.name) was scored with engines MISSING, so this table is not the comparison it claims to be:
                \(absent.map { "  - \($0)" }.joined(separator: "\n"))

                REPAIR: run the capture test. It now targets exactly the missing
                pairs and no longer requires the reference to be absent, so this
                is fixable in place rather than only before the reference lands:
                  AF_FLOW_SCORING=1 AF_FLOW_FIXTURES=... ./scripts/run-tests.sh \\
                    -only-testing:AFFlowTests/TranscriptionScoringTests/testCaptureAllCandidateTranscriptsForUnreferencedAudio
                """
            )

            // NOTE: the per-clip incumbent check below is retained, but the
            // authoritative statement now lives in the report's CAVEATS block,
            // because a `print` here is filtered out of the wrapper's output.
            //
            // The incumbent is optional, because the archive script may not
            // have been run, but its ABSENCE must be stated rather than left
            // for the reader to notice. It is the row that answers whether
            // AF Flow beats the app it replaced.
            if !rows.contains(where: { $0.fixture == fixture.name && $0.modelID == Self.incumbentModelID }) {
                print("NOTE: \(fixture.name) has no incumbent row, so the beat-the-incumbent question is unanswered for it.")
            }
        }
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
            let draftURL = outputDirectory.appendingPathComponent("\(stem).draft-reference.txt")
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
        /// SHA256 of the audio this transcript was produced from. Optional so
        /// an incumbent row written in by a script without the hash still
        /// loads; such a row simply never matches a SHA filter.
        let fixtureSHA: String?
        /// `local` for a model this app runs, `incumbent` for a transcript
        /// carried in from the app being replaced. Only `local` entries are
        /// rewritten by a capture run, so an incumbent row survives re-capture.
        let source: String

        /// The engine ran and returned nothing.
        ///
        /// **A recorded answer, not a missing one, and the distinction is what
        /// lets C2 terminate.** Capture used to `continue` past an engine that
        /// produced no text, which left the pair permanently absent from
        /// coverage. Once coverage became the thing that gates completeness,
        /// that turned a deterministic failure into an infinite loop: the pair
        /// is required, capture can never produce it, and every run reports the
        /// clip incomplete forever. `turbo 954 [auto]` does exactly this on
        /// `ru-20260712-73d9fbc1`.
        ///
        /// It is also the honest score. An engine that returns nothing for 29
        /// seconds of speech has not been skipped, it has failed completely,
        /// and a 100 percent error rate is the correct entry in a table that
        /// decides which engine to ship. Silently omitting the row would let
        /// the worst possible result look like an absence of data.
        ///
        /// Detected from the text rather than stored as a flag, because a
        /// successful transcription is never empty and a second field could
        /// disagree with the first.
        var producedNoText: Bool {
            hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Runs the candidate models against every clip whose transcript coverage
    /// is INCOMPLETE, and writes the transcripts beside the audio.
    ///
    /// **The driver used to be "clips that have no reference yet", and that was
    /// a trap with no floor.** It meant the repair window closed at the exact
    /// moment the input arrived: once Andrew saved the five `.reference.txt`
    /// files, this test found nothing pending and skipped, so a clip that was
    /// missing one engine could never be completed, and the scoring run would
    /// fail forever on an incompleteness nothing could repair. That was live on
    /// 2026-07-22, one row short on `ru-20260712-73d9fbc1`.
    ///
    /// It is now driven by `missingCoverage(for:audioSHA:)`, the same
    /// definition the scoring assertion reads. That subsumes the old behaviour
    /// exactly: a clip with no transcripts at all is missing every pair, so it
    /// is captured in full as before. A clip missing one pair now captures one
    /// pair, which is the case that previously had no path at all.
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
        // Printed BEFORE the skip, deliberately. The first version of this
        // printed afterwards, so when the directory resolved to the wrong place
        // the test skipped in 0.029 seconds and the only signal that came back
        // was "TEST EXECUTE SUCCEEDED". A capture that silently did nothing was
        // indistinguishable from one that worked. The diagnostic has to come
        // before the guard it diagnoses.
        let allAudio = try audioFixtureURLs()
        print("fixtures directory: \(fixturesDirectory.path)")
        print("audio clips found: \(allAudio.count)")

        // Loaded before the pending check, because coverage is scoped to the
        // audio's SHA and there is no way to ask what is missing for a clip
        // without first knowing which audio it is.
        let clips = try allAudio.map { (url: $0, audio: try AudioFixtureLoader.load($0)) }

        var missingByStem: [String: [(modelID: String, language: String?)]] = [:]
        for clip in clips {
            let stem = clip.url.deletingPathExtension().lastPathComponent
            let missing = missingCoverage(for: stem, audioSHA: clip.audio.sha256)
            guard !missing.isEmpty else { continue }
            missingByStem[stem] = missing
            print("  \(stem): missing \(missing.count) of \(requiredCoverage().count) -> "
                + missing.map { Self.coverageKey(modelID: $0.modelID, language: $0.language) }.joined(separator: ", "))
        }
        let pending = clips.filter { missingByStem[$0.url.deletingPathExtension().lastPathComponent] != nil }
        print("clips with incomplete coverage: \(pending.count)")

        try XCTSkipIf(
            pending.isEmpty,
            """
            Every clip in \(fixturesDirectory.path) already has complete coverage,
            so there is nothing to capture. That is a legitimate no-op.
            If you expected work here, check that AF_FLOW_FIXTURES reached this
            process: `test-without-building` runs from a pre-generated
            .xctestrun, so TEST_RUNNER_ variables have to be set on the
            `build-for-testing` invocation that generates it, not on the run
            itself. `audio clips found: 0` above means the path is wrong.
            """
        )

        var captured: [String: [PersistedHypothesis]] = [:]
        var skipped: [String] = []

        for modelName in candidateModels {
            guard let descriptor = SpeechModelCatalog.model(named: modelName) else {
                skipped.append("\(modelName): not in the catalog on this OS")
                continue
            }

            // Do not pay for a model load nothing needs. A one-pair repair run
            // must not reload all four models, or the cheap path is not cheap
            // and the expensive path gets used instead.
            guard missingByStem.values.contains(where: { $0.contains { $0.modelID == modelName } }) else {
                continue
            }

            let manager = ModelManager(modelName: modelName)
            if !manager.cachedModelNames.contains(modelName) && !downloadsAllowed {
                skipped.append("\(descriptor.pickerTitle): not cached, and AF_FLOW_ALLOW_MODEL_DOWNLOAD is not set")
                continue
            }

            for language in languages {
                let label = language ?? "auto"

                let needing = pending.filter { clip in
                    let stem = clip.url.deletingPathExtension().lastPathComponent
                    return missingByStem[stem]?.contains {
                        $0.modelID == modelName && $0.language == language
                    } ?? false
                }
                guard !needing.isEmpty else { continue }

                await manager.loadModel(name: modelName, language: language)

                guard manager.isReady else {
                    skipped.append("\(descriptor.pickerTitle) [\(label)]: load failed, \(manager.error?.localizedDescription ?? "unknown")")
                    continue
                }

                for clip in needing {
                    let stem = clip.url.deletingPathExtension().lastPathComponent
                    let started = Date()
                    let hypothesis = await manager.transcribe(audioBuffer: clip.audio.samples, language: language)
                    let elapsed = Date().timeIntervalSince(started)

                    // An engine returning nothing is RECORDED, not skipped. See
                    // PersistedHypothesis.producedNoText: skipping it left the
                    // pair permanently uncoverable, so a deterministic failure
                    // became a run that could never complete. It is also the
                    // honest score, because returning nothing for real speech
                    // is the worst possible result rather than the absence of
                    // one.
                    let text = hypothesis ?? ""
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        skipped.append("\(descriptor.pickerTitle) [\(label)] on \(stem): RETURNED NO TEXT, recorded as a total failure")
                    }

                    captured[stem, default: []].append(PersistedHypothesis(
                        model: descriptor.pickerTitle,
                        modelID: modelName,
                        language: label,
                        hypothesis: text,
                        seconds: elapsed,
                        audioDuration: clip.audio.duration,
                        fixtureSHA: clip.audio.sha256,
                        source: "local"
                    ))
                    print(String(
                        format: "captured %@ [%@] on %@ in %.2fs%@",
                        descriptor.pickerTitle, label, stem, elapsed,
                        text.isEmpty ? "  <-- NO TEXT" : ""
                    ))
                }
            }
        }

        for (stem, entries) in captured {
            // **Upsert by coverage key, NOT "replace every local row".**
            //
            // The previous line was `persistedHypotheses(for: stem).filter
            // { $0.source != "local" }` plus the new entries, which is correct
            // only while a capture run always produces EVERY local row. The
            // moment capture became targeted, that line became a data-loss
            // path: repairing one missing pair would have written back one
            // local row and silently destroyed the other seven, turning a
            // one-row gap into a seven-row gap while printing "wrote".
            //
            // Keyed replacement has neither failure. Rows this run re-captured
            // are replaced; every other row on disk survives, including the
            // incumbent, whose key is never in the candidate set.
            let capturedKeys = Set(entries.map { Self.coverageKey(modelID: $0.modelID, language: $0.language) })
            let existing = persistedHypotheses(for: stem)
            let kept = existing.filter {
                !capturedKeys.contains(Self.coverageKey(modelID: $0.modelID, language: $0.language))
            }
            let merged = kept + entries

            // The invariant, ENFORCED rather than merely asserted: a capture may
            // add rows and may replace rows, and may never REDUCE what is on
            // disk. This is the canary for a future edit reverting to wholesale
            // replacement, which is the shape that just had to be fixed.
            //
            // It was an `XCTAssertGreaterThanOrEqual` and Codex was right that
            // this made it decorative. An XCTAssert RECORDS a failure and
            // returns; it does not stop the function. So the run went straight
            // on to `writeHypotheses` and destroyed the rows anyway, and the
            // only difference the guard made was a red test next to a truncated
            // file. A data-loss guard has to be control flow, not a report.
            guard merged.count >= existing.count else {
                throw CaptureWouldLoseRowsError(
                    stem: stem,
                    before: existing.count,
                    after: merged.count
                )
            }

            try writeHypotheses(merged, for: stem)
            print("wrote \(merged.count) transcripts to \(stem).hypotheses.json "
                + "(\(kept.count) kept, \(entries.count) captured this run)")
        }

        if !skipped.isEmpty {
            print("\nnot captured:\n" + skipped.map { "  - \($0)" }.joined(separator: "\n"))
        }

        XCTAssertFalse(
            captured.isEmpty,
            "No transcript was captured for any clip:\n" + skipped.map { "  - \($0)" }.joined(separator: "\n")
        )

        // **Capture worked out exactly which pairs it had to produce, and then
        // never checked that it produced them.** It reported whatever survived
        // and called that a run, which is the project's signature error aimed
        // at the one step whose entire job is filling gaps: a model that fails
        // to load, or a clip that errors, would leave the gap open and the run
        // would still exit green having printed "wrote".
        //
        // The list of required pairs is already computed above, so asserting
        // against it costs nothing and closes the loop.
        for (stem, wanted) in missingByStem.sorted(by: { $0.key < $1.key }) {
            let produced = Set(
                (captured[stem] ?? []).map { Self.coverageKey(modelID: $0.modelID, language: $0.language) }
            )
            let stillMissing = wanted
                .map { Self.coverageKey(modelID: $0.modelID, language: $0.language) }
                .filter { !produced.contains($0) }
            XCTAssertTrue(
                stillMissing.isEmpty,
                """
                \(stem): capture set out to produce \(wanted.count) pair(s) and did not produce all of them.
                Still missing:
                \(stillMissing.map { "  - \($0)" }.joined(separator: "\n"))
                Reasons reported by this run:
                \(skipped.isEmpty ? "  (none reported, which is itself the bug)" : skipped.map { "  - \($0)" }.joined(separator: "\n"))
                """
            )
        }
    }

    /// Written to the output directory, which under the sandbox is inside the
    /// app container. READ from the fixtures directory, which is where the
    /// wrapper copies results and where a corrected reference lives.
    ///
    /// These were the same URL until Codex round 2. That meant a scoring run
    /// read hypotheses out of a REUSABLE container temp directory rather than
    /// from the fixtures beside the audio, so a previous run's leftovers could
    /// be scored as if they were current. Two different jobs, two directories.
    private func hypothesesWriteURL(for stem: String) -> URL {
        outputDirectory.appendingPathComponent("\(stem).hypotheses.json")
    }

    private func hypothesesReadURL(for stem: String) -> URL {
        fixturesDirectory.appendingPathComponent("\(stem).hypotheses.json")
    }

    /// Returns only entries captured from THIS EXACT audio.
    ///
    /// Each entry records the SHA256 of the clip it was produced from. Without
    /// that, any non-empty file suppressed live transcription, so re-recording
    /// a fixture under the same name would silently score the OLD transcripts
    /// against the NEW reference and report it as a measurement. Entries with a
    /// missing or mismatched SHA are discarded, which degrades to live
    /// transcription rather than to a confident wrong number.
    func persistedHypotheses(for stem: String, audioSHA: String? = nil) -> [PersistedHypothesis] {
        guard let data = try? Data(contentsOf: hypothesesReadURL(for: stem)) else { return [] }
        guard let entries = try? JSONDecoder().decode([PersistedHypothesis].self, from: data) else { return [] }
        guard let audioSHA else { return entries }
        return entries.filter { $0.fixtureSHA == audioSHA }
    }

    private func writeHypotheses(_ entries: [PersistedHypothesis], for stem: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: hypothesesWriteURL(for: stem), options: .atomic)
    }

    /// Every audio clip in the fixtures directory, referenced or not.
    ///
    /// Split out from `audioWithoutReference()` because the two callers want
    /// genuinely different sets and used to share one. Draft generation wants
    /// clips with no reference, because producing a draft for a clip that
    /// already has a corrected reference would be pointless. Capture wants ALL
    /// clips, because transcript coverage and reference existence are unrelated
    /// facts, and conflating them is what closed the repair window.
    func audioFixtureURLs() throws -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fixturesDirectory.path) else { return [] }
        let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aiff", "caf"]
        return try manager.contentsOfDirectory(at: fixturesDirectory, includingPropertiesForKeys: nil)
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func audioWithoutReference() throws -> [URL] {
        let manager = FileManager.default
        return try audioFixtureURLs().filter {
            let stem = $0.deletingPathExtension().lastPathComponent
            return !manager.fileExists(
                atPath: fixturesDirectory.appendingPathComponent("\(stem).reference.txt").path
            )
        }
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

    /// The four scoring defects an independent audit confirmed on 2026-07-24,
    /// each pinned by the case that exposed it.
    ///
    /// Grouped deliberately: all four share one shape, which is a metric that
    /// reports SUCCESS when it has measured nothing. That is this project's
    /// signature error moved from the guards into the arithmetic, and it was
    /// live on the real fixtures on the day Andrew was asked to correct them.
    func testMetricsNeverReportSuccessWhenNothingWasMeasured() {
        // 1. A reference with NO punctuation. Two of the five real drafts were
        //    like this, one across 58 words. Dividing by a zero mark count
        //    returned 0.0 percent, a flawless score, for every engine and for
        //    the cloud incumbent, on the metric he ranked second.
        let noPunctuation = TextScoring.punctuationErrorRate(
            hypothesis: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043C}\u{0438}\u{0440}!",
            reference: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}"
        )
        XCTAssertFalse(noPunctuation.isMeasurable)
        XCTAssertTrue(
            noPunctuation.percent.hasPrefix("n/a"),
            "a zero denominator must never print as a percentage, got \(noPunctuation.percent)"
        )

        // 2. An EMPTY reference, which is how this task starts if the file is
        //    created before the text is pasted in. Every metric divided by
        //    zero at once and the whole clip read as nine engines tied at
        //    perfect. loadFixtures now refuses it outright; this pins the
        //    arithmetic underneath so the two cannot drift apart.
        let empty = TextScoring.inflectionDiagnostic(
            hypothesis: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}",
            reference: ""
        )
        XCTAssertEqual(empty.verdict, "not measurable", "an empty reference is not a clean transcript")
        XCTAssertTrue(empty.wer.percent.hasPrefix("n/a"))
        XCTAssertTrue(empty.cer.percent.hasPrefix("n/a"))

        // 3. THE EXACT CASE THIS METRIC WAS WRITTEN FOR, which it failed.
        //    In the C1 clip "prompt" survived in Latin script once and was
        //    Cyrillicised elsewhere in the same utterance. Set membership saw
        //    one survivor and reported the term fully preserved, so the
        //    code-switching metric scored a clean pass on the only failure it
        //    was built to detect.
        let terms = TextScoring.latinTermsPreserved(
            hypothesis: "\u{044F} \u{0445}\u{043E}\u{0447}\u{0443} prompt \u{0438} \u{0435}\u{0449}\u{0435} \u{043F}\u{0440}\u{043E}\u{043C}\u{043F}\u{0443}\u{0442}",
            reference: "\u{044F} \u{0445}\u{043E}\u{0447}\u{0443} prompt \u{0438} \u{0435}\u{0449}\u{0435} prompt"
        )
        XCTAssertEqual(terms.expected.count, 2)
        XCTAssertEqual(terms.missing, ["prompt"], "one occurrence lost of two must count as one lost")
        XCTAssertEqual(terms.preserved, 1)

        // 4. An ellipsis is ONE sentence ending, not three. This metric reports
        //    a DIRECTION, merged versus split, and it is the project's
        //    most-confirmed defect, so a miscount here manufactures evidence
        //    for the finding the whole voice layer is being designed around.
        XCTAssertEqual(TextScoring.boundaryCount(in: "\u{0410}... \u{0411}."), 2)
        let ellipsis = TextScoring.sentenceBoundaries(
            hypothesis: "\u{0410}... \u{0411}.",
            reference: "\u{0410}. \u{0411}."
        )
        XCTAssertEqual(ellipsis.delta, 0)
        XCTAssertEqual(ellipsis.verdict, "matches", "spelling a pause as an ellipsis is not a split sentence")

        // The genuine merge case must still be detected, or fixing the false
        // positive would have removed the signal along with the noise.
        let merged = TextScoring.sentenceBoundaries(
            hypothesis: "\u{0410} \u{0411} \u{0412}.",
            reference: "\u{0410}. \u{0411}. \u{0412}."
        )
        XCTAssertEqual(merged.verdict, "merged 2")
    }

    /// **The class, not the instance.** Every metric in this pipeline divides
    /// by something derived from the reference, and every one of them returned
    /// a value that reads as GOOD when the reference had nothing to divide by.
    ///
    /// Four separate sites, found across two Codex rounds and one audit, each
    /// fixed on its own before anyone noticed they were one bug: `Rate` printed
    /// 0.0 percent, `BoundaryCount` printed "matches", `TermPreservation`
    /// printed 0/0, and `realtimeFactor` printed 0.00x, which is the fastest
    /// value there is. Fixing them one at a time is what let the fourth ship.
    ///
    /// This test takes a fully degenerate row, empty reference and zero
    /// duration, and asserts that NOTHING in the rendered output reads as a
    /// result. It is deliberately written against the rendered strings rather
    /// than the properties, because the rendered string is what Andrew decides
    /// on, and it will fail on a fifth site that nobody thought to add a
    /// property for.
    func testNoMetricReportsAGoodValueForAnUnmeasurableInput() {
        let empty = ""
        let hypothesis = "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440} prompt"

        let row = ScoreRow(
            model: "M", modelID: "m", language: "ru", fixture: "clip",
            hypothesis: hypothesis,
            wer: TextScoring.wordErrorRate(hypothesis: hypothesis, reference: empty),
            cer: TextScoring.characterErrorRate(hypothesis: hypothesis, reference: empty),
            punctuation: TextScoring.punctuationErrorRate(hypothesis: hypothesis, reference: empty),
            boundaries: TextScoring.sentenceBoundaries(hypothesis: hypothesis, reference: empty),
            missingSpaces: TextScoring.missingSpaceAfterPeriod(in: hypothesis),
            latinTerms: TextScoring.latinTermsPreserved(hypothesis: hypothesis, reference: empty),
            seconds: 1.5,
            audioDuration: 0
        )

        // Each rendered cell, named, so a failure says WHICH one regressed.
        let cells: [(String, String)] = [
            ("WER", row.wer.percent),
            ("CER", row.cer.percent),
            ("punctuation", row.punctuation.percent),
            ("boundaries", row.boundaries.verdict),
            ("latin terms", row.latinTerms.summary),
            ("realtime factor", row.realtimeFactorSummary),
            ("errors are", TextScoring.inflectionDiagnostic(hypothesis: hypothesis, reference: empty).summary),
        ]

        for (name, rendered) in cells {
            XCTAssertTrue(
                rendered == "n/a" || rendered.hasPrefix("n/a") || rendered == "not measurable",
                """
                \(name) rendered "\(rendered)" for a reference with nothing to measure.

                Every metric here divides by something derived from the reference.
                When the reference is empty the answer is "not measurable", never a
                number, and never a word like "matches" that reads as success. This
                has now been fixed four separate times as four separate bugs; if you
                are reading this because it failed, you have found the fifth.
                """
            )
        }

        // And the inverse, so the fix did not simply blank the report: a real
        // reference must still produce real numbers.
        let real = "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043C}\u{0438}\u{0440}. prompt"
        XCTAssertTrue(TextScoring.wordErrorRate(hypothesis: hypothesis, reference: real).percent.hasSuffix("%"))
        XCTAssertTrue(TextScoring.punctuationErrorRate(hypothesis: hypothesis, reference: real).percent.hasSuffix("%"))
        XCTAssertEqual(TextScoring.latinTermsPreserved(hypothesis: hypothesis, reference: real).summary, "1/1")
        XCTAssertNotEqual(TextScoring.sentenceBoundaries(hypothesis: hypothesis, reference: real).verdict, "n/a")
    }

    /// The coverage arithmetic, which is now the single definition of "this
    /// clip is fully captured" that both the capture harness and the scoring
    /// assertion read.
    ///
    /// **This test exists because the bug it guards was live and unrepairable.**
    /// On 2026-07-22 `ru-20260712-73d9fbc1` held 7 of its 8 required local rows.
    /// Capture asked "does a reference exist" and scoring asked "did every
    /// engine produce a row", and because those are different questions the
    /// clip was simultaneously "done" to one side and "incomplete" to the
    /// other, with no code path able to move it. The partial case is therefore
    /// the case this test is built around; a clip with nothing and a clip with
    /// everything were never the hard part.
    func testPartialCoverageIsReportedAsIncomplete() {
        let required: [(modelID: String, language: String?)] = [
            (modelID: "turbo632", language: nil),
            (modelID: "turbo632", language: "ru"),
            (modelID: "turbo954", language: nil),
            (modelID: "turbo954", language: "ru"),
        ]

        func row(_ modelID: String, _ language: String) -> PersistedHypothesis {
            PersistedHypothesis(
                model: modelID, modelID: modelID, language: language,
                hypothesis: "x", seconds: 1, audioDuration: 1,
                fixtureSHA: "sha", source: "local"
            )
        }

        // Nothing captured: everything is missing. The old predicate got this
        // one right, which is why the bug survived.
        XCTAssertEqual(
            Self.missingCoverage(required: required, present: []).count,
            4
        )

        // Everything captured: nothing is missing.
        let complete = [row("turbo632", "auto"), row("turbo632", "ru"),
                        row("turbo954", "auto"), row("turbo954", "ru")]
        XCTAssertTrue(Self.missingCoverage(required: required, present: complete).isEmpty)

        // THE CASE THAT BROKE. Three of four present. A predicate asking only
        // "is this empty" calls this complete; this one names the gap.
        let partial = [row("turbo632", "auto"), row("turbo632", "ru"), row("turbo954", "ru")]
        let missing = Self.missingCoverage(required: required, present: partial)
        XCTAssertEqual(missing.count, 1, "a clip missing one engine must not read as captured")
        XCTAssertEqual(
            missing.map { Self.coverageKey(modelID: $0.modelID, language: $0.language) },
            ["turbo954|auto"]
        )

        // The incumbent is not a candidate model, so it can never satisfy
        // coverage and can never be mistaken for a local row.
        let incumbentOnly = [PersistedHypothesis(
            model: "Wispr Flow (cloud incumbent)", modelID: "wispr-qwen-http", language: "ru",
            hypothesis: "x", seconds: 1, audioDuration: 1, fixtureSHA: "sha", source: "incumbent"
        )]
        XCTAssertEqual(
            Self.missingCoverage(required: required, present: incumbentOnly).count,
            4,
            "an incumbent row must not be counted as coverage of a candidate model"
        )

        // The `nil` language and the string "auto" are the SAME pair. They are
        // written differently on the two sides of the pipeline, and one
        // formatting difference here is the whole class of bug this replaced.
        XCTAssertEqual(
            Self.coverageKey(modelID: "m", language: nil),
            Self.coverageKey(modelID: "m", language: "auto")
        )
    }

    /// The WER-to-CER reading, which is the number that decides which model
    /// AF Flow runs, so it gets known-answer cases rather than trust.
    ///
    /// **The assertion that matters is the last one.** Both cases below score
    /// an identical WER of 100 percent, so WER cannot tell them apart, and the
    /// raw "WER minus CER gap" the report used to recommend cannot either: both
    /// have a large gap, because a Russian word is five or six characters and
    /// that alone makes CER smaller. Only the normalised share separates
    /// "wrong ending" from "wrong word", and separating them is the entire C2
    /// question.
    func testInflectionDiagnosticSeparatesEndingsFromWrongWords() {
        // 11 words, 68 characters after normalisation. Deliberately a realistic
        // sentence rather than a two-word toy: with 2 words the share can only
        // land on a few values and the thresholds sit inside the rounding.
        let reference = "\u{043F}\u{043E}\u{043C}\u{0435}\u{043D}\u{044F}\u{0442}\u{044C} \u{0438}\u{043D}\u{0442}\u{0435}\u{0440}\u{0444}\u{0435}\u{0439}\u{0441} \u{043F}\u{0440}\u{0438}\u{043B}\u{043E}\u{0436}\u{0435}\u{043D}\u{0438}\u{044F} \u{0438} \u{0442}\u{0430}\u{043A}\u{0436}\u{0435} \u{043E}\u{0442}\u{0432}\u{0435}\u{0442}\u{044C} \u{043C}\u{043E}\u{0436}\u{0435}\u{043C} \u{043B}\u{0438} \u{043C}\u{044B} \u{044D}\u{0442}\u{043E} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C}"

        // Right words, wrong endings. BOTH errors here are real, dated
        // observations from his own dictation on 2026-07-20, recorded in
        // voice-observations.md: a genitive lost after a verb, and an
        // imperative flattened to an infinitive. Not invented strings.
        let endings = TextScoring.inflectionDiagnostic(
            hypothesis: "\u{043F}\u{043E}\u{043C}\u{0435}\u{043D}\u{044F}\u{0442}\u{044C} \u{0438}\u{043D}\u{0442}\u{0435}\u{0440}\u{0444}\u{0435}\u{0439}\u{0441} \u{043F}\u{0440}\u{0438}\u{043B}\u{043E}\u{0436}\u{0435}\u{043D}\u{0438}\u{0435} \u{0438} \u{0442}\u{0430}\u{043A}\u{0436}\u{0435} \u{043E}\u{0442}\u{0432}\u{0435}\u{0442}\u{0438}\u{0442}\u{044C} \u{043C}\u{043E}\u{0436}\u{0435}\u{043C} \u{043B}\u{0438} \u{043C}\u{044B} \u{044D}\u{0442}\u{043E} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C}",
            reference: reference
        )

        // **Exactly the same two words wrong, but wrong by SUBSTITUTION rather
        // than by inflection.** This is the "\u{0432}\u{0435}\u{0440}\u{0438}\u{043B}\u{0438}\u{0441}\u{044C}" class from 2026-07-20,
        // where a real Russian word replaces a different real Russian word and
        // the sentence stops meaning anything. No dictionary can reach it,
        // because both words are legitimate elsewhere.
        //
        // The pairing is the point: WER is IDENTICAL to the case above, 2 words
        // of 11, so WER cannot tell these two apart and neither can a raw
        // WER-minus-CER gap. Only the normalised share can.
        let substitution = TextScoring.inflectionDiagnostic(
            hypothesis: "\u{043F}\u{043E}\u{043C}\u{0435}\u{043D}\u{044F}\u{0442}\u{044C} \u{0438}\u{043D}\u{0442}\u{0435}\u{0440}\u{0444}\u{0435}\u{0439}\u{0441} \u{043A}\u{0430}\u{0440}\u{0442}\u{043E}\u{0448}\u{043A}\u{0430} \u{0438} \u{0442}\u{0430}\u{043A}\u{0436}\u{0435} \u{0437}\u{0430}\u{0431}\u{0443}\u{0434}\u{044C} \u{043C}\u{043E}\u{0436}\u{0435}\u{043C} \u{043B}\u{0438} \u{043C}\u{044B} \u{044D}\u{0442}\u{043E} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C}",
            reference: reference
        )

        XCTAssertEqual(endings.referenceWords, 11)
        XCTAssertEqual(endings.referenceCharacters, 68)
        XCTAssertEqual(endings.inflectionFloor, 11.0 / 68.0, accuracy: 0.0001)
        XCTAssertEqual(endings.substitutionCeiling, 58.0 / 68.0, accuracy: 0.0001)

        // Hand-computed, then independently reproduced before being written
        // down, because an expected value nobody checked is not a known answer.
        // endings: WER 2/11, CER 3/68, ratio 0.24, share 0.12.
        // substitution: WER 2/11, CER 14/68, ratio 1.13, clamped share 1.00.
        XCTAssertEqual(endings.wer.errors, 2)
        XCTAssertEqual(endings.cer.errors, 3)
        XCTAssertEqual(substitution.wer.errors, 2)
        XCTAssertEqual(substitution.cer.errors, 14)

        XCTAssertEqual(endings.substitutionShare, 0.117, accuracy: 0.01)
        XCTAssertEqual(endings.verdict, "endings")

        XCTAssertEqual(substitution.substitutionShare, 1.0, accuracy: 0.01)
        XCTAssertEqual(substitution.verdict, "wrong words")

        // The clamp fires here and must stay VISIBLE: the raw ratio exceeds the
        // ceiling because the replacement words differ in length from the ones
        // they replaced. Reporting only the clamped share would hide that.
        XCTAssertGreaterThan(substitution.ratio, substitution.substitutionCeiling)

        // A clean transcript must not be reported as a defect.
        let perfect = TextScoring.inflectionDiagnostic(hypothesis: reference, reference: reference)
        XCTAssertEqual(perfect.verdict, "no errors")
        XCTAssertEqual(perfect.substitutionShare, 0)

        // THE POINT, and the reason this metric exists at all. IDENTICAL WER,
        // opposite diagnosis. If this assertion ever fails, the report has gone
        // back to being numbers nobody can act on, and the C2 model decision
        // goes back to being a guess.
        XCTAssertEqual(
            endings.wer.value,
            substitution.wer.value,
            accuracy: 0.0001,
            "the pair must be WER-matched or it proves nothing"
        )
        XCTAssertLessThan(endings.substitutionShare, substitution.substitutionShare)
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
            hypothesis: "one", seconds: 0.6, audioDuration: 30,
            fixtureSHA: "abc123", source: "incumbent"
        )
        let local = PersistedHypothesis(
            model: "Turbo", modelID: "turbo", language: "ru",
            hypothesis: "two", seconds: 1.2, audioDuration: 30,
            fixtureSHA: "abc123", source: "local"
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
        // Transcripts captured from DIFFERENT audio must not be scored as if
        // they described this clip. Re-recording a fixture under the same name
        // would otherwise score the old transcripts against the new reference
        // and report it as a measurement. Codex round 2, finding 1.
        XCTAssertEqual(persistedHypotheses(for: "clip", audioSHA: "abc123").count, 2)
        XCTAssertEqual(
            persistedHypotheses(for: "clip", audioSHA: "DIFFERENT").count, 0,
            "hypotheses from other audio must be discarded, falling back to live transcription"
        )

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

    /// Thrown, not asserted, because the write happens on the next line and an
    /// XCTAssert does not stop it.
    struct CaptureWouldLoseRowsError: Error, CustomStringConvertible {
        let stem: String
        let before: Int
        let after: Int

        var description: String {
            """
            REFUSING TO WRITE \(stem).hypotheses.json: the merge would reduce it
            from \(before) rows to \(after).

            A capture adds rows or replaces them. It never removes them. This is
            the wholesale-replacement bug returning, and the file on disk is
            still intact because nothing was written.
            """
        }
    }

    /// Thrown rather than skipped, so the run stops at the input instead of
    /// reporting a perfect score against nothing.
    struct EmptyReferenceError: Error, CustomStringConvertible {
        let stem: String
        let path: String

        var description: String {
            """
            \(stem).reference.txt exists but is EMPTY.

            An empty reference is not a perfect transcription, it is an
            unusable input. Scoring against it would divide by zero in every
            metric and report every engine at 0.0 percent error.

            Either paste the corrected text into it, or delete the file so the
            clip is treated as not yet corrected.
              \(path)
            """
        }
    }

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

        /// The same zero-denominator shape a fourth time, now in the speed
        /// column: a zero or missing `audioDuration` rendered `0.00x`, which is
        /// the FASTEST possible value and therefore the most flattering one a
        /// model could be given for a measurement that never happened.
        ///
        /// **Stop patching instances.** This is the fourth site in two files:
        /// `Rate`, `BoundaryCount`, `TermPreservation` and here. Every one
        /// divides by something derived from the input and every one returned a
        /// value that reads as good when the input was absent. They are covered
        /// together by `testNoMetricReportsAGoodValueForAnUnmeasurableInput`,
        /// which is written to fail if a FIFTH is ever added.
        var isSpeedMeasurable: Bool { audioDuration > 0 }
        var realtimeFactor: Double { audioDuration <= 0 ? 0 : seconds / audioDuration }
        var realtimeFactorSummary: String {
            isSpeedMeasurable ? String(format: "%.2fx", realtimeFactor) : "n/a"
        }
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

                // **An empty reference is a broken input, not a perfect one,
                // and every gate in this file used to pass it.** The guard
                // above checks that the FILE EXISTS, which is not the same as
                // the reference being present: a zero-byte or whitespace-only
                // `.reference.txt` produced `total == 0` in every Rate, and
                // `Rate.value` returned 0 for a zero denominator, so WER, CER
                // and punctuation all printed 0.0 percent. Nine engines tied at
                // a flawless score on a clip nobody had corrected, `scores.md`
                // written, exit zero.
                //
                // Reachable by ordinary use: creating the file before pasting
                // into it, or saving an empty buffer, is exactly how someone
                // starts this task. He is creating five of these by hand today.
                guard !reference.isEmpty else {
                    throw EmptyReferenceError(stem: stem, path: referenceURL.path)
                }

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

    static func render(
        rows: [ScoreRow],
        skipped: [String],
        fixtures: [Fixture],
        caveats: [String] = []
    ) -> String {
        var out = "# C2 model scores\n\n"
        out += "Generated by TranscriptionScoringTests. WER and CER are punctuation-blind\n"
        out += "and case-folded; punctuation and boundaries are measured separately, because\n"
        out += "averaging them into one number hides exactly the defects C2 exists to fix.\n\n"

        // FIRST, before any number. Everything here makes the table below a
        // narrower comparison than it looks, and all of it used to be a stdout
        // line that the test wrapper's grep filtered away.
        if !caveats.isEmpty {
            out += "## READ THIS BEFORE THE NUMBERS\n\n"
            for caveat in caveats { out += "- \(caveat)\n" }
            out += "\n"
        }

        out += "## Fixture manifest\n\n"
        out += "| Fixture | Duration | Source rate | Reference words | Punct marks | SHA256 |\n"
        out += "|---|---|---|---|---|---|\n"
        for fixture in fixtures {
            // Reference shape is in the manifest because an empty or truncated
            // reference is the failure mode that scores every engine perfect,
            // and the manifest was the one place a reader would have looked.
            let words = fixture.reference.split(separator: " ").count
            let marks = fixture.reference.filter { TextScoring.isPunctuation($0) }.count
            out += "| \(fixture.name) | \(String(format: "%.1fs", fixture.duration)) | \(String(format: "%.0f Hz", fixture.sourceSampleRate)) | \(words) | \(marks)\(marks == 0 ? " **NONE**" : "") | `\(fixture.sha256.prefix(16))` |\n"
        }

        if !rows.isEmpty {
            var referenceByFixture: [String: String] = [:]
            for fixture in fixtures { referenceByFixture[fixture.name] = fixture.reference }

            out += "\n## Scores\n\n"
            out += "| Model | Lang | Fixture | WER | CER | Errors are | Punct | Boundaries | No-space | Latin terms | Time | RTF |\n"
            out += "|---|---|---|---|---|---|---|---|---|---|---|---|\n"
            for row in rows {
                let errorKind = referenceByFixture[row.fixture].map {
                    TextScoring.inflectionDiagnostic(hypothesis: row.hypothesis, reference: $0).summary
                } ?? "n/a"
                out += "| \(row.model) | \(row.language) | \(row.fixture) | \(row.wer.percent) | \(row.cer.percent) | \(errorKind) | \(row.punctuation.percent) | \(row.boundaries.hypothesis)/\(row.boundaries.reference) \(row.boundaries.verdict) | \(row.missingSpaces) | \(row.latinTerms.summary) | \(String(format: "%.2fs", row.seconds)) | \(row.realtimeFactorSummary) |\n"
            }

            out += "\n### How to read this\n\n"
            out += "- **Errors are** is the WER-to-CER reading, and it is the column to read\n"
            out += "  first. It is a share from 0.00 to 1.00: **0 means every error is a wrong\n"
            out += "  ENDING on a correctly heard word, 1 means every error is a completely\n"
            out += "  different word.** Endings are the Russian inflection problem, they need a\n"
            out += "  better acoustic model, and neither the dictionary nor the cleanup prompt\n"
            out += "  can touch them. Wrong words are much cheaper to attack.\n"
            out += "- **Do not read the raw WER minus CER gap.** This report used to tell you\n"
            out += "  to, and it was wrong. CER is smaller than WER for a reason that has\n"
            out += "  nothing to do with quality: a Russian word is five or six characters, so\n"
            out += "  every error is a smaller share of characters than of words. Every model\n"
            out += "  shows a large gap, always, including one whose every error is a different\n"
            out += "  word. The share above normalises that away by computing both endpoints\n"
            out += "  from the reference itself.\n"
            out += "- **Boundaries** is hypothesis over reference. \"merged N\" is the predicted\n"
            out += "  defect, already confirmed three independent ways.\n"
            out += "- **Latin terms** is the code-switching test. Lost terms mean the model\n"
            out += "  Cyrillicised English vocabulary, the failure his register hits hardest\n"
            out += "  however good WER looks.\n"
            out += "- **RTF** is transcription time over audio duration, and it feeds the empty\n"
            out += "  latency actuals table. Under 1.0 is faster than real time.\n"

            // **The transcripts do NOT go in this file.** They used to, and
            // that put roughly forty verbatim renderings of Andrew's private
            // speech into the one artefact a future session reads wholesale to
            // find the numbers. `fixtures/README.md` is explicit that derived
            // lessons may travel and raw rows never do, and this was the single
            // largest hole in that rule: not a leak out of the machine, but a
            // file designed to be read into a context window in full, every
            // time anyone wants a WER figure.
            //
            // Found by reading the report during a dry run rather than by
            // review, which is its own small lesson: the privacy shape of an
            // artefact is visible when you look at the artefact, not when you
            // look at the code that writes it.
            //
            // They still get written, because comparing what the engines
            // actually heard is the whole point of a correction pass. They go
            // beside it, so reading the scores is not the same act as reading
            // his speech.
            out += "\n## Transcripts\n\n"
            out += "Not here, deliberately. See `transcripts.md` in the same folder.\n"
            out += "This file is read whole by anyone wanting the numbers, and his\n"
            out += "verbatim speech does not belong in something read that casually.\n"
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
