import SwiftUI
import Combine

@main
struct GhostPepperApp: App {
    private static let automaticTerminationReason = "Ghost Pepper keeps a persistent menu bar presence."
    private static let forceOnboarding = ProcessInfo.processInfo.arguments.contains("--force-onboarding")
    @StateObject private var appState = AppState()
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @State private var hasInitialized = false
    private let onboardingController = OnboardingWindowController()

    var body: some Scene {
        MenuBarExtra {
            if !onboardingCompleted {
                Button("Show Setup Window") {
                    onboardingController.bringToFront()
                }
                Divider()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            } else {
                MenuBarView(appState: appState)
            }
        } label: {
            Group {
                switch appState.status {
                case .recording:
                    Image("MenuBarIconRedDim")
                        .renderingMode(.original)
                case .loading:
                    Image(systemName: "ellipsis.circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.orange)
                case .error:
                    Image(systemName: "exclamationmark.triangle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.yellow)
                default:
                    Image("MenuBarIcon")
                        .renderingMode(.template)
                }
            }
            .onAppear {
                ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)
                guard !hasInitialized else { return }
                hasInitialized = true
                // Minimize is disabled for an LSUIElement app because there is
                // no Dock tile to minimize into. This gives the app a Dock
                // presence for as long as a real window is open, and takes it
                // away again afterwards.
                DockPresenceController.shared.start()
                if Self.forceOnboarding {
                    onboardingCompleted = false
                    onboardingController.show(appState: appState) {
                        onboardingCompleted = true
                        await appState.initialize()
                        appState.showMeetingTranscriptWindow()
                    }
                } else if onboardingCompleted {
                    Task {
                        await appState.initialize()
                        appState.showMeetingTranscriptWindow()
                    }
                } else {
                    onboardingController.show(appState: appState) {
                        onboardingCompleted = true
                        await appState.initialize()
                        appState.showMeetingTranscriptWindow()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
                appState.prepareForTermination()
            }
        }
    }
}


// NOTE: this type lives here rather than in its own file on purpose.
// project.yml lists whole directories as sources, so XcodeGen would pick a new
// file up automatically, but XcodeGen is not installed on this machine and the
// .xcodeproj is checked in. A new file therefore compiles only after manual
// pbxproj surgery, which is how this cost a build cycle on 2026-07-21. Adding
// a type to an existing file avoids that entirely.

/// Shows AF Flow in the Dock only while it has a real window open.
///
/// **The bug this fixes, reported by Andrew on 2026-07-21.** He could not
/// "fold" a window, meaning minimize it, and had to close it instead. The
/// window in question already had `.miniaturizable` in its style mask, so the
/// mask was never the cause.
///
/// The cause is `LSUIElement` being true in Info.plist. That makes AF Flow an
/// agent app with no Dock icon, and **macOS disables the minimize button for
/// such apps**, because minimizing means shrinking into a Dock tile and an
/// agent app has no tile. It applies to every window regardless of style mask,
/// which is exactly the symptom he described.
///
/// **Why this is not simply `LSUIElement = false`.** CLAUDE.md's product spec
/// says AF Flow is a menu-bar app, and a permanent Dock icon changes what the
/// product is. Andrew chose the middle option on 2026-07-21: be a normal
/// application while a window is open, so minimize works and Cmd+Tab reaches
/// it, and drop back to menu-bar-only when the last window closes, so an idle
/// AF Flow stays invisible exactly as it is today.
@MainActor
final class DockPresenceController {

    /// Whether a window should count toward showing a Dock icon.
    ///
    /// Split out as a pure function over a description of a window rather than
    /// over `NSWindow` itself, so it can be tested without a running app. The
    /// filtering is the part with the judgement in it, and an untested
    /// judgement inside an AppKit notification handler is the kind of logic
    /// that silently rots.
    struct WindowFacts {
        let isVisible: Bool
        let isTitled: Bool
        let isPanel: Bool
    }

    /// Titled, visible, and not a panel.
    ///
    /// Panels are excluded deliberately: the recording overlay and the chat
    /// window are borderless `NSPanel`s that appear during ordinary dictation.
    /// Counting those would make the Dock icon flicker in and out every time
    /// Andrew speaks, which would be a worse bug than the one being fixed.
    static func shouldShowInDock(_ windows: [WindowFacts]) -> Bool {
        windows.contains { $0.isVisible && $0.isTitled && !$0.isPanel }
    }

    static let shared = DockPresenceController()

    private var observers: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default
        // `didBecomeKey` covers a window opening or being brought forward.
        // `willClose` fires before the window leaves `NSApp.windows`, so the
        // closing window is excluded explicitly rather than being counted as
        // still open and leaving a Dock icon behind forever.
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DockPresenceController.shared.sync(closing: nil) }
        })
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            let closing = notification.object as? NSWindow
            MainActor.assumeIsolated { DockPresenceController.shared.sync(closing: closing) }
        })

        sync(closing: nil)
    }

    private func sync(closing: NSWindow?) {
        let facts = NSApp.windows
            .filter { $0 !== closing }
            .map {
                WindowFacts(
                    isVisible: $0.isVisible,
                    isTitled: $0.styleMask.contains(.titled),
                    isPanel: $0 is NSPanel
                )
            }

        let desired: NSApplication.ActivationPolicy =
            Self.shouldShowInDock(facts) ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)

        // Becoming a regular app while already frontmost can leave the windows
        // behind other apps, because the activation policy change reorders the
        // app. Re-activating keeps the window the user just opened in front.
        if desired == .regular {
            NSApp.activate(ignoringOtherApps: false)
        }
    }
}
