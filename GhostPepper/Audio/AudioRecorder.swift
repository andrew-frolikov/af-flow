import AVFoundation
import AppKit
import CoreAudio

/// What the microphone actually delivered during one recording.
///
/// This exists because on 2026-08-09 it did not. Six dictations captured nothing
/// and the durable log recorded only that they had produced no text, so the
/// question "did the frames never arrive, or did they arrive empty?" — the
/// question that separates a dead audio engine from a muted microphone — could
/// not be answered from the log at all. `AudioRecorder` printed the sample count
/// to stdout, which for an app launched from Finder is /dev/null.
struct CaptureReport: Equatable {
    var inputFormatDescription: String
    var holdDuration: TimeInterval?
    var tapCallbacks: Int
    var convertedChunks: Int
    var sampleCount: Int
    var maxAmplitude: Float

    /// One line, written to the durable log after every recording.
    var summary: String {
        var parts = [
            "capture format=\(inputFormatDescription)",
            holdDuration.map { String(format: "hold=%.2fs", $0) } ?? "hold=unknown",
            "callbacks=\(tapCallbacks)",
            "chunks=\(convertedChunks)",
            "samples=\(sampleCount)",
            String(format: "peak=%.4f", maxAmplitude)
        ]

        if let verdict {
            parts.append(verdict)
        }

        return parts.joined(separator: " ")
    }

    /// Named so the two failure shapes can never be confused again. Frames that
    /// never arrive mean the engine's input path is dead; frames that arrive as
    /// zeroes mean the route is alive and the microphone is not.
    private var verdict: String? {
        if tapCallbacks == 0 {
            return "VERDICT=the microphone delivered no audio at all"
        }

        if sampleCount > 0, maxAmplitude == 0 {
            return "VERDICT=the microphone delivered digital silence"
        }

        return nil
    }
}

/// The shape of the hardware input route, read from Core Audio rather than from
/// the engine's own idea of it.
///
/// Codex round 1 of 2026-08-09, P1: the notification observers cannot see a
/// Bluetooth mic changing profile while the engine is idle.
/// `AVAudioEngineConfigurationChange` is posted while the graph is RENDERING,
/// and between dictations this graph is stopped; the default-device ID does not
/// move when the same device flips HFP to A2DP; and there is no wake. So the
/// engine has to be checked against the route rather than trusted to notice.
struct InputRouteSignature: Equatable {
    var deviceID: AudioDeviceID
    var sampleRate: Double
    var channelCount: UInt32
}

final class AudioRecorder {
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?
    var onConvertedAudioChunk: (([Float]) -> Void)?
    /// Called with the human-readable reason whenever the engine had to be
    /// rebuilt before a recording. Wired to the debug log: on 2026-08-09 the
    /// absence of exactly this line is what made the outage invisible.
    var onEngineRebuilt: ((String) -> Void)?

    /// The device ID to record from. If nil, uses the system default.
    var targetDeviceID: AudioDeviceID?

    /// Kept alive across recordings so AVFAudio does not have to re-run device
    /// discovery on every hotkey press. We rebuild when the user changes the
    /// target input device, and when anything could have invalidated the input
    /// path underneath us.
    ///
    /// THE SECOND CLAUSE IS NOT OPTIONAL AND WAS ONCE MISSING. Commit `9c4e2a4`
    /// made this engine persistent for startup latency and deleted the comment
    /// warning that "AVAudioEngine does not reliably recover when the default
    /// input device or its sample rate changes between sessions (Bluetooth mics
    /// flipping between HFP/A2DP profiles is the common trigger)". On 2026-08-09
    /// Andrew's Mac woke, his AirPods connected, and this engine's input path
    /// died with nothing watching. Six dictations captured zero frames while the
    /// app reported itself recording, including one he held for 103 seconds.
    ///
    /// Latency is preserved: a healthy engine is never rebuilt. See
    /// `rebuildEngineIfInvalidated()`.
    private var engine = AVAudioEngine()
    private var configuredTargetDeviceID: AudioDeviceID?
    private let bufferLock = NSLock()
    private let tapStateLock = NSLock()

