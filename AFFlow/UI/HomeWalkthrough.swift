import SwiftUI
import AppKit

/// **The first run, on Home, over the fog.**
///
/// Andrew: "I want there to be full onboarding here on this page, so that if a
/// person downloads the app and turns it on, here is Home, and it walks them
/// through setup, with this animation, beautifully, in my style." And on the
/// old one, which he liked: "it was very simple and it was great."
///
/// So this is a redesign of WHERE it lives and how it looks, not of what it
/// teaches. Spec: `docs/design/af-flow-home-hero.md`, part 2.
///
/// Two rules here are bans rather than preferences, and both were live defects
/// in the onboarding this replaces:
///
/// 1. **No chord literal, anywhere.** Every keycap and every sentence renders
///    the live binding. The old Try It step hardcoded "Right Command + Right
///    Option" in its instruction, its keycaps and its waiting message, and bound
///    the factory default in its monitor, so it could instruct one chord and
///    listen for another. Home was fixed for this class on 2026-07-26: "the
///    screen has to say what is actually bound, or the first thing the app tells
///    him is a lie."
/// 2. **No Accessibility, in any step, row, button or sentence.** It is
///    permanently blocked by the App Sandbox, proven 2026-08-21 across 28
///    queries on every build after every grant, and the sandbox stays. Asking
///    for it would be asking for something that can never be given. The
///    permission surface is exactly two grants: Microphone and Input Monitoring.
struct HomeWalkthrough: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var appState: AppState
    let isWindowVisible: Bool
    let onFinished: () -> Void

    @AppStorage("onboardingWelcomeSeen") private var welcomeSeen = false
    @AppStorage("onboardingShortcutChosen") private var shortcutChosen = false

    @State private var step: Step = .welcome
    @State private var micGranted = false
    @State private var inputMonitoringGranted = false
    @State private var pollTimer: Timer?
    @State private var capturing = false

    enum Step: Int, CaseIterable { case welcome, setup, shortcut, tryIt, done }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome: welcomeStep
            case .setup: setupStep
            case .shortcut: shortcutStep
            case .tryIt: tryItStep
            case .done: doneStep
            }
        }
        .frame(maxWidth: 400)
        .multilineTextAlignment(.center)
        .onAppear {
            // **Resume is derived, not stored as an index.** Grants and models
            // report their own state, so a stored step number would go stale
            // against reality the moment a permission changed outside the app.
            step = resumedStep()
            refreshGrants()
            startPollingIfNeeded()
        }
        .onDisappear { stopPolling() }
        .onChange(of: step) { _, _ in startPollingIfNeeded() }
        .onChange(of: isWindowVisible) { _, _ in startPollingIfNeeded() }
    }

    private func resumedStep() -> Step {
        if !welcomeSeen { return .welcome }
        if !(PermissionChecker.microphoneStatus() == .authorized) { return .setup }
        if !PermissionChecker.checkInputMonitoring() { return .setup }
        if !shortcutChosen { return .shortcut }
        return .tryIt
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            // No icon. The mark's plate is invisible on ink without a hairline,
            // the canon allows that hairline only in the website header, and the
            // sidebar lockup already shows the mark a few points away.
            Text("AF Flow")
                .font(theme.displayFont)
                .tracking(-0.48)
                .foregroundStyle(Brand.textOnDark)

            Text("Sovereign personal intelligence for your Mac")
                .font(theme.textFont(size: 15))
                .foregroundStyle(Brand.secondaryOnDark)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 12) {
                reassurance("lock.shield.fill",
                            "All open-source models. Voice to text, meeting transcription, your second brain and Q and A run under your control.")
                reassurance("externaldrive.fill",
                            "No accounts required. Your notes, transcripts and wiki stay on this Mac.")
            }
            .padding(.top, 26)

            primary("Get started") {
                welcomeSeen = true
                advance(to: .setup)
            }
            .padding(.top, 28)
        }
    }

    private var setupStep: some View {
        VStack(spacing: 0) {
            stepTitle("Setup")
            Text("Grant two permissions. AF Flow chooses the local models.")
                .font(theme.textFont(size: 13))
                .foregroundStyle(Brand.secondaryOnDark)
                .padding(.top, 8)

            VStack(spacing: 9) {
                permissionRow(
                    name: "Microphone",
                    detail: "To hear your voice",
                    granted: micGranted,
                    grant: {
                        // `checkMicrophone` triggers the system prompt when the
                        // status is notDetermined, and returns false when it is
                        // already denied, which is when the privacy pane is the
                        // only route left.
                        Task {
                            let granted = await PermissionChecker.checkMicrophone()
                            await MainActor.run {
                                micGranted = granted
                                if !granted, PermissionChecker.microphoneStatus() == .denied {
                                    PermissionChecker.openMicrophoneSettings()
                                }
                            }
                        }
                    }
                )
                permissionRow(
                    name: "Input Monitoring",
                    detail: "To notice your shortcut",
                    granted: inputMonitoringGranted,
                    grant: { PermissionChecker.promptInputMonitoring() },
                    // Returning without granting is not an error, only "still
                    // waiting". macOS grants this one in System Settings and
                    // nowhere else, so saying so is the useful thing.
                    waitingCaption: "Not granted yet. macOS grants this in System Settings."
                )
            }
            .padding(.top, 22)

            if micGranted && inputMonitoringGranted {
                primary("Continue") { advance(to: .shortcut) }
                    .padding(.top, 24)
            }

            // Skipping is allowed and must be SAFE, not silent: a missing grant
            // resurfaces on the compact Home as its permission-warning line.
            ghostLink("Set up later") { advance(to: .shortcut) }
                .padding(.top, micGranted && inputMonitoringGranted ? 14 : 24)
        }
    }

    private var shortcutStep: some View {
        VStack(spacing: 0) {
            stepTitle("Your shortcut")
            Text("Hold these keys anywhere, speak, release. Your words land where the cursor is.")
                .font(theme.textFont(size: 13))
                .foregroundStyle(Brand.secondaryOnDark)
                .padding(.top, 8)

            if !inputMonitoringGranted {
                // Reachable through "Set up later". Capture cannot work without
                // the grant, and saying which grant is missing beats a dead field.
                calloutRow("AF Flow cannot see the keyboard yet")
                    .padding(.top, 22)
                ghostButton("Back to Setup") { advance(to: .setup) }
                    .padding(.top, 18)
            } else if capturing {
                // The app's own recorder, not a second capture state machine.
                ShortcutRecorderView(
                    title: "Hold the keys you want",
                    chord: appState.pushToTalkChord,
                    onRecordingStateChange: appState.setShortcutCaptureActive
                ) { chord in
                    appState.updateShortcut(chord, for: .pushToTalk)
                    if appState.shortcutErrorMessage == nil {
                        capturing = false
                    }
                }
                .padding(.top, 20)
                .frame(maxWidth: 340)

                if let problem = appState.shortcutErrorMessage {
                    calloutRow(problem).padding(.top, 12)
                }

                ghostButton("Cancel") { capturing = false }
                    .padding(.top, 16)
            } else {
                // **The live binding, never a factory default dressed as an
                // offer.** On a true first run this IS the default; on a rerun
                // it is whatever the user already has.
                Keycap(text: appState.pushToTalkChord.displayString)
                    .padding(.top, 22)

                HStack(spacing: 10) {
                    primary("Use this") {
                        shortcutChosen = true
                        advance(to: .tryIt)
                    }
                    ghostButton("Press my own") { capturing = true }
                }
                .padding(.top, 20)

                Text("Hands-free and other shortcuts live in Settings.")
                    .font(theme.captionFont)
                    .foregroundStyle(Brand.secondaryOnDark)
                    .padding(.top, 16)
            }
        }
    }

    private var tryItStep: some View {
        VStack(spacing: 0) {
            stepTitle("Try it")
            HStack(spacing: 8) {
                Text("Hold")
                    .font(theme.textFont(size: 13))
                    .foregroundStyle(Brand.textOnDark)
                Keycap(text: appState.pushToTalkChord.displayString)
                Text("and say something")
                    .font(theme.textFont(size: 13))
                    .foregroundStyle(Brand.textOnDark)
            }
            .padding(.top, 18)

            Text("Your words land on the clipboard, and you paste them where you want them.")
                .font(theme.captionFont)
                .foregroundStyle(Brand.secondaryOnDark)
                .padding(.top, 14)

            HStack(spacing: 10) {
                ghostButton("Skip") { advance(to: .done) }
                primary("Continue") { advance(to: .done) }
            }
            .padding(.top, 26)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Brand.mist)

            Text("You're all set")
                .font(theme.displayFont)
                .tracking(-0.48)
                .foregroundStyle(Brand.textOnDark)
                .padding(.top, 16)

            Text("AF Flow lives in your menu bar")
                .font(theme.textFont(size: 13))
                .foregroundStyle(Brand.secondaryOnDark)
                .padding(.top, 8)

            Text("Hold \(appState.pushToTalkChord.displayString) anywhere and speak. Nothing you say leaves this Mac.")
                .font(theme.textFont(size: 13))
                .foregroundStyle(Brand.textOnDark)
                .padding(.top, 18)

            primary("Start using AF Flow") {
                stopPolling()
                onFinished()
            }
            .padding(.top, 28)
        }
    }

    // MARK: - Pieces, all obeying the fill rule

    private func stepTitle(_ text: String) -> some View {
        Text(text)
            .font(theme.sectionTitleFont)
            .tracking(-0.32)
            .foregroundStyle(Brand.textOnDark)
    }

    private func reassurance(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Brand.mist)
                .frame(width: 16)
            Text(text)
                .font(theme.textFont(size: 13))
                .foregroundStyle(Brand.secondaryOnDark)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A dark well: ink at 55% over the plate, which is an effective 0.928 over
    /// white. Paper reads 12.01:1 on it, `#B9C3BE` 7.49:1, mist 9.67:1. Ink-side
    /// per the fill rule; a translucent paper fill here is how contrast dies.
    private func well<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.surfaceDark.opacity(0.55))
            )
    }

    private func permissionRow(
        name: String,
        detail: String,
        granted: Bool,
        grant: @escaping () -> Void,
        waitingCaption: String? = nil
    ) -> some View {
        well {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 11) {
                    Image(systemName: granted ? "checkmark.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(granted ? Brand.mist : Brand.secondaryOnDark)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(theme.textFont(size: 13, weight: 500))
                            .foregroundStyle(Brand.textOnDark)
                        Text(detail)
                            .font(theme.captionFont)
                            .foregroundStyle(Brand.secondaryOnDark)
                    }
                    Spacer(minLength: 8)
                    if granted {
                        Text("Granted")
                            .font(theme.textFont(size: 11.5, weight: 600))
                            .foregroundStyle(Brand.mist)
                    } else {
                        Button("Grant", action: grant)
                            .buttonStyle(AFFlowPrimaryButtonStyle())
                            .controlSize(.small)
                    }
                }
                if !granted, let waitingCaption {
                    Text(waitingCaption)
                        .font(theme.captionFont)
                        .foregroundStyle(Brand.secondaryOnDark)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// **Clay is banned as body text on the fog** at 3.78:1, so a problem is
    /// paper text with a clay dot carrying the alarm at the 3:1 non-text
    /// minimum.
    private func calloutRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Brand.statusLiveOnDark).frame(width: 7, height: 7)
            Text(text)
                .font(theme.textFont(size: 13))
                .foregroundStyle(Brand.textOnDark)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primary(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action).buttonStyle(AFFlowPrimaryButtonStyle())
    }

    private func ghostButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action).buttonStyle(AFFlowGhostButtonStyle())
    }

    private func ghostLink(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(theme.captionFont)
                .foregroundStyle(Brand.secondaryOnDark)
        }
        .buttonStyle(.plain)
    }

    private struct Keycap: View {
        @Environment(\.appTheme) private var theme
        let text: String
        var body: some View {
            // One of only two paper-side fills allowed on the fog, because it
            // is solid: 16.37:1 whatever the video is doing underneath.
            Text(text.isEmpty ? "no shortcut set" : text)
                .font(theme.textFont(size: 15, weight: 500))
                .foregroundStyle(Brand.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Brand.well))
        }
    }

    // MARK: - Grants

    private func advance(to next: Step) {
        step = next
    }

    private func refreshGrants() {
        micGranted = PermissionChecker.microphoneStatus() == .authorized
        inputMonitoringGranted = PermissionChecker.checkInputMonitoring()
    }

    /// **Polling runs only while the Setup step is current AND the window is
    /// really visible, and stops the moment both grants land.**
    ///
    /// The front door does not poll. A review on 2026-08-24 found an
    /// unconditional two-second timer running forever because Home mounts the
    /// whole shell on every launch; putting a permission step on Home would put
    /// that back if it were not scoped here. Accessibility is never queried.
    private func startPollingIfNeeded() {
        stopPolling()
        guard step == .setup, isWindowVisible else { return }
        refreshGrants()
        guard !(micGranted && inputMonitoringGranted) else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                refreshGrants()
                if micGranted && inputMonitoringGranted { stopPolling() }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
