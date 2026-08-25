import Foundation

struct TranscriptionLabStageTimings: Codable, Equatable {
    let transcriptionDuration: TimeInterval?
    let cleanupDuration: TimeInterval?
}

final class TranscriptionLabStore {
    private static let minimumDisplayableAudioDuration: TimeInterval = 0.05

    /// How long a transcript is kept. A year, because the text is a few KB and
    /// there is no reason to lose what he said in March.
    static let defaultTranscriptRetention: TimeInterval = 365 * 86_400

    /// How long the WAV is kept. Seven days, matching the meeting-audio
    /// retention he chose on 2026-07-29 rather than inventing a second number.
    /// It is the window the lab rerun needs, and 30 dictations a day of audio is
    /// real disk. A transcript therefore outlives its audio, deliberately: the
    /// row stays searchable and the playback button goes away.
    /// THREE DAYS, his decision on 2026-08-24, down from seven.
    ///
    /// He wants no disk spent on dictation WAVs and asked for them gone
    /// entirely. Three days is the compromise he took once told what it costs:
    /// keeping audio is the only way to answer "it dropped half my sentence",
    /// which is how the 2026-08-05 loss was finally diagnosed and how the
    /// truncation defect was withdrawn on 2026-08-21. Three days covers a bug he
    /// notices and reports the same week, and nothing beyond that.
    ///
    /// Meeting audio is a SEPARATE store and keeps its 7 days; it is the
    /// recovery path when a call's capture dies mid-meeting.
    static let defaultAudioRetention: TimeInterval = 3 * 86_400

    /// A backstop, not a policy. Time decides what is kept; this only stops an
    /// unbounded file if something goes wrong with the clock.
    private let maxEntries: Int
    private let transcriptRetention: TimeInterval
    private let audioRetention: TimeInterval
    private let now: () -> Date

    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        directoryURL: URL? = nil,
        maxEntries: Int = 20_000,
        transcriptRetention: TimeInterval = TranscriptionLabStore.defaultTranscriptRetention,
        audioRetention: TimeInterval = TranscriptionLabStore.defaultAudioRetention,
        now: @escaping () -> Date = Date.init
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL
        self.maxEntries = maxEntries
        self.transcriptRetention = transcriptRetention
        self.audioRetention = audioRetention
        self.now = now
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// Everything still within the transcript window, newest first.
    ///
    /// Reading also PRUNES: entries past the transcript window are dropped and
    /// audio past the shorter audio window is deleted. Doing it on read rather
    /// than on a timer means the policy applies the moment the app is opened,
    /// with no scheduler to starve.
    func loadEntries() throws -> [TranscriptionLabEntry] {
        migrateLegacyArchiveIfNeeded()

        var entries = readIndexLines()
        // Newest first, and de-duplicated by id: the file is append-only, so a
        // re-inserted entry appears twice and the LAST line is the current one.
        var seen = Set<UUID>()
        entries = entries.reversed().filter { seen.insert($0.id).inserted }
        entries.sort { $0.createdAt > $1.createdAt }

        let cutoff = now().addingTimeInterval(-transcriptRetention)
        let withinWindow = entries.filter { $0.createdAt >= cutoff }
        // Anything the backstop cap drops is expired too. Dropping it from the
        // index without deleting its audio would orphan the WAV forever, with
        // nothing left pointing at it.
        var expired = entries.filter { $0.createdAt < cutoff }
        expired.append(contentsOf: withinWindow.dropFirst(maxEntries))
        var kept = Array(withinWindow.prefix(maxEntries))

        // Audio outlives nothing; the transcript outlives the audio.
        let audioCutoff = now().addingTimeInterval(-audioRetention)
        for entry in kept where entry.createdAt < audioCutoff {
            try? FileManager.default.removeItem(at: audioURL(for: entry.audioFileName))
        }
        for entry in expired {
            try? FileManager.default.removeItem(at: audioURL(for: entry.audioFileName))
        }

        kept = pruneUndisplayableEntries(from: kept)
        if !expired.isEmpty {
            removeStageTimings(for: Set(expired.map(\.id)))
            compactIndex(to: kept)
        }
        return kept
    }

    /// Parses the append-only index, one entry per line.
    ///
    /// **A line that will not decode costs that line and nothing else.** The old
    /// single JSON array meant one malformed byte cost the whole archive, which
    /// is why this format was chosen over raising the cap on the old one.
    private func readIndexLines() -> [TranscriptionLabEntry] {
        guard let text = try? String(contentsOf: indexURL, encoding: .utf8) else { return [] }
        var entries: [TranscriptionLabEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(TranscriptionLabEntry.self, from: data) else {
                continue
            }
            entries.append(entry)
        }
        return entries
    }

