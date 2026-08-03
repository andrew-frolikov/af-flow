import Foundation

struct TranscriptionLabStageTimings: Codable, Equatable {
    let transcriptionDuration: TimeInterval?
    let cleanupDuration: TimeInterval?
}

final class TranscriptionLabStore {
    private static let minimumDisplayableAudioDuration: TimeInterval = 0.05

    private let directoryURL: URL
    private let maxEntries: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        directoryURL: URL? = nil,
        maxEntries: Int = 50
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL
        self.maxEntries = maxEntries
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func loadEntries() throws -> [TranscriptionLabEntry] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: indexURL)
            let entries = try decoder.decode([TranscriptionLabEntry].self, from: data)
            return pruneUndisplayableEntries(from: entries).sorted { $0.createdAt > $1.createdAt }
        } catch {
            // This used to call `resetStoredArchive()`, which deletes the index,
            // the timings AND the whole audio directory. One malformed byte took
            // every dictation and every WAV he had, and `insert()` calls this, so
            // it could fire while SAVING a new recording rather than only at
            // launch.
            //
            // A read failure means "I could not read this", never "this should be
            // destroyed". The audio is irreplaceable and the index is not, so the
            // index is moved aside and the audio is left exactly where it is,
            // orphaned but recoverable by hand.
            quarantineUnreadableFile(at: indexURL)
            return []
        }
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

    func insert(
        _ entry: TranscriptionLabEntry,
        audioData: Data,
        stageTimings: TranscriptionLabStageTimings
    ) throws {
        try FileManager.default.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)
        try audioData.write(to: audioURL(for: entry.audioFileName), options: .atomic)

        var entries = try loadEntries()
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { $0.createdAt > $1.createdAt }
        var timings = try loadStageTimings()
        timings[entry.id] = stageTimings

        let prunedEntries = Array(entries.prefix(maxEntries))
        let prunedEntryIDs = Set(entries.dropFirst(maxEntries).map(\.id))
        let prunedFileNames = Set(entries.dropFirst(maxEntries).map(\.audioFileName))
        for fileName in prunedFileNames {
            try? FileManager.default.removeItem(at: audioURL(for: fileName))
        }
        for entryID in prunedEntryIDs {
            timings.removeValue(forKey: entryID)
        }

        try writeEntries(prunedEntries)
        try writeStageTimings(timings)
    }

    func deleteEntry(id: UUID) throws {
        var entries = try loadEntries()
        guard let entry = entries.first(where: { $0.id == id }) else { return }

        try? FileManager.default.removeItem(at: audioURL(for: entry.audioFileName))
        entries.removeAll { $0.id == id }

        var timings = try loadStageTimings()
        timings.removeValue(forKey: id)

        try writeEntries(entries)
        try writeStageTimings(timings)
    }

    func deleteAllEntries() {
        resetStoredArchive()
    }

    func audioURL(for audioFileName: String) -> URL {
        audioDirectoryURL.appendingPathComponent(audioFileName)
    }

    private var indexURL: URL {
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

        try? writeEntries(visibleEntries)
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

    private func writeEntries(_ entries: [TranscriptionLabEntry]) throws {
        let data = try encoder.encode(entries)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: indexURL, options: .atomic)
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
    private func quarantineUnreadableFile(at url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }

        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1
        var destination = directoryURL.appendingPathComponent("\(base).unreadable-\(counter).\(ext)")
        while fileManager.fileExists(atPath: destination.path) {
            counter += 1
            destination = directoryURL.appendingPathComponent("\(base).unreadable-\(counter).\(ext)")
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
