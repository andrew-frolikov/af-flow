// GhostPepper/UI/OnboardingWindow.swift
import SwiftUI
import AppKit
import AVFoundation
import CoreAudio

// MARK: - Mic Level Monitor

@MainActor
class MicLevelMonitor: ObservableObject {
    @Published var level: Float = 0
    private var engine: AVAudioEngine?
    private var isRunning = false

    func start(deviceID: AudioDeviceID? = nil) {
        guard !isRunning else { return }
        // Only start if mic permission is already granted
        guard PermissionChecker.microphoneStatus() == .authorized else { return }
        let engine = AVAudioEngine()

        if let deviceID {
            let audioUnit = engine.inputNode.audioUnit!
            var targetDeviceID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &targetDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { return }
        }

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames {
                let sample = channelData[0][i]
                sum += sample * sample
            }
            let rms = sqrtf(sum / Float(max(frames, 1)))
            // Normalize to 0-1 range (RMS of speech is typically 0.01-0.1)
            let normalized = min(rms * 10, 1.0)
            Task { @MainActor [weak self] in
                self?.level = normalized
            }
        }

        do {
            try engine.start()
            self.engine = engine
            isRunning = true
        } catch {
            // Silently fail — mic level is not critical
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
    }
}

// MARK: - Window Controller

class OnboardingWindowController {
    private var window: NSWindow?

    func show(appState: AppState, onComplete: @escaping () async -> Void) {
        dismiss()

        // The .regular flip that used to live here is gone: AF Flow is a
        // permanent Dock app as of 2026-07-21, so this was a no-op. Removed
        // rather than left, because the next person reading it would
        // reasonably conclude the app's Dock presence is still dynamic.
        //
        // Found by the sweep that followed Codex finding 5, not by Codex. Four
        // call sites managed one global; three are gone and this was the last.
        // The dispatch below is kept: it also lets the window finish being
        // built before the view is installed.
        DispatchQueue.main.async {
            let onboardingView = OnboardingView(appState: appState, onComplete: { [weak self] in
                await onComplete()
                self?.dismiss()
            })

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AF Flow"
            window.contentView = NSHostingView(rootView: AFFlowThemedRoot { onboardingView })
            window.applyAFFlowSkin()
            window.center()
            window.level = .normal
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            self.window = window
        }
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}

// MARK: - Main Onboarding View

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    let onComplete: () async -> Void
    @State private var currentStep = 1

    var body: some View {
        VStack {
            switch currentStep {
            case 1:
                WelcomeStep(onContinue: { currentStep = 2 })
            case 2:
                SetupStep(appState: appState, modelManager: appState.modelManager, onContinue: { currentStep = 3 })
            case 3:
                TryItStep(appState: appState, onContinue: { currentStep = 4 })
            case 4:
                DoneStep(onComplete: completeOnboarding)
            default:
                EmptyView()
            }
        }
        .frame(width: 480, height: 620)
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        Task {
            await onComplete()
        }
    }
}

// MARK: - Step 1: Welcome

struct WelcomeStep: View {
    @Environment(\.appTheme) private var theme
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .cornerRadius(24)

            Text("AF Flow")
                .font(.system(size: 28, weight: .bold))

            Text("Sovereign personal intelligence\nfor your Mac")
                .font(.title3)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(theme.accent)
                    Text("All open-source models. Voice-to-text, meeting transcription, your second brain, and Q&A run under your control.")
                        .font(.callout)
                        .foregroundStyle(theme.textSecondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(theme.accent)
                    Text("No accounts required. Your notes, transcripts, and wiki stay on this Mac.")
                        .font(.callout)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.statusReady.opacity(0.08))
                    .strokeBorder(theme.statusReady.opacity(0.2))
            )
            .padding(.horizontal, 24)

            Spacer()

            Button(action: onContinue) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Step 2: Setup