    /// Moves his existing JSON-array archive into the append-only format.
    ///
    /// Runs once. His 50 recordings are the measurement instrument two defects
    /// were found with, so the legacy file is left on disk afterwards rather than
    /// deleted: if this migration is ever wrong, the original is still there.
    private func migrateLegacyArchiveIfNeeded() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: indexURL.path),
              fileManager.fileExists(atPath: legacyIndexURL.path) else {
            return
        }

        guard let data = try? Data(contentsOf: legacyIndexURL),
              let entries = try? decoder.decode([TranscriptionLabEntry].self, from: data) else {
            // The legacy file exists and will not decode. Skipping quietly would
            // lose his whole history from the UI while the file sat there looking
            // fine, so it is moved aside exactly as an unreadable index is: the
            // bytes survive for recovery by hand, and the audio is untouched.
            quarantineUnreadableFile(at: legacyIndexURL)
            return
        }

        try? writeIndex(entries)
        // The original is set aside rather than deleted or left in place. Left in
        // place it would be re-migrated the moment the new index went missing,
        // silently resurrecting entries he had cleared. "migrated", not
        // "unreadable": nothing was wrong with it.
        quarantineUnreadableFile(at: legacyIndexURL, marker: "migrated")
    }

    func loadStageTimings() throws -> [UUID: TranscriptionLabStageTimings] {
        guard FileManager.default.fileExists(atPath: timingsURL.path) else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: timingsURL)
            let encodedTimings = try decoder.decode([String: TranscriptionLabStageTimings].self, from: data)
            return Dictionary(uniqueKeysWithValues: encodedTimings.compactMap { key, value in
                guard let entryID = UUID(uuidString: key) else {
                    return nil
                }

                return (entryID, value)
            })
        } catch {
            // This file holds two durations per entry and nothing else. It is
            // purely cosmetic, and it used to be able to delete every transcript
            // and every WAV: the least important file on disk destroying the most
            // important data. Losing the timings costs a number in the UI.
            quarantineUnreadableFile(at: timingsURL)
            return [:]
        }
    }

    /// `audioData` is optional, and the transcript is stored either way.
    ///
    /// 2026-08-24: his history stopped on 08-08 and he had not touched the
    /// setting. One guard in the caller governed both the WAV and the text,
    /// while the toggle spoke only about recordings. This store was always built
    /// for the split — 365-day transcripts, 7-day audio, pruned independently —
    /// so the text simply stops depending on the audio.
    func insert(
        _ entry: TranscriptionLabEntry,
        audioData: Data?,
        stageTimings: TranscriptionLabStageTimings
    ) throws {
        if let audioData {
            try FileManager.default.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)
            try audioData.write(to: audioURL(for: entry.audioFileName), options: .atomic)
        }

        migrateLegacyArchiveIfNeeded()

        // APPEND one line. The old store rewrote every held entry on every
        // insert, which is fine at 50 and quadratic at a year of them: raising
        // retention on that implementation would have made saving a dictation
        // slower every single day.
        try appendToIndex(entry)

        var timings = try loadStageTimings()
        timings[entry.id] = stageTimings
        try writeStageTimings(timings)
    }

    func deleteEntry(id: UUID) throws {
        var entries = try loadEntries()
        guard let entry = entries.first(where: { $0.id == id }) else { return }

        try? FileManager.default.removeItem(at: audioURL(for: entry.audioFileName))
        entries.removeAll { $0.id == id }

        var timings = try loadStageTimings()
        timings.removeValue(forKey: id)

        try writeIndex(entries)
        try writeStageTimings(timings)
    }

    func deleteAllEntries() {
        resetStoredArchive()
    }

    func audioURL(for audioFileName: String) -> URL {
        audioDirectoryURL.appendingPathComponent(audioFileName)
    }

    private var indexURL: URL {
        directoryURL.appendingPathComponent("transcription-lab-index.jsonl")
    }

    /// The pre-2026-08-04 single-JSON-array archive. Read once by the migration
    /// and then left alone, never deleted.
    private var legacyIndexURL: URL {
        directoryURL.appendingPathComponent("transcription-lab-index.json")
    }

    private var audioDirectoryURL: URL {
        directoryURL.appendingPathComponent("audio", isDirectory: true)
    }

    private var timingsURL: URL {
        directoryURL.appendingPathComponent("transcription-lab-timings.json")
    }

    private func pruneUndisplayableEntries(from entries: [TranscriptionLabEntry]) -> [TranscriptionLabEntry] {
        let visibleEntries = entries.filter { $0.audioDuration >= Self.minimumDisplayableAudioDuration }
        let removedEntries = entries.filter { $0.audioDuration < Self.minimumDisplayableAudioDuration }

        guard !removedEntries.isEmpty else {
            return visibleEntries
        }

        for entry in removedEntries {
            try? FileManager.default.removeItem(at: audioURL(for: entry.audioFileName))
        }

        try? writeIndex(visibleEntries)
        removeStageTimings(for: Set(removedEntries.map(\.id)))
        return visibleEntries
    }

    private func removeStageTimings(for entryIDs: Set<UUID>) {
        guard FileManager.default.fileExists(atPath: timingsURL.path),
              let data = try? Data(contentsOf: timingsURL),
              var encodedTimings = try? decoder.decode([String: TranscriptionLabStageTimings].self, from: data) else {
            return
        }

        for entryID in entryIDs {
            encodedTimings.removeValue(forKey: entryID.uuidString)
        }

        let timingPairs: [(UUID, TranscriptionLabStageTimings)] = encodedTimings.compactMap { key, value in
            guard let entryID = UUID(uuidString: key) else {
                return nil
            }

            return (entryID, value)
        }
        let timings = Dictionary(uniqueKeysWithValues: timingPairs)
        try? writeStageTimings(timings)
    }

    /// Rewrites the whole index. Only for compaction and deletion, never for a
    /// routine insert.
    private func writeIndex(_ entries: [TranscriptionLabEntry]) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let lines = try entries
            .sorted { $0.createdAt < $1.createdAt }
            .map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try text.write(to: indexURL, atomically: true, encoding: .utf8)
    }

    /// Adds one line to the end of the index.
    ///
    /// Opens for appending rather than reading and rewriting, so the cost of
    /// saving a dictation does not grow with how many he has already made.
    private func appendToIndex(_ entry: TranscriptionLabEntry) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let line = String(decoding: try encoder.encode(entry), as: UTF8.self) + "\n"
        guard let data = line.data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: indexURL.path) {
            try data.write(to: indexURL, options: .atomic)
            return
        }
        // `forUpdating`, not `forWritingTo`: the newline repair below has to READ
        // the last byte, and a write-only handle throws on read. That mistake
        // made every insert fail, which the retention tests caught immediately.
        let handle = try FileHandle(forUpdating: indexURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        // Repair a missing trailing newline BEFORE appending. Found by
        // `testInsertingIntoACorruptArchiveStillKeepsBothTheOldAudioAndTheNew` on
        // 2026-08-04: without this, a file whose last line was cut short by a
        // partial write or a crash gets the next entry glued onto it, and ONE
        // malformed line then costs TWO recordings instead of the one already
        // damaged. The whole point of this format is that damage stays local.
        let end = try handle.offset()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let lastByte = try handle.read(upToCount: 1)
            if lastByte != Data([0x0A]) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
            }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: data)
    }

    /// Rewrites the index without the expired lines, so an append-only file does
    /// not grow forever with entries nobody can see.
    private func compactIndex(to entries: [TranscriptionLabEntry]) {
        try? writeIndex(entries)
    }

    private func writeStageTimings(_ timings: [UUID: TranscriptionLabStageTimings]) throws {
        let encodedTimings = Dictionary(uniqueKeysWithValues: timings.map { key, value in
            (key.uuidString, value)
        })
        let timingsData = try encoder.encode(encodedTimings)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try timingsData.write(to: timingsURL, options: .atomic)
    }

    /// Moves a file that could not be decoded out of the way, keeping its bytes.
    ///
    /// Deliberately a rename and not a delete. Whatever is in there was written
    /// by this app and may still hold recoverable entries; a human with a text
    /// editor can get them back, and nothing else on disk is touched. The
    /// counter means a second corruption cannot overwrite the first copy, which
    /// would otherwise lose the recovery file on the very next launch.
    ///
    /// Failing silently is correct here. This runs on a path that is already
    /// handling one failure, and being unable to move the file is not a reason
    /// to make the app unusable: the caller carries on with an empty archive
    /// either way, and the audio is untouched regardless.
    private func quarantineUnreadableFile(at url: URL, marker: String = "unreadable") {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }

        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1
        var destination = directoryURL.appendingPathComponent("\(base).\(marker)-\(counter).\(ext)")
        while fileManager.fileExists(atPath: destination.path) {
            counter += 1
            destination = directoryURL.appendingPathComponent("\(base).\(marker)-\(counter).\(ext)")
        }

        try? fileManager.moveItem(at: url, to: destination)
    }

    /// Deletes everything: index, timings and audio.
    ///
    /// **Only for Clear History**, where destroying it all is exactly what he
    /// asked for. It must never be reachable from an error path; that is the
    /// 2026-08-03 bug, and the reason this comment says so.
    private func resetStoredArchive() {
        try? FileManager.default.removeItem(at: indexURL)
        // The legacy array too, or Clear History would leave it behind and the
        // migration would resurrect everything on the next launch.
        try? FileManager.default.removeItem(at: legacyIndexURL)
        try? FileManager.default.removeItem(at: timingsURL)
        try? FileManager.default.removeItem(at: audioDirectoryURL)
    }

    private static var defaultDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("GhostPepper", isDirectory: true)
            .appendingPathComponent("transcription-lab", isDirectory: true)
    }
}
