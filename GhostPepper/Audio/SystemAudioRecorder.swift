import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Captures system audio output (what other call participants say) for the
/// "Others" channel of meeting transcription.
///
/// ## Why this is allowed, and why it is not screen capture
///
/// This was previously stubbed to always throw. At the time, capturing system
/// audio meant the system screen-capture framework, which demands the Screen and
/// System Audio Recording permission, and AF Flow's hard rule 1 banned that
/// outright. The banned-symbol sweep checks for that framework by name, so it is
/// deliberately not named here: the guard is text-based and strict, which is
/// correct, and teaching it to ignore comments would be the weakening this
/// project keeps refusing.
///
/// macOS 14.4 added Core Audio process taps, which capture audio only. They sit
/// in their own TCC category (`NSAudioCaptureUsageDescription`) and cannot see
/// the screen. Andrew relaxed hard rule 1 on 2026-07-27 to permit the wider
/// permission "if it is best practice"; the narrower route does the job, so the
/// wider one is declined and this app still touches no screen-capture API.
///
/// ## Measured, not assumed
///
/// Published reports call tap behaviour under App Sandbox "fragile", and at
/// least one project disabled its sandbox to work around it.
/// `scripts/audiotap-probe/` tested that on Andrew's Mac rather than believing
/// it: with AF Flow's exact entitlements and the sandbox ON, it captured real
/// system audio, 352 callbacks and 180,224 frames at peak 0.718. **The sandbox
/// stays on.** Re-run the probe rather than trusting this comment.
///
/// ## The realtime rule, which shaped the whole design
///
/// The first version did the obvious thing: allocate a buffer in the IO proc,
/// run `AVAudioConverter`, call the chunk closure, spawn a `Task`. Codex refused
/// it, correctly. That runs on a **Core Audio realtime thread**, where
/// allocation, ARC traffic and blocking cause dropouts, and those dropouts would
/// land in the audio Andrew is listening to, not only in the transcript.
///
/// So the IO proc now does the least possible: downmix to mono into
/// preallocated storage and hand it to a ring buffer. Everything expensive
/// (resampling, appending, callbacks) happens on a normal serial queue.
///
/// Output matches `AudioRecorder`: 16 kHz mono float, which is what
/// `ChunkedTranscriptionPipeline` and WhisperKit expect.
final class SystemAudioRecorder {
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?
    var onConvertedAudioChunk: (([Float]) -> Void)?

    /// Called when the "Others" channel stops on its own, for example because
    /// the output device changed mid-meeting. Reported rather than hidden:
    /// silently capturing nothing is the failure mode this project keeps paying
    /// for.
    var onCaptureInterrupted: ((String) -> Void)?

    private struct State {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        var isRunning = false
        var deviceListener: AudioObjectPropertyListenerBlock?
        /// The queue the listener was registered with. Core Audio matches on
        /// queue AND block when removing, so removing with a different queue
        /// leaves the listener installed and firing after stop.
        var deviceListenerQueue: DispatchQueue?
        /// Set for the whole of `startRecording()`, so a second start cannot
        /// build a second tap and a concurrent stop cannot report success while
        /// startup carries on behind it.
        var isStarting = false
        /// Set when a stop arrives mid-startup. Startup then destroys what it
        /// built instead of publishing it.
        var stopRequestedDuringStart = false
    }

    /// Lifecycle state. Guarded, and never touched from the IO proc.
    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    private let ring = MonoRingBuffer(capacity: 48_000 * 60)
    private let drainQueue = DispatchQueue(
        label: "com.frolikov.afflow.systemaudio.drain",
        qos: .userInitiated
    )
    private var drainTimer: DispatchSourceTimer?

