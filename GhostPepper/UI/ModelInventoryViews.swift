import SwiftUI

struct ModelInventoryCard: View {
    @Environment(\.appTheme) private var theme
    let rows: [RuntimeModelRow]
    var onDelete: ((RuntimeModelRow) -> Void)?
    var onDownload: ((RuntimeModelRow) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                ModelInventoryRow(
                    row: row,
                    onDelete: canDelete(row) ? { onDelete?(row) } : nil,
                    onDownload: canDownload(row) ? { onDownload?(row) } : nil
                )
                .id(row.viewIdentity)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.textBackground)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.separator, lineWidth: 1))
        )
    }

    private func canDelete(_ row: RuntimeModelRow) -> Bool {
        guard onDelete != nil, row.allowsDeletion else { return false }
        return row.status == .loaded && !row.isSelected
    }

    private func canDownload(_ row: RuntimeModelRow) -> Bool {
        guard onDownload != nil, row.allowsManualDownload else { return false }
        return row.status == .notLoaded
    }
}

private extension RuntimeModelRow {
    var viewIdentity: String {
        "\(id)-\(status.identityKey)-\(isSelected)"
    }
}

private extension RuntimeModelStatus {
    var identityKey: String {
        switch self {
        case .notLoaded:
            return "not-loaded"
        case .loading:
            return "loading"
        case .loaded:
            return "loaded"
        case .downloading(let progress):
            let progressKey = progress.map { String(format: "%.3f", $0) } ?? "indeterminate"
            return "downloading-\(progressKey)"
        case .systemManaged:
            return "system-managed"
        }
    }
}

private struct ModelInventoryRow: View {
    @Environment(\.appTheme) private var theme
    let row: RuntimeModelRow
    var onDelete: (() -> Void)?
    var onDownload: (() -> Void)?
    @State private var isDeleting = false

    var body: some View {
        HStack(spacing: 8) {
            if let onDownload, row.status == .notLoaded, !isDeleting {
                Button(action: onDownload) {
                    ModelInventoryStatusIndicator(status: .notLoaded)
                }
                .buttonStyle(.borderless)
                .help("Download model")
            } else {
                ModelInventoryStatusIndicator(status: isDeleting ? .loading : row.status)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(theme.bodyFont)
                        .foregroundStyle(isDeleting ? theme.textSecondary : theme.textPrimary)

                    if row.isSelected {
                        Text("Selected")
                            .font(theme.textFont(size: 11.5, weight: 600))
                            .foregroundStyle(theme.accent)
                    }
                }

                Text(isDeleting ? "Removing..." : statusText)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer()

            Text(row.sizeDescription)
                .font(theme.captionFont)
                .foregroundStyle(theme.textSecondary)

            if let onDelete {
                if isDeleting {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14, height: 14)
                } else {
                    Button(action: {
                        isDeleting = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            onDelete()
                            // Small delay so "Removing..." is visible before status changes
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                isDeleting = false
                            }
                        }
                    }) {
                        Image(systemName: "trash")
                            .font(theme.captionFont)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove downloaded model to free disk space")
                }
            }
        }
    }

    private var statusText: String {
        switch row.status {
        case .loaded:
            return "Loaded"
        case .loading:
            return "Loading"
        case .notLoaded:
            return "Not loaded"
        case .downloading(let progress?):
            return "Downloading \(Int(progress * 100))%"
        case .downloading(nil):
            return "Preparing"
        case .systemManaged:
            return "Managed by macOS"
        }
    }
}

private struct ModelInventoryStatusIndicator: View {
    @Environment(\.appTheme) private var theme
    let status: RuntimeModelStatus

    var body: some View {
        Group {
            switch status {
            case .loaded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.statusReady)
            case .loading:
                ProgressView()
                    .controlSize(.mini)
            case .notLoaded:
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(theme.textSecondary)
            case .downloading(let progress):
                PieProgressIndicator(progress: progress)
            case .systemManaged:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.statusReady)
            }
        }
        .font(theme.captionFont)
        .frame(width: 14, height: 14)
    }
}

private struct PieProgressIndicator: View {
     @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appTheme) private var theme
    let progress: Double?
    @State private var rotation = Angle.zero

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.separator, lineWidth: 1)

            if let progress {
                PieSliceShape(progress: max(0.05, min(progress, 1)))
                    .fill(theme.accent)
            } else {
                PieSliceShape(progress: 0.28)
                    .fill(theme.accent)
                    .rotationEffect(rotation)
                    .onAppear {
                        // A spinner that never stops is the clearest case for
                        // the reduced-motion rule. The slice still shows
                        // progress; it just does not rotate.
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            rotation = .degrees(360)
                        }
                    }
            }
        }
    }
}

private struct PieSliceShape: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let startAngle = Angle.degrees(-90)
        let endAngle = Angle.degrees(-90 + max(0, min(progress, 1)) * 360)

        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
