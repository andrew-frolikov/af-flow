import SwiftUI

/// Modal sheet that sizes an index build, then streams progress while it runs.
/// Closes on completion or cancel.
///
/// AF Flow never stores a cloud credential (CLAUDE.md hard rule 1), so the
/// builder `fetchBuilder()` resolves is always the on-device `LocalWikiEngine`
/// (see `AppState.indexBuilder(for:)`), which is free. Cost display is gone
/// entirely rather than kept as a generic fallback: there is no reachable code
/// path that can produce a non-zero cost, and a currency-formatted placeholder
/// for a capability the app must never have is residue, not a feature.
struct BuildIndexSheet: View {
    @Environment(\.appTheme) private var theme
    let kind: IndexKind
    let fetchBuilder: () -> (any IndexBuilding)?
    let onClose: () -> Void

    @State private var phase: Phase = .estimating
    @State private var estimate: IndexBuildEstimate?
    @State private var statusLine: String = ""
    @State private var entriesWritten: Int = 0
    @State private var meetingsProcessed: Int = 0
    @State private var totalMeetings: Int = 0

    @State private var errorMessage: String?
    @State private var buildTask: Task<Void, Never>?

    enum Phase {
        case estimating
        case readyToBuild
        case building
        case completed
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: kind.iconSystemName)
                    .font(.system(size: 16))
                Text("Build \(kind.displayName) index")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }

            switch phase {
            case .estimating:
                estimatingView
            case .readyToBuild:
                readyView
            case .building:
                buildingView
            case .completed:
                completedView
            case .failed:
                failedView
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            await runEstimate()
        }
    }

    private var estimatingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Checking what needs building…")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder
    private var readyView: some View {
        if let estimate {
            VStack(alignment: .leading, spacing: 12) {
                if estimate.nothingToDo {
                    Text("**Index is up to date**. Every meeting is already covered by an existing entry, so there is nothing to do.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .padding(8)
                        .background(theme.statusReady.opacity(0.1))
                        .cornerRadius(6)
                } else if estimate.isResume {
                    Text("**Resuming existing index**: \(estimate.existingEntryCount) entries on disk, \(estimate.alreadyProcessedCount) of \(estimate.totalMeetingCount) meetings already covered. This run will only process the remaining \(estimate.unprocessedCount).")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .padding(8)
                        .background(theme.accent.opacity(0.1))
                        .cornerRadius(6)
                }

                if !estimate.nothingToDo {
                    // Only one branch is possible: `fetchBuilder()` always resolves
                    // to the free, on-device `LocalWikiEngine`. The paid branch that
                    // used to sit here priced a cloud model in USD, which AF Flow
                    // can never reach (hard rule 1) and which would have been the
                    // wrong currency anyway (hard rule 9, costs in CAD).
                    Text("**\(estimate.unprocessedCount)** meetings to process on-device with \(estimate.modelDisplayName). Free, CAD 0.")
                        .font(.system(size: 13))
                    Text("Runs in the background on the local model. You can hit Stop at any time; the build resumes where it left off.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }

                HStack {
                    Spacer()
                    Button(estimate.nothingToDo ? "Done" : "Cancel", action: onClose)
                        .keyboardShortcut(.cancelAction)
                    if !estimate.nothingToDo {
                        Button(estimate.isResume ? "Resume" : "Build") {
                            runBuild()
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                    }
                }
            }
        }
    }

    private var buildingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text(statusLine.isEmpty ? "Building…" : statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if totalMeetings > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(meetingsProcessed) of \(totalMeetings) meetings")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                        Text("\(Int(progressFraction * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                    }
                    ProgressView(value: progressFraction)
                        .progressViewStyle(.linear)
                        .tint(theme.accent)
                }
            }

            HStack(spacing: 16) {
                Label("\(entriesWritten) entries written", systemImage: "doc.text")
                Label("On device, CAD 0", systemImage: "bolt.circle")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(theme.textSecondary)

            HStack {
                Spacer()
                Button("Stop") {
                    buildTask?.cancel()
                }
            }
        }
    }

    private var progressFraction: Double {
        guard totalMeetings > 0 else { return 0 }
        return min(1, Double(meetingsProcessed) / Double(totalMeetings))
    }

    private var completedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.statusReady)
                Text("Built \(entriesWritten) entries")
                    .font(.system(size: 13, weight: .medium))
            }
            if totalMeetings > 0 {
                Text("\(meetingsProcessed) of \(totalMeetings) meetings covered")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            Text("Ran entirely on this Mac. Total cost CAD 0.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
            }
        }
    }

    private var failedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.statusLive)
                Text("Build failed")
                    .font(.system(size: 13, weight: .medium))
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Actions

    private func runEstimate() async {
        guard let builder = fetchBuilder() else {
            self.errorMessage = "Couldn't construct an index builder. Check that a local cleanup model is downloaded in Settings."
            self.phase = .failed
            return
        }
        do {
            let est = try await builder.estimateBuildCost(kind: kind)
            self.estimate = est
            self.totalMeetings = est.totalMeetingCount
            self.meetingsProcessed = est.alreadyProcessedCount
            self.phase = .readyToBuild
        } catch {
            self.errorMessage = "Couldn't estimate cost: \(error.localizedDescription)"
            self.phase = .failed
        }
    }

    private func runBuild() {
        // Fetched at click time so the picker's current model selection is
        // honored — AppState's builder cache invalidates when the model
        // setting changes.
        guard let activeBuilder = fetchBuilder() else {
            errorMessage = "Couldn't construct an index builder. Check that a local cleanup model is downloaded in Settings."
            phase = .failed
            return
        }
        phase = .building
        statusLine = "Starting…"
        entriesWritten = 0
        let task = Task { @MainActor in
            do {
                for try await event in activeBuilder.buildFullIndex(kind: kind) {
                    if Task.isCancelled { break }
                    switch event {
                    case .estimating, .estimated:
                        break
                    case .status(let s):
                        statusLine = s
                    case .entryWritten:
                        entriesWritten += 1
                    case .meetingsProcessed(let processed, let total):
                        meetingsProcessed = processed
                        totalMeetings = total
                    case .usage:
                        // Cost tracking dropped with the paid-model UI. The local
                        // engine always reports zero, so there is nothing to show.
                        break
                    case .completed:
                        phase = .completed
                        return
                    case .error(let msg):
                        errorMessage = msg
                        phase = .failed
                        return
                    }
                }
                if Task.isCancelled {
                    phase = .completed
                }
            } catch {
                errorMessage = error.localizedDescription
                phase = .failed
            }
        }
        buildTask = task
    }

}