    /// Bumped on every rebuild. Exposed so tests can prove the observers moved
    /// with the engine instead of watching a discarded one.
    private(set) var engineGeneration = 1
    /// The generation the configuration-change observer is registered against.
    /// If this ever falls behind `engineGeneration` the app is blind again.
    private(set) var configurationChangeObservedGeneration = 0

    /// Counters behind `CaptureReport`. Written from the audio thread under
    /// `tapStateLock`, read after stop.
    private(set) var tapCallbackCount = 0
    private(set) var convertedChunkCount = 0
    private var lastInputFormatDescription = "unknown"
    private var lastCaptureSampleCount = 0
    private var lastCaptureMaxAmplitude: Float = 0

    private let invalidationLock = NSLock()
    private var pendingInvalidationReasons: [String] = []
    /// The route shape the live engine was built against. Compared on every
    /// start; see `invalidateIfRouteChanged()`.
    private(set) var engineBuiltForRoute: InputRouteSignature?
    /// Injectable so the baseline logic can be driven deterministically instead
    /// of depending on whichever microphone the test host happens to have.
    var routeSignatureProvider: (AudioDeviceID?) -> InputRouteSignature? = {
        AudioRecorder.currentInputRouteSignature(targetDeviceID: $0)
    }
    private var configurationChangeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private let defaultInputListenerQueue = DispatchQueue(label: "com.frolikov.afflow.default-input-listener")

    init() {
        observeConfigurationChange()
        observeWake()
        observeDefaultInputDevice()
    }