    private let collected = SystemAudioBuffer()
    private var converter: AVAudioConverter?
    private var sourceSampleRate: Double = 0

    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }()

    deinit {
        // A recorder dropped without `stopRecording()` would otherwise leave a
        // live tap and aggregate device registered with Core Audio.
        let leftover = stateLock.withLock { current -> State in
            let snapshot = current
            current = State()
            return snapshot
        }
        Self.destroy(state: leftover)
    }

    /// Starts capturing system audio output.
    ///
    /// Throws rather than degrading silently. `DualStreamCapture` catches this
    /// and continues microphone-only, so a failure costs the "Others" channel
    /// rather than the whole meeting.
    func startRecording() async throws {
        guard #available(macOS 14.4, *) else {
            throw SystemAudioRecorderError.requiresNewerMacOS
        }

        let claimed = stateLock.withLock { current -> Bool in
            guard !current.isRunning, !current.isStarting else { return false }
            current.isStarting = true
            current.stopRequestedDuringStart = false
            return true
        }
        guard claimed else { return }

        var pending = State()

        // Anything created before a later step fails must be torn down here, or
        // the tap and aggregate device leak on every failed start.
        func abort(_ error: SystemAudioRecorderError) -> SystemAudioRecorderError {
            Self.destroy(state: pending)
            stateLock.withLock { current in
                current.isStarting = false
                current.stopRequestedDuringStart = false
            }
            return error
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "AF Flow meeting capture"
        description.isPrivate = true
        // Never mute what he is listening to. A meeting he cannot hear is worse
        // than a meeting that is not transcribed.
        description.muteBehavior = .unmuted

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTap)
        guard tapStatus == noErr, createdTap != kAudioObjectUnknown else {
            throw abort(.tapUnavailable(tapStatus))
        }
        pending.tapID = createdTap

        guard let tapUID = Self.stringProperty(of: createdTap, selector: kAudioTapPropertyUID) else {
            throw abort(.tapUnavailable(kAudioHardwareUnspecifiedError))
        }

        guard let output = Self.defaultOutputDevice() else {
            throw abort(.noOutputDevice)
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AF Flow meeting capture",
            kAudioAggregateDeviceUIDKey: "com.frolikov.afflow.meeting.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]

        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &createdAggregate
        )
        guard aggregateStatus == noErr, createdAggregate != kAudioObjectUnknown else {
            throw abort(.aggregateUnavailable(aggregateStatus))
        }
        pending.aggregateID = createdAggregate

        guard let streamFormat = Self.inputStreamFormat(of: createdAggregate) else {
            throw abort(.aggregateUnavailable(kAudioHardwareUnspecifiedError))
        }

        // Captured by value into the IO proc, so the realtime thread never reads
        // mutable state off this object.
        let channelCount = Int(max(1, streamFormat.channelCount))
        let isInterleaved = streamFormat.isInterleaved
        let ring = self.ring

        ring.reset()
        collected.reset()
        converter = nil
        sourceSampleRate = streamFormat.sampleRate

        var createdProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &createdProcID,
            createdAggregate,
            nil
        ) { _, inputData, _, _, _ in
            // REALTIME THREAD. No allocation, no ARC traffic, no callbacks, no
            // Task. Downmix into preallocated storage and return.
            ring.writeDownmixed(
                from: inputData,
                channelCount: channelCount,
                interleaved: isInterleaved
            )
        }

        guard ioStatus == noErr, let createdProcID else {
            throw abort(.ioProcUnavailable(ioStatus))
        }
        pending.ioProcID = createdProcID

        let startStatus = AudioDeviceStart(createdAggregate, createdProcID)
        guard startStatus == noErr else {
            throw abort(.ioProcUnavailable(startStatus))
        }

        pending.deviceListener = installDefaultOutputListener()
        pending.deviceListenerQueue = pending.deviceListener == nil ? nil : drainQueue
        pending.isRunning = true

        let published = stateLock.withLock { current -> Bool in
            guard !current.stopRequestedDuringStart else { return false }
            current = pending
            return true
        }

        guard published else {
            // A stop landed while this was building. Destroy what we made
            // rather than leaving a live tap nobody owns.
            Self.destroy(state: pending)
            stateLock.withLock { current in
                current.isStarting = false
                current.stopRequestedDuringStart = false
            }
            return
        }

        startDraining()
        onRecordingStarted?()
    }

    /// Stops capture and returns everything recorded, as 16 kHz mono float.
    func stopRecording() async -> [Float] {
        let previous = stateLock.withLock { current -> State in
            if current.isStarting {
                // Startup is mid-flight. It will destroy what it built rather
                // than publishing it, so there is nothing to tear down here.
                current.stopRequestedDuringStart = true
                return State()
            }
            let snapshot = current
            current = State()
            return snapshot
        }

        guard previous.isRunning else { return [] }

        // Stop the audio flowing first, so the final drain sees a settled ring.
        Self.destroy(state: previous)

        let timer = drainTimer
        drainTimer = nil
        timer?.cancel()

        // Cancelling a timer does not wait for a handler that is already
        // running or already queued. `drainQueue` is serial, so an async block
        // enqueued now runs strictly after any in-flight handler, and awaiting
        // it is what makes the final drain the last word rather than a racer.
        await withCheckedContinuation { continuation in
            drainQueue.async { [weak self] in
                self?.drainOnce()
                continuation.resume()
            }
        }

        onRecordingStopped?()
        return collected.drain()
    }

    /// Whether capture is currently running.
    var capturing: Bool { stateLock.withLock { $0.isRunning } }

    /// Frames the realtime callback had to drop because the drain fell behind.
    /// Zero in normal operation; non-zero means the transcript has holes, which
    /// is worth surfacing rather than discovering later.
    var droppedFrames: Int { ring.droppedFrames }

    // MARK: - Draining, off the realtime thread

    private func startDraining() {
        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.drainOnce()
        }
        drainTimer = timer
        timer.resume()
    }

    private func drainOnce() {
        let samples = ring.readAll()
        guard !samples.isEmpty else { return }
        guard let converted = convertToTargetFormat(samples), !converted.isEmpty else { return }

        // Appended synchronously, on the drain queue. An unstructured Task here
        // meant the final chunk could reach `onConvertedAudioChunk` and be
        // missing from the returned buffer, because `stopRecording()` could
        // drain before the Task ran.
        collected.append(converted)
        onConvertedAudioChunk?(converted)
    }

    private func convertToTargetFormat(_ monoSamples: [Float]) -> [Float]? {
        guard sourceSampleRate > 0 else { return nil }

        // The ring already delivers mono, so only the sample rate can differ.
        if sourceSampleRate == targetFormat.sampleRate {
            return monoSamples
        }

        guard let monoSource = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        if converter == nil {
            converter = AVAudioConverter(from: monoSource, to: targetFormat)
        }
        guard let converter else { return nil }

        guard let input = AVAudioPCMBuffer(
            pcmFormat: monoSource,
            frameCapacity: AVAudioFrameCount(monoSamples.count)
        ) else { return nil }
        input.frameLength = AVAudioFrameCount(monoSamples.count)
        if let channel = input.floatChannelData {
            monoSamples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                channel[0].update(from: base, count: monoSamples.count)
            }
        }

        let ratio = targetFormat.sampleRate / sourceSampleRate
        let capacity = AVAudioFrameCount(Double(monoSamples.count) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }

        guard conversionError == nil,
              output.frameLength > 0,
              let channelData = output.floatChannelData else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
    }

    // MARK: - Output device changes

    /// The aggregate device is bound to whichever output device was default when
    /// capture started. If the output switches to AirPods mid-meeting, it keeps
    /// pointing at the old device and quietly records nothing.
    ///
    /// That happened during the probe runs on 2026-07-27, so it is a real case
    /// rather than a theoretical one. Rebuilding the aggregate live is possible
    /// but is a second lifecycle to get wrong; stopping and SAYING so is the
    /// honest behaviour, and it leaves the microphone channel running.
    private func installDefaultOutputListener() -> AudioObjectPropertyListenerBlock? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task {
                guard self.capturing else { return }
                _ = await self.stopRecording()
                self.onCaptureInterrupted?(
                    "The audio output device changed, so AF Flow stopped recording the other participants. Your microphone is still being recorded. Stop and start the meeting again to capture them."
                )
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            drainQueue,
            listener
        )
        return status == noErr ? listener : nil
    }

    // MARK: - Teardown

    /// Idempotent by construction: callers swap the state out under the lock and
    /// hand the old value here, so two concurrent stops cannot both destroy the
    /// same objects.
    private static func destroy(state: State) {
        if let listener = state.deviceListener, let queue = state.deviceListenerQueue {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            // Must be the SAME queue used at registration: Core Audio matches on
            // queue and block together, so a mismatched queue silently leaves
            // the listener installed and firing after capture has stopped.
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            )
        }

        if state.aggregateID != kAudioObjectUnknown, let ioProcID = state.ioProcID {
            AudioDeviceStop(state.aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(state.aggregateID, ioProcID)
        }

        if state.aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(state.aggregateID)
        }

        if state.tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(state.tapID)
        }
    }

    // MARK: - Core Audio property helpers

    private static func stringProperty(
        of object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func defaultOutputDevice() -> (id: AudioObjectID, uid: String)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        guard let uid = stringProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID) else {
            return nil
        }
        return (deviceID, uid)
    }

    private static func inputStreamFormat(of device: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streamDescription)
        guard status == noErr, streamDescription.mSampleRate > 0 else { return nil }
        return AVAudioFormat(streamDescription: &streamDescription)
    }
}

