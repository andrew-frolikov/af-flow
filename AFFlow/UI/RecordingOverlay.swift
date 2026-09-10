import SwiftUI
import AppKit

enum OverlayMessage: Equatable {
    case recording
    case modelLoading
    case cleaningUp
    case transcribing
    case clipboardFallback
    case noSoundDetected
    /// The microphone is not delivering WHILE he is still holding the key.
    /// Separate from `noSoundDetected`, which is the post-mortem: this one
    /// arrives in time for him to stop talking, and it names which of the two
    /// failure shapes it is so the remedy is not a guess.
    case captureFailing(CaptureHealth.Verdict)
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
        case .captureFailing(.digitalSilence):
            return "Mic is sending silence"
        case .captureFailing(.conversionFailing):
            return "Audio is not converting"
        case .captureFailing:
            return "Mic is not sending audio"
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
        case .clipboardFallback, .noSoundDetected, .learnedCorrection, .cannotStart,
             .captureFailing:
            return false
        }
    }

    var secondaryText: String? {
        switch self {
        case .clipboardFallback:
            return "⌘V to paste"
        case .noSoundDetected:
            return "Check your mic in Settings → Recording"
        case .captureFailing(.digitalSilence):
            return "Check your mic is not muted"
        case .captureFailing(.conversionFailing):
            return "Audio is arriving but cannot be read"

        case .captureFailing:
            // Re-picking the microphone in Settings rebuilds the audio engine,
            // which is what recovers a route that died underneath it.
            return "Re-pick your mic in Settings → Recording"
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
        case .clipboardFallback, .learnedCorrection, .noSoundDetected, .cannotStart,
             .captureFailing:
            // The wide pill, because these all carry a second line telling him
            // what to do about it. Deliberately NOT added to
            // `scheduleDismissIfNeeded`: this one appears while he is still
            // holding the key, so it must stay until the recording ends and the
            // transcribing message replaces it.
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

    private var textColor: Color { appTheme.overlayText }

    private var pillFill: Color { appTheme.overlayFill }

    /// One colour per state, read from the theme's overlay slots so the two
    /// novelty skins keep their own overlays without a brand-only branch here.
    ///
    /// The grades are the DARK ones: this pill floats over whatever he is
    /// dictating into, so it is ink with paper text, and the light status
    /// colours would not carry on it. Recording is the clay red rather than
    /// pine, because a hot microphone has to read as red at a glance and pine
    /// cannot mean both "ready" and "recording".
    private var dotColor: Color {
        switch message {
        case .recording:
            return appTheme.overlayStatusLive
        case .modelLoading:
            return appTheme.overlayStatusBusy
        case .cleaningUp, .transcribing:
            return appTheme.overlayStatusBusy
        case .clipboardFallback:
            return appTheme.overlayStatusReady
        case .noSoundDetected, .cannotStart, .captureFailing:
            return appTheme.overlayStatusLive
        case .learnedCorrection:
            return appTheme.overlayStatusReady
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
                    .font(appTheme.textFont(size: 18, weight: 600))
                    .foregroundStyle(appTheme.overlayStatusReady)
            } else {
                // The pulse means "this is still happening". It used to run on
                // every message, including the ones that are already finished,
                // so a completed paste blinked at him as if it were still
                // working. Now only the in-progress states move.
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .brandPulse(active: message.isInProgress, isPulsing: isPulsing)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(message.primaryText)
                    .font(appTheme.textFont(size: 13, weight: 600))
                    .foregroundStyle(textColor)

                if let secondaryText = message.secondaryText {
                    Text(secondaryText)
                        .font(appTheme.textFont(size: 12, weight: 500))
                        // The 80%-opacity trick dies. An opacity of the
                        // primary colour is a guess; `overlaySecondaryText` is
                        // the canon's --dark-muted and measures 9.21:1 on the
                        // pill, computed rather than eyeballed.
                        .foregroundStyle(appTheme.overlaySecondaryText)
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
                        appTheme.overlayEdge,
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