struct SetupStep: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var appState: AppState
    @ObservedObject var modelManager: ModelManager
    let onContinue: () -> Void

    @State private var micGranted = false
    @State private var micDenied = false
    @State private var accessibilityGranted = false
    @State private var permissionTimer: Timer?
    @State private var localIntelligenceLoadStarted = false
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0
    @StateObject private var micLevel = MicLevelMonitor()

    private var allComplete: Bool {
        micGranted && accessibilityGranted && requiredModelsReady
    }

    private var voiceModelReady: Bool {
        modelManager.isReady
    }

    private var cleanupModelReady: Bool {
        appState.textCleanupManager.isReady
    }

    private var requiredModelsReady: Bool {
        voiceModelReady && cleanupModelReady
    }

    private var localIntelligenceStatus: String {
        if modelManager.state == .error || appState.textCleanupManager.state == .error {
            return "Download failed"
        }

        if let activeDownload = RuntimeModelInventory.activeDownloadText(rows: [speechModelRow, cleanupModelRow].compactMap(\.self)) {
            return activeDownload
        }

        if requiredModelsReady {
            return "Ready for voice-to-text"
        }

        return "Downloading the local models AF Flow needs"
    }

    private var modelRows: [RuntimeModelRow] {
        RuntimeModelInventory.rows(
            selectedSpeechModelName: appState.speechModel,
            activeSpeechModelName: modelManager.modelName,
            speechModelState: modelManager.state,
            speechDownloadProgress: modelManager.downloadProgress,
            cachedSpeechModelNames: modelManager.cachedModelNames,
            cleanupState: appState.textCleanupManager.state,
            selectedCleanupModelKind: appState.textCleanupManager.selectedCleanupModelKind,
            selectedWikiModelKind: nil,
            cachedCleanupKinds: appState.textCleanupManager.cachedModelKinds
        )
    }

    private var speechModelRow: RuntimeModelRow? {
        modelRows.first(where: { $0.id == appState.speechModel })
    }

    private var cleanupModelRow: RuntimeModelRow? {
        guard let descriptor = TextCleanupManager.cleanupModels.first(where: { $0.kind == appState.textCleanupManager.selectedCleanupModelKind }) else {
            return nil
        }
        return modelRows.first(where: { $0.id == "cleanup-\(descriptor.fileName)" })
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Setup 🌶️")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 24)
                .padding(.bottom, 8)

            Text("Grant permissions. AF Flow chooses the local models.")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)
                .padding(.bottom, 16)

            ScrollView {
            VStack(spacing: 10) {
                SetupRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "To hear your voice",
                    isComplete: micGranted
                ) {
                    if micDenied {
                        Button("Open Settings") {
                            PermissionChecker.openMicrophoneSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                        .controlSize(.small)
                    } else if !micGranted {
                        Button("Grant") {
                            Task {
                                let granted = await PermissionChecker.checkMicrophone()
                                micGranted = granted
                                if granted {
                                    inputDevices = AudioDeviceManager.listInputDevices()
                                    selectedDeviceID = AudioDeviceManager.selectedInputDeviceID() ?? AudioDeviceManager.defaultInputDeviceID() ?? 0
                                    micLevel.start(deviceID: selectedDeviceID == 0 ? nil : selectedDeviceID)
                                } else {
                                    micDenied = true
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                        .controlSize(.small)
                    }
                }

                if micGranted {
                    VStack(spacing: 8) {
                        if inputDevices.count > 1 {
                            Picker("Input Device", selection: $selectedDeviceID) {
                                ForEach(inputDevices) { device in
                                    Text(device.name).tag(device.id)
                                }
                            }
                            .onChange(of: selectedDeviceID) { _, newValue in
                                AudioDeviceManager.setSelectedInputDevice(newValue)
                                // Restart level monitor for new device
                                micLevel.stop()
                                micLevel.start(deviceID: newValue == 0 ? nil : newValue)
                            }
                        }

                        // Sound level meter
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                                .font(.caption)
                                .foregroundStyle(theme.textSecondary)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(theme.controlBackground)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(micLevel.level > 0.7 ? theme.statusLive : micLevel.level > 0.3 ? theme.accent : theme.statusReady)
                                        .frame(width: geo.size.width * CGFloat(micLevel.level))
                                        .animation(.easeOut(duration: 0.08), value: micLevel.level)
                                }
                            }
                            .frame(height: 8)

                            Text("Sound check")
                                .font(.caption2)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                SetupRow(
                    icon: "keyboard.fill",
                    title: "Accessibility",
                    subtitle: "For keyboard shortcuts & pasting",
                    isComplete: accessibilityGranted
                ) {
                    if !accessibilityGranted {
                        Button("Grant") {
                            PermissionChecker.openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                        .controlSize(.small)
                    }
                }

                VStack(spacing: 8) {
                    SetupRow(
                        icon: "waveform",
                        title: "Local Models",
                        subtitle: localIntelligenceStatus,
                        isComplete: requiredModelsReady
                    ) {
                        if modelManager.state == .loading || appState.textCleanupManager.state.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else if modelManager.state == .error || appState.textCleanupManager.state == .error {
                            Button("Retry") {
                                Task { await loadRequiredLocalModels() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accent)
                            .controlSize(.small)
                        }
                    }

                    OnboardingModelSummary(
                        speechModelRow: speechModelRow,
                        cleanupModelRow: cleanupModelRow
                    )
                }
            }
            .padding(.horizontal, 24)
            }

            Spacer(minLength: 8)

            if allComplete {
                Button(action: {
                    stopPermissionPolling()
                    onContinue()
                }) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            let microphoneStatus = PermissionChecker.microphoneStatus()
            micGranted = microphoneStatus == .authorized
            micDenied = microphoneStatus == .denied
            accessibilityGranted = PermissionChecker.checkAccessibility()

            if micGranted {
                inputDevices = AudioDeviceManager.listInputDevices()
                selectedDeviceID = AudioDeviceManager.selectedInputDeviceID() ?? AudioDeviceManager.defaultInputDeviceID() ?? 0
                micLevel.start(deviceID: selectedDeviceID == 0 ? nil : selectedDeviceID)
            }

            if !localIntelligenceLoadStarted && !requiredModelsReady {
                localIntelligenceLoadStarted = true
                Task { await loadRequiredLocalModels() }
            }

            startPermissionPolling()
        }
        .onDisappear {
            stopPermissionPolling()
            micLevel.stop()
        }
    }

    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            let accessibilityGrantedNow = PermissionChecker.checkAccessibility()
            if accessibilityGrantedNow {
                accessibilityGranted = true
            }

            if accessibilityGrantedNow {
                stopPermissionPolling()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func loadRequiredLocalModels() async {
        await modelManager.loadModel(name: appState.speechModel)
        await appState.textCleanupManager.loadModel(kind: appState.textCleanupManager.selectedCleanupModelKind)
    }
}

private extension CleanupModelState {
    var isLoading: Bool {
        switch self {
        case .downloading, .loadingModel:
            return true
        case .idle, .ready, .error:
            return false
        }
    }
}

struct SetupRow<Actions: View>: View {
    @Environment(\.appTheme) private var theme
    let icon: String
    let title: String
    let subtitle: String
    let isComplete: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(isComplete ? theme.statusReady : theme.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer()

            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.statusReady)
                    .font(.title3)
            } else {
                actions()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.controlBackground)
        )
    }
}

private struct OnboardingModelSummary: View {
    @Environment(\.appTheme) private var theme
    let speechModelRow: RuntimeModelRow?
    let cleanupModelRow: RuntimeModelRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let row = speechModelRow {
                OnboardingModelRow(label: "Voice", name: row.name, size: row.sizeDescription, status: row.status)
            }
            if let row = cleanupModelRow {
                OnboardingModelRow(label: "Cleanup", name: row.name, size: row.sizeDescription, status: row.status)
            }

            Text("AF Flow picks these during onboarding. Advanced model controls live in Settings.")
                .font(.caption2)
                .foregroundStyle(theme.textSecondary)
                .padding(.top, 4)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.controlBackground)
        )
    }
}

