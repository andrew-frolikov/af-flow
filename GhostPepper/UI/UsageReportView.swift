import Charts
import SwiftUI

/// "Usage report" pane on the right sidebar. Renders a bar chart of how many
/// times the user has hit each feature in the trailing window, then offers a
/// "Generate feature requests" button that asks the currently-selected
/// cleanup model to write a short note in the user's voice describing what
/// they used most and what they'd like AF Flow to focus on next.
///
/// Generation is local-only (cleanup-model picker, not the agent backend) so
/// it never spends Claude API credits.
struct UsageReportView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var usageStats: UsageStatsStore
    @ObservedObject var cleanupManager: TextCleanupManager

    /// Active reporting window. Defaults to 7 days (matches the feature-
    /// request prompt below); the picker at the top can switch this.
    @State private var window: UsageStatsStore.Window = .sevenDays
    @State private var generatedNote: String = ""
    @State private var isGenerating: Bool = false
    @State private var generationError: String? = nil

    private var snapshot: UsageStatsStore.Snapshot {
        _ = usageStats.version
        return usageStats.snapshot(window: window)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                windowPicker
                summaryHeader
                chart
                generateSection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
    }

    private var windowPicker: some View {
        Picker("", selection: $window) {
            ForEach(UsageStatsStore.Window.allCases) { w in
                Text(w.title).tag(w)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.window.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(snapshot.totalWindowed)")
                    .font(.system(size: 26, weight: .semibold))
                Text("uses")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
            if snapshot.window != .lifetime {
                Text("\(snapshot.totalLifetime) lifetime")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By feature · \(snapshot.window.title.lowercased())")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .textCase(.uppercase)
            if snapshot.totalWindowed == 0 && snapshot.totalLifetime == 0 {
                Text("No usage tracked yet. Run dictation, record a meeting, build a People index, or ask a Q&A question, and counts show up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                Chart(snapshot.rows) { row in
                    BarMark(
                        x: .value("Feature", row.event.shortLabel),
                        y: .value("Uses", row.windowed)
                    )
                    .foregroundStyle(theme.accent.gradient)
                    .annotation(position: .top, alignment: .center) {
                        if row.windowed > 0 {
                            Text("\(row.windowed)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 180)
                rowBreakdown
            }
        }
    }

    private var rowBreakdown: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(snapshot.rows) { row in
                HStack(spacing: 6) {
                    Text(row.event.shortLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .frame(width: 70, alignment: .leading)
                    if snapshot.window == .lifetime {
                        Text("\(row.lifetime) lifetime")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        Text("\(row.windowed) in window · \(row.lifetime) lifetime")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(.top, 4)
    }

    private var generateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Feature requests")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .textCase(.uppercase)

            Button(action: generate) {
                HStack(spacing: 6) {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(isGenerating ? "Writing…" : "Generate feature requests")
                }
            }
            .disabled(isGenerating || snapshot.totalLifetime == 0)
            .help(snapshot.totalLifetime == 0
                  ? "Use the app a bit first. Needs at least one tracked event."
                  : "Asks the selected cleanup model to write a short note about what to focus on next.")

            Text("Uses the cleanup-model picker (\(cleanupManager.selectedCleanupModelDisplayName)). No cloud calls.")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)

            if cleanupManager.selectedCleanupModelKind == .qwen35_0_8b_q4_k_m {
                Text("Tip: 0.8B can mis-rank tiny tables. Switch to Qwen 3.5 2B or larger for better prose.")
                    .font(.system(size: 10))
                    .foregroundColor(theme.accent.opacity(0.85))
            }

            if let generationError {
                Text(generationError)
                    .font(.system(size: 11))
                    .foregroundColor(theme.statusLive.opacity(0.85))
                    .padding(.top, 4)
            }

            if !generatedNote.isEmpty {
                Text(generatedNote)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accent.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.accent.opacity(0.25), lineWidth: 1)
                    )
                    .padding(.top, 4)
            }
        }
    }

    private func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        generationError = nil
        let snapshotForPrompt = snapshot
        let userText = Self.usageStatsBlock(from: snapshotForPrompt)
        let prompt = Self.systemPrompt
        Task { @MainActor in
            do {
                let result = try await cleanupManager.clean(
                    text: userText,
                    prompt: prompt,
                    modelKind: cleanupManager.selectedCleanupModelKind
                )
                generatedNote = result
            } catch {
                generationError = "Couldn't generate: \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    private static let systemPrompt = """
    You are writing a short, casual feature-request note from a AF Flow user to the development team.

    The user message starts with "WINDOW PHRASE: …". Use that phrase VERBATIM in your first sentence so the team knows what time period this covers.

    The user message also contains a pre-ranked usage report. The TOP feature line tells you what they use most. The ZERO list tells you what they don't touch. Trust those lines exactly. DO NOT swap or invert them.

    Write 3–5 first-person ("I") sentences:
    - First sentence: open with "Looking at my usage <WINDOW PHRASE>" or similar, then name the top feature (use its label verbatim) and note how heavily it's used.
    - Mention one or two other features they actually use.
    - Acknowledge what they don't use (the ZERO list) only if relevant.
    - End with one concrete request: the team should spend more time on the TOP feature.

    No bullet points. No headers. No markdown. Don't quote raw numbers: say "heavily", "occasionally", "barely". Stay grounded in the ranking; do not invent usage you don't see.
    """

    private static func windowPhrase(_ window: UsageStatsStore.Window) -> String {
        switch window {
        case .sevenDays: return "over the last 7 days"
        case .thirtyDays: return "over the last 30 days"
        case .lifetime: return "over all time"
        }
    }

    private static func usageStatsBlock(from snapshot: UsageStatsStore.Snapshot) -> String {
        // Pre-rank the rows so a small local model doesn't have to compare
        // numbers itself — it has historically gotten this wrong (e.g.
        // labeled the lowest-count row as "most used").
        let used = snapshot.rows.filter { $0.windowed > 0 }.sorted { $0.windowed > $1.windowed }
        let zero = snapshot.rows.filter { $0.windowed == 0 }

        var lines: [String] = []
        lines.append("WINDOW PHRASE: \(windowPhrase(snapshot.window))")
        lines.append("Total uses in this window: \(snapshot.totalWindowed)")
        lines.append("Total uses lifetime: \(snapshot.totalLifetime)")
        lines.append("")

        if let top = used.first {
            lines.append("TOP feature: \(top.event.promptDescription) (\(top.windowed) uses in this window)")
        } else {
            lines.append("TOP feature: none. Every counter is zero in this window")
        }

        if used.count > 1 {
            lines.append("OTHER features used (ranked high → low):")
            for row in used.dropFirst() {
                lines.append("- \(row.event.promptDescription): \(row.windowed) uses")
            }
        }

        if !zero.isEmpty {
            let names = zero.map { $0.event.promptDescription }.joined(separator: ", ")
            lines.append("ZERO uses in this window (do not claim these are used): \(names)")
        }

        return lines.joined(separator: "\n")
    }
}
