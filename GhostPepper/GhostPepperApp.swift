import SwiftUI
import Combine

@main
struct GhostPepperApp: App {
    private static let automaticTerminationReason = "AF Flow keeps a persistent menu bar presence."
    private static let forceOnboarding = ProcessInfo.processInfo.arguments.contains("--force-onboarding")

    /// True when this process was launched by `xcodebuild test` as the test
    /// host rather than by Andrew.
    ///
    /// **Why this exists, and it is a second egress route entirely separate from
    /// the one fixed in TextCleanupManager.** `xcodebuild test` launches the app
    /// as its test host, and the app then runs its own startup path: onboarding
    /// completes, `initialize()` runs, and the speech model loads, downloading
    /// itself if the container has no cache. Since the test host was given its
    /// own bundle identifier it has its own empty container, so that startup is
    /// a fresh multi-hundred-megabyte fetch that no test asked for and no test
    /// gate covers. It is the most likely source of the 346 MB
    /// `CFNetworkDownload` temp file observed on 2026-07-26 during a run whose
    /// cleanup models were already cached. Codex found it.
    ///
    /// Anchored to what the SYSTEM produces rather than to a flag someone has to
    /// remember to pass: `XCTestConfigurationFilePath` is set by XCTest itself,
    /// in every configuration, and cannot be present in Andrew's own launch.
    private static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
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
            // Every state wears Andrew's own mark. Two of them used to swap it
            // for a stock SF symbol, an orange `ellipsis.circle` and a yellow
            // `exclamationmark.triangle`, so the menu bar stopped showing his
            // brand at exactly the moments he is most likely to be looking at
            // it. The coloured variants of the mark already existed in the
            // asset catalogue and were simply never wired up.
            Group {
                switch appState.status {
                case .recording:
                    Image("MenuBarIconRed")
                        .renderingMode(.original)
                case .loading, .transcribing, .cleaningUp:
                    Image("MenuBarIconOrange")
                        .renderingMode(.original)
                case .error:
                    Image("MenuBarIconRedDim")
                        .renderingMode(.original)
                default:
                    Image("MenuBarIcon")
                        .renderingMode(.template)
                }
            }
            .onAppear {
                ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)
                guard !hasInitialized else { return }
                hasInitialized = true
                // The test host must do NOTHING at startup. It is the app, so
                // it would otherwise load models, open windows and compete for
                // the microphone while the suite runs. Returning here also
                // means a stray `onboardingCompleted = true` in the test
                // domain can never trigger a model download.
                if Self.isRunningTests { return }
                // All four of these used to open the fork's meeting window.
                // AF Flow's own front door is the only thing launching the app
                // or clicking the Dock icon should ever show.
                reopenDelegate.openMainWindow = { appState.showHomeWindow() }
                if Self.forceOnboarding {
                    onboardingCompleted = false
                    onboardingController.show(appState: appState) {
                        onboardingCompleted = true
                        await appState.initialize()
                        appState.showHomeWindow()
                    }
                } else if onboardingCompleted {
                    Task {
                        await appState.initialize()
                        appState.showHomeWindow()
                    }
                } else {
                    onboardingController.show(appState: appState) {
                        onboardingCompleted = true
                        await appState.initialize()
                        appState.showHomeWindow()
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
