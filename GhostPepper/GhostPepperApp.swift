import SwiftUI
import Combine

@main
struct GhostPepperApp: App {
    private static let automaticTerminationReason = "Ghost Pepper keeps a persistent menu bar presence."
    private static let forceOnboarding = ProcessInfo.processInfo.arguments.contains("--force-onboarding")
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppReopenDelegate.self) private var reopenDelegate
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
                reopenDelegate.openMainWindow = { appState.showOrCreateMeetingWindow() }
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

/// Opens the main window when Andrew clicks the Dock icon.
///
/// The app is a plain Dock app as of 2026-07-21 (LSUIElement removed, his
/// decision after the dynamic Dock-presence approach failed in his hands).
/// A MenuBarExtra-only SwiftUI app has no reopen behavior of its own, so a
/// Dock click would do nothing at all, which reads as "the app doesn't open".
/// This is the smallest AppKit hook that fixes that, and it fires only on his
/// own click: it can never open a window he did not ask for.
final class AppReopenDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            openMainWindow?()
        }
        return true
    }
}
