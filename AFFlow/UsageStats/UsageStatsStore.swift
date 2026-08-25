import Combine
import Foundation

/// Tracks how the user actually exercises AF Flow. Counters are
/// UserDefaults-backed so they survive launches without needing a database;
/// each call appends a timestamp into a per-event date list, which lets us
/// answer both "lifetime use" and "last 7 days" without separate buckets.
///
/// Wired from AppState at the few hot paths (dictation completion, Granola
/// import, meeting recording finish, agent Q&A submission). The right-side
/// "Usage report" panel reads counts and shoves them at a local model so it
/// can write back a "spend more time on X" feature-request note.
@MainActor
final class UsageStatsStore: ObservableObject {
    enum Event: String, CaseIterable, Identifiable {
        case dictation
        case meetingRecord
        case granolaImport
        case peoplePage
        case qaQuestion

        var id: String { rawValue }

        /// Short label for axes/legends. Long-form descriptions live in the
        /// LLM prompt only — the chart axis can't render multiline text.
        var shortLabel: String {
            switch self {
            case .dictation: return "Dictation"
            case .meetingRecord: return "Meetings"
            case .granolaImport: return "Granola"
            case .peoplePage: return "People"
            case .qaQuestion: return "Q&A"
            }
        }

        /// Sentence the LLM sees so it can write a coherent feature request.
        var promptDescription: String {
            switch self {
            case .dictation: return "Voice-to-text dictation"
            case .meetingRecord: return "Native meeting recording"
            case .granolaImport: return "Granola transcript import"
            case .peoplePage: return "People-index pages generated"
            case .qaQuestion: return "Cross-meeting Q&A questions"
            }
        }
    }

    /// Reporting window the Usage report panel can flip between.
    enum Window: String, CaseIterable, Identifiable {
        case sevenDays
        case thirtyDays
        case lifetime

        var id: String { rawValue }
        var title: String {
            switch self {
            case .sevenDays: return "7 days"
            case .thirtyDays: return "30 days"
            case .lifetime: return "Lifetime"
            }
        }
        /// `nil` means lifetime (no cutoff). Otherwise the number of trailing
        /// days to include.
        var trailingDays: Int? {
            switch self {
            case .sevenDays: return 7
            case .thirtyDays: return 30
            case .lifetime: return nil
            }
        }
    }

    /// Bumped on every record so SwiftUI views observing the store re-render.
    @Published private(set) var version: Int = 0

    private let defaults: UserDefaults
    private static let storageKey = "usageStats.events.v1"

    /// Per-event timestamp lists: `[event.rawValue: [unix-seconds...]]`. We
    /// trim each list at write time so it can't grow without bound.
    private var events: [String: [TimeInterval]]

