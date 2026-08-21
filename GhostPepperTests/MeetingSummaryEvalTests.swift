import CryptoKit
import XCTest
@testable import GhostPepper

/// Measures how much a meeting summary invents, over Andrew's REAL transcripts,
/// against the REAL local model.
///
/// WHY IT IS OPT-IN AND WHY IT READS FROM OUTSIDE THE REPO. The eval corpus is his
/// own meetings, including personal conversations. Those transcripts are the only material
/// that reproduces the defect, and none of them may ever land in git. So the corpus
/// is a directory named by `AF_FLOW_MEETING_NOTES`, and this file contains no meeting
/// content at all.
///
/// WHY A SKIP IS SHOUTED ABOUT. On 2026-08-21 a missing name in `run-tests.sh`'s env
/// list made a test skip, and the skip read as a pass. Both env names below are
/// forwarded by `scripts/run-tests.sh`; if a run reports nothing here, the run
/// measured nothing.
///
/// Run it:
///     AF_FLOW_SUMMARY_EVALS=1 \
///     AF_FLOW_MEETING_NOTES="$HOME/Claude/AndrewFrolikov OS/Meetings" \
///     ./scripts/run-tests.sh -only-testing:GhostPepperTests/MeetingSummaryEvalTests
final class MeetingSummaryEvalTests: XCTestCase {

    struct Note {
        let name: String
        let transcript: String
        /// What he typed during the meeting. The prompt explicitly lets the model use
        /// facts from the notes, so they are part of the support set as well as part
        /// of the input. Codex, 2026-08-21: checking a summary against the transcript
        /// alone counts a note-only fact as invented.
        let notes: String
        let segments: [TranscriptSegment]
    }

    // MARK: - Gates

    private func requireOptIn() throws {
        // SELF-GATED rather than relying on run-tests.sh to skip the class by name.
        // A test whose safety lives in its caller is unsafe the moment anyone runs it
        // from Xcode's UI, and this one loads a multi-gigabyte model.
        guard ProcessInfo.processInfo.environment["AF_FLOW_SUMMARY_EVALS"] == "1" else {
            throw XCTSkip("""
            Summary evals load a real local model and read Andrew's real meetings.
            Set AF_FLOW_SUMMARY_EVALS=1 and AF_FLOW_MEETING_NOTES to run them.
            """)
        }
    }

    private func requireCorpus() throws -> [Note] {
        guard let directory = ProcessInfo.processInfo.environment["AF_FLOW_MEETING_NOTES"], !directory.isEmpty else {
            throw XCTSkip("AF_FLOW_MEETING_NOTES must point at a directory of meeting markdown files.")
        }
        let notes = Self.loadNotes(in: directory)
        // Not a skip. Opting in and then measuring nothing is the failure this
        // project keeps paying for, and it must be red rather than green.
        XCTAssertFalse(notes.isEmpty, """
        AF_FLOW_MEETING_NOTES=\(directory) held no meeting file with a ## Transcript section,
        so this run measured nothing. That must not pass.
        """)
        return notes
    }

    /// Which prompt this run measures.
    ///
    /// BEFORE AND AFTER IN ONE PAIR OF RUNS, with no source edit between them. The
    /// superseded prompt is kept in the generator for the stored-prompt migration, so
    /// pointing the eval at it costs nothing and removes the temptation to measure
    /// "before" by editing the file and remembering to put it back.
    ///
    ///     AF_FLOW_SUMMARY_EVAL_PROMPT=superseded   the prompt that named example headings
    ///     (unset)                                   what the app ships today
    private func promptUnderTest() -> String {
        if ProcessInfo.processInfo.environment["AF_FLOW_SUMMARY_EVAL_PROMPT"] == "superseded" {
            return MeetingSummaryGenerator.supersededSummaryPromptWithExampleHeadings
        }
        return MeetingSummaryGenerator.finalSummaryPrompt
    }

    /// Meetings run to 146 KB of transcript, which is about thirty LLM calls each on
    /// the 0.8B. The eval runs with AF Flow quit, so its wall clock is time Andrew has
    /// no dictation, and a two-hour measurement is not a measurement he can afford.
    /// Each transcript is capped, and the cap is REPORTED rather than applied quietly:
    /// a bound nobody is told about reads as full coverage.
    private func transcriptCharacterCap() -> Int {
        if let raw = ProcessInfo.processInfo.environment["AF_FLOW_SUMMARY_EVAL_MAX_CHARS"],
           let value = Int(raw), value > 0 {
            return value
        }
        return 20_000
    }

