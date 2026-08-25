import XCTest
@testable import GhostPepper

/// **What saving a dictation is allowed to cost him.**
///
/// The index became append-only on 2026-08-04 for one reason: the old store
/// rewrote every held entry on every insert, so saving a dictation got slower
/// every day he used the app. `appendToIndex` says so in as many words.
///
/// The stage timings did not get the same treatment, and until 2026-08-24 that
/// did not matter, because a transcript was only archived when audio saving was
/// on — which for him was almost never. Then the history fix (`1e47801`) made
/// EVERY dictation archive a transcript, and `insert` began loading, mutating
/// and rewriting the entire timings dictionary on the path between his key
/// release and his clipboard. Codex found it in round 4 of that session.
///
/// The numbers that make it worth fixing rather than noting: his
/// release-to-clipboard latency is already sore at a 1.59 s median and a 4.0 s
/// p90 over 237 dictations, and `archiveRecordingForLab` is awaited *before*
/// `textPaster.paste`. At 186 entries the rewrite is nothing. At a year of them
/// it is the same cumulative cost the index was restructured to avoid.
///
/// So these tests pin the COST, not just the content. A test that only checked
/// that a timing round-trips would pass just as happily on the implementation
/// that grows forever — which is exactly how this survived a format change that
/// was made for this precise reason.
final class TranscriptionLabTimingsAppendOnlyTests: XCTestCase {

    // MARK: - The cost