    deinit {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let defaultInputListener {
            var address = Self.defaultInputDeviceAddress
            // Same queue as registration: Core Audio matches on queue AND block,
            // so a mismatch silently leaves the listener installed and firing.
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                defaultInputListenerQueue,
                defaultInputListener
            )
        }
    }

    // MARK: - Engine invalidation

    /// The reasons the engine cannot be trusted, or nil if it can. Several
    /// causes accumulate because one physical event (a wake with a Bluetooth mic
    /// attached) arrives as more than one notification, and the log has to name
    /// all of them.
    var pendingEngineInvalidationReason: String? {
        invalidationLock.lock()
        defer { invalidationLock.unlock() }
        return pendingInvalidationReasons.isEmpty
            ? nil
            : pendingInvalidationReasons.joined(separator: ", ")
    }

    /// Marks the engine as untrustworthy. Safe to call from any thread: Core
    /// Audio listeners fire on their own queue. Never rebuilds inline — a
    /// rebuild mid-recording would throw away audio he is in the middle of
    /// speaking.
    func invalidateEngine(reason: String) {
        invalidationLock.lock()
        if !pendingInvalidationReasons.contains(reason) {
            pendingInvalidationReasons.append(reason)
        }
        invalidationLock.unlock()
    }

    /// Rebuilds the engine if anything invalidated it, and does nothing at all
    /// otherwise so the prewarm and the hotkey latency survive.
    func rebuildEngineIfInvalidated() {
        invalidationLock.lock()
        let reasons = pendingInvalidationReasons
        pendingInvalidationReasons = []
        invalidationLock.unlock()

        guard !reasons.isEmpty else { return }

        rebuildEngine()
        onEngineRebuilt?(reasons.joined(separator: ", "))
    }

    /// Whether the route moved out from under an engine built for `previous`.
    ///
    /// Deliberately conservative in both directions. No previous signature means
    /// the engine is fresh and already correct. An unreadable current signature
    /// is no information at all, and treating it as a change would rebuild on
    /// every hotkey press whenever the Core Audio read is flaky, throwing away
    /// the prewarm this persistent engine exists to keep.
    static func inputRouteChanged(from previous: InputRouteSignature?, to current: InputRouteSignature?) -> Bool {
        guard let previous, let current else { return false }
        return previous != current
    }

    /// Reads the current shape of whichever device this recorder will record
    /// from — the pinned device if there is one, otherwise the system default.
    static func currentInputRouteSignature(targetDeviceID: AudioDeviceID?) -> InputRouteSignature? {
        guard let deviceID = targetDeviceID ?? AudioDeviceManager.defaultInputDeviceID(),
              deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }

        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &rateSize, &sampleRate) == noErr,
              sampleRate > 0 else {
            return nil
        }

        var configAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var configSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &configAddress, 0, nil, &configSize) == noErr,
              configSize > 0 else {
            return nil
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(configSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &configAddress, 0, nil, &configSize, bufferListPointer) == noErr else {
            return nil
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        let channelCount = bufferList.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        guard channelCount > 0 else { return nil }

        return InputRouteSignature(deviceID: deviceID, sampleRate: sampleRate, channelCount: channelCount)
    }

    /// Invalidates the engine if the route changed shape since it was built.
    /// This is the check that catches what no notification can.
    ///
    /// It compares only. Recording the baseline is `noteEngineBoundToRoute()`'s
    /// job, and the split matters: Codex round 2 caught this function setting
    /// the baseline in a `defer`, which `rebuildEngine()` then cleared, leaving
    /// the recording immediately after every rebuild with nothing to compare
    /// against — the original failure, one recording later.
    func invalidateIfRouteChanged() {
        let current = routeSignatureProvider(targetDeviceID)

        guard Self.inputRouteChanged(from: engineBuiltForRoute, to: current) else { return }

        let was = engineBuiltForRoute.map { "\(Int($0.sampleRate))Hz/\($0.channelCount)ch" } ?? "unknown"
        let now = current.map { "\(Int($0.sampleRate))Hz/\($0.channelCount)ch" } ?? "unknown"
        invalidateEngine(reason: "the input route changed shape (\(was) → \(now))")
    }

    /// Records the route the live engine is now bound to. Called from every
    /// place an engine becomes bound to hardware — prewarm, rebuild, and the
    /// start of a recording — because a baseline that is missing at any of them
    /// is a window in which a profile flip goes unnoticed.
    private func noteEngineBoundToRoute() {
        if let current = routeSignatureProvider(targetDeviceID) {
            engineBuiltForRoute = current
        }
    }

    private static var defaultInputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Re-registered on every rebuild. Registering once in `init` would leave
    /// the observer watching a discarded engine after the first rebuild, which
    /// is the 2026-08-09 blindness reached one rebuild later.
    private func observeConfigurationChange() {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
        }

        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.invalidateEngine(reason: "the audio graph was reconfigured")
        }
        configurationChangeObservedGeneration = engineGeneration
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidateEngine(reason: "the machine woke from sleep")
        }
    }

    private func observeDefaultInputDevice() {
        var address = Self.defaultInputDeviceAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.invalidateEngine(reason: "the default input device changed")
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultInputListenerQueue,
            listener
        )
        if status == noErr {
            defaultInputListener = listener
        }
    }

    #if DEBUG
    var test_currentEngine: AVAudioEngine { engine }
    #endif

    /// The accumulated audio samples captured during recording.
    /// Accessible for reading within the module (internal) so tests can inspect it.
    var audioBuffer: [Float] = []

    /// Target format for WhisperKit: 16 kHz, mono, Float32.
    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }()
    private let stopFlushSlackNanoseconds: UInt64 = 5_000_000
    private var tapBufferDurationNanoseconds: UInt64 = 20_000_000
    private var lastConvertedChunkAtNanoseconds: UInt64?
    private var inFlightTapCallbacks = 0
    private var stopWaitContinuation: CheckedContinuation<Void, Never>?

    /// Pre-warm the audio engine so the first recording starts faster.
    func prewarm() {
        applyTargetDeviceIfNeeded()
        _ = engine.inputNode // Force node initialization
        engine.prepare()
        // Without this, a route flip between launch and the first dictation of
        // the day has nothing to be compared against and goes unnoticed.
        noteEngineBoundToRoute()
    }

    /// Reset the audio engine to pick up a newly selected input route.
    /// Call this after changing the microphone selection in Settings.
    func resetForDeviceChange() {
        rebuildEngine()
        prewarm()
    }

    static func serializeAudioBuffer(_ samples: [Float]) throws -> Data {
        samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    static func serializePlayableArchiveAudioBuffer(_ samples: [Float]) throws -> Data {
        let sampleRate = UInt32(16_000)
        let channelCount = UInt16(1)
        let bitsPerSample = UInt16(16)
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataSize = samples.count * bytesPerSample
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample) / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let riffChunkSize = UInt32(36 + dataSize)

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(contentsOf: riffChunkSize.littleEndianBytes)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(contentsOf: UInt32(16).littleEndianBytes)
        data.append(contentsOf: UInt16(1).littleEndianBytes)
        data.append(contentsOf: channelCount.littleEndianBytes)
        data.append(contentsOf: sampleRate.littleEndianBytes)
        data.append(contentsOf: byteRate.littleEndianBytes)
        data.append(contentsOf: blockAlign.littleEndianBytes)
        data.append(contentsOf: bitsPerSample.littleEndianBytes)
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: UInt32(dataSize).littleEndianBytes)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = Int16((clamped * Float(Int16.max)).rounded())
            data.append(contentsOf: scaled.littleEndianBytes)
        }

        return data
    }

    static func deserializeAudioBuffer(from data: Data) throws -> [Float] {
        let stride = MemoryLayout<Float>.stride
        guard data.count.isMultiple(of: stride) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        return data.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            return Array(floatBuffer)
        }
    }

    static func deserializeArchivedAudioBuffer(from data: Data) throws -> [Float] {
        if data.starts(with: Data("RIFF".utf8)) {
            return try deserializeWAVAudioBuffer(from: data)
        }

        return try deserializeAudioBuffer(from: data)
    }

    /// Clears the in-memory audio buffer.
    func resetBuffer() {
        bufferLock.lock()
        audioBuffer = []
        bufferLock.unlock()
    }

    /// Snapshot the buffer under the lock from a sync context.
    /// Extracted so async callers don't touch NSLock directly (Swift 6 enforcement).
    private func snapshotBuffer() -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return audioBuffer
    }

    /// Starts capturing audio from the targeted input device (or system default).
    /// Audio is converted to 16 kHz mono Float32 and appended to `audioBuffer`.
    func startRecording() throws {
        resetBuffer()

        // BEFORE anything touches the input node. A wake or a route change since
        // the last recording means this engine's input path may be dead, and a
        // dead path accepts a tap, starts without error, and delivers nothing.
        //
        // The route check runs first because it catches what the notifications
        // cannot: a device changing shape while the engine sat idle posts no
        // notification at all.
        invalidateIfRouteChanged()
        rebuildEngineIfInvalidated()

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        applyTargetDeviceIfNeeded()

        let inputNode = engine.inputNode
        // `inputFormat(forBus:)` reflects the bus's *actual* HW input format.
        // `outputFormat(forBus:)` is the downstream format and is the one that
        // can go stale. Always trust inputFormat for input nodes.
        let hwFormat = inputNode.inputFormat(forBus: 0)
        lastInputFormatDescription = "\(Int(hwFormat.sampleRate))Hz/\(hwFormat.channelCount)ch"
        resetCaptureCounters()
        lastCaptureSampleCount = 0
        lastCaptureMaxAmplitude = 0

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputAvailable
        }

        // Keep the tap interval short so stop-time tail flushes stay cheap.
        let bufferDuration = 0.02
        let bufferSize = max(1, AVAudioFrameCount(hwFormat.sampleRate * bufferDuration))
        resetTapDrainState(bufferDurationSeconds: Double(bufferSize) / hwFormat.sampleRate)

        cachedConverter = nil
        cachedConverterSourceFormat = nil

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] pcmBuffer, _ in
            guard let self = self else { return }
            self.beginTapCallback()
            defer { self.endTapCallback() }

            // For devices with >2 channels (e.g. aggregate devices), AVAudioConverter
            // can't downmix to mono. Manually downmix to mono first, then convert.
            if pcmBuffer.format.channelCount > 2 {
                self.convertWithManualDownmix(buffer: pcmBuffer)
            } else {
                guard let converter = self.converter(for: pcmBuffer.format) else { return }
                self.convert(buffer: pcmBuffer, using: converter)
            }
        }

        try engine.start()
        // This engine is now bound to this route. Covers the case where no
        // prewarm ever ran.
        noteEngineBoundToRoute()
        onRecordingStarted?()
    }

    private var cachedConverter: AVAudioConverter?
    private var cachedConverterSourceFormat: AVAudioFormat?

    private func rebuildEngine() {
        engine.stop()
        engine = AVAudioEngine()
        engineGeneration += 1
        configuredTargetDeviceID = nil
        // The new engine is bound to whatever route exists NOW, and that is the
        // baseline the next recording must compare against. Clearing it here
        // instead was Codex round 2's P1.
        noteEngineBoundToRoute()
        // The observer watches a specific engine object, so it has to follow.
        observeConfigurationChange()
    }

    private func applyTargetDeviceIfNeeded() {
        if targetDeviceID == nil, configuredTargetDeviceID != nil {
            rebuildEngine()
        }

        guard configuredTargetDeviceID != targetDeviceID,
              let deviceID = targetDeviceID else {
            return
        }

        // Rebuild the engine when switching devices so inputNode picks up the new format
        rebuildEngine()

        let audioUnit = engine.inputNode.audioUnit!
        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("AudioRecorder: failed to set device \(deviceID) on audio unit, status=\(status)")
            return
        }

        configuredTargetDeviceID = deviceID
        print("AudioRecorder: targeting device \(deviceID) directly on audio unit")
    }

    private func converter(for sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        if let cachedConverter, let cachedConverterSourceFormat,
           cachedConverterSourceFormat.sampleRate == sourceFormat.sampleRate,
           cachedConverterSourceFormat.channelCount == sourceFormat.channelCount {
            return cachedConverter
        }

        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        cachedConverter = converter
        cachedConverterSourceFormat = sourceFormat
        if converter == nil {
            print("AudioRecorder: failed to create converter from \(sourceFormat) to \(targetFormat)")
        }
        return converter
    }

    /// Stops capturing audio and returns the recorded buffer.
    /// Waits only for the remainder of the active tap interval plus any
    /// in-flight conversion work so stop latency tracks the tap size.
    func stopRecording() async -> [Float] {
        let flushDelay = stopFlushDelayNanoseconds()
        if flushDelay > 0 {
            try? await Task.sleep(nanoseconds: flushDelay)
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        await waitForTapCallbacksToDrain()
        onRecordingStopped?()

        let result = snapshotBuffer()
        // The amplitude scan used to be `result.map { abs($0) }.max()`, which
        // ALLOCATES a second array the size of the recording and walks it, on the
        // release-to-text path, to print one number. A 60-second brain-dump is
        // 960,000 samples, so this was a megabyte of allocation and a full pass
        // between him letting go of the key and seeing his text.
        //
        // Same number, no allocation, single pass.
        var maxAmplitude: Float = 0
        for sample in result {
            let magnitude = abs(sample)
            if magnitude > maxAmplitude { maxAmplitude = magnitude }
        }

        // These two feed `captureReport(holdDuration:)`. They used to go to
        // `print`, which for an app launched from Finder is /dev/null, so on
        // 2026-08-09 the numbers that would have identified the fault in seconds
        // were written nowhere at all.
        lastCaptureSampleCount = result.count
        lastCaptureMaxAmplitude = maxAmplitude

        return result
    }

    // MARK: - Private

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetFormat.sampleRate / buffer.format.sampleRate)
        ) + 1 // +1 to avoid rounding down to zero

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return
        }

        var error: NSError?
        var allConsumed = false

        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            print("AudioRecorder: conversion error – \(error.localizedDescription)")
            return
        }

        guard let channelData = convertedBuffer.floatChannelData, convertedBuffer.frameLength > 0 else {
            return
        }

        let frames = Array(UnsafeBufferPointer(start: channelData[0], count: Int(convertedBuffer.frameLength)))

        appendConvertedFrames(frames)
    }

    /// Manual mono downmix for devices with >2 channels (aggregate devices).
    /// AVAudioConverter can't handle non-standard channel counts, so we average
    /// all channels to mono first, then use a mono→mono converter for sample rate.
    private func convertWithManualDownmix(buffer: AVAudioPCMBuffer) {
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return }

        // Average all channels to produce mono samples
        var monoSamples = [Float](repeating: 0, count: frameLength)

        if let channelData = buffer.floatChannelData {
            // Non-interleaved: each channel is a separate pointer
            for frame in 0..<frameLength {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += channelData[ch][frame]
                }
                monoSamples[frame] = sum / Float(channelCount)
            }
        } else {
            return
        }

        // Create a mono buffer at the source sample rate
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false)!
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frameLength)) else { return }
        monoBuffer.frameLength = AVAudioFrameCount(frameLength)
        if let dest = monoBuffer.floatChannelData?[0] {
            monoSamples.withUnsafeBufferPointer { src in
                dest.update(from: src.baseAddress!, count: frameLength)
            }
        }

        // Now convert mono→mono with sample rate change (source rate → 16kHz)
        guard let converter = self.converter(for: monoFormat) else { return }
        self.convert(buffer: monoBuffer, using: converter)
    }

    #if DEBUG
    func test_convert(samples: [Float]) {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat),
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?.pointee {
            samples.withUnsafeBufferPointer { source in
                if let baseAddress = source.baseAddress {
                    channelData.update(from: baseAddress, count: samples.count)
                }
            }
        }

        convert(buffer: buffer, using: converter)
    }
    #endif

    private func appendConvertedFrames(_ frames: [Float]) {
        bufferLock.lock()
        audioBuffer.append(contentsOf: frames)
        bufferLock.unlock()

        recordConvertedChunkArrival()
        onConvertedAudioChunk?(frames)
    }

    private func resetTapDrainState(bufferDurationSeconds: TimeInterval) {
        tapStateLock.lock()
        defer { tapStateLock.unlock() }
        tapBufferDurationNanoseconds = UInt64(bufferDurationSeconds * 1_000_000_000)
        lastConvertedChunkAtNanoseconds = nil
        inFlightTapCallbacks = 0
        stopWaitContinuation = nil
    }

    /// Zeroes the capture counters so one recording can never report the
    /// previous recording's numbers. A stale count here would say the
    /// microphone was fine on the run where it was not.
    func resetCaptureCounters() {
        tapStateLock.lock()
        tapCallbackCount = 0
        convertedChunkCount = 0
        tapStateLock.unlock()
    }

    /// What the microphone delivered for the recording that just ended.
    /// `holdDuration` comes from the caller because only it knows when the key
    /// went down.
    func captureReport(holdDuration: TimeInterval?) -> CaptureReport {
        tapStateLock.lock()
        let callbacks = tapCallbackCount
        let chunks = convertedChunkCount
        tapStateLock.unlock()

        return CaptureReport(
            inputFormatDescription: lastInputFormatDescription,
            holdDuration: holdDuration,
            tapCallbacks: callbacks,
            convertedChunks: chunks,
            sampleCount: lastCaptureSampleCount,
            maxAmplitude: lastCaptureMaxAmplitude
        )
    }

    private func beginTapCallback() {
        tapStateLock.lock()
        inFlightTapCallbacks += 1
        tapCallbackCount += 1
        tapStateLock.unlock()
    }

    private func endTapCallback() {
        var continuation: CheckedContinuation<Void, Never>?
        tapStateLock.lock()
        inFlightTapCallbacks = max(0, inFlightTapCallbacks - 1)
        if inFlightTapCallbacks == 0 {
            continuation = stopWaitContinuation
            stopWaitContinuation = nil
        }
        tapStateLock.unlock()
        continuation?.resume()
    }

    private func recordConvertedChunkArrival() {
        tapStateLock.lock()
        lastConvertedChunkAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        convertedChunkCount += 1
        tapStateLock.unlock()
    }

    private func stopFlushDelayNanoseconds() -> UInt64 {
        tapStateLock.lock()
        let tapBufferDurationNanoseconds = self.tapBufferDurationNanoseconds
        let lastConvertedChunkAtNanoseconds = self.lastConvertedChunkAtNanoseconds
        tapStateLock.unlock()

        guard tapBufferDurationNanoseconds > 0 else {
            return 0
        }

        guard let lastConvertedChunkAtNanoseconds else {
            return tapBufferDurationNanoseconds + stopFlushSlackNanoseconds
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= lastConvertedChunkAtNanoseconds
            ? now - lastConvertedChunkAtNanoseconds
            : 0
        let remaining = elapsed >= tapBufferDurationNanoseconds
            ? 0
            : tapBufferDurationNanoseconds - elapsed
        return remaining + stopFlushSlackNanoseconds
    }

    private func waitForTapCallbacksToDrain() async {
        let hasInFlightCallbacks = tapStateLock.withLock { inFlightTapCallbacks > 0 }
        guard hasInFlightCallbacks else {
            return
        }

        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = tapStateLock.withLock {
                if inFlightTapCallbacks == 0 {
                    return true
                }

                stopWaitContinuation = continuation
                return false
            }

            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }
}

