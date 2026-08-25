import XCTest
@testable import AFFlow

/// What happens to his dictation history when a file on disk cannot be read.
///
/// Until 2026-08-03 the answer was: **all of it is destroyed.** Both
/// `loadEntries()` and `loadStageTimings()` called `resetStoredArchive()` in
/// their `catch`, and that deletes the index, the timings AND the entire audio
/// directory. One malformed byte anywhere in a JSON file took every transcript
/// and every WAV he had.
///
/// Three things made it worse than it first looks:
///
/// 1. `insert()` calls both loaders, so the wipe could fire *while saving a new
///    dictation* rather than only at launch.
/// 2. The timings file holds nothing but two durations per entry, and is purely
///    cosmetic. The least important file on disk could destroy the most
///    important data.
/// 3. Those 50 recordings are the highest-yield measurement instrument this
///    project has; two passes over them have already found two defects.
///
/// A read failure means "I could not read this", never "this should be
/// destroyed". The file is moved aside instead, so a human can still recover it.
///
/// Updated 2026-08-04 when the index became append-only JSONL. The properties
/// are unchanged and every one still has to hold; only the filename moved. The
/// format change makes the archive STRONGER here, because one bad line now costs
/// one entry instead of everything — `TranscriptionLabRetentionTests` pins that
/// separately. A wholly unreadable index is still possible (a truncated write, a
/// permissions fault) and is still what these tests cover.
final class TranscriptionLabStoreCorruptionTests: XCTestCase {
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

    private func timings() -> TranscriptionLabStageTimings {
        TranscriptionLabStageTimings(transcriptionDuration: 0.25, cleanupDuration: 0.5)
    }

    /// The one that matters. His audio is irreplaceable; the index is not.
    func testACorruptIndexDoesNotDeleteHisAudio() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        try store.insert(makeEntry(audioFileName: "first.wav"), audioData: Data([0x01]), stageTimings: timings())
        try store.insert(makeEntry(audioFileName: "second.wav"), audioData: Data([0x02]), stageTimings: timings())

        try Data("{ this is not json".utf8)
            .write(to: directory.appendingPathComponent("transcription-lab-index.jsonl"))

        _ = try? store.loadEntries()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioURL(in: directory, named: "first.wav").path),
            "a corrupt index destroyed his audio"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioURL(in: directory, named: "second.wav").path),
            "a corrupt index destroyed his audio"
        )
    }

    /// A wholly unreadable append-only index costs no audio and no bytes.
    ///
    /// The JSONL format does not quarantine, and does not need to: unparseable
    /// lines are skipped where they lie, the file is never moved or truncated,
    /// and the next insert appends after them. Recovery is "open the file",
    /// which is strictly better than "find the renamed copy".
    func testAnUnreadableAppendOnlyIndexKeepsItsBytesAndHisAudio() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        try store.insert(makeEntry(audioFileName: "first.wav"), audioData: Data([0x01]), stageTimings: timings())

        let garbage = "{ this is not json\n"
        let indexURL = directory.appendingPathComponent("transcription-lab-index.jsonl")
        try Data(garbage.utf8).write(to: indexURL)

        XCTAssertEqual(try store.loadEntries().count, 0)
        XCTAssertEqual(try String(contentsOf: indexURL, encoding: .utf8), garbage,
                       "the unreadable bytes must be left exactly where they are")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(in: directory, named: "first.wav").path),
                      "an unreadable index destroyed his audio")
    }

    /// The LEGACY single-array archive is the one that still gets quarantined,
    /// and it is the one that needs it: one bad byte there costs every entry, so
    /// skipping it quietly would drop his whole history out of the UI while the
    /// file sat on disk looking fine.
    func testACorruptLegacyArchiveIsMovedAsideWithItsContentsIntact() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)

        let garbage = "{ this is not json"
        try Data(garbage.utf8).write(to: directory.appendingPathComponent("transcription-lab-index.json"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("audio", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(to: audioURL(in: directory, named: "first.wav"))

        _ = try? store.loadEntries()

        let quarantined = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.contains("unreadable") } ?? []

        // A `guard` and not a bare subscript after `XCTAssertEqual`. The assert
        // records a failure and carries on, so indexing an empty array here
        // TRAPS, and a trap takes the whole test bundle down. xcodebuild then
        // restarts and reports "Executed 4 tests, with 4 failures" for a class
        // holding six: the two that never completed vanish from the total with
        // nothing saying so. That is how this file was written the first time,
        // and it is the same silent-green shape the suite keeps producing.
        guard let name = quarantined.first, quarantined.count == 1 else {
            return XCTFail("expected exactly one quarantined index, got \(quarantined)")
        }

        let recovered = try String(
            contentsOf: directory.appendingPathComponent(name),
            encoding: .utf8
        )
        XCTAssertEqual(recovered, garbage)
    }

    /// The timings file holds two durations per entry and nothing else. It must
    /// not be able to cost him a single transcript, let alone all of them.
    func testACorruptTimingsFileCostsNeitherEntriesNorAudio() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        try store.insert(makeEntry(audioFileName: "first.wav"), audioData: Data([0x01]), stageTimings: timings())

        try Data("nonsense".utf8)
            .write(to: directory.appendingPathComponent("transcription-lab-timings.jsonl"))

        let loadedTimings = (try? store.loadStageTimings()) ?? [:]
        XCTAssertTrue(loadedTimings.isEmpty)

        let entries = try store.loadEntries()
        XCTAssertEqual(entries.map(\.audioFileName), ["first.wav"], "a corrupt timings file lost his transcript")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(in: directory, named: "first.wav").path))
    }

    /// Saving a new dictation reads the index first, so the old wipe could fire
    /// mid-save. The new recording must survive a corrupt index.
    func testInsertingIntoACorruptArchiveStillKeepsBothTheOldAudioAndTheNew() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        try store.insert(makeEntry(audioFileName: "old.wav"), audioData: Data([0x01]), stageTimings: timings())

        try Data("{ broken".utf8)
            .write(to: directory.appendingPathComponent("transcription-lab-index.jsonl"))

        try store.insert(makeEntry(audioFileName: "new.wav"), audioData: Data([0x02]), stageTimings: timings())

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioURL(in: directory, named: "old.wav").path),
            "the orphaned audio was deleted, so the dictation is unrecoverable"
        )
        XCTAssertEqual(try store.loadEntries().map(\.audioFileName), ["new.wav"])
    }

    /// A second corruption must not overwrite the first quarantine, or the
    /// recovery copy is lost to the very next launch.
    func testASecondCorruptionKeepsTheFirstQuarantine() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        let legacyURL = directory.appendingPathComponent("transcription-lab-index.json")
        let indexURL = directory.appendingPathComponent("transcription-lab-index.jsonl")

        try Data("first breakage".utf8).write(to: legacyURL)
        _ = try? store.loadEntries()

        try? FileManager.default.removeItem(at: indexURL)
        try Data("second breakage".utf8).write(to: legacyURL)
        _ = try? store.loadEntries()

        let quarantined = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.contains("unreadable") } ?? []
        XCTAssertEqual(quarantined.count, 2, "a quarantine was overwritten: \(quarantined)")
    }

    /// Clear History is the one place that SHOULD destroy everything, and it
    /// still must.
    func testClearHistoryStillRemovesEverything() throws {
        let directory = makeFixture()
        let store = TranscriptionLabStore(directoryURL: directory)
        try store.insert(makeEntry(audioFileName: "first.wav"), audioData: Data([0x01]), stageTimings: timings())

        store.deleteAllEntries()

        XCTAssertTrue(try store.loadEntries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(in: directory, named: "first.wav").path))
    }
}
