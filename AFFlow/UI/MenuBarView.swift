import SwiftUI
import CoreAudio
import ServiceManagement

struct MenuBarView: View {
    @AppStorage("meetingTranscriptEnabled") private var meetingTranscriptEnabled: Bool = false
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // First item, and it did not exist before 2026-07-26. Once the home
            // window was closed the only way back to it was a Dock click, which
            // is not a thing anyone thinks to try, and on a screen share it
            // looks like the app has no window at all.
            Button("Open AF Flow") {
                appState.showHomeWindow()
            }

            Divider()

            Button("Settings...") {
                appState.showSettings()
            }

            Button("Debug Log...") {
                appState.showDebugLog()
            }

            // Meeting transcription, restored 2026-07-27 on Andrew's request to
            // transcribe his Meet and Zoom calls.
            //
            // The fork's old entries were deleted for a good reason: they were
            // gated on a key nothing wrote, and one of them was labelled
            // "IDE...", in the menu he opens more than any other surface. This is
            // deliberately ONE entry, gated on a setting he turns on himself,
            // and it says what it does.
            // Read through this view's own @AppStorage rather than through
            // `appState`. `@AppStorage` on an ObservableObject CLASS never fires
            // objectWillChange, so gating on `appState.meetingTranscriptEnabled`
            // would leave this entry missing until something else happened to
            // redraw the menu. That is the "switch that cannot do what its label
            // says" failure this work removed elsewhere; it would be careless to
            // reintroduce it in the entry point.
            if meetingTranscriptEnabled {
                Divider()

                if appState.activeMeetingSession != nil {
                    Button("Stop Meeting Transcription") {
                        appState.stopMeetingTranscription()
                    }
                } else {
                    Button("Transcribe a Meeting...") {
                        appState.startMeetingTranscriptionFromMenu()
                    }
                }
            }

            Text("AF Flow v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 2)

            if let statusText = statusLine {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
            }

            if case .downloading(_, let progress) = appState.textCleanupManager.state {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 14)
            }

            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)

                if appState.canReloadAudioInput {
                    Button("Reload Audio Input") {
                        appState.resetAudioEngine()
                    }
                }
                if error.contains("Input Monitoring") {
                    Button("Open Input Monitoring Settings") {
                        PermissionChecker.openInputMonitoringSettings()
                    }
                    Button("Retry") {
                        Task { await appState.startHotkeyMonitor() }
                    }
                }
                // Was "Open Accessibility Settings", matched on the old error
                // string. Granting Accessibility changes nothing under the
                // sandbox; Input Monitoring is what the hotkey actually needs.
                if error.contains("Input Monitoring") {
                    Button("Open Input Monitoring Settings") {
                        PermissionChecker.promptInputMonitoring()
                    }
                    Button("Retry") {
                        Task { await appState.startHotkeyMonitor() }
                    }
                }
                if error.contains("Microphone") {
                    Button("Open Microphone Settings") {
                        PermissionChecker.openMicrophoneSettings()
                    }
                }
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
    }

    private var statusLine: String? {
        switch appState.status {
        case .ready:
            return nil
        case .loading:
            return "Loading..."
        case .recording:
            return "Recording..."
        case .transcribing:
            return "Transcribing..."
        case .cleaningUp:
            return "Cleaning up..."
        case .error:
            return nil
        }
    }
}
