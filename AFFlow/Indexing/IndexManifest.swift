import Foundation

/// Tracks which meetings have been folded into a given index, and a snapshot of
/// canonical names + aliases used to ground the LLM's fuzzy-merge decisions on
/// incremental updates.
///
/// Persisted at `<save dir>/.indexes/<kind>/_manifest.json`.
struct IndexManifest: Codable, Equatable {
    let version: Int
    let kind: IndexKind
    var builtAt: Date
    var processedMeetings: [String: ProcessedMeeting]

    struct ProcessedMeeting: Codable, Equatable {
        let processedAt: Date
        let entriesTouched: [String]

        enum CodingKeys: String, CodingKey {
            case processedAt = "processed_at"
            case entriesTouched = "entries_touched"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case kind
        case builtAt = "built_at"
        case processedMeetings = "processed_meetings"
    }

    static let currentVersion = 1

    static func empty(kind: IndexKind) -> IndexManifest {
        IndexManifest(
            version: currentVersion,
            kind: kind,
            builtAt: Date(),
            processedMeetings: [:]
        )
    }

    func isProcessed(meetingPath: String) -> Bool {
        processedMeetings[meetingPath] != nil
    }

    mutating func markProcessed(meetingPath: String, entriesTouched: [String], at date: Date = Date()) {
        processedMeetings[meetingPath] = ProcessedMeeting(processedAt: date, entriesTouched: entriesTouched)
    }

    /// Returns a `[canonical_name: [aliases]]` snapshot derived from the entry
    /// files currently on disk. Used by the incremental prompt so the agent can
    /// fuzzy-match a new mention to an existing entry rather than create a dupe.
    static func aliasSnapshot(in saveDir: URL, kind: IndexKind) -> [String: [String]] {
        let root = MarkdownArchivePaths.indexRoot(in: saveDir, kind: kind)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [:] }

        var snapshot: [String: [String]] = [:]
        for url in entries where url.pathExtension == "md" && !url.lastPathComponent.hasPrefix("_") {
            guard let entry = try? IndexEntryFile.read(from: url) else { continue }
            snapshot[entry.canonicalName] = entry.aliases
        }
        return snapshot
    }
}

extension IndexManifest {
    enum IOError: Error {
        case writeFailed(String)
    }

    static func load(from url: URL) throws -> IndexManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IndexManifest.self, from: data)
    }

    /// Loads if file exists; returns an empty manifest otherwise.
    static func loadOrEmpty(at url: URL, kind: IndexKind) -> IndexManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty(kind: kind)
        }
        return (try? load(from: url)) ?? .empty(kind: kind)
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
