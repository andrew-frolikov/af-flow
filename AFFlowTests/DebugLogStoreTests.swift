import XCTest
@testable import AFFlow

@MainActor
final class DebugLogStoreTests: XCTestCase {
    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStore(maxEntries: Int = 250) -> DebugLogStore {
        let fileURL = makeDirectory().appendingPathComponent("debug-log.jsonl")
        return DebugLogStore(maxEntries: maxEntries, storageURL: fileURL)
    }

    func testStorePersistsEntriesAcrossInstances() throws {
        let fileURL = makeDirectory().appendingPathComponent("debug-log.jsonl")

        do {
            let firstStore = DebugLogStore(maxEntries: 10, storageURL: fileURL)
            firstStore.record(category: .performance, message: "session complete")
        }

        let secondStore = DebugLogStore(maxEntries: 10, storageURL: fileURL)

        XCTAssertEqual(secondStore.entries.map(\.message), ["session complete"])
    }

    // MARK: - Retention is measured in days, not entries

    /// The reason this changed: at 250 entries the log held about two days of
    /// his usage, so "did it get worse on Wednesday" had already been
    /// overwritten by the time he asked it. Retention is now a time window.
    func testEntriesOlderThanTheRetentionWindowAreDroppedOnLoad() throws {
        let fileURL = makeDirectory().appendingPathComponent("debug-log.jsonl")
        let now = Date()

        do {
            let store = DebugLogStore(
                maxEntries: 10_000,
                retention: 30 * 24 * 60 * 60,
                storageURL: fileURL,
                now: { now.addingTimeInterval(-40 * 24 * 60 * 60) }
            )
            store.record(category: .hotkey, message: "forty days ago")
        }

        do {
            let store = DebugLogStore(
                maxEntries: 10_000,
                retention: 30 * 24 * 60 * 60,
                storageURL: fileURL,
                now: { now.addingTimeInterval(-20 * 24 * 60 * 60) }
            )
            store.record(category: .hotkey, message: "twenty days ago")
        }

        let store = DebugLogStore(
            maxEntries: 10_000,
            retention: 30 * 24 * 60 * 60,
            storageURL: fileURL,
            now: { now }
        )

        XCTAssertEqual(store.entries.map(\.message), ["twenty days ago"])
    }

    /// The window has to be wide enough to answer a question about last week.
    /// A 250-entry cap could not, which is the defect this replaces.
    func testAnEntryFromLastWeekSurvivesFarMoreThanTwoHundredAndFiftyNewerOnes() throws {
        let fileURL = makeDirectory().appendingPathComponent("debug-log.jsonl")
        let now = Date()

        do {
            let store = DebugLogStore(
                maxEntries: 50_000,
                retention: 30 * 24 * 60 * 60,
                storageURL: fileURL,
                now: { now.addingTimeInterval(-7 * 24 * 60 * 60) }
            )
            store.record(category: .model, message: "last wednesday")
        }

        let store = DebugLogStore(
            maxEntries: 50_000,
            retention: 30 * 24 * 60 * 60,
            storageURL: fileURL,
            now: { now }
        )
        for index in 0..<400 {
            store.record(category: .performance, message: "since then \(index)")
        }

        XCTAssertEqual(store.entries.first?.message, "last wednesday")
        XCTAssertEqual(store.entries.count, 401)
    }

    // MARK: - Writing one entry must not rewrite the whole log

    /// Raising the retention window on the old implementation would have made
    /// it quadratically worse, not just bigger: `persistEntries()` re-encoded
    /// and rewrote every entry held, on every single `record()`. Thirty days of
    /// history rewritten per log line is the same shape as meeting bug 15.
    ///
    /// Appending leaves everything already written byte-for-byte untouched, so
    /// asserting the previous file content is still a prefix of the new one
    /// pins the cost at O(1) per entry without measuring time.
    func testRecordingAppendsRatherThanRewritingTheFile() throws {
        let fileURL = makeDirectory().appendingPathComponent("debug-log.jsonl")
        let store = DebugLogStore(maxEntries: 10_000, storageURL: fileURL)

        store.record(category: .hotkey, message: "first")
        let afterFirst = try Data(contentsOf: fileURL)
        store.record(category: .hotkey, message: "second")
        let afterSecond = try Data(contentsOf: fileURL)

        XCTAssertGreaterThan(afterSecond.count, afterFirst.count)
        XCTAssertEqual(
            afterSecond.prefix(afterFirst.count),
            afterFirst,
            "recording appended nothing: the file was rewritten from scratch"
        )
    }