    private func modelKind() -> LocalCleanupModelKind {
        // The summariser runs on whatever the cleanup manager is set to, which is the
        // 0.8B. The ladder above it is what an escalation would measure, so the model
        // is a parameter of the run rather than a constant.
        if let raw = ProcessInfo.processInfo.environment["AF_FLOW_SUMMARY_EVAL_MODEL"],
           let kind = LocalCleanupModelKind(rawValue: raw) {
            return kind
        }
        return .qwen35_0_8b_q4_k_m
    }

    // MARK: - The eval

    @MainActor
    func testSummariesOfHisRealMeetingsInventNothing() async throws {
        try requireOptIn()
        let notes = try requireCorpus()
        let kind = modelKind()

        guard TextCleanupManager.isModelDownloaded(kind) else {
            // App-hosted tests run in the com.frolikov.afflow.TESTHOST container, which
            // has its own empty models directory. On 2026-08-21 this skip made a run
            // that measured nothing exit 0. `scripts/link-models-into-test-host.sh`
            // hard-links his real models in, costing no disk and no download.
            throw XCTSkip("""
            Cleanup model \(kind.rawValue) is not visible to the test host.
            Run scripts/link-models-into-test-host.sh, then run this again.
            A skipped eval measured nothing; do not read it as a pass.
            """)
        }
        let manager = TextCleanupManager(selectedCleanupModelKind: kind)
        await manager.loadModel(kind: kind)
        guard manager.state == .ready else {
            throw XCTSkip("Cleanup model \(kind.rawValue) failed to load after being downloaded.")
        }
        manager.activeLLM?.seed = 1

        let prompt = promptUnderTest()
        let cap = transcriptCharacterCap()
        // The model is named explicitly, because the generator otherwise walks its
        // own ladder and every rung of this measurement would run on the same one.
        let generator = MeetingSummaryGenerator(cleanupManager: manager, preferredModelKind: kind)

        var lines: [String] = []
        var totalConfirmed = 0
        var produced = 0
        var capped: [String] = []
        var worst: (name: String, count: Int) = ("", 0)

        for note in notes {
            let transcript = MeetingTranscript(meetingName: note.name)
            var used = note.segments
            var characters = 0
            var kept: [TranscriptSegment] = []
            for segment in used {
                characters += segment.text.count
                if characters > cap { break }
                kept.append(segment)
            }
            if kept.count < used.count {
                capped.append("\(note.name): \(kept.count) of \(used.count) segments")
            }
            used = kept
            transcript.segments = used
            transcript.notes = note.notes
            let transcriptText = used.map(\.text).joined(separator: "\n")

            guard let summary = await generator.generateSummary(transcript: transcript, finalPrompt: prompt) else {
                lines.append("\(note.name): the model returned nothing")
                continue
            }
            produced += 1
            let report = SummaryFabrication.check(
                summary: summary,
                transcript: transcriptText + "\n" + note.notes,
                prompt: prompt
            )
            totalConfirmed += report.confirmed.count
            if report.confirmed.count > worst.count { worst = (note.name, report.confirmed.count) }
            lines.append("\(note.name)  ->  \(report.summaryLine)")
            lines.append(report.detail)
        }

        let promptLabel = ProcessInfo.processInfo.environment["AF_FLOW_SUMMARY_EVAL_PROMPT"] ?? "shipping"
        let report = """
        prompt: \(promptLabel)   model: \(kind.rawValue)   meetings: \(notes.count)   \
        summaries produced: \(produced)   confirmed fabrication findings: \(totalConfirmed)
        worst: \(worst.name) with \(worst.count)
        transcript cap: \(cap) characters. Truncated: \(capped.isEmpty ? "none" : capped.joined(separator: ", "))

        \(lines.joined(separator: "\n"))
        """
        // `scripts/run-tests.sh` filters the test process's stdout by prefix, the same
        // way the meeting bake-off does. Without the prefix this report is discarded
        // by the wrapper and the run reports a bare pass or fail with no numbers,
        // which is a measurement nobody can read.
        for line in report.components(separatedBy: .newlines) {
            print("SUMMARY-EVAL \(line)")
        }

        // A zero that comes from generating nothing is not a clean result. Codex,
        // 2026-08-21: without this, a run where every call failed reports success.
        XCTAssertGreaterThan(produced, 0, """
        The model returned nothing for all \(notes.count) meeting(s), so a fabrication
        count of zero means nothing was measured.

        \(report)
        """)

        XCTAssertEqual(totalConfirmed, 0, """
        The summariser asserted \(totalConfirmed) thing(s) his transcripts do not contain.

        \(report)
        """)
    }

