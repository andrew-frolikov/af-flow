import Foundation

struct TranscriptionLabStageTimings: Codable, Equatable {
    let transcriptionDuration: TimeInterval?
    let cleanupDuration: TimeInterval?
}

/// One line of the append-only timings file: an entry id and its two durations.
///
/// A separate type from `TranscriptionLabStageTimings` on purpose. The stored
/// line has to carry the id, because the file is no longer a dictionary keyed by
/// one; making the id a property of the public timings struct instead would put
/// a storage detail into the type the UI reads.
private struct TranscriptionLabStageTimingLine: Codable {
    let id: String
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
        // Reading PRUNES, and pruning removes timings. Without this the prune
        // would read an empty new file, decline to remove anything, and the
        // durations of entries it had just dropped would reappear the moment the
        // migration finally ran on the next read.
        migrateLegacyStageTimingsIfNeeded()

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
        lineData(of: indexURL).compactMap { try? decoder.decode(TranscriptionLabEntry.self, from: $0) }
    }

    /// Splits an append-only file into lines AS BYTES, never as a String.
    ///
    /// Codex, 2026-08-24: `String(contentsOf:encoding:.utf8)` fails on the whole
    /// file if a single byte anywhere in it is not valid UTF-8, so one damaged
    /// byte returned an empty archive — hiding every intact line and defeating
    /// the exact property this format exists to provide. The comment above
    /// claimed damage stayed local while the reader could not deliver it.
    ///
    /// Splitting the raw `Data` on newlines keeps a damaged line's blast radius
    /// to that line: the slice fails to decode, is skipped, and its neighbours
    /// are untouched.
    private func lineData(of url: URL) -> [Data] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let slices: [Data.SubSequence] = data.split(
            omittingEmptySubsequences: true,
            whereSeparator: { (byte: UInt8) in byte == 0x0A }
        )
        return slices.map { slice in Data(slice) }
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

        // Write first, and only then retire the original. Codex found this shape
        // on the timings migration on 2026-08-24; it was already here, and it is
        // worse here, because this file is his transcripts rather than two
        // durations. A swallowed write failure followed by an unconditional
        // rename leaves the only copy of his history under a name nothing reads.
        do {
            try writeIndex(entries)
        } catch {
            return
        }
        // The original is set aside rather than deleted or left in place. Left in
        // place it would be re-migrated the moment the new index went missing,
        // silently resurrecting entries he had cleared. "migrated", not
        // "unreadable": nothing was wrong with it.
        quarantineUnreadableFile(at: legacyIndexURL, marker: "migrated")
    }

    /// Still `throws` although it no longer can: every caller writes `try`, and
    /// the read path is not where a signature churn earns its diff.
    func loadStageTimings() throws -> [UUID: TranscriptionLabStageTimings] {
        migrateLegacyStageTimingsIfNeeded()
        return readStageTimingLines()
    }

    /// Parses the append-only timings file, one record per line.
    ///
    /// **A line that will not decode costs that line and nothing else**, exactly
    /// as `readIndexLines` does for the index next to it. The old single JSON
    /// dictionary could not offer that: one malformed byte took every duration he
    /// had, and the whole file was quarantined to keep the bytes recoverable.
    /// There is nothing to quarantine now, because a damaged line is simply
    /// skipped and its bytes stay where they are.
    ///
    /// The file is append-only, so a re-inserted entry appears more than once and
    /// the LAST line is the current one. Iterating in file order and overwriting
    /// is what makes that true.
    private func readStageTimingLines() -> [UUID: TranscriptionLabStageTimings] {
        var timings: [UUID: TranscriptionLabStageTimings] = [:]
        for data in lineData(of: timingsURL) {
            guard let record = try? decoder.decode(TranscriptionLabStageTimingLine.self, from: data),
                  let entryID = UUID(uuidString: record.id) else {
                continue
            }
            timings[entryID] = TranscriptionLabStageTimings(
                transcriptionDuration: record.transcriptionDuration,
                cleanupDuration: record.cleanupDuration
            )
        }
        return timings
    }

    /// Moves his existing timings dictionary into the append-only format.
    ///
    /// Runs once, and mirrors `migrateLegacyArchiveIfNeeded` deliberately: same
    /// guard, same quarantine, same "migrated" marker. His 186 entries carry the
    /// durations the history tab shows, and losing them to a format change would
    /// be the least important file on disk taking real data with it — which is
    /// the exact 2026-08-03 failure this store was rebuilt to make impossible.
    private func migrateLegacyStageTimingsIfNeeded() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: timingsURL.path),
              fileManager.fileExists(atPath: legacyTimingsURL.path) else {
            return
        }

        guard let data = try? Data(contentsOf: legacyTimingsURL),
              let encodedTimings = try? decoder.decode([String: TranscriptionLabStageTimings].self, from: data) else {
            // Skipping quietly would empty every duration in the UI while the
            // file sat on disk looking fine. The bytes are set aside instead.
            quarantineUnreadableFile(at: legacyTimingsURL)
            return
        }

        let timings = Dictionary(uniqueKeysWithValues: encodedTimings.compactMap { key, value -> (UUID, TranscriptionLabStageTimings)? in
            guard let entryID = UUID(uuidString: key) else {
                return nil
            }

            return (entryID, value)
        })
        // WRITE FIRST, AND ONLY THEN RETIRE THE ORIGINAL.
        //
        // Codex, 2026-08-24: this was `try? write` followed by an unconditional
        // rename. A write that failed — a full disk, a permissions fault — was
        // swallowed, the legacy file was renamed anyway, and the only surviving
        // copy of his durations became a `.migrated-1` file no reader looks at.
        // The least important file on disk taking real data with it, again.
        do {
            try writeStageTimings(timings)
        } catch {
            // The new file is not there. The legacy one is now the only copy, so
            // it stays exactly where it is and the migration retries next time.
            return
        }
        // Set aside rather than deleted or left in place. Left in place it would
        // be re-migrated the moment the new file went missing, resurrecting
        // durations for entries he had cleared.
        quarantineUnreadableFile(at: legacyTimingsURL, marker: "migrated")
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
        // BEFORE the append, not after. Appending first would create the new
        // timings file, and the migration guard would then decline to move his
        // existing durations across — losing every one of them on the first
        // dictation after the upgrade, without an error anywhere.
        migrateLegacyStageTimingsIfNeeded()

        // APPEND one line. The old store rewrote every held entry on every
        // insert, which is fine at 50 and quadratic at a year of them: raising
        // retention on that implementation would have made saving a dictation
        // slower every single day.
        try appendToIndex(entry)

        // APPEND one line here too, for the same reason and at the same cost.
        //
        // This used to load, mutate and rewrite the ENTIRE timings dictionary on
        // every insert. It went unnoticed because a transcript was only archived
        // when audio saving was on, which for him was almost never. The 2026-08-24
        // history fix made every dictation archive a transcript, which put that
        // whole-file rewrite between his key release and his clipboard:
        // `archiveRecordingForLab` is awaited BEFORE `textPaster.paste`, and his
        // latency is already sore at a 1.59 s median and a 4.0 s p90. Codex found
        // it in round 4 of that session.
        //
        // The index was made append-only for exactly this. Leaving the timings on
        // the old shape meant the cost the restructure removed came back through
        // the smaller file sitting next to it.
        try appendStageTiming(stageTimings, for: entry.id)
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
        directoryURL.appendingPathComponent("transcription-lab-timings.jsonl")
    }

    /// His timings as they were stored until 2026-08-24: one JSON dictionary
    /// keyed by entry id, rewritten whole on every insert.
    private var legacyTimingsURL: URL {
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

    /// Append-only is not append-forever. When retention drops an entry its
    /// timing goes with it, and the rewrite that does so also collapses the
    /// duplicate lines a rerun leaves behind. Same job `compactIndex` does for
    /// the index, on the same schedule, and never on the insert path.
    ///
    /// It rewrites ONLY when something was actually removed. A rewrite that
    /// changes nothing would still discard any damaged line the reader is
    /// deliberately skipping over, turning a locally damaged file into a quietly
    /// truncated one.
    private func removeStageTimings(for entryIDs: Set<UUID>) {
        var timings = readStageTimingLines()
        guard !timings.isEmpty else { return }

        var removedAny = false
        for entryID in entryIDs where timings.removeValue(forKey: entryID) != nil {
            removedAny = true
        }
        guard removedAny else { return }

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
        try appendLine(String(decoding: try encoder.encode(entry), as: UTF8.self), to: indexURL)
    }

    /// Adds one timing record to the end of the timings file.
    private func appendStageTiming(_ stageTimings: TranscriptionLabStageTimings, for entryID: UUID) throws {
        let record = TranscriptionLabStageTimingLine(
            id: entryID.uuidString,
            transcriptionDuration: stageTimings.transcriptionDuration,
            cleanupDuration: stageTimings.cleanupDuration
        )
        try appendLine(String(decoding: try encoder.encode(record), as: UTF8.self), to: timingsURL)
    }

    /// Appends one line to an append-only file, creating it if needed.
    ///
    /// Shared by the index and the timings so the two files cannot drift apart
    /// on the property that matters: the cost of saving a dictation does not
    /// grow with how many he has already made.
    private func appendLine(_ line: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = (line + "\n").data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        // `forUpdating`, not `forWritingTo`: the newline repair below has to READ
        // the last byte, and a write-only handle throws on read. That mistake
        // made every insert fail, which the retention tests caught immediately.
        let handle = try FileHandle(forUpdating: url)
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

    /// Rewrites the whole timings file. Only for compaction, deletion and the
    /// one-off migration, never for a routine insert.
    ///
    /// Sorted by id so the bytes are a function of the content alone. A
    /// dictionary's iteration order is not stable across runs, and an
    /// append-only file whose rewrites reshuffle everything is one whose
    /// diffs and recovery-by-hand are needlessly hard to read.
    private func writeStageTimings(_ timings: [UUID: TranscriptionLabStageTimings]) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let lines = try timings
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { entryID, value -> String in
                let record = TranscriptionLabStageTimingLine(
                    id: entryID.uuidString,
                    transcriptionDuration: value.transcriptionDuration,
                    cleanupDuration: value.cleanupDuration
                )
                return String(decoding: try encoder.encode(record), as: UTF8.self)
            }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try text.write(to: timingsURL, atomically: true, encoding: .utf8)
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
        // The legacy timings dictionary too, for the same reason as the legacy
        // index above: left behind, the migration would resurrect every duration
        // he had just cleared on the very next read.
        try? FileManager.default.removeItem(at: legacyTimingsURL)
        try? FileManager.default.removeItem(at: audioDirectoryURL)
    }

    private static var defaultDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("GhostPepper", isDirectory: true)
            .appendingPathComponent("transcription-lab", isDirectory: true)
    }
}