    /// One entry per line, so the probe can read the log without holding all of
    /// it, and so a truncated final write costs one entry rather than the file.
    func testEachEntryIsItsOwnLine() throws {
        let fileURL = makeDirectory().appendingPathComponent("debug-log.jsonl")
        let store = DebugLogStore(maxEntries: 10_000, storageURL: fileURL)

        store.record(category: .hotkey, message: "first")
        store.record(category: .ocr, message: "second")
        store.record(category: .cleanup, message: "third")

        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            XCTAssertNoThrow(
                try JSONDecoder().decode(DebugLogEntry.self, from: Data(line.utf8))
            )
        }
    }

    /// A half-written final line (killed mid-append, force quit) must cost that
    /// one entry and not the whole history.
    func testATruncatedFinalLineDoesNotDiscardTheEntriesBeforeIt() throws {
        let fileURL = makeDirectory().appendingPathComponent("debug-log.jsonl")

        do {
            let store = DebugLogStore(maxEntries: 10_000, storageURL: fileURL)
            store.record(category: .hotkey, message: "intact")
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"not-final"#.utf8))
        try handle.close()

        let store = DebugLogStore(maxEntries: 10_000, storageURL: fileURL)

        XCTAssertEqual(store.entries.map(\.message), ["intact"])
    }

    // MARK: - His existing history must not be thrown away

    /// The live log on his Mac is a JSON array at `debug-log.json`. Converting
    /// the format must carry it over, or the change to answer "what happened
    /// last week" would start by deleting last week.
    func testTheLegacyJSONArrayIsMigratedIntoTheLineFormat() throws {
        let directory = makeDirectory()
        let legacyURL = directory.appendingPathComponent("debug-log.json")
        let fileURL = directory.appendingPathComponent("debug-log.jsonl")

        let legacy = [
            DebugLogEntry(timestamp: Date().addingTimeInterval(-3600), category: .model, message: "older"),
            DebugLogEntry(timestamp: Date().addingTimeInterval(-60), category: .hotkey, message: "newer")
        ]
        try JSONEncoder().encode(legacy).write(to: legacyURL)

        let store = DebugLogStore(maxEntries: 10_000, storageURL: fileURL)

        XCTAssertEqual(store.entries.map(\.message), ["older", "newer"])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "migration did not produce the line-format file"
        )
    }

    /// Migration runs once. A second launch must not append his history again.
    func testMigrationDoesNotRunTwice() throws {
        let directory = makeDirectory()
        let legacyURL = directory.appendingPathComponent("debug-log.json")
        let fileURL = directory.appendingPathComponent("debug-log.jsonl")

        let legacy = [
            DebugLogEntry(timestamp: Date().addingTimeInterval(-60), category: .hotkey, message: "only once")
        ]
        try JSONEncoder().encode(legacy).write(to: legacyURL)

        _ = DebugLogStore(maxEntries: 10_000, storageURL: fileURL)
        let second = DebugLogStore(maxEntries: 10_000, storageURL: fileURL)

        XCTAssertEqual(second.entries.map(\.message), ["only once"])
    }

    func testStoreDropsOldestEntriesWhenCapacityIsExceeded() {
        let store = makeStore(maxEntries: 2)

        store.record(category: .hotkey, message: "first")
        store.record(category: .ocr, message: "second")
        store.record(category: .cleanup, message: "third")

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.map(\.message), ["second", "third"])
    }

    func testClearRemovesFormattedLogOutput() {
        let store = makeStore(maxEntries: 2)

        store.record(category: .model, message: "loaded")
        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.formattedText, "")
    }

    func testSensitiveEntriesAreIgnoredWhenNoDebugViewerIsOpen() {
        let store = makeStore()

        store.recordSensitive(category: .cleanup, message: "full prompt")

        XCTAssertTrue(store.entries.isEmpty)
    }

    func testSensitiveEntriesAreRecordedOnlyWhileDebugViewerIsOpen() {
        let store = makeStore()

        store.beginLiveViewing()
        store.recordSensitive(category: .cleanup, message: "full prompt")
        store.endLiveViewing()
        store.recordSensitive(category: .cleanup, message: "full output")

        XCTAssertEqual(store.entries.map(\.message), ["full prompt"])
    }
}
