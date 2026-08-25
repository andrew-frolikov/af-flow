import Foundation

/// Streaming events emitted by `IndexBuilder` during a build or update.
enum IndexBuildEvent {
    case estimating
    case estimated(IndexBuildEstimate)
    /// Status line update: e.g. "Reading 2026-04-28/standup.md"
    case status(String)
    case entryWritten(slug: String, canonicalName: String)
    /// Updated meetings-processed count, derived from accumulated entry source_meetings.
    case meetingsProcessed(processed: Int, total: Int)
    case usage(QAUsage)
    case completed
    case error(String)
}

struct IndexBuildEstimate {
    let totalMeetingCount: Int
    let alreadyProcessedCount: Int
    let existingEntryCount: Int
    let likelyLowUSD: Double
    let likelyHighUSD: Double
    let modelDisplayName: String

    var unprocessedCount: Int { max(0, totalMeetingCount - alreadyProcessedCount) }
    var isResume: Bool { existingEntryCount > 0 }
    var nothingToDo: Bool { unprocessedCount == 0 && existingEntryCount > 0 }
}