private struct OnboardingModelRow: View {
    @Environment(\.appTheme) private var theme
    let label: String
    let name: String
    let size: String
    let status: RuntimeModelStatus

    var body: some View {
        HStack(spacing: 8) {
            statusIndicator
                .frame(width: 14, height: 14)

            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 50, alignment: .leading)

            Text(name)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .loaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.statusReady)
                .font(.caption)
        case .loading:
            ProgressView()
                .controlSize(.mini)
        case .downloading(let progress):
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
        case .notLoaded:
            Image(systemName: "circle")
                .foregroundStyle(theme.textSecondary)
                .font(.caption)
        case .systemManaged:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.statusReady)
                .font(.caption)
        }
    }

    private var statusText: String {
        switch status {
        case .loaded: "Ready"
        case .loading: "Loading..."
        case .downloading(let progress?): "Downloading \(Int(progress * 100))%"
        case .downloading(nil): "Preparing..."
        case .notLoaded: size
        case .systemManaged: "Managed by macOS"
        }
    }
}

// MARK: - Step 3: Try It

@MainActor
class TryItController: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var transcribedText: String?
    @Published var statusMessage = "Waiting for you to hold Right Command + Right Option..."
    @Published var monitorStartFailed = false

    private var hotkeyMonitor: HotkeyMonitoring?
    private var audioRecorder: AudioRecorder?
    private var hasAdvanced = false
    private var retryCount = 0
    private let maxRetries = 5
    private let transcriber: SpeechTranscriber
    private let hotkeyMonitorFactory: ([ChordAction: KeyChord]) -> HotkeyMonitoring

    init(
        transcriber: SpeechTranscriber,
        hotkeyMonitorFactory: @escaping ([ChordAction: KeyChord]) -> HotkeyMonitoring = { bindings in
            HotkeyMonitor(bindings: bindings)
        }
    ) {
        self.transcriber = transcriber
        self.hotkeyMonitorFactory = hotkeyMonitorFactory
    }

    func start(onAdvance: @escaping () -> Void) {
        let recorder = AudioRecorder()
        recorder.targetDeviceID = AudioDeviceManager.selectedInputDeviceID()
        recorder.prewarm()
        self.audioRecorder = recorder

        let monitor = hotkeyMonitorFactory([
            .pushToTalk: AppState.defaultPushToTalkChord
        ])
        monitor.onRecordingStart = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.statusMessage = ""
                self.isRecording = true
                try? recorder.startRecording()
            }
        }
        monitor.onRecordingStop = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                self.isTranscribing = true
                let buffer = await recorder.stopRecording()
                let text = await self.transcriber.transcribe(audioBuffer: buffer)
                self.isTranscribing = false
                if let text {
                    self.transcribedText = text
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.advance(onAdvance: onAdvance)
                    }
                } else {
                    self.statusMessage = "No speech detected. Check the selected microphone and try again."
                }
            }
        }

        if monitor.start() {
            self.hotkeyMonitor = monitor
        } else {
            retryStartMonitor(monitor: monitor)
        }
    }

    func advance(onAdvance: () -> Void) {
        guard !hasAdvanced else { return }
        hasAdvanced = true
        cleanup()
        onAdvance()
    }

    func cleanup() {
        hotkeyMonitor?.stop()
        hotkeyMonitor = nil
        audioRecorder = nil
    }

    private func retryStartMonitor(monitor: HotkeyMonitoring) {
        guard retryCount < maxRetries else {
            monitorStartFailed = true
            return
        }
        retryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if monitor.start() {
                self?.hotkeyMonitor = monitor
            } else {
                self?.retryStartMonitor(monitor: monitor)
            }
        }
    }
}