    /// The regression test for the defect's actual cause.
    ///
    /// The prompt used to name three example headings, and the model emitted all three
    /// verbatim and invented content to fill them. This needs no model and no corpus,
    /// so it runs in every routine verification run rather than only in an opt-in one.
    func testTheShippingPromptOffersNoExampleHeadings() {
        let examples = SummaryFabrication.exampleHeadings(in: MeetingSummaryGenerator.finalSummaryPrompt)
        XCTAssertTrue(examples.isEmpty, """
        The summary prompt names \(examples) as example headings.

        A 0.8B model copies what it is shown. On 2026-08-19 these exact headings came
        back verbatim over a transcript that mentioned none of them, and the model
        invented a Q3 budget approval, a hiring decision and a finance-team action item
        to fill them. Describe the headings; do not name them.
        """)
    }

    /// Pins the superseded prompt to the exact bytes that shipped.
    ///
    /// `AppState` replaces a stored `meetingSummaryPrompt` only when it is EQUAL to
    /// this string. Nothing else in the codebase reads it, so it looks like dead text
    /// that anyone would happily reflow, and a reflow would silently stop the
    /// migration firing: every install holding a stored copy would keep emitting the
    /// three invented headings forever, with the whole suite green. Found by an
    /// independent reviewer on 2026-08-21, who noted the first migration has a test
    /// pinning its invariant and this one had none.
    ///
    /// If this fails, the fix is to restore the literal, NOT to update the hash.
    func testTheSupersededPromptStillMatchesWhatShipped() {
        let data = Data(MeetingSummaryGenerator.supersededSummaryPromptWithExampleHeadings.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            digest,
            "09477adaa7f753c8f04ad6bec6b231a4e664df38e5494c88b32b6cc5cc00269d",
            """
            The superseded summary prompt no longer matches the text that shipped, so
            AppState's migration will not recognise a stored copy of it and anyone
            holding one keeps the fabricating prompt. Restore the literal.
            """
        )
    }

    func testTheChunkPromptOffersNoExampleHeadings() {
        let examples = SummaryFabrication.exampleHeadings(in: MeetingSummaryGenerator.defaultPrompt)
        XCTAssertTrue(examples.isEmpty, "The per-chunk prompt names \(examples) as example headings.")
    }

    // MARK: - Corpus loading

    /// Parses `**[MM:SS] Speaker:** text` lines out of the `## Transcript` section.
    static func loadNotes(in directory: String) -> [Note] {
        let root = URL(fileURLWithPath: directory)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var notes: [Note] = []
        for case let file as URL in walker where file.pathExtension == "md" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard let body = transcriptSection(of: text) else { continue }
            let segments = Self.segments(in: body)
            guard !segments.isEmpty else { continue }
            notes.append(Note(
                name: file.lastPathComponent,
                transcript: body,
                notes: section(of: text, heading: "## Notes", placeholder: "*No notes.*") ?? "",
                segments: segments
            ))
        }
        return notes.sorted { $0.name < $1.name }
    }

    static func transcriptSection(of text: String) -> String? {
        section(of: text, heading: "## Transcript", placeholder: "*No transcript.*")
    }

    static func section(of text: String, heading: String, placeholder: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) else {
            return nil
        }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("## ") { break }
            body.append(line)
        }
        let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty || joined == placeholder { return nil }
        return joined
    }

    static func segments(in body: String) -> [TranscriptSegment] {
        let pattern = try! NSRegularExpression(pattern: #"^\*\*\[(?:(\d+):)?(\d+):(\d+)\]\s*([^:]+):\*\*\s*(.*)$"#)
        var segments: [TranscriptSegment] = []
        for line in body.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: range) else { continue }
            func group(_ index: Int) -> String? {
                guard let r = Range(match.range(at: index), in: line) else { return nil }
                return String(line[r])
            }
            let hours = Int(group(1) ?? "0") ?? 0
            let minutes = Int(group(2) ?? "0") ?? 0
            let seconds = Int(group(3) ?? "0") ?? 0
            let speaker = (group(4) ?? "Others").trimmingCharacters(in: .whitespaces)
            let text = (group(5) ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let start = TimeInterval(hours * 3600 + minutes * 60 + seconds)
            segments.append(TranscriptSegment(
                id: UUID(),
                speaker: speaker == "Me" ? .me : .remote(name: speaker == "Others" ? nil : speaker),
                startTime: start,
                endTime: start,
                text: text
            ))
        }
        return segments
    }
}