// MARK: - Errors

private extension AudioRecorder {
    static func deserializeWAVAudioBuffer(from data: Data) throws -> [Float] {
        guard data.count >= 44,
              data.starts(with: Data("RIFF".utf8)),
              data.dropFirst(8).starts(with: Data("WAVE".utf8)) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        var offset = 12
        var audioFormat: UInt16?
        var bitsPerSample: UInt16?
        var channelCount: UInt16?
        var sampleData = Data()

        while offset + 8 <= data.count {
            let chunkIDData = data[offset..<(offset + 4)]
            let chunkSize = UInt32(littleEndian: data[(offset + 4)..<(offset + 8)].withUnsafeBytes { $0.load(as: UInt32.self) })
            offset += 8

            guard offset + Int(chunkSize) <= data.count else {
                throw AudioRecorderPersistenceError.invalidSerializedAudioData
            }

            let chunkData = data[offset..<(offset + Int(chunkSize))]
            let chunkID = String(decoding: chunkIDData, as: UTF8.self)

            if chunkID == "fmt " {
                guard chunkData.count >= 16 else {
                    throw AudioRecorderPersistenceError.invalidSerializedAudioData
                }

                audioFormat = UInt16(littleEndian: chunkData[chunkData.startIndex..<(chunkData.startIndex + 2)].withUnsafeBytes { $0.load(as: UInt16.self) })
                channelCount = UInt16(littleEndian: chunkData[(chunkData.startIndex + 2)..<(chunkData.startIndex + 4)].withUnsafeBytes { $0.load(as: UInt16.self) })
                bitsPerSample = UInt16(littleEndian: chunkData[(chunkData.startIndex + 14)..<(chunkData.startIndex + 16)].withUnsafeBytes { $0.load(as: UInt16.self) })
            } else if chunkID == "data" {
                sampleData = Data(chunkData)
            }

            offset += Int(chunkSize)
            if chunkSize.isMultiple(of: 2) == false {
                offset += 1
            }
        }

        guard audioFormat == 1,
              channelCount == 1,
              bitsPerSample == 16,
              sampleData.count.isMultiple(of: 2) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        return sampleData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            return int16Buffer.map { Float($0) / Float(Int16.max) }
        }
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

enum AudioRecorderError: Error, LocalizedError {
    case noInputAvailable
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .noInputAvailable:
            return "No audio input device available."
        case .converterCreationFailed:
            return "Failed to create audio format converter."
        }
    }
}

enum AudioRecorderPersistenceError: Error {
    case invalidSerializedAudioData
}