    private static let retentionDays: Int = 90
    private static let maxEventsPerKind: Int = 5_000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.dictionary(forKey: Self.storageKey) as? [String: [TimeInterval]] {
            self.events = raw
        } else {
            self.events = [:]
        }
    }

    func record(_ event: Event, count: Int = 1, at date: Date = Date()) {
        guard count > 0 else { return }
        let now = date.timeIntervalSince1970
        var list = events[event.rawValue] ?? []
        for _ in 0..<count { list.append(now) }
        list = trim(list)
        events[event.rawValue] = list
        defaults.set(events, forKey: Self.storageKey)
        version &+= 1
    }

    /// Lifetime count for one event.
    func lifetimeCount(_ event: Event) -> Int {
        events[event.rawValue]?.count ?? 0
    }

    /// Count for the trailing N days (default 7).
    func recentCount(_ event: Event, days: Int = 7, asOf reference: Date = Date()) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = reference.timeIntervalSince1970 - Double(days) * 86_400
        return (events[event.rawValue] ?? []).filter { $0 >= cutoff }.count
    }

    /// Snapshot used by both the chart and the LLM prompt. Returns events in
    /// `Event.allCases` order so the bar chart preserves a stable layout
    /// across renders.
    struct Snapshot: Equatable {
        struct Row: Equatable, Identifiable {
            let event: Event
            let lifetime: Int
            /// Count for the selected window. Equals `lifetime` when
            /// `window == .lifetime`, otherwise the trailing-N-days count.
            let windowed: Int
            var id: String { event.id }
        }
        let rows: [Row]
        let window: Window
        let totalWindowed: Int
        let totalLifetime: Int
    }

    /// One data point for the line chart: a single bucket, single event.
    struct SeriesPoint: Equatable, Identifiable {
        let event: Event
        let date: Date
        let count: Int
        var id: String { "\(event.rawValue)-\(Int(date.timeIntervalSince1970))" }
    }

    /// Returns flattened points (one row per bucket per event, including
    /// zeros) so Swift Charts can draw a continuous line per event.
    ///
    /// Bucketing:
    /// - 7 days  → 7 daily buckets ending today
    /// - 30 days → 30 daily buckets ending today
    /// - lifetime → monthly buckets from first event's month through this month
    func timeSeries(window: Window, asOf reference: Date = Date()) -> [SeriesPoint] {
        let calendar = Calendar(identifier: .gregorian)
        let bucketStarts: [Date]
        let bucketFor: (TimeInterval) -> Date?

        switch window {
        case .sevenDays, .thirtyDays:
            let days = window.trailingDays ?? 7
            let today = calendar.startOfDay(for: reference)
            bucketStarts = (0..<days).reversed().compactMap { i in
                calendar.date(byAdding: .day, value: -i, to: today)
            }
            bucketFor = { ts in
                let date = Date(timeIntervalSince1970: ts)
                return calendar.startOfDay(for: date)
            }
        case .lifetime:
            let allTimestamps = events.values.flatMap { $0 }
            guard let earliest = allTimestamps.min().map({ Date(timeIntervalSince1970: $0) }) else {
                return []
            }
            let firstMonth = calendar.dateInterval(of: .month, for: earliest)?.start ?? earliest
            let thisMonth = calendar.dateInterval(of: .month, for: reference)?.start ?? reference
            var monthList: [Date] = []
            var cursor = firstMonth
            while cursor <= thisMonth {
                monthList.append(cursor)
                guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
                cursor = next
            }
            bucketStarts = monthList
            bucketFor = { ts in
                let date = Date(timeIntervalSince1970: ts)
                return calendar.dateInterval(of: .month, for: date)?.start
            }
        }

        // Accumulate counts per (event, bucket).
        var counts: [Event: [Date: Int]] = [:]
        for event in Event.allCases {
            counts[event] = Dictionary(uniqueKeysWithValues: bucketStarts.map { ($0, 0) })
            for ts in events[event.rawValue] ?? [] {
                guard let bucket = bucketFor(ts) else { continue }
                if counts[event]?[bucket] != nil {
                    counts[event]?[bucket, default: 0] += 1
                }
            }
        }

        var points: [SeriesPoint] = []
        for event in Event.allCases {
            for bucket in bucketStarts {
                let c = counts[event]?[bucket] ?? 0
                points.append(SeriesPoint(event: event, date: bucket, count: c))
            }
        }
        return points
    }

    func snapshot(window: Window = .sevenDays, asOf reference: Date = Date()) -> Snapshot {
        let rows = Event.allCases.map { event in
            let lifetime = lifetimeCount(event)
            let windowed: Int
            if let days = window.trailingDays {
                windowed = recentCount(event, days: days, asOf: reference)
            } else {
                windowed = lifetime
            }
            return Snapshot.Row(event: event, lifetime: lifetime, windowed: windowed)
        }
        let totalWindowed = rows.reduce(0) { $0 + $1.windowed }
        let totalLifetime = rows.reduce(0) { $0 + $1.lifetime }
        return Snapshot(rows: rows, window: window, totalWindowed: totalWindowed, totalLifetime: totalLifetime)
    }

    private func trim(_ list: [TimeInterval]) -> [TimeInterval] {
        let cutoff = Date().timeIntervalSince1970 - Double(Self.retentionDays) * 86_400
        var filtered = list.filter { $0 >= cutoff }
        if filtered.count > Self.maxEventsPerKind {
            filtered = Array(filtered.suffix(Self.maxEventsPerKind))
        }
        return filtered
    }

    // MARK: - Disk backfill

    /// Bumped to `v2` after the date-inference fix: the original v1 backfill
    /// used filesystem `creationDate`, which collapsed years of meetings into
    /// "whenever the folder was last restored/synced". v2 parses the dated
    /// folder name (e.g. `2026-04-24/foo.md` → 2026-04-24) so historical
    /// events land on their real calendar day.
    private static let backfillSentinelKey = "usageStats.backfill.v2"
    /// Headers we read from each meeting markdown's frontmatter to decide
    /// whether the file was native or Granola-imported. Cheap substring
    /// check — we don't parse YAML.
    private static let granolaImportMarker = "imported_from: granola"
    /// Cap the per-file read so a stray multi-megabyte transcript can't make
    /// the backfill scan stall the launch path.
    private static let frontmatterReadByteLimit = 1024

    /// One-time scan that seeds counters for files that already exist on
    /// disk before usage tracking was wired up. Runs at most once per device
    /// (gated by a UserDefaults sentinel). The save directory is the user's
    /// meetings archive — backfill reads:
    ///   - Meeting `.md` files in dated subfolders (skips `.indexes`)
    ///   - Each file's frontmatter for the `imported_from: granola` marker
    ///     to classify the row as Granola vs. native
    ///   - `<saveDir>/.indexes/people/*.md` for people-page count
    /// Timestamps come from each file's creation date (falls back to
    /// modification date) so the 7/30-day windows place historical events
    /// on the right calendar day.
    func backfillFromDisk(meetingsSaveDir: URL) {
        if defaults.bool(forKey: Self.backfillSentinelKey) { return }
        // Drop any timestamps previously written by an earlier backfill version
        // (or by in-session activity that's also on disk now). Disk is the
        // source of truth for these three; dictation and qa stay untouched.
        events[Event.meetingRecord.rawValue] = []
        events[Event.granolaImport.rawValue] = []
        events[Event.peoplePage.rawValue] = []
        let (native, granola) = Self.scanMeetings(saveDir: meetingsSaveDir)
        let people = Self.scanPeople(saveDir: meetingsSaveDir)
        merge(native, into: .meetingRecord)
        merge(granola, into: .granolaImport)
        merge(people, into: .peoplePage)
        defaults.set(true, forKey: Self.backfillSentinelKey)
        defaults.set(events, forKey: Self.storageKey)
        version &+= 1
    }

    private func merge(_ timestamps: [TimeInterval], into event: Event) {
        guard !timestamps.isEmpty else { return }
        var list = events[event.rawValue] ?? []
        list.append(contentsOf: timestamps)
        list.sort()
        events[event.rawValue] = list
    }

    private static func scanMeetings(saveDir: URL) -> (native: [TimeInterval], granola: [TimeInterval]) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: saveDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }
        var native: [TimeInterval] = []
        var granola: [TimeInterval] = []
        for folder in folders {
            // Only descend into date-shaped folders (YYYY-MM-DD). The
            // `.indexes` directory is hidden so it's already filtered above,
            // but defensively skip anything that doesn't look like a date.
            let folderName = folder.lastPathComponent
            guard isDatedFolder(folderName), let folderDate = parseDatedFolder(folderName) else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            // Folder-date is the source of truth — filesystem creation dates
            // get clobbered by restores/syncs and stop being meaningful.
            let ts = folderDate.timeIntervalSince1970
            for file in files where file.pathExtension == "md" {
                if fileMentionsGranolaImport(file) {
                    granola.append(ts)
                } else {
                    native.append(ts)
                }
            }
        }
        return (native, granola)
    }

    /// "2026-04-24" → noon-local that day. Noon avoids edge cases where a
    /// midnight timestamp slides into the previous day under different
    /// time-zone math.
    private static func parseDatedFolder(_ name: String) -> Date? {
        let parts = name.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = y
        components.month = m
        components.day = d
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)
    }

    private static func scanPeople(saveDir: URL) -> [TimeInterval] {
        let fm = FileManager.default
        let peopleDir = saveDir
            .appendingPathComponent(".indexes", isDirectory: true)
            .appendingPathComponent("people", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(
            at: peopleDir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "_manifest.json" }
            .map { fileTimestamp($0) }
    }

    private static func isDatedFolder(_ name: String) -> Bool {
        // Quick shape check: 10 chars, dashes at positions 4 and 7, rest
        // digits. Cheap enough to do per-folder without regex.
        guard name.count == 10 else { return false }
        let chars = Array(name)
        guard chars[4] == "-", chars[7] == "-" else { return false }
        for (i, c) in chars.enumerated() where i != 4 && i != 7 {
            guard c.isNumber else { return false }
        }
        return true
    }

    private static func fileTimestamp(_ url: URL) -> TimeInterval {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        if let created = values?.creationDate { return created.timeIntervalSince1970 }
        if let modified = values?.contentModificationDate { return modified.timeIntervalSince1970 }
        return Date().timeIntervalSince1970
    }

    private static func fileMentionsGranolaImport(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: frontmatterReadByteLimit),
              let head = String(data: data, encoding: .utf8) else { return false }
        return head.contains(granolaImportMarker)
    }
}
