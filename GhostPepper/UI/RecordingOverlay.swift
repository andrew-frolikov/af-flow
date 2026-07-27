import SwiftUI
import AppKit

enum OverlayMessage: Equatable {
    case recording
    case modelLoading
    case cleaningUp
    case transcribing
    case clipboardFallback
    case noSoundDetected
    case learnedCorrection(MisheardReplacement)
    /// Shown when a recording cannot start and none of the other messages fit.
    /// Carries its own reason so a new blocked reason cannot be added without
    /// telling Andrew something.
    case cannotStart(String)

    var primaryText: String {
        switch self {
        case .cannotStart:
            return "Cannot record yet"
        case .recording:
            return "Recording..."
        case .modelLoading:
            return "Loading models..."
        case .cleaningUp:
            return "Cleaning up..."
        case .transcribing:
            return "Transcribing..."
        case .clipboardFallback:
            return "Copied to clipboard"
        case .noSoundDetected:
            return "No sound detected"
        case .learnedCorrection:
            return "Learned correction"
        }
    }

    /// Whether the app is still working on something, as opposed to reporting a
    /// result. Drives the pulse in `OverlayPillView`.
    var isInProgress: Bool {
        switch self {
        case .recording, .modelLoading, .cleaningUp, .transcribing:
            return true
        case .clipboardFallback, .noSoundDetected, .learnedCorrection, .cannotStart:
            return false
        }
    }

    var secondaryText: String? {
        switch self {
        case .clipboardFallback:
            return "⌘V to paste"
        case .noSoundDetected:
            return "Check your mic in Settings → Recording"
        case .learnedCorrection(let replacement):
            return "\(replacement.wrong) → \(replacement.right)"
        case .cannotStart(let reason):
            return reason
        default:
            return nil
        }
    }
}

class RecordingOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayPillView>?
    private var dismissWorkItem: DispatchWorkItem?
    private var currentMessage: OverlayMessage?
    var onNoSoundSettingsTapped: (() -> Void)?

    func show(message: OverlayMessage = .recording) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        if let hostingView = hostingView, let panel = panel {
            let size = panelSize(for: message)
            hostingView.rootView = OverlayPillView(message: message, onTap: message == .noSoundDetected ? { [weak self] in self?.onNoSoundSettingsTapped?() } : nil)
            panel.setContentSize(size)
            panel.ignoresMouseEvents = message != .noSoundDetected
            panel.contentViewController?.view.frame = NSRect(origin: .zero, size: size)
            hostingView.frame = NSRect(origin: .zero, size: size)
            position(panel: panel)
            panel.orderFrontRegardless()
            currentMessage = message
            scheduleDismissIfNeeded(for: message)
            return
        }

        let size = panelSize(for: message)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = message != .noSoundDetected
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hosting = NSHostingView(rootView: OverlayPillView(message: message, onTap: message == .noSoundDetected ? { [weak self] in self?.onNoSoundSettingsTapped?() } : nil))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let contentViewController = NSViewController()
        contentViewController.view = container
        panel.contentViewController = contentViewController
        self.hostingView = hosting

        position(panel: panel)
        panel.orderFrontRegardless()
        self.panel = panel
        currentMessage = message
        scheduleDismissIfNeeded(for: message)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        currentMessage = nil
    }

    func dismiss(ifShowing message: OverlayMessage) {
        guard currentMessage == message else {
            return
        }

        dismiss()
    }

    private func position(panel: NSPanel) {
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panel.frame.width / 2
            let y = screenFrame.minY + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func panelSize(for message: OverlayMessage) -> NSSize {
        switch message {
        case .clipboardFallback, .learnedCorrection, .noSoundDetected, .cannotStart:
            return NSSize(width: 420, height: 84)
        default:
            return NSSize(width: 300, height: 60)
        }
    }

    private func scheduleDismissIfNeeded(for message: OverlayMessage) {
        switch message {
        case .clipboardFallback, .learnedCorrection, .noSoundDetected, .cannotStart:
            let delay: TimeInterval = message == .noSoundDetected ? 5 : 3
            let workItem = DispatchWorkItem { [weak self] in
                self?.dismiss()
            }
            dismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        default:
            return
        }
    }
}

struct OverlayPillView: View {
    let message: OverlayMessage
    var onTap: (() -> Void)?
    @AppStorage(AppTheme.storageKey) private var selectedThemeID = AppThemeID.current.rawValue
    @State private var isPulsing = false

    private var appTheme: AppTheme {
        AppTheme.resolve(selectedThemeID)
    }

    /// True when the pill is wearing AF Flow's own look rather than one of the
    /// two novelty skins inherited from the fork. Everything brand-specific
    /// below is gated on this, so the skins keep working untouched.
    private var isBrand: Bool { appTheme.id == .current }

    private var textColor: Color {
        if isBrand { return AFFlowPalette.overlayText }
        return appTheme.usesDarkText ? .black : .white
    }

    private var pillFill: Color {
        switch appTheme.id {
        case .current:
            return AFFlowPalette.overlayFill.opacity(0.94)
        case .windows95:
            return Color(red: 0.78, green: 0.78, blue: 0.72).opacity(0.96)
        case .space:
            return Color(red: 0.03, green: 0.04, blue: 0.16).opacity(0.92)
        }
    }

    /// One tint per state, drawn from the same palette the home window uses, so
    /// the pill that appears while he speaks looks like it came from the same
    /// app as the window he opened.
    private var dotColor: Color {
        switch message {
        case .recording:
            return isBrand ? AFFlowPalette.red : .red
        case .modelLoading:
            return isBrand ? AFFlowPalette.gold : appTheme.accent
        case .cleaningUp, .transcribing:
            return isBrand ? AFFlowPalette.gold : appTheme.accent
        case .clipboardFallback:
            return isBrand ? AFFlowPalette.teal : appTheme.accent
        case .noSoundDetected, .cannotStart:
            return isBrand ? AFFlowPalette.red : appTheme.accent
        case .learnedCorrection:
            return isBrand ? AFFlowPalette.teal : .green
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if message == .modelLoading {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
            } else if case .learnedCorrection = message {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isBrand ? AFFlowPalette.teal : .green)
            } else {
                // The pulse means "this is still happening". It used to run on
                // every message, including the ones that are already finished,
                // so a completed paste blinked at him as if it were still
                // working. Now only the in-progress states move.
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .opacity(isPulsing && message.isInProgress ? 0.4 : 1.0)
                    .animation(
                        message.isInProgress
                            ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                            : .default,
                        value: isPulsing
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(message.primaryText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(textColor)

                if let secondaryText = message.secondaryText {
                    Text(secondaryText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(textColor.opacity(0.8))
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(pillFill)
                // The brand pill gets a hairline too. Without one it is a
                // shape-less dark blob against a dark app; with one it reads as
                // a deliberate object, which is what it has to look like on a
                // screen share.
                .overlay(
                    Capsule().stroke(
                        isBrand ? AFFlowPalette.overlayRule.opacity(0.55) : appTheme.accent.opacity(0.7),
                        lineWidth: 1
                    )
                )
        )
        .onAppear { isPulsing = true }
        .onTapGesture {
            onTap?()
        }
    }
}