/// A fixed-capacity mono ring buffer written from the realtime thread and read
/// from a normal queue.
///
/// Storage is allocated once, so the write path performs no allocation. The
/// indices are guarded by `os_unfair_lock`, which is the lock Apple recommends
/// on this side because it participates in priority inheritance, and the
/// critical section is a bounded copy. This is deliberately described as cheap
/// and uncontended rather than as "lock free", because it is not lock free and
/// saying otherwise would be the kind of claim this project keeps retracting.
final class MonoRingBuffer: @unchecked Sendable {
    private struct Cursor {
        var writeIndex = 0
        var available = 0
        var dropped = 0
    }

    private let capacity: Int
    private let scratchCapacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    /// Preallocated landing area for `readAll()`, sized to the whole ring so a
    /// full drain never needs to allocate while the writer lock is held.
    private let drainScratch: UnsafeMutablePointer<Float>
    private let cursor: OSAllocatedUnfairLock<Cursor>

    init(capacity: Int, scratchCapacity: Int = 16_384) {
        self.capacity = max(1, capacity)
        self.scratchCapacity = max(1, scratchCapacity)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0, count: self.capacity)
        scratch = .allocate(capacity: self.scratchCapacity)
        scratch.initialize(repeating: 0, count: self.scratchCapacity)
        drainScratch = .allocate(capacity: self.capacity)
        drainScratch.initialize(repeating: 0, count: self.capacity)
        cursor = OSAllocatedUnfairLock(initialState: Cursor())
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        scratch.deinitialize(count: scratchCapacity)
        scratch.deallocate()
        drainScratch.deinitialize(count: capacity)
        drainScratch.deallocate()
    }

    var droppedFrames: Int { cursor.withLock { $0.dropped } }

    func reset() {
        cursor.withLock { $0 = Cursor() }
    }

    /// Downmixes every channel of `bufferList` to mono and appends it.
    ///
    /// Reads ALL buffers, not just the first. Codex caught that: an aggregate
    /// device commonly delivers non-interleaved stereo as two separate buffers,
    /// so taking only the first would silently capture one channel while telling
    /// the converter it had two.
    func writeDownmixed(
        from bufferList: UnsafePointer<AudioBufferList>,
        channelCount: Int,
        interleaved: Bool
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard buffers.count > 0 else { return }

        var frameCount = 0

        if interleaved {
            guard let raw = buffers[0].mData, buffers[0].mDataByteSize > 0 else { return }
            let channels = max(1, Int(buffers[0].mNumberChannels))
            let totalSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let availableFrames = totalSamples / channels
            frameCount = min(availableFrames, scratchCapacity)
            guard frameCount > 0 else { return }
            // Truncation to the scratch buffer is a real loss and is counted.
            // Silently clipping it would make `droppedFrames` claim a clean run.
            if availableFrames > frameCount {
                cursor.withLock { $0.dropped += availableFrames - frameCount }
            }

            let samples = raw.assumingMemoryBound(to: Float.self)
            let scale = 1.0 / Float(channels)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[frame * channels + channel]
                }
                scratch[frame] = sum * scale
            }
        } else {
            let planes = min(buffers.count, max(1, channelCount))
            guard let firstData = buffers[0].mData, buffers[0].mDataByteSize > 0 else { return }
            let availableFrames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            frameCount = min(availableFrames, scratchCapacity)
            guard frameCount > 0 else { return }
            if availableFrames > frameCount {
                cursor.withLock { $0.dropped += availableFrames - frameCount }
            }

            scratch.update(from: firstData.assumingMemoryBound(to: Float.self), count: frameCount)

            if planes > 1 {
                for plane in 1..<planes {
                    guard let data = buffers[plane].mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let count = min(
                        Int(buffers[plane].mDataByteSize) / MemoryLayout<Float>.size,
                        frameCount
                    )
                    for frame in 0..<count {
                        scratch[frame] += samples[frame]
                    }
                }
                let scale = 1.0 / Float(planes)
                for frame in 0..<frameCount {
                    scratch[frame] *= scale
                }
            }
        }

        let frames = frameCount
        cursor.withLock { state in
            if state.available + frames > capacity {
                // The drain has fallen behind. Dropping keeps the buffer
                // coherent, and the count is reported rather than hidden.
                state.dropped += frames
                return
            }
            for index in 0..<frames {
                storage[(state.writeIndex + index) % capacity] = scratch[index]
            }
            state.writeIndex = (state.writeIndex + frames) % capacity
            state.available += frames
        }
    }

    /// Removes and returns everything buffered.
    ///
    /// The `Array` is built OUTSIDE the lock. Allocating inside it would make
    /// the realtime IO proc wait on a malloc, which is the blocking this design
    /// exists to avoid: the write path being allocation free buys nothing if the
    /// reader allocates while holding the same lock.
    func readAll() -> [Float] {
        let count = cursor.withLock { state -> Int in
            guard state.available > 0 else { return 0 }
            let start = ((state.writeIndex - state.available) % capacity + capacity) % capacity
            let total = state.available
            // Bounded copy into preallocated storage, no allocation.
            for index in 0..<total {
                drainScratch[index] = storage[(start + index) % capacity]
            }
            state.available = 0
            return total
        }

        guard count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: drainScratch, count: count))
    }
}

