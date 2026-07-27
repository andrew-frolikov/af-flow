import SwiftUI

/// Right-side panel showing what AF Flow does, which model is doing it,
/// and the toolkit of local models. Local model rows expose inline
/// download/delete affordances.
struct ModelsSidebarView: View {
    @AppStorage("speechModel") private var selectedSpeechModelID: String = SpeechModelCatalog.defaultModelID
    @AppStorage("selectedCleanupModelKind") private var selectedCleanupModelKindRaw: String = LocalCleanupModelKind.qwen35_0_8b_q4_k_m.rawValue

    @ObservedObject var cleanupManager: TextCleanupManager
    @ObservedObject var modelManager: ModelManager
    let onDownloadSpeechModel: (String) -> Void

    @State private var refreshTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    functionsSection
                    localModelsSection
                    footer
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                .id(refreshTick)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Models")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            Button(action: {
                refreshTick += 1
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Re-check status")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Section 1 · Functions

    private var functionsSection: some View {
        section(title: "What AF Flow does") {
            FunctionRowPicker(
                icon: "waveform",
                title: "Speech-to-text",
                location: .local,
                isEmpty: downloadedSpeechModels.isEmpty,
                emptyMessage: "Download a speech model in Settings → Models"
            ) {
                Picker("", selection: $selectedSpeechModelID) {
                    ForEach(downloadedSpeechModels, id: \.id) { model in
                        Text(model.pickerTitle).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: selectedSpeechModelID) { _, modelID in
                    onDownloadSpeechModel(modelID)
                }
            }

            FunctionRow(
                icon: "person.wave.2",
                title: "Speaker diarization",
                modelLabel: diarizationLabel,
                location: .local,
                available: diarizationAvailable
            )

            FunctionRowPicker(
                icon: "sparkles",
                title: "Cleanup",
                location: .local,
                isEmpty: downloadedCleanupModels.isEmpty,
                emptyMessage: "Download a cleanup model in Settings → Models"
            ) {
                Picker("", selection: $selectedCleanupModelKindRaw) {
                    ForEach(downloadedCleanupModels, id: \.kind) { desc in
                        Text(desc.displayName).tag(desc.kind.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            FunctionRow(
                icon: "doc.text",
                title: "Meeting summary",
                modelLabel: (cleanupModel?.displayName ?? "-") + " (same as Cleanup)",
                location: .local,
                available: cleanupModel.map { TextCleanupManager.isModelDownloaded($0.kind) } ?? false
            )

            FunctionRow(
                icon: "cpu",
                title: "2nd Brain Q&A",
                modelLabel: wikiQAModel?.displayName ?? "Qwen 3.5 4B Q4_K_M (auto)",
                location: .local,
                available: wikiQAModel != nil
            )
        }
    }

    /// Speech models that are ready to drive speech-to-text. System-managed
    /// assets are usable before a locale-specific download is requested.
    private var downloadedSpeechModels: [SpeechModelDescriptor] {
        SpeechModelCatalog.availableModels.filter {
            $0.isSystemManaged || ModelManager.isCached($0)
        }
    }

    /// Cleanup models the user has actually downloaded.
    private var downloadedCleanupModels: [CleanupModelDescriptor] {
        TextCleanupManager.cleanupModels.filter { TextCleanupManager.isModelDownloaded($0.kind) }
    }

    // MARK: - Section 2 · Local models

    private var localModelsSection: some View {
        section(title: "Local models") {
            ForEach(SpeechModelCatalog.availableModels, id: \.id) { model in
                let downloaded = model.isSystemManaged || ModelManager.isCached(model)
                let isActive = model.id == selectedSpeechModelID
                LocalModelRow(
                    title: model.pickerTitle,
                    subtitle: "\(model.variantName) · \(model.sizeDescription)",
                    capabilities: capabilities(for: model),
                    isDownloaded: downloaded,
                    isActive: isActive,
                    progress: speechRowProgress(for: model, downloaded: downloaded),
                    onDownload: (!model.isSystemManaged && !downloaded)
                        ? { onDownloadSpeechModel(model.id) }
                        : nil,
                    onDelete: (!model.isSystemManaged && downloaded && !isActive)
                        ? { modelManager.deleteCachedModel(model) }
                        : nil
                )
            }
            ForEach(TextCleanupManager.cleanupModels, id: \.kind) { desc in
                let downloaded = TextCleanupManager.isModelDownloaded(desc.kind)
                let isActive = desc.kind.rawValue == selectedCleanupModelKindRaw
                let progress = cleanupRowProgress(for: desc.kind, downloaded: downloaded)
                LocalModelRow(
                    title: desc.displayName,
                    subtitle: desc.sizeDescription,
                    // Driven by `recommendation`, not by kind: this ForEach
                    // iterates TextCleanupManager.cleanupModels, which no
                    // longer contains .gemma4_12b_it_optiq_4bit_mlx (its
                    // descriptor was removed -- see TextCleanupManager.swift
                    // near line 796), so a kind-based check here was already
                    // dead code. Models without a recommendation tier (e.g.
                    // deepseekR1Qwen7BModel, whose doc comment states
                    // "Cleanup-quality is unverified -- primarily added for
                    // the agent path") must not be labeled "cleanup" /
                    // "meeting summary" capable, since that overstates what
                    // the model has actually been verified to do.
                    capabilities: desc.recommendation != nil
                        ? ["cleanup", "meeting summary"]
                        : ["agent tool-use"],
                    isDownloaded: downloaded,
                    isActive: isActive,
                    progress: progress,
                    onDownload: downloaded ? nil : {
                        cleanupManager.startLoad(kind: desc.kind)
                    },
                    onDelete: (downloaded && !isActive) ? ({
                        // Ledger 27: deleting a loaded model waits for any
                        // in-flight generation, so this is async now.
                        Task { @MainActor in
                            await cleanupManager.deleteCachedModel(kind: desc.kind)
                        }
                    } as () -> Void) : nil,
                    onCancel: (progress != nil && cleanupManager.isLoadCancellable) ? {
                        cleanupManager.cancelActiveLoad()
                    } : nil
                )
            }
        }
    }

    /// Inline progress for a speech-model row. The speech `ModelManager` only
    /// tracks one in-flight download/load at a time and tags it via
    /// `modelName`, so only the matching row reports a non-nil value.
    private func speechRowProgress(for model: SpeechModelDescriptor, downloaded: Bool) -> RowProgress? {
        guard modelManager.modelName == model.id else { return nil }
        switch modelManager.state {
        case .loading:
            if model.isSystemManaged {
                return .downloading(modelManager.downloadProgress)
            }
            return downloaded ? .loading : .downloading(modelManager.downloadProgress)
        case .idle, .ready, .error:
            return nil
        }
    }

    /// Inline progress for a cleanup-model row. `TextCleanupManager.state`
    /// carries the kind for download/load transitions; ready/idle/error don't
    /// distinguish per-model.
    private func cleanupRowProgress(for kind: LocalCleanupModelKind, downloaded: Bool) -> RowProgress? {
        switch cleanupManager.state {
        case .downloading(let activeKind, let progress) where activeKind == kind:
            return .downloading(progress)
        case .loadingModel(let activeKind) where activeKind == kind:
            return .loading
        default:
            return nil
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("AF Flow runs 100% on-device.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: - Resolved selections

    private var speechModel: SpeechModelDescriptor? {
        SpeechModelCatalog.model(named: selectedSpeechModelID)
    }

    private var cleanupModel: CleanupModelDescriptor? {
        TextCleanupManager.cleanupModels.first { $0.kind.rawValue == selectedCleanupModelKindRaw }
    }

    private var wikiQAModel: CleanupModelDescriptor? {
        let preferred: [LocalCleanupModelKind] = [
            .qwen35_4b_q4_k_m,
            .qwen35_2b_q4_k_m,
            .qwen35_0_8b_q4_k_m,
        ]
        return preferred.compactMap { kind in
            TextCleanupManager.cleanupModels.first { $0.kind == kind && TextCleanupManager.isModelDownloaded(kind) }
        }.first
    }

    private var diarizationLabel: String {
        if let m = speechModel, m.supportsSpeakerFiltering {
            return m.pickerTitle
        }
        return "needs a FluidAudio model"
    }

    private var diarizationAvailable: Bool {
        guard let m = speechModel, m.supportsSpeakerFiltering else { return false }
        return ModelManager.isCached(m)
    }

    private func capabilities(for model: SpeechModelDescriptor) -> [String] {
        var caps = ["speech-to-text"]
        if model.supportsSpeakerFiltering { caps.append("diarization") }
        return caps
    }

    // MARK: - Section wrapper

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
        }
    }
}

// MARK: - Rows

private enum ModelLocation { case local, cloud }

/// FunctionRow variant that hosts a Picker (or any inline selector view) on
/// the secondary line. The picker is constrained to choices the user can
/// actually use — caller filters to downloaded local models.
private struct FunctionRowPicker<Picker: View>: View {
    let icon: String
    let title: String
    let location: ModelLocation
    /// If true, the picker is shown disabled and a small hint replaces the
    /// secondary line so the user knows where to go to fix it.
    let isEmpty: Bool
    let emptyMessage: String
    @ViewBuilder let picker: () -> Picker

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Text(location == .local ? "local" : "cloud")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(location == .local ? .green : .blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background((location == .local ? Color.green : Color.blue).opacity(0.12))
                        .cornerRadius(3)
                }
                if isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    picker()
                        .frame(maxWidth: 220)
                        .controlSize(.small)
                }
            }
            Spacer()
        }
    }
}

private struct FunctionRow: View {
    let icon: String
    let title: String
    let modelLabel: String
    let location: ModelLocation
    let available: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                HStack(spacing: 4) {
                    Text(modelLabel)
                        .font(.system(size: 11))
                        .foregroundColor(available ? .secondary : .red.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(location == .local ? "local" : "cloud")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(location == .local ? .green : .blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            (location == .local ? Color.green : Color.blue).opacity(0.12)
                        )
                        .cornerRadius(3)
                }
            }
            Spacer()
        }
    }
}

