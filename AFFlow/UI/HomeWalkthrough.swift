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
    @State private var listeningPulse = false
    @StateObject private var tryIt: TryItController
    @StateObject private var micLevel = MicLevelMonitor()

    /// **The hero is a brand-skin surface.** Under Windows 95 and Space the fog
    /// and its dark components do not render, so the walkthrough lays out the
    /// same content on the skin's own ground with the skin's own vocabulary.
    /// Hardcoding the brand's dark values here would have put paper text on a
    /// grey Windows 95 panel.
    private var onHero: Bool { theme.id == .current }

    private var primaryText: Color { onHero ? Brand.textOnDark : theme.textPrimary }
    private var secondaryText: Color { onHero ? Brand.secondaryOnDark : theme.textSecondary }
    private var accentText: Color { onHero ? Brand.mist : theme.accent }
    private var alarmDot: Color { onHero ? Brand.statusLiveOnDark : theme.statusLive }
    private var wellFill: Color { onHero ? Brand.surfaceDark.opacity(0.55) : theme.controlBackground }

    enum Step: Int, CaseIterable { case welcome, setup, shortcut, tryIt, done }

    init(appState: AppState, isWindowVisible: Bool, onFinished: @escaping () -> Void) {
        self.appState = appState
        self.isWindowVisible = isWindowVisible
        self.onFinished = onFinished
        _tryIt = StateObject(wrappedValue: TryItController(transcriber: appState.transcriber))
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcomeStep
                case .setup: setupStep
                case .shortcut: shortcutStep
                case .tryIt: tryItStep
                case .done: doneStep
                }
            }
            // The outgoing step leaves, the incoming one arrives with a small
            // upward drift. `.id` is what makes SwiftUI treat a step change as
            // a replacement rather than a diff, so the transition actually
            // runs. Reduced motion collapses this to nothing, handled by
            // `brandReveal`.
            .id(step)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 8)),
                    removal: .opacity
                )
            )
        }
        .brandReveal(value: step)
        .frame(maxWidth: 400)
        .multilineTextAlignment(.center)
        .onAppear {
            // **Resume is derived, not stored as an index.** Grants and models
            // report their own state, so a stored step number would go stale
            // against reality the moment a permission changed outside the app.
            step = resumedStep()
            refreshGrants()
            startPollingIfNeeded()
            syncTryItLifecycle()
            syncMeterLifecycle()
            Task { await loadModels() }
        }
        .onDisappear {
            stopPolling()
            tryIt.cleanup()
            micLevel.stop()
            // Never leave his real shortcut suspended.
            appState.setShortcutCaptureActive(false)
        }
        .onChange(of: step) { _, _ in startPollingIfNeeded() }
        .onChange(of: isWindowVisible) { _, _ in
            startPollingIfNeeded()
            syncTryItLifecycle()
            syncMeterLifecycle()
        }
        .onChange(of: step) { _, _ in
            syncTryItLifecycle()
            syncMeterLifecycle()
        }
        .onChange(of: micGranted) { _, _ in syncMeterLifecycle() }
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
                .foregroundStyle(primaryText)

            Text("Sovereign personal intelligence for your Mac")
                .font(theme.textFont(size: 15))
                .foregroundStyle(secondaryText)
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
                .foregroundStyle(secondaryText)
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
                if micGranted {
                    soundCheckRow
                }
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

            modelsRow.padding(.top, 9)

            // Continue only when both grants are in AND the models are ready:
            // the app cannot transcribe a word without them, so offering the
            // next step earlier would be offering a broken try-it.
            if micGranted && inputMonitoringGranted && modelsReady {
                primary("Continue") { advance(to: .shortcut) }
                    .padding(.top, 24)
            }

            // Skipping is allowed and must be SAFE, not silent: a missing grant
            // resurfaces on the compact Home as its permission-warning line.
            ghostLink("Set up later") { advance(to: .shortcut) }
                .padding(.top, micGranted && inputMonitoringGranted && modelsReady ? 14 : 24)
        }
    }

    private var modelsReady: Bool {
        appState.modelManager.isReady && cleanupReady
    }

    private var modelsFailed: Bool {
        appState.modelManager.state == .error || appState.textCleanupManager.state == .error
    }

    /// The models row. Its subtitle mirrors the LIVE status rather than a fixed
    /// sentence, so it cannot claim "ready" while a download is still running.
    private var modelsRow: some View {
        well {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 11) {
                    Image(systemName: modelsReady ? "checkmark.circle" : (modelsFailed ? "circle" : "arrow.down.circle"))
                        .font(.system(size: 15))
                        .foregroundStyle(modelsReady ? accentText : (modelsFailed ? alarmDot : secondaryText))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Local models")
                            .font(theme.textFont(size: 13, weight: 500))
                            .foregroundStyle(primaryText)
                        Text(modelsSubtitle)
                            .font(theme.captionFont)
                            .foregroundStyle(secondaryText)
                    }
                    Spacer(minLength: 8)
                    if modelsFailed {
                        Button("Retry") { Task { await loadModels() } }
                            .buttonStyle(AFFlowPrimaryButtonStyle())
                            .controlSize(.small)
                    } else if !modelsReady {
                        ProgressView().controlSize(.small).colorScheme(onHero ? .dark : .light)
                    }
                }

                Text("AF Flow picks these during onboarding. Advanced model controls live in Settings.")
                    .font(theme.captionFont)
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelsSubtitle: String {
        if modelsFailed { return "Download failed" }
        if !appState.cleanupEnabled, appState.modelManager.isReady { return "Ready for voice-to-text" }
        if modelsReady { return "Ready for voice-to-text" }
        if let progress = appState.modelManager.downloadProgress, progress > 0, progress < 1 {
            return "Downloading \(Int(progress * 100))%"
        }
        return "Downloading the local models AF Flow needs"
    }

    /// The sound check. Its own caption until the first sound arrives, so
    /// silence reads as "say something" rather than as a broken microphone.
    private var soundCheckRow: some View {
        well {
            VStack(alignment: .leading, spacing: 9) {
                Text(micLevel.level > 0.02 ? "Hearing you" : "Say something")
                    .font(theme.captionFont)
                    .foregroundStyle(secondaryText)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(primaryText.opacity(0.14))
                        Capsule()
                            // Turns clay above 0.7, which is the level at which
                            // clipping starts to cost him words.
                            .fill(micLevel.level > 0.7 ? alarmDot : accentText)
                            .frame(width: max(4, geo.size.width * CGFloat(min(micLevel.level * 1.6, 1))))
                    }
                }
                .frame(height: 8)
            }
        }
    }

    /// **Respects the cleanup policy rather than bypassing it.**
    ///
    /// This used to call `textCleanupManager.loadModel` directly, which skips
    /// the guards in `AppState.refreshCleanupModelState()`. For a user who has
    /// cleanup disabled or on a non-local backend that meant a multi-gigabyte
    /// download they had already declined, a race against `initialize()`'s
    /// unload, and `modelsReady` possibly never becoming true, so Continue
    /// never appeared and the walkthrough stalled.
    private func loadModels() async {
        await appState.modelManager.loadModel(name: appState.speechModel)
        await appState.refreshCleanupModelState()
    }

    /// Cleanup counts as ready when the policy says it is not wanted: waiting
    /// for a model nobody asked for is how Continue never arrives.
    private var cleanupReady: Bool {
        guard appState.cleanupEnabled else { return true }
        return appState.textCleanupManager.isReady
    }

    private var shortcutStep: some View {
        VStack(spacing: 0) {
            stepTitle("Your shortcut")
            Text("Hold these keys anywhere, speak, release. Your words land where the cursor is.")
                .font(theme.textFont(size: 13))
                .foregroundStyle(secondaryText)
                .padding(.top, 8)

            if !inputMonitoringGranted {
                // Reachable through "Set up later". Capture cannot work without
                // the grant, and saying which grant is missing beats a dead field.
                calloutRow("AF Flow cannot see the keyboard yet. Its shortcut needs Input Monitoring.")
                    .padding(.top, 22)
                HStack(spacing: 10) {
                    ghostButton("Back to Setup") { advance(to: .setup) }
                    // **There has to be a way out.** Without this the only
                    // control here was "Back to Setup", whose only control was
                    // "Set up later" back to here: a user who declines Input
                    // Monitoring looped between two steps forever and could
                    // never reach Home at all. Skipping must be safe, and it
                    // was safe one step earlier and not this one.
                    primary("Skip for now") { advance(to: .done) }
                }
                .padding(.top, 18)
                Text("You can set the shortcut later in Settings.")
                    .font(theme.captionFont)
                    .foregroundStyle(secondaryText)
                    .padding(.top, 14)
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
                Keycap(text: appState.pushToTalkChord.displayString, onHero: onHero)
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
                    .foregroundStyle(secondaryText)
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
                    .foregroundStyle(primaryText)
                Keycap(text: appState.pushToTalkChord.displayString, onHero: onHero)
                Text("and say something")
                    .font(theme.textFont(size: 13))
                    .foregroundStyle(primaryText)
            }
            .padding(.top, 18)

            // A reserved height, so proving it works does not make the layout
            // jump under the reader as the state changes.
            tryItState
                .frame(minHeight: 92)
                .padding(.top, 18)

            HStack(spacing: 10) {
                ghostButton("Skip") { advance(to: .done) }
                primary("Continue") { advance(to: .done) }
            }
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    private var tryItState: some View {
        if tryIt.monitorStartFailed {
            // **Never Accessibility**, which cannot be granted in this sandbox.
            // What this actually needs is Input Monitoring.
            VStack(spacing: 14) {
                calloutRow("AF Flow cannot see the keyboard yet. Grant Input Monitoring, then come back.")
                ghostButton("Back to Setup") { advance(to: .setup) }
            }
        } else if tryIt.isRecording {
            HStack(spacing: 9) {
                Circle()
                    .fill(alarmDot)
                    .frame(width: 10, height: 10)
                    .brandPulse(active: true, isPulsing: listeningPulse)
                Text("Listening...")
                    .font(theme.textFont(size: 13))
                    .foregroundStyle(primaryText)
            }
            .onAppear { listeningPulse = true }
        } else if tryIt.isTranscribing {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small).colorScheme(onHero ? .dark : .light)
                Text("Transcribing...")
                    .font(theme.textFont(size: 13))
                    .foregroundStyle(primaryText)
            }
        } else if let text = tryIt.transcribedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 12) {
                // His words, on the brand's reading surface. A solid light well
                // is the second of the two paper-side exceptions on the fog,
                // and user content is Inter, never the display face.
                Text("\u{201C}\(text)\u{201D}")
                    .font(theme.textFont(size: 15))
                    .foregroundStyle(onHero ? Brand.textPrimary : theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 380)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(onHero ? Brand.well : theme.textBackground)
                    )
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(accentText)
                    Text("It works. Your words land where the cursor is.")
                        .font(theme.textFont(size: 13))
                        .foregroundStyle(accentText)
                }
            }
        } else if tryIt.heardNothing {
            // **An empty result is not a success**, and nil is an empty result.
            // A nil transcription used to fall through to "Waiting for you",
            // and a whitespace-only one showed this callout and then
            // auto-advanced two seconds later as though it had worked.
            calloutRow("No speech detected. Check the microphone and try again.")
        } else {
            Text("Waiting for you...")
                .font(theme.textFont(size: 13))
                .foregroundStyle(secondaryText)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(accentText)

            Text("You're all set")
                .font(theme.displayFont)
                .tracking(-0.48)
                .foregroundStyle(primaryText)
                .padding(.top, 16)

            Text("AF Flow lives in your menu bar")
                .font(theme.textFont(size: 13))
                .foregroundStyle(secondaryText)
                .padding(.top, 8)

            Text("Hold \(appState.pushToTalkChord.displayString) anywhere and speak. Nothing you say leaves this Mac.")
                .font(theme.textFont(size: 13))
                .foregroundStyle(primaryText)
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
            .foregroundStyle(primaryText)
    }

    private func reassurance(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(accentText)
                .frame(width: 16)
            Text(text)
                .font(theme.textFont(size: 13))
                .foregroundStyle(secondaryText)
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
                    .fill(wellFill)
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
                        .foregroundStyle(granted ? accentText : secondaryText)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(theme.textFont(size: 13, weight: 500))
                            .foregroundStyle(primaryText)
                        Text(detail)
                            .font(theme.captionFont)
                            .foregroundStyle(secondaryText)
                    }
                    Spacer(minLength: 8)
                    if granted {
                        Text("Granted")
                            .font(theme.textFont(size: 11.5, weight: 600))
                            .foregroundStyle(accentText)
                    } else {
                        Button("Grant", action: grant)
                            .buttonStyle(AFFlowPrimaryButtonStyle())
                            .controlSize(.small)
                    }
                }
                if !granted, let waitingCaption {
                    Text(waitingCaption)
                        .font(theme.captionFont)
                        .foregroundStyle(secondaryText)
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
            Circle().fill(alarmDot).frame(width: 7, height: 7)
            Text(text)
                .font(theme.textFont(size: 13))
                .foregroundStyle(primaryText)
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
                .foregroundStyle(secondaryText)
        }
        .buttonStyle(.plain)
    }

    private struct Keycap: View {
        @Environment(\.appTheme) private var theme
        let text: String
        var onHero: Bool = true
        var body: some View {
            // On the fog this is one of only two paper-side fills allowed,
            // because it is SOLID: 16.37:1 whatever the video is doing
            // underneath. Off the fog it is the skin's own control surface.
            Text(text.isEmpty ? "no shortcut set" : text)
                .font(theme.textFont(size: 15, weight: 500))
                .foregroundStyle(onHero ? Brand.textPrimary : theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(onHero ? Brand.well : theme.textBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(onHero ? Color.clear : theme.separator, lineWidth: 1)
                        )
                )
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

    /// The monitor, the recorder and the transcriber warm-up exist only while
    /// this step is current AND the window is really visible. They hold the
    /// microphone, and this app's whole history is about not competing for it.
    /// The level meter holds an audio engine, so it runs only on the Setup
    /// step, only once the microphone is granted, and only while the window is
    /// really visible.
    private func syncMeterLifecycle() {
        if step == .setup, micGranted, isWindowVisible {
            micLevel.start(deviceID: AudioDeviceManager.selectedInputDeviceID())
        } else {
            micLevel.stop()
        }
    }

    private func syncTryItLifecycle() {
        if step == .tryIt, isWindowVisible {
            // **Suspend the app's own monitor first.** It is bound to the same
            // chord, so without this one press drove BOTH the real dictation
            // pipeline, which pastes into whatever he had focused, and the
            // try-it. The same suspension the shortcut recorder uses.
            appState.setShortcutCaptureActive(true)
            tryIt.chord = appState.pushToTalkChord
            tryIt.start { advance(to: .done) }
        } else {
            tryIt.cleanup()
            appState.setShortcutCaptureActive(false)
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
