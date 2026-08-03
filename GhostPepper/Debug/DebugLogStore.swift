import Foundation
import Combine

enum DebugLogCategory: String, Codable {
    case hotkey = "Hotkey"
    case ocr = "OCR"
    case cleanup = "Cleanup"
    case model = "Model"
    case performance = "Performance"
}

struct DebugLogEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let timestamp: Date
    let category: DebugLogCategory
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date,
        category: DebugLogCategory,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

/// The app's record of what it decided, and the only place a question about
/// last week can be answered from.
///
/// **Retention is a time window, not an entry count.** It used to be 250
/// entries, which was about two days of his usage, so on 2026-08-02 the
/// evidence for "did the mistakes get worse on Wednesday" had already been
/// overwritten by the time he asked. Thirty days is wide enough that a
/// complaint about last week still has something behind it.
///
/// **Entries are appended, not rewritten.** The previous implementation
/// re-encoded and rewrote every entry it held on every single `record()`.
/// That was tolerable at 250 entries and would have been quadratic at thirty
/// days: the same shape as meeting bug 15, arriving through the change that
/// was meant to help. One JSON object per line means a write costs one line
/// regardless of how much history sits above it, and it means a write killed
/// half way through costs that one line rather than the file.
final class DebugLogStore: ObservableObject {
    /// The recent window held in memory for the debug window to display.
    /// Disk holds the full retention period; this is only what the UI shows.
    @Published private(set) var entries: [DebugLogEntry] = []

    private let maxEntries: Int
    private let retention: TimeInterval
    private let storageURL: URL
    private let now: () -> Date
    private let formatter: DateFormatter
    private var liveViewerCount = 0

    /// Guards `handle` and every touch of the file. One process and one store,
    /// so a lock is enough; what it must prevent is two appends interleaving
    /// inside a single line, which would corrupt both.
    private let fileLock = NSLock()
    private var handle: FileHandle?

    init(
        maxEntries: Int = 20_000,
        retention: TimeInterval = 30 * 24 * 60 * 60,
        storageURL: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.maxEntries = maxEntries
        self.retention = retention
        self.storageURL = storageURL ?? Self.defaultStorageURL
        self.now = now
        self.formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        migrateLegacyLogIfPresent()

        // Load, drop anything past the retention window, and write the file
        // back only if that dropped something. Compaction happens once per
        // launch; every write after it is an append.
        let loaded = loadEntries()
        let kept = loaded.filter { now().timeIntervalSince($0.timestamp) <= retention }
        if kept.count != loaded.count {
            rewriteFile(with: kept)
        }
        entries = Array(kept.suffix(maxEntries))
    }

    deinit {
        try? handle?.close()
    }

    var formattedText: String {
        entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.category.rawValue)] \(entry.message)"
        }
        .joined(separator: "\n\n")
    }

    func record(category: DebugLogCategory, message: String) {
        let entry = DebugLogEntry(
            timestamp: now(),
            category: category,
            message: message
        )

        entries.append(entry)
        trimToCapacity()
        append(entry)
    }

    func beginLiveViewing() {
        liveViewerCount += 1
    }

    func endLiveViewing() {
        liveViewerCount = max(0, liveViewerCount - 1)
    }

    func recordSensitive(category: DebugLogCategory, message: String) {
        guard liveViewerCount > 0 else {
            return
        }

        record(category: category, message: message)
    }

    func clear() {
        entries.removeAll()
        rewriteFile(with: [])
    }

    /// Bounds what the UI holds. It does NOT bound the file: the whole point of
    /// this change is that disk keeps thirty days even though the window shows
    /// a slice of it.
    private func trimToCapacity() {
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    // MARK: - Disk

    private func append(_ entry: DebugLogEntry) {
        guard var line = try? JSONEncoder().encode(entry) else {
            return
        }
        line.append(0x0A)

        fileLock.lock()
        defer { fileLock.unlock() }

        guard let handle = openHandleLocked() else {
            return
        }
        // `seekToEnd` before every write rather than trusting the offset: the
        // handle survives a compaction that truncated the file underneath it.
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private func openHandleLocked() -> FileHandle? {
        if let handle {
            return handle
        }
        let directory = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: storageURL.path) {
            FileManager.default.createFile(atPath: storageURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: storageURL)
        return handle
    }

    private func loadEntries() -> [DebugLogEntry] {
        guard let data = try? Data(contentsOf: storageURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        // A line that does not decode is skipped rather than fatal. The case
        // that matters is the last one: a process killed mid-append leaves a
        // half-written object, and losing that single entry must not cost the
        // thirty days above it.
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(DebugLogEntry.self, from: Data($0.utf8))
        }
    }

    /// Replaces the file wholesale. Only two callers: the once-per-launch
    /// compaction, and `clear()`.
    private func rewriteFile(with entries: [DebugLogEntry]) {
        let encoder = JSONEncoder()
        var data = Data()
        for entry in entries {
            guard var line = try? encoder.encode(entry) else { continue }
            line.append(0x0A)
            data.append(line)
        }

        fileLock.lock()
        defer { fileLock.unlock() }

        let directory = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
        // The atomic write replaced the inode, so a handle held from before it
        // now points at a file nothing will ever read again. Drop it and let
        // the next append reopen.
        try? handle?.close()
        handle = nil
    }

    /// Carries his existing history into the line format.
    ///
    /// The live log on his Mac is a JSON array at `debug-log.json` holding
    /// everything the app has recorded. Changing format without this would
    /// answer "what happened last week" by deleting last week.
    ///
    /// Runs only when the line-format file does not yet exist, so it happens
    /// once and a second launch cannot append his history a second time. The
    /// old file is left in place rather than deleted: it costs 50 KB and it is
    /// the only copy until the new one has survived a while.
    private func migrateLegacyLogIfPresent() {
        guard !FileManager.default.fileExists(atPath: storageURL.path) else {
            return
        }
        let legacyURL = storageURL
            .deletingLastPathComponent()
            .appendingPathComponent("debug-log.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode([DebugLogEntry].self, from: data),
              !legacy.isEmpty else {
            return
        }

        rewriteFile(with: legacy)
    }

    private static var defaultStorageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("GhostPepper", isDirectory: true)
            .appendingPathComponent("debug-log.jsonl")
    }
}