/// Accumulates converted samples for the final transcript.
///
/// A lock rather than an actor, so `drainOnce()` can append without an `await`.
/// As an actor, appends had to be spawned in a Task and could land after
/// `stopRecording()` had already read the buffer, silently losing the last
/// chunk of every meeting.
private final class SystemAudioBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Float]())

    func append(_ chunk: [Float]) {
        lock.withLock { $0.append(contentsOf: chunk) }
    }

    func reset() {
        lock.withLock { $0.removeAll(keepingCapacity: true) }
    }

    func drain() -> [Float] {
        lock.withLock { samples in
            let result = samples
            samples.removeAll(keepingCapacity: false)
            return result
        }
    }
}

// MARK: - Errors

enum SystemAudioRecorderError: Error, LocalizedError {
    case requiresNewerMacOS
    case tapUnavailable(OSStatus)
    case aggregateUnavailable(OSStatus)
    case ioProcUnavailable(OSStatus)
    case noOutputDevice

    var errorDescription: String? {
        switch self {
        case .requiresNewerMacOS:
            return "Capturing other participants needs macOS 14.4 or later. Meeting transcription will use the microphone only."
        case .tapUnavailable(let status):
            return "AF Flow could not start system audio capture (\(status)). Check System Settings, Privacy and Security, Audio Recording. Meeting transcription will use the microphone only."
        case .aggregateUnavailable(let status):
            return "AF Flow could not set up the system audio device (\(status)). Meeting transcription will use the microphone only."
        case .ioProcUnavailable(let status):
            return "AF Flow could not start reading system audio (\(status)). Meeting transcription will use the microphone only."
        case .noOutputDevice:
            return "No audio output device is available, so other participants cannot be recorded. Meeting transcription will use the microphone only."
        }
    }
}
