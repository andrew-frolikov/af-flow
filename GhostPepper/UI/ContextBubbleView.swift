import AppKit
import SwiftUI

/// AF Flow logo view — uses the character image, falls back to emoji.
private struct PepperLogo: View {
    @Environment(\.appTheme) private var theme
    var size: CGFloat = 32

    var body: some View {
        if let image = NSImage(named: "ghost-pepper-character") ?? Bundle.main.image(forResource: "ghost-pepper-character") {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Text("🌶️")
                .font(theme.textFont(size: size * 0.7))
        }
    }
}

/// The AF Flow Context Bubble — a branded floating panel used to prompt
/// the user when a meeting is auto-detected in a call app.
///
/// This view previously also hosted a cloud "Context Bundler" chat UI that sent
/// a captured command plus screen context to a cloud service. That UI is out of
/// scope for AF Flow (CLAUDE.md hard rule 1: no cloud services, keys, or
/// tokens). It is gone, and so are the callbacks that fed it: keeping them as
/// accepted-but-unused parameters preserved the wiring that made the capability
/// re-attachable in one line, which is not what "removed" means (LOOP.md
/// section 3).
struct ContextBubbleView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var session: PepperChatSession
    var onMinimize: () -> Void
    var onOpenInMeetings: ((URL) -> Void)?
    @AppStorage(AppTheme.storageKey) private var selectedThemeID = AppThemeID.current.rawValue

    private var appTheme: AppTheme { AppTheme.resolve(selectedThemeID) }
    private var panelText: Color { appTheme.usesDarkText ? .black : .white }
    private var subduedPanelText: Color { panelText.opacity(appTheme.usesDarkText ? 0.62 : 0.7) }
    private var subtlePanelFill: Color { panelText.opacity(appTheme.usesDarkText ? 0.08 : 0.06) }
    private var cornerRadius: CGFloat { appTheme.id == .windows95 ? 0 : 16 }

    var body: some View {
        VStack(spacing: 0) {
            if let actionMessage = session.messages.last(where: { $0.action != nil && $0.action?.responded != true }) {
                meetingPromptView(message: actionMessage)
            } else if session.messages.contains(where: { $0.action?.responded == true }) {
                // Action was just handled (meeting started) — auto-dismiss
                Color.clear
                    .frame(height: 0)
                    .onAppear { onMinimize() }
            } else {
                // Nothing to show — dismiss
                Color.clear
                    .frame(height: 0)
                    .onAppear { onMinimize() }
            }
        }
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(appTheme.contextBubbleBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(appTheme.accent.opacity(appTheme.id == .windows95 ? 0.8 : 0.24), lineWidth: appTheme.id == .windows95 ? 2 : 1)
        )
        .shadow(color: .black.opacity(appTheme.id == .windows95 ? 0.22 : 0.5), radius: appTheme.id == .windows95 ? 10 : 30, y: appTheme.id == .windows95 ? 6 : 15)
    }

    // MARK: - Meeting Prompt

    private func meetingPromptView(message: PepperChatMessage) -> some View {
        VStack(spacing: 16) {
            PepperLogo(size: 40)

            if let rendered = try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(rendered)
                    .font(theme.textFont(size: 14, weight: 500))
                    .foregroundColor(panelText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            } else {
                Text(message.text)
                    .font(theme.textFont(size: 14, weight: 500))
                    .foregroundColor(panelText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            if let action = message.action {
                HStack(spacing: 10) {
                    Button(action: {
                        action.onAccept()
                        session.markActionResponded(messageID: message.id)
                    }) {
                        Text(action.acceptLabel)
                            .font(theme.textFont(size: 13, weight: 600))
                            .foregroundColor(appTheme.accentText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: appTheme.id == .windows95 ? 0 : 8).fill(appTheme.accent))
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        action.onDecline?()
                        session.markActionResponded(messageID: message.id)
                    }) {
                        Text(action.declineLabel)
                            .font(theme.textFont(size: 13))
                            .foregroundColor(subduedPanelText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: appTheme.id == .windows95 ? 0 : 8).fill(subtlePanelFill))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(24)
    }

}

// MARK: - Flow Layout (for chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