/// Per-row download/load progress signal for `LocalModelRow`. `.downloading`
/// carries an optional fraction so we can show indeterminate spinners while
/// waiting for the first byte; `.loading` covers the post-download model load.
enum RowProgress: Equatable {
    case downloading(Double?)
    case loading
}

private struct LocalModelRow: View {
    let title: String
    let subtitle: String
    let capabilities: [String]
    let isDownloaded: Bool
    let isActive: Bool
    var progress: RowProgress? = nil
    var onDownload: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isDownloaded ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isDownloaded ? .primary : .secondary)
                    if isActive {
                        Text("active")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(3)
                    }
                    if !isDownloaded && progress == nil {
                        Text("not downloaded")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(capabilities.joined(separator: " · "))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.85))
                if let progress {
                    progressView(progress)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            actionButton
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if progress != nil, let onCancel {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .help("Cancel download")
            .padding(.top, 2)
        } else if progress != nil {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
                .padding(.top, 3)
        } else if let onDownload, !isDownloaded {
            Button(action: onDownload) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Download model")
            .padding(.top, 2)
        } else if let onDelete {
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove downloaded model to free disk space")
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func progressView(_ progress: RowProgress) -> some View {
        switch progress {
        case .downloading(let value?):
            HStack(spacing: 6) {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 140)
                Text("\(Int(value * 100))%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
        case .downloading(nil):
            Text("Preparing…")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        case .loading:
            Text("Loading…")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}