struct TryItStep: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var appState: AppState
    let onContinue: () -> Void
    @StateObject private var controller: TryItController

    init(appState: AppState, onContinue: @escaping () -> Void) {
        self.appState = appState
        self.onContinue = onContinue
        self._controller = StateObject(wrappedValue: TryItController(transcriber: appState.transcriber))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Try It")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 24)

            Text("Hold **Right Command + Right Option** and say something")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)

            HStack(spacing: 6) {
                KeyCap(label: "⌘ right", highlighted: true, isActive: controller.isRecording)
                KeyCap(label: "⌥ right", highlighted: true, isActive: controller.isRecording)
            }
            .padding(.vertical, 8)

            VStack(spacing: 12) {
                if controller.isRecording {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(theme.statusLive)
                            .frame(width: 10, height: 10)
                        Text("Recording...")
                            .foregroundStyle(theme.textSecondary)
                    }
                } else if controller.isTranscribing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing...")
                            .foregroundStyle(theme.textSecondary)
                    }
                } else if let text = controller.transcribedText {
                    VStack(spacing: 8) {
                        Text("\"\(text)\"")
                            .font(.body)
                            .italic()
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(theme.controlBackground)
                            )
                            .padding(.horizontal, 24)

                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.statusReady)
                            Text("It works! Your words will be pasted wherever your cursor is.")
                                .font(.callout)
                                .foregroundStyle(theme.statusReady)
                        }
                    }
                } else if controller.monitorStartFailed {
                    Text("Could not start hotkey monitor.\nPlease verify Accessibility is enabled in System Settings.")
                        .font(.callout)
                        .foregroundStyle(theme.statusLive)
                        .multilineTextAlignment(.center)
                } else {
                    Text(controller.statusMessage)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .frame(minHeight: 100)

            Spacer()

            HStack {
                Button("Skip") {
                    controller.advance(onAdvance: onContinue)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(action: {
                    controller.advance(onAdvance: onContinue)
                }) {
                    Text("Continue")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .onAppear { controller.start(onAdvance: onContinue) }
        .onDisappear { controller.cleanup() }
    }
}

struct KeyCap: View {
    @Environment(\.appTheme) private var theme
    let label: String
    let highlighted: Bool
    var isActive: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: highlighted ? .semibold : .regular))
            .foregroundStyle(highlighted ? .white : theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(highlighted
                        ? (isActive ? theme.statusLive : theme.accent)
                        : theme.controlBackground)
            )
            .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}

