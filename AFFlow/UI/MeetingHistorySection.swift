import AppKit
import SwiftUI

/// The Meetings list inside the History window.
///
/// His ask on 2026-08-02: meetings should be where his recent dictations are,
/// rather than only behind the meeting window. He chose a separate section in
/// the same window over one interleaved timeline, so dictations stay above and
/// this sits below them.
///
/// **It lives in its own file deliberately.** `SettingsWindow.swift` is 160 KB
/// and the reason the big-file rule exists; adding to it is what makes it worse.
///
/// The list is read from disk ONCE, into `@State`, and refreshed on demand.
/// That is not an optimisation, it is a correctness requirement:
/// `MeetingHistory.loadEntries` reads every transcript file in full to pull the
/// title out of its header, so calling it from `body` would re-read every
/// meeting he has ever recorded on every redraw of this window.
struct MeetingHistorySection: View {
    @Environment(\.appTheme) private var theme
    /// Shared with the dictation list above, so one search box covers both.
    let searchText: String
    let onOpen: (URL) -> Void

    @State private var groups: [MeetingHistoryGroup] = []
    @State private var hasLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Meetings")
                    .font(theme.textFont(size: 15, weight: 600))
                Spacer()
                Button {
                    load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(theme.captionFont)
                }
                .buttonStyle(.borderless)
                .help("Re-read the meetings folder")
            }

            Text("Saved as markdown next to your notes. Deleting one here is not offered on purpose: these are files, and Finder is where you delete files.")
                .font(theme.captionFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if filteredGroups.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Meetings Yet" : "No Results",
                    systemImage: searchText.isEmpty ? "person.2.wave.2" : "magnifyingglass",
                    description: Text(
                        searchText.isEmpty
                            ? "Record a meeting and its transcript will appear here."
                            : "No meetings match \"\(searchText)\"."
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(filteredGroups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.date)
                                .font(theme.textFont(size: 11.5, weight: 600))
                                .foregroundStyle(theme.textSecondary)

                            ForEach(group.entries) { entry in
                                MeetingHistoryRow(entry: entry, onOpen: onOpen)
                            }
                        }
                    }
                }
            }
        }
        .task {
            guard !hasLoaded else { return }
            load()
        }
    }

    private var filteredGroups: [MeetingHistoryGroup] {
        MeetingHistoryGroup.filter(groups, matching: searchText)
    }

    private func load() {
        hasLoaded = true
        let directory = MeetingTranscriptSettings.effectiveSaveDirectory()
        groups = MeetingHistory.loadEntries(from: directory).map {
            MeetingHistoryGroup(date: $0.date, entries: $0.entries)
        }
    }
}

/// `MeetingHistory` returns tuples, which `ForEach` cannot identify. This gives
/// them a stable identity without changing that shared API.
struct MeetingHistoryGroup: Identifiable {
    let date: String
    let entries: [MeetingHistoryEntry]

    var id: String { date }

    /// What the Meetings list shows for a given search box.
    ///
    /// Deliberately not a computed property inside the view: a filter buried in
    /// a `body` is a filter no test can reach, and the two things it does are
    /// both easy to get quietly wrong.
    ///
    /// 1. **Airtable rows are dropped.** They are CSV data tables that happen to
    ///    live under the meetings folder. `MeetingHistory.loadEntries` returns
    ///    them because the meeting window's sidebar wants them; a list of
    ///    meetings does not.
    /// 2. **A group with no surviving entries disappears**, so a search never
    ///    leaves a bare date header with nothing under it.
    static func filter(_ groups: [MeetingHistoryGroup], matching searchText: String) -> [MeetingHistoryGroup] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.compactMap { group in
            let matching = group.entries.filter { entry in
                guard !entry.isAirtable else { return false }
                guard !needle.isEmpty else { return true }
                return entry.name.localizedCaseInsensitiveContains(needle)
                    || entry.dateFolder.localizedCaseInsensitiveContains(needle)
            }
            return matching.isEmpty ? nil : MeetingHistoryGroup(date: group.date, entries: matching)
        }
    }
}

private struct MeetingHistoryRow: View {
    @Environment(\.appTheme) private var theme
    let entry: MeetingHistoryEntry
    let onOpen: (URL) -> Void

    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                onOpen(entry.fileURL)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: entry.isGranola ? "square.and.arrow.down" : "waveform.and.mic")
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.textSecondary)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .help("Open this meeting")

            Button {
                copyTranscript()
            } label: {
                Image(systemName: didCopy ? "checkmark" : "square.on.square")
                    .font(theme.bodyFont)
            }
            .buttonStyle(.borderless)
            .help("Copy this transcript")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
            } label: {
                Image(systemName: "folder")
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
    }

    private func copyTranscript() {
        guard let contents = try? String(contentsOf: entry.fileURL, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(contents, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didCopy = false
        }
    }
}
