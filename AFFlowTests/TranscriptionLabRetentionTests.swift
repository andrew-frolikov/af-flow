import XCTest
@testable import AFFlow

/// How long his dictation history is kept.
///
/// Until 2026-08-04 the answer was "the last 50 recordings", and the probe found
/// him sitting exactly at that cap: **every new dictation evicted the oldest and
/// deleted its WAV.** He had been losing a recording every time he spoke, with
/// nothing saying so.
///
/// He chose time-based retention, transcripts kept longer than audio, because
/// the text is what he searches and the audio is what is large. The numbers:
///
/// - **Transcripts: 365 days.** A few KB each. There is no reason to lose the
///   text of something he said in March.
/// - **Audio: 7 days.** Matching the meeting-audio retention he already chose on
///   2026-07-29 rather than inventing a second number. It is the window the lab
///   rerun needs, and 30 dictations a day of WAV is real disk.
///
/// A transcript therefore outlives its audio, which is deliberate: the row stays
/// searchable and the playback button goes away.
///
/// The index is append-only JSONL for the same reason the debug log is. The old
/// store rewrote the WHOLE array on every insert, which is fine at 50 entries
/// and quadratic at a year of them; raising retention on that implementation
/// would have made it slower every day.
final class TranscriptionLabRetentionTests: XCTestCase {
    private func makeFixture() -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directoryURL) }
        return directoryURL
    }

    private func audioURL(in directory: URL, named name: String) -> URL {
        directory.appendingPathComponent("audio", isDirectory: true).appendingPathComponent(name)
    }

    private func entry(_ name: String, ageInDays: Double, now: Date) -> TranscriptionLabEntry {
        TranscriptionLabEntry(
            id: UUID(),
            createdAt: now.addingTimeInterval(-ageInDays * 86_400),
            audioFileName: name,
            audioDuration: 1.5,
            windowContext: nil,
            rawTranscription: "raw \(name)",
            correctedTranscription: "corrected \(name)",
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 2B",
            cleanupUsedFallback: false,
            speakerFilteringEnabled: false,
            speakerFilteringRan: false,
            speakerFilteringUsedFallback: false,
            diarizationSummary: nil
        )
    }

    private func timings() -> TranscriptionLabStageTimings {
        TranscriptionLabStageTimings(transcriptionDuration: 0.25, cleanupDuration: 0.5)
    }

    private func store(at directory: URL, now: Date) -> TranscriptionLabStore {
        TranscriptionLabStore(directoryURL: directory, now: { now })
    }

    /// The headline. He dictates all day; the 51st recording must not cost him
    /// the 1st.
    func testFarMoreThanFiftyRecentDictationsAreAllKept() throws {
        let directory = makeFixture()
        let now = Date()
        let subject = store(at: directory, now: now)

        for index in 0..<120 {
            try subject.insert(
                entry("r\(index).wav", ageInDays: Double(index) / 24.0, now: now),
                audioData: Data([UInt8(index % 256)]),
                stageTimings: timings()
            )
        }

        XCTAssertEqual(try subject.loadEntries().count, 120)
    }

    func testATranscriptOlderThanAYearIsDropped() throws {
        let directory = makeFixture()
        let now = Date()
        let subject = store(at: directory, now: now)

        try subject.insert(entry("ancient.wav", ageInDays: 400, now: now),
                           audioData: Data([0x01]), stageTimings: timings())
        try subject.insert(entry("recent.wav", ageInDays: 1, now: now),
                           audioData: Data([0x02]), stageTimings: timings())

        XCTAssertEqual(try subject.loadEntries().map(\.audioFileName), ["recent.wav"])
    }

    /// The point of splitting the two windows: the text survives, the WAV does
    /// not, and the row stays searchable either way.
    func testATranscriptOlderThanAWeekKeepsItsTextAndLosesItsAudio() throws {
        let directory = makeFixture()
        let now = Date()
        let subject = store(at: directory, now: now)

        try subject.insert(entry("old.wav", ageInDays: 30, now: now),
                           audioData: Data([0x01]), stageTimings: timings())
        try subject.insert(entry("fresh.wav", ageInDays: 1, now: now),
                           audioData: Data([0x02]), stageTimings: timings())

        let entries = try subject.loadEntries()
        XCTAssertEqual(Set(entries.map(\.audioFileName)), ["old.wav", "fresh.wav"],
                       "a 30-day-old transcript should still be listed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audioURL(in: directory, named: "old.wav").path),
            "audio past the 7-day window should be gone"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioURL(in: directory, named: "fresh.wav").path)
        )
    }

    /// Appending, not rewriting. The old store rewrote every held entry on every
    /// insert; at a year of history that is quadratic and gets slower daily.
    func testInsertingAppendsRatherThanRewritingTheWholeIndex() throws {
        let directory = makeFixture()
        let now = Date()
        let subject = store(at: directory, now: now)
        let indexURL = directory.appendingPathComponent("transcription-lab-index.jsonl")

        try subject.insert(entry("a.wav", ageInDays: 0.3, now: now),
                           audioData: Data([0x01]), stageTimings: timings())
        let afterFirst = try Data(contentsOf: indexURL).count

        try subject.insert(entry("b.wav", ageInDays: 0.2, now: now),
                           audioData: Data([0x02]), stageTimings: timings())
        let afterSecond = try Data(contentsOf: indexURL).count

        // A rewrite of both entries would roughly double. An append adds one
        // line, so the file grows by about one entry's worth either way — what
        // distinguishes them is that the FIRST line is byte-identical.
        let lines = try String(contentsOf: indexURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertGreaterThan(afterSecond, afterFirst)
        XCTAssertTrue(lines[0].contains("a.wav"), "the first line should be untouched by the second insert")
    }

    /// One malformed line costs that line. The whole reason for leaving a single
    /// JSON array behind.
    func testOneCorruptLineCostsOneEntryAndNotTheArchive() throws {
        let directory = makeFixture()
        let now = Date()
        let subject = store(at: directory, now: now)
        let indexURL = directory.appendingPathComponent("transcription-lab-index.jsonl")

        try subject.insert(entry("a.wav", ageInDays: 0.3, now: now),
                           audioData: Data([0x01]), stageTimings: timings())
        try subject.insert(entry("b.wav", ageInDays: 0.2, now: now),
                           audioData: Data([0x02]), stageTimings: timings())

        var text = try String(contentsOf: indexURL, encoding: .utf8)
        text += "{ this line is not json\n"
        try text.write(to: indexURL, atomically: true, encoding: .utf8)

        let entries = try subject.loadEntries()
        XCTAssertEqual(Set(entries.map(\.audioFileName)), ["a.wav", "b.wav"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(in: directory, named: "a.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(in: directory, named: "b.wav").path))
    }

    /// His existing archive is a JSON array. It must survive the format change,
    /// because it is the measurement instrument two defects were found with.
    func testTheLegacyJSONArrayIsMigratedRatherThanLost() throws {
        let directory = makeFixture()
        let now = Date()
        let legacy = [
            entry("legacy-one.wav", ageInDays: 2, now: now),
            entry("legacy-two.wav", ageInDays: 3, now: now)
        ]
        let encoder = JSONEncoder()
        try encoder.encode(legacy).write(
            to: directory.appendingPathComponent("transcription-lab-index.json")
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("audio", isDirectory: true),
            withIntermediateDirectories: true
        )
        for name in ["legacy-one.wav", "legacy-two.wav"] {
            try Data([0x01]).write(to: audioURL(in: directory, named: name))
        }

        let entries = try store(at: directory, now: now).loadEntries()

        XCTAssertEqual(Set(entries.map(\.audioFileName)), ["legacy-one.wav", "legacy-two.wav"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("transcription-lab-index.jsonl").path
            ),
            "the migration should have written the new format"
        )
    }

    func testEntriesStillComeBackNewestFirst() throws {
        let directory = makeFixture()
        let now = Date()
        let subject = store(at: directory, now: now)

        try subject.insert(entry("older.wav", ageInDays: 2, now: now),
                           audioData: Data([0x01]), stageTimings: timings())
        try subject.insert(entry("newer.wav", ageInDays: 1, now: now),
                           audioData: Data([0x02]), stageTimings: timings())

        XCTAssertEqual(try subject.loadEntries().map(\.audioFileName), ["newer.wav", "older.wav"])
    }

    /// Clear History still destroys everything, which is the one place that
    /// should.
    func testClearHistoryStillRemovesEverything() throws {
        let directory = makeFixture()
        let now = Date()
        let subject = store(at: directory, now: now)
        try subject.insert(entry("a.wav", ageInDays: 0.3, now: now),
                           audioData: Data([0x01]), stageTimings: timings())

        subject.deleteAllEntries()

        XCTAssertTrue(try subject.loadEntries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(in: directory, named: "a.wav").path))
    }

    /// Deleting one row still removes that row and its audio and nothing else.
    func testDeletingOneEntryLeavesTheOthersAlone() throws {
        let directory = makeFixture()
        let now = Date()
        let subject = store(at: directory, now: now)
        let doomed = entry("doomed.wav", ageInDays: 0.3, now: now)
        try subject.insert(doomed, audioData: Data([0x01]), stageTimings: timings())
        try subject.insert(entry("keeper.wav", ageInDays: 0.2, now: now),
                           audioData: Data([0x02]), stageTimings: timings())

        try subject.deleteEntry(id: doomed.id)

        XCTAssertEqual(try subject.loadEntries().map(\.audioFileName), ["keeper.wav"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(in: directory, named: "doomed.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(in: directory, named: "keeper.wav").path))
    }

    /// An entry re-inserted under the same id must not appear twice in an
    /// append-only file.
    func testReinsertingTheSameEntryDoesNotDuplicateIt() throws {
        let directory = makeFixture()
        let now = Date()
        let subject = store(at: directory, now: now)
        let same = entry("same.wav", ageInDays: 0.3, now: now)

        try subject.insert(same, audioData: Data([0x01]), stageTimings: timings())
        try subject.insert(same, audioData: Data([0x01]), stageTimings: timings())

        XCTAssertEqual(try subject.loadEntries().count, 1)
    }

    /// Migrates his REAL archive, not a synthetic one.
    ///
    /// The synthetic migration test above uses entries this file built. His
    /// actual 50 recordings carry OCR window context, diarization summaries and
    /// optional fields that a hand-made fixture does not, and a migration that
    /// only works on tidy data is exactly the shape this project keeps shipping.
    /// So this points the real store at a COPY of his real archive and counts.
    ///
    /// Reads a copy and writes only inside a temp directory; his archive is
    /// never touched. Needs `scripts/stage-language-replay.sh` first.
    /// SKIPPED unless `TEST_RUNNER_AF_FLOW_VERIFY_REAL_ARCHIVE=1`.
    func testHisRealArchiveMigratesWithoutLosingAnEntry() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AF_FLOW_VERIFY_REAL_ARCHIVE"] == "1",
            "set TEST_RUNNER_AF_FLOW_VERIFY_REAL_ARCHIVE=1 and stage first"
        )

        let staged = AppSupportDirectory.url
            .appendingPathComponent("replay", isDirectory: true)
        let legacy = staged.appendingPathComponent("transcription-lab-index.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: legacy.path),
                          "nothing staged at \(staged.path)")

        let expected = try JSONDecoder()
            .decode([TranscriptionLabEntry].self, from: Data(contentsOf: legacy))
        XCTAssertGreaterThan(expected.count, 0)

        let work = makeFixture()
        try FileManager.default.copyItem(
            at: legacy, to: work.appendingPathComponent("transcription-lab-index.json")
        )

        // His real entries span months, so the clock is pinned just after the
        // newest one. A real `now` would expire the older ones and the count
        // would not match for a reason that is policy rather than migration.
        let newest = expected.map(\.createdAt).max() ?? Date()
        let subject = TranscriptionLabStore(
            directoryURL: work, now: { newest.addingTimeInterval(60) }
        )

        let migrated = try subject.loadEntries()
        XCTAssertEqual(migrated.count, expected.count,
                       "his real archive lost entries in migration")
        XCTAssertEqual(Set(migrated.map(\.id)), Set(expected.map(\.id)),
                       "the migrated ids are not the same set")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: work.appendingPathComponent("transcription-lab-index.jsonl").path
            )
        )
        print("REAL ARCHIVE migrated \(migrated.count) of \(expected.count) entries")
    }
}