// MARK: - Step 4: Done

struct DoneStep: View {
    @Environment(\.appTheme) private var theme
    let onComplete: () -> Void
    @State private var isCompleting = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(theme.statusReady)

            Text("You're All Set!")
                .font(.system(size: 28, weight: .bold))

            Text("AF Flow lives in your menu bar")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)

            // Menu bar mockup
            HStack(spacing: 10) {
                Spacer()
                Image(systemName: "moon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                Image(systemName: "display")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .foregroundStyle(theme.accent)
                Image(systemName: "wifi")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                Image(systemName: "battery.75percent")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.controlBackground)
            )
            .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 8) {
                Text("From the menu bar you can:")
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
                BulletPoint("Switch your microphone")
                BulletPoint("Change your recording shortcuts")
                BulletPoint("Record and transcribe meetings")
                BulletPoint("Import meetings and build your second brain")
                BulletPoint("Ask local questions over your archive")
            }
            .padding(.horizontal, 40)

            Spacer()

            Button {
                guard !isCompleting else { return }
                isCompleting = true
                onComplete()
            } label: {
                HStack(spacing: 8) {
                    if isCompleting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isCompleting ? "Finishing Setup..." : "Start Using AF Flow")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .disabled(isCompleting)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }
}

struct BulletPoint: View {
    @Environment(\.appTheme) private var theme
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(theme.textSecondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(theme.textSecondary)
        }
    }
}