    /// The one that matters. Bytes already on disk must not be rewritten.
    ///
    /// Asserting the byte PREFIX rather than counting writes is deliberate: it
    /// is the actual property "append-only" names, it is observable from
    /// outside the store, and it cannot be satisfied by an implementation that
    /// re-encodes the whole file and happens to be fast today.
    func testSavingADictationAppendsItsTimingRatherThanRewritingThemAll() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)

        for index in 0..<3 {
            try store.insert(
                makeEntry(audioFileName: "existing-\(index).wav"),
                audioData: Data([0x01]),
                stageTimings: timings(transcription: Double(index))
            )
        }

        let before = try Data(contentsOf: timingsURL(in: directory))
        XCTAssertFalse(before.isEmpty, "nothing was written, so this test proves nothing")

        try store.insert(
            makeEntry(audioFileName: "the-new-one.wav"),
            audioData: Data([0x02]),
            stageTimings: timings(transcription: 99)
        )

        let after = try Data(contentsOf: timingsURL(in: directory))
        XCTAssertEqual(
            after.prefix(before.count),
            before,
            "saving a dictation rewrote timings that were already on disk, so the cost grows with his archive"
        )
        XCTAssertGreaterThan(after.count, before.count, "the new timing was not written at all")
    }

    /// The same property stated as a number: one dictation, one line.
    func testTheTimingsFileHoldsOneLinePerSavedDictation() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)

        for index in 0..<5 {
            try store.insert(
                makeEntry(audioFileName: "entry-\(index).wav"),
                audioData: Data([0x01]),
                stageTimings: timings(transcription: Double(index))
            )
        }

        XCTAssertEqual(lineCount(of: timingsURL(in: directory)), 5)
    }

    /// What he actually feels: the tenth dictation must not cost more to save
    /// than the first.
    func testSavingTheTenthDictationWritesNoMoreThanSavingTheFirst() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)

        try store.insert(
            makeEntry(audioFileName: "first.wav"),
            audioData: Data([0x01]),
            stageTimings: timings(transcription: 0)
        )
        let afterFirst = try Data(contentsOf: timingsURL(in: directory)).count

        for index in 1..<9 {
            try store.insert(
                makeEntry(audioFileName: "middle-\(index).wav"),
                audioData: Data([0x01]),
                stageTimings: timings(transcription: Double(index))
            )
        }
        let beforeTenth = try Data(contentsOf: timingsURL(in: directory)).count

        try store.insert(
            makeEntry(audioFileName: "tenth.wav"),
            audioData: Data([0x01]),
            stageTimings: timings(transcription: 9)
        )
        let afterTenth = try Data(contentsOf: timingsURL(in: directory)).count

        let costOfTheTenth = afterTenth - beforeTenth
        XCTAssertLessThanOrEqual(
            costOfTheTenth,
            afterFirst,
            "the tenth dictation grew the file by more than the whole file was after the first, so the cost is cumulative"
        )
    }

    // MARK: - The content still has to be right

    func testATimingSurvivesBeingWrittenAndReadBack() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        let entry = makeEntry(audioFileName: "kept.wav")
        let stageTimings = TranscriptionLabStageTimings(transcriptionDuration: 1.25, cleanupDuration: 0.5)

        try store.insert(entry, audioData: Data([0x01]), stageTimings: stageTimings)

        XCTAssertEqual(try store.loadStageTimings()[entry.id], stageTimings)
    }

    /// A rerun re-inserts the same id. The append-only index resolves that by
    /// taking the LAST line; timings must resolve it the same way, or the
    /// history tab shows the durations of a run he has replaced.
    func testRewritingATimingKeepsTheNewestOne() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        let entry = makeEntry(audioFileName: "rerun.wav")

        try store.insert(entry, audioData: Data([0x01]), stageTimings: timings(transcription: 1))
        try store.insert(entry, audioData: Data([0x01]), stageTimings: timings(transcription: 2))

        XCTAssertEqual(try store.loadStageTimings()[entry.id]?.transcriptionDuration, 2)
    }

    /// The reason this format was chosen for the index, applied here: one
    /// damaged line costs one number in the UI, not every number.
    func testOneUnreadableLineCostsOnlyItsOwnTiming() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        let survivor = makeEntry(audioFileName: "survivor.wav")

        try store.insert(makeEntry(audioFileName: "damaged.wav"), audioData: Data([0x01]), stageTimings: timings(transcription: 1))

        // Corrupt the first line in place, exactly as a partial write would.
        let url = timingsURL(in: directory)
        var lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        lines[0] = "{ this line was cut short"
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        try store.insert(survivor, audioData: Data([0x02]), stageTimings: timings(transcription: 7))

        let loaded = try store.loadStageTimings()
        XCTAssertEqual(loaded[survivor.id]?.transcriptionDuration, 7, "a damaged line cost a timing that was not damaged")
        XCTAssertEqual(loaded.count, 1)
    }

    // MARK: - His existing 186 entries have to come across

    func testEveryTimingHeAlreadyHasSurvivesTheMoveToTheNewFormat() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        let firstID = UUID()
        let secondID = UUID()

        try JSONEncoder().encode([
            firstID.uuidString: TranscriptionLabStageTimings(transcriptionDuration: 1.5, cleanupDuration: 0.25),
            secondID.uuidString: TranscriptionLabStageTimings(transcriptionDuration: 2.5, cleanupDuration: nil)
        ]).write(to: legacyTimingsURL(in: directory))

        let loaded = try store.loadStageTimings()

        XCTAssertEqual(loaded[firstID]?.transcriptionDuration, 1.5)
        XCTAssertEqual(loaded[firstID]?.cleanupDuration, 0.25)
        XCTAssertEqual(loaded[secondID]?.transcriptionDuration, 2.5)
        XCTAssertNil(loaded[secondID]?.cleanupDuration)
    }

    /// Set aside, not deleted, and not left in place where it would be
    /// re-migrated the moment the new file went missing. Same reasoning as the
    /// legacy index, and the same marker.
    func testTheOldTimingsFileIsSetAsideOnceItHasBeenMoved() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)

        try JSONEncoder().encode([
            UUID().uuidString: TranscriptionLabStageTimings(transcriptionDuration: 1.5, cleanupDuration: 0.25)
        ]).write(to: legacyTimingsURL(in: directory))

        _ = try store.loadStageTimings()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyTimingsURL(in: directory).path),
            "the legacy file was left in place, so it will be migrated again after a Clear History"
        )
        let setAside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("transcription-lab-timings") && $0.contains("migrated") }
        XCTAssertEqual(setAside.count, 1, "the original bytes were not kept: \(setAside)")
    }

    /// A legacy file that will not decode must not be silently skipped: it would
    /// sit there looking fine while every duration vanished from the UI.
    func testAnUnreadableOldTimingsFileKeepsItsBytes() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        let garbage = "not json at all"
        try Data(garbage.utf8).write(to: legacyTimingsURL(in: directory))

        _ = try store.loadStageTimings()

        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("transcription-lab-timings") && $0.contains("unreadable") }
        XCTAssertEqual(quarantined.count, 1, "the unreadable legacy timings file was lost: \(quarantined)")
        let recovered = try String(
            contentsOf: directory.appendingPathComponent(quarantined[0]),
            encoding: .utf8
        )
        XCTAssertEqual(recovered, garbage)
    }

    // MARK: - What Codex round 1 found

    /// **One bad byte must not hide every good line.**
    ///
    /// `String(contentsOf:encoding:.utf8)` fails on the WHOLE file if a single
    /// byte anywhere in it is not valid UTF-8, so the first version of this
    /// reader returned an empty archive from one damaged byte — while the
    /// comment above it promised damage stayed local. The reader splits raw
    /// bytes now. Found by Codex, 2026-08-24.
    func testOneInvalidByteDoesNotHideEveryOtherTiming() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        let first = UUID()
        let second = UUID()

        var bytes = Data()
        bytes.append(Data(#"{"id":"\#(first.uuidString)","transcriptionDuration":1,"cleanupDuration":2}"#.utf8))
        bytes.append(0x0A)
        bytes.append(contentsOf: [0xFF, 0xFE, 0x7B, 0x22])   // not valid UTF-8 in any encoding
        bytes.append(0x0A)
        bytes.append(Data(#"{"id":"\#(second.uuidString)","transcriptionDuration":3,"cleanupDuration":4}"#.utf8))
        bytes.append(0x0A)
        try bytes.write(to: timingsURL(in: directory))

        let loaded = try store.loadStageTimings()

        XCTAssertEqual(loaded[first]?.transcriptionDuration, 1, "one bad byte hid an intact line")
        XCTAssertEqual(loaded[second]?.transcriptionDuration, 3, "one bad byte hid an intact line")
        XCTAssertEqual(loaded.count, 2)
    }

    /// **A migration that cannot write must not retire the only copy.**
    ///
    /// The first version wrote with `try?` and then renamed the legacy file
    /// unconditionally. A full disk or a permissions fault was swallowed, the
    /// original became a `.migrated-1` file nothing reads, and every duration he
    /// had was gone. Found by Codex, 2026-08-24.
    ///
    /// The write is failed here by making the directory unwritable, which is the
    /// closest a test can get to his disk filling up.
    func testAMigrationThatCannotWriteKeepsHisTimings() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        let entryID = UUID()

        try JSONEncoder().encode([
            entryID.uuidString: TranscriptionLabStageTimings(transcriptionDuration: 1.5, cleanupDuration: 0.25)
        ]).write(to: legacyTimingsURL(in: directory))

        // Fail the write the way a full disk would.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        _ = try? store.loadStageTimings()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // The point: once the fault clears, his durations are still reachable.
        let loaded = try store.loadStageTimings()
        XCTAssertEqual(
            loaded[entryID]?.transcriptionDuration,
            1.5,
            "a failed migration retired the only copy of his timings"
        )
    }

    // MARK: - Compaction still has to happen

    /// Append-only is not append-forever. When retention drops an entry its
    /// timing has to go too, or the file grows without bound behind him.
    func testDroppingAnEntryDropsItsTiming() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        let doomed = makeEntry(audioFileName: "doomed.wav")
        let kept = makeEntry(audioFileName: "kept.wav")

        try store.insert(doomed, audioData: Data([0x01]), stageTimings: timings(transcription: 1))
        try store.insert(kept, audioData: Data([0x02]), stageTimings: timings(transcription: 2))

        try store.deleteEntry(id: doomed.id)

        let loaded = try store.loadStageTimings()
        XCTAssertNil(loaded[doomed.id], "a deleted entry kept its timing")
        XCTAssertEqual(loaded[kept.id]?.transcriptionDuration, 2)
    }

    // MARK: - Helpers

    private func makeFixture() -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directoryURL) }
        return directoryURL
    }

    private func timingsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("transcription-lab-timings.jsonl")
    }

    private func legacyTimingsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("transcription-lab-timings.json")
    }

    private func lineCount(of url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func timings(transcription: TimeInterval) -> TranscriptionLabStageTimings {
        TranscriptionLabStageTimings(transcriptionDuration: transcription, cleanupDuration: 0.5)
    }

    private func makeEntry(audioFileName: String, createdAt: Date = Date()) -> TranscriptionLabEntry {
        TranscriptionLabEntry(
            id: UUID(),
            createdAt: createdAt,
            audioFileName: audioFileName,
            audioDuration: 1.5,
            windowContext: nil,
            rawTranscription: "raw",
            correctedTranscription: "corrected",
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 2B",
            cleanupUsedFallback: false,
            speakerFilteringEnabled: false,
            speakerFilteringRan: false,
            speakerFilteringUsedFallback: false,
            diarizationSummary: nil
        )
    }
}
