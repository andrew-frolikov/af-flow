import AVFoundation
import AppKit
import AudioToolbox
import XCTest
@testable import GhostPepper

final class AudioRecorderTests: XCTestCase {
    func testBufferStartsEmpty() {
        let recorder = AudioRecorder()
        XCTAssertTrue(recorder.audioBuffer.isEmpty)
    }

    func testBufferClearsOnReset() {
        let recorder = AudioRecorder()
        recorder.audioBuffer = [1.0, 2.0, 3.0]
        recorder.resetBuffer()
        XCTAssertTrue(recorder.audioBuffer.isEmpty)
    }

    func testAudioBufferSerializationRoundTripsSamples() throws {
        let samples: [Float] = [0.25, -0.5, 0.75, 0.0]

        let data = try AudioRecorder.serializeAudioBuffer(samples)
        let decoded = try AudioRecorder.deserializeAudioBuffer(from: data)

        XCTAssertEqual(decoded, samples)
    }

    func testPlayableArchiveSerializationCreatesWAVDataThatRoundTripsSamples() throws {
        let samples: [Float] = [0.25, -0.5, 0.75, 0.0]

        let data = try AudioRecorder.serializePlayableArchiveAudioBuffer(samples)
        let riffHeader = String(decoding: data.prefix(4), as: UTF8.self)
        let waveHeader = String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self)
        let decoded = try AudioRecorder.deserializeArchivedAudioBuffer(from: data)

        XCTAssertEqual(riffHeader, "RIFF")
        XCTAssertEqual(waveHeader, "WAVE")
        XCTAssertEqual(decoded.count, samples.count)
        for (decodedSample, expectedSample) in zip(decoded, samples) {
            XCTAssertEqual(decodedSample, expectedSample, accuracy: 0.0001)
        }
    }

    func testConvertedSamplesAreDeliveredToChunkCallback() throws {
        let recorder = AudioRecorder()
        var deliveredChunks: [[Float]] = []
        recorder.onConvertedAudioChunk = { chunk in
            deliveredChunks.append(chunk)
        }

        recorder.test_convert(samples: [0.1, 0.2])
        recorder.test_convert(samples: [0.3, 0.4])

        XCTAssertEqual(deliveredChunks, [[0.1, 0.2], [0.3, 0.4]])
    }

    func testChunkDeliveryStillAccumulatesFinalAudioBuffer() throws {
        let recorder = AudioRecorder()
        var deliveredSamples: [Float] = []
        recorder.onConvertedAudioChunk = { chunk in
            deliveredSamples.append(contentsOf: chunk)
        }

        recorder.test_convert(samples: [0.1, 0.2])
        recorder.test_convert(samples: [0.3, 0.4])

        XCTAssertEqual(deliveredSamples, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(recorder.audioBuffer, [0.1, 0.2, 0.3, 0.4])
    }
}

/// The "Others" channel of meeting transcription downmixes system audio to mono
/// on a Core Audio realtime thread.
///
/// Codex found, on review, that the first implementation read only the FIRST
/// buffer of the `AudioBufferList`. An aggregate device commonly delivers
/// non-interleaved stereo as two separate buffers, so that version would have
/// captured the left channel while telling the converter it had two, and nobody
/// would have noticed until a meeting transcript was missing half the room.
///
/// These run with no audio hardware and no permission, because they drive the
/// ring buffer directly with hand-built buffer lists.
final class MonoRingBufferTests: XCTestCase {

    /// Builds a non-interleaved (planar) buffer list: one buffer per channel.
    private func planarBufferList(
        channels: [[Float]],
        run: (UnsafePointer<AudioBufferList>) -> Void
    ) {
        var storage = channels.map { $0 }
        let list = AudioBufferList.allocate(maximumBuffers: channels.count)
        defer { free(list.unsafeMutablePointer) }

        var pointers: [UnsafeMutablePointer<Float>] = []
        for index in 0..<channels.count {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: storage[index].count)
            pointer.update(from: storage[index], count: storage[index].count)
            pointers.append(pointer)
            list[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(storage[index].count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer)
            )
        }
        defer { pointers.forEach { $0.deallocate() } }

        run(UnsafePointer(list.unsafeMutablePointer))
    }

    /// Builds an interleaved buffer list: one buffer, samples woven together.
    private func interleavedBufferList(
        frames: [[Float]],
        run: (UnsafePointer<AudioBufferList>) -> Void
    ) {
        let channelCount = frames.first?.count ?? 0
        var flat: [Float] = []
        for frame in frames { flat.append(contentsOf: frame) }

        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }

        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: flat.count)
        pointer.update(from: flat, count: flat.count)
        defer { pointer.deallocate() }

        list[0] = AudioBuffer(
            mNumberChannels: UInt32(channelCount),
            mDataByteSize: UInt32(flat.count * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(pointer)
        )

        run(UnsafePointer(list.unsafeMutablePointer))
    }

    /// The regression test for the bug Codex found. The right channel is the
    /// only one carrying signal; an implementation that reads only the first
    /// buffer returns silence and fails here.
    func testPlanarStereoReadsBothChannelsNotJustTheFirst() {
        let ring = MonoRingBuffer(capacity: 1024)

        planarBufferList(channels: [
            [0.0, 0.0, 0.0, 0.0],   // left: silent
            [1.0, 1.0, 1.0, 1.0],   // right: full scale
        ]) { list in
            ring.writeDownmixed(from: list, channelCount: 2, interleaved: false)
        }

        let samples = ring.readAll()
        XCTAssertEqual(samples.count, 4)
        for value in samples {
            XCTAssertEqual(
                value,
                0.5,
                accuracy: 0.0001,
                "Averaging a silent left channel with a full-scale right must give 0.5. Getting 0 means only the first buffer was read, which silently drops half the room."
            )
        }
    }

    func testInterleavedStereoIsAveragedAcrossChannels() {
        let ring = MonoRingBuffer(capacity: 1024)

        interleavedBufferList(frames: [
            [0.0, 1.0],
            [0.0, 1.0],
            [0.5, 0.5],
        ]) { list in
            ring.writeDownmixed(from: list, channelCount: 2, interleaved: true)
        }

        let samples = ring.readAll()
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[2], 0.5, accuracy: 0.0001)
    }

    func testMonoPassesThroughUnchanged() {
        let ring = MonoRingBuffer(capacity: 1024)

        planarBufferList(channels: [[0.25, -0.25, 0.75]]) { list in
            ring.writeDownmixed(from: list, channelCount: 1, interleaved: false)
        }

        let samples = ring.readAll()
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(samples[1], -0.25, accuracy: 0.0001)
        XCTAssertEqual(samples[2], 0.75, accuracy: 0.0001)
    }

    /// Overflow must be counted rather than silently corrupting the buffer. A
    /// transcript with holes is recoverable; a transcript that looks complete
    /// and is not is the failure this project keeps paying for.
    func testOverflowIsDroppedAndCounted() {
        let ring = MonoRingBuffer(capacity: 4)

        planarBufferList(channels: [[0.1, 0.2, 0.3, 0.4]]) { list in
            ring.writeDownmixed(from: list, channelCount: 1, interleaved: false)
        }
        XCTAssertEqual(ring.droppedFrames, 0)

        // The ring is now full. The next write cannot fit.
        planarBufferList(channels: [[0.5, 0.6]]) { list in
            ring.writeDownmixed(from: list, channelCount: 1, interleaved: false)
        }

        XCTAssertEqual(ring.droppedFrames, 2, "Dropped frames must be reported, not hidden.")

        // Assert the SAMPLES, not the count. Codex caught that the earlier
        // version checked only `count == 4`, which a buffer that overwrote the
        // audio while keeping the count would have passed. "Survive intact"
        // means these exact values.
        let survivors = ring.readAll()
        XCTAssertEqual(survivors.count, 4)
        XCTAssertEqual(survivors[0], 0.1, accuracy: 0.0001)
        XCTAssertEqual(survivors[1], 0.2, accuracy: 0.0001)
        XCTAssertEqual(survivors[2], 0.3, accuracy: 0.0001)
        XCTAssertEqual(survivors[3], 0.4, accuracy: 0.0001)
    }

    func testReadAllDrainsSoSamplesAreNeverDeliveredTwice() {
        let ring = MonoRingBuffer(capacity: 64)

        planarBufferList(channels: [[0.1, 0.2]]) { list in
            ring.writeDownmixed(from: list, channelCount: 1, interleaved: false)
        }

        XCTAssertEqual(ring.readAll().count, 2)
        XCTAssertTrue(ring.readAll().isEmpty, "A second read must not repeat audio already handed over.")
    }

    /// The earlier version of this used a write that overflowed and was therefore
    /// dropped before `reset()` was ever called, so the buffer was already empty
    /// and the assertion could not fail. It also never covered the part of
    /// `reset()` that re-points the two buffers after a swap.
    func testResetClearsBufferedAudioAndDropCount() {
        let ring = MonoRingBuffer(capacity: 4)

        // Fits, so it is genuinely buffered and reset has something to clear.
        planarBufferList(channels: [[0.1, 0.2]]) { list in
            ring.writeDownmixed(from: list, channelCount: 1, interleaved: false)
        }
        // And overflow it, so there is a drop count to clear too.
        planarBufferList(channels: [[0.3, 0.4, 0.5]]) { list in
            ring.writeDownmixed(from: list, channelCount: 1, interleaved: false)
        }
        XCTAssertGreaterThan(ring.droppedFrames, 0)

        ring.reset()

        XCTAssertEqual(ring.droppedFrames, 0)
        XCTAssertTrue(
            ring.readAll().isEmpty,
            "reset() left buffered audio behind, so the next meeting would begin with the previous one's tail."
        )
    }

    /// `reset()` re-points the front and spare buffers, so it must be correct
    /// AFTER a swap has already exchanged them, not only from the initial state.
    func testResetIsCorrectAfterASwapHasExchangedTheBuffers() {
        let ring = MonoRingBuffer(capacity: 8)

        planarBufferList(channels: [[1, 2, 3]]) { list in
            ring.writeDownmixed(from: list, channelCount: 1, interleaved: false)
        }
        XCTAssertEqual(ring.readAll(), [1, 2, 3])  // swaps front and spare

        ring.reset()

        planarBufferList(channels: [[7, 8]]) { list in
            ring.writeDownmixed(from: list, channelCount: 1, interleaved: false)
        }
        XCTAssertEqual(
            ring.readAll(),
            [7, 8],
            "After a reset that follows a swap, writes must land where reads look."
        )
    }

    /// Successive fill/drain cycles must keep sample order and must not leak
    /// audio from the previous cycle. With a double buffer this is where a
    /// mixed-up swap would show, since the second read comes from the buffer the
    /// first read handed back.
    func testSuccessiveDrainsReadBackInOrderWithNoBleedThrough() {
        let ring = MonoRingBuffer(capacity: 4)

        planarBufferList(channels: [[1, 2, 3]]) { list in
            ring.writeDownmixed(from: list, channelCount: 1, interleaved: false)
        }
        XCTAssertEqual(ring.readAll(), [1, 2, 3])

        planarBufferList(channels: [[4, 5, 6]]) { list in
            ring.writeDownmixed(from: list, channelCount: 1, interleaved: false)
        }
        XCTAssertEqual(ring.readAll(), [4, 5, 6], "Samples must read back in order across a wrap.")
    }
    /// Codex round 2 finding 6: frames beyond the scratch buffer were silently
    /// clipped and NOT counted, so `droppedFrames` could report a clean run
    /// while audio was being thrown away. The existing overflow test missed it
    /// because it only overflowed ring capacity, never scratch capacity.
    func testFramesBeyondScratchCapacityAreCountedNotSilentlyClipped() {
        let ring = MonoRingBuffer(capacity: 4096, scratchCapacity: 4)

        planarBufferList(channels: [[1, 2, 3, 4, 5, 6, 7]]) { list in
            ring.writeDownmixed(from: list, channelCount: 1, interleaved: false)
        }

        XCTAssertEqual(
            ring.readAll().count,
            4,
            "Only a scratch buffer's worth can be taken in one callback."
        )
        XCTAssertEqual(
            ring.droppedFrames,
            3,
            "The three frames that did not fit must be reported. Counting them as zero is a metric that says the run was clean while audio was lost."
        )
    }
}

/// THE 2026-08-09 OUTAGE.
///
/// `AudioRecorder` keeps one `AVAudioEngine` alive across every dictation and
/// rebuilds it only when Andrew changes the microphone in Settings. On
/// 2026-08-09 the Mac woke from sleep at 22:03:25, the AirPods connected and
/// became the system input, and the running engine's input path was invalidated
/// underneath it. Every dictation after that installed a fresh tap on a dead
/// path: `engine.start()` returned success, `Recording started.` was logged, and
/// the tap delivered no frames. Six in a row, over 103 seconds on the first.
///
/// The protection used to exist. Commit `9c4e2a4` (2026-04-17) deleted it for
/// startup latency, along with the comment that predicted exactly this:
/// "AVAudioEngine does not reliably recover when the default input device or its
/// sample rate changes between sessions (Bluetooth mics flipping between
/// HFP/A2DP profiles is the common trigger)."
///
/// These tests hold the line that the engine is rebuilt whenever anything could
/// have invalidated its input path, and that the observers which detect that
/// survive the rebuild.
final class AudioRecorderEngineInvalidationTests: XCTestCase {
    func testAFreshRecorderHasNothingToRebuild() {
        let recorder = AudioRecorder()

        XCTAssertNil(recorder.pendingEngineInvalidationReason)
    }

    func testInvalidatingRecordsWhyTheEngineCannotBeTrusted() {
        let recorder = AudioRecorder()

        recorder.invalidateEngine(reason: "the machine woke")

        XCTAssertEqual(recorder.pendingEngineInvalidationReason, "the machine woke")
    }

    /// A wake and a device change arrive as two separate notifications for one
    /// physical event. The log has to name both, or the next person debugging
    /// this sees only whichever fired last.
    func testSeveralCausesBeforeTheNextRecordingAreAllReported() {
        let recorder = AudioRecorder()

        recorder.invalidateEngine(reason: "the machine woke")
        recorder.invalidateEngine(reason: "the default input device changed")

        XCTAssertEqual(
            recorder.pendingEngineInvalidationReason,
            "the machine woke, the default input device changed"
        )
    }

    func testTheSameCauseTwiceIsNotReportedTwice() {
        let recorder = AudioRecorder()

        recorder.invalidateEngine(reason: "the machine woke")
        recorder.invalidateEngine(reason: "the machine woke")

        XCTAssertEqual(recorder.pendingEngineInvalidationReason, "the machine woke")
    }

    func testRebuildingClearsTheReasonSoTheNextRecordingDoesNotRebuildAgain() {
        let recorder = AudioRecorder()
        recorder.invalidateEngine(reason: "the machine woke")

        recorder.rebuildEngineIfInvalidated()

        XCTAssertNil(recorder.pendingEngineInvalidationReason)
    }

    func testRebuildingIsSkippedEntirelyWhenNothingInvalidatedTheEngine() {
        let recorder = AudioRecorder()
        let generationBefore = recorder.engineGeneration

        recorder.rebuildEngineIfInvalidated()

        XCTAssertEqual(
            recorder.engineGeneration,
            generationBefore,
            "Rebuilding a healthy engine would throw away the prewarm and slow every hotkey press."
        )
    }

    func testRebuildingReplacesTheEngine() {
        let recorder = AudioRecorder()
        let generationBefore = recorder.engineGeneration
        recorder.invalidateEngine(reason: "the machine woke")

        recorder.rebuildEngineIfInvalidated()

        XCTAssertEqual(recorder.engineGeneration, generationBefore + 1)
    }

    /// THE BUG THIS TEST EXISTS FOR: registering the configuration-change
    /// observer once, in `init`, against the engine that existed then. After the
    /// first rebuild the observer would be watching a discarded engine and the
    /// app would be blind again — the exact state it was in on 2026-08-09, just
    /// reached one rebuild later. Verified by deliberately registering only in
    /// `init` and watching this fail.
    func testTheConfigurationChangeObserverFollowsTheEngineAcrossRebuilds() {
        let recorder = AudioRecorder()

        recorder.invalidateEngine(reason: "the machine woke")
        recorder.rebuildEngineIfInvalidated()

        XCTAssertEqual(
            recorder.configurationChangeObservedGeneration,
            recorder.engineGeneration,
            "The observer must be re-registered against the engine that now exists, not the one that was discarded."
        )
    }

    func testAConfigurationChangeOnTheLiveEngineInvalidatesIt() {
        let recorder = AudioRecorder()

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: recorder.test_currentEngine
        )

        XCTAssertNotNil(
            recorder.pendingEngineInvalidationReason,
            "AVFAudio telling us the graph was reconfigured is the one signal that arrives for a Bluetooth mic coming back on a different route."
        )
    }

    func testWakingFromSleepInvalidatesTheEngine() {
        let recorder = AudioRecorder()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        XCTAssertNotNil(recorder.pendingEngineInvalidationReason)
    }

    // MARK: - Route signature
    //
    // CODEX ROUND 1, P1, 2026-08-09. The notification observers above do not
    // close the hole on their own. `AVAudioEngineConfigurationChange` is posted
    // by AVFAudio while the graph is RENDERING, and between dictations this
    // engine is stopped. So a Bluetooth mic that flips HFP/A2DP profile, or an
    // aggregate device that changes rate, while the engine sits idle fires
    // nothing: no configuration change (not rendering), no default-device change
    // (the ID is the same, and the app is pinned to a UID anyway), and no wake.
    // The next recording then reuses the stale graph and captures zero frames,
    // which is the exact failure the patch exists to prevent.
    //
    // The answer is not another notification. It is to stop trusting the engine
    // and check the route's shape against the shape it was built for.

    func testAnUnchangedRouteDoesNotForceARebuild() {
        let route = InputRouteSignature(deviceID: 73, sampleRate: 48000, channelCount: 1)

        XCTAssertFalse(
            AudioRecorder.inputRouteChanged(from: route, to: route),
            "Rebuilding a healthy engine throws away the prewarm and slows every hotkey press."
        )
    }

    func testASampleRateFlipForcesARebuild() {
        XCTAssertTrue(
            AudioRecorder.inputRouteChanged(
                from: InputRouteSignature(deviceID: 73, sampleRate: 48000, channelCount: 1),
                to: InputRouteSignature(deviceID: 73, sampleRate: 24000, channelCount: 1)
            ),
            "48 kHz to 24 kHz is the AirPods HFP flip, named in the comment commit 9c4e2a4 deleted."
        )
    }

    func testAChannelCountChangeForcesARebuild() {
        XCTAssertTrue(
            AudioRecorder.inputRouteChanged(
                from: InputRouteSignature(deviceID: 73, sampleRate: 48000, channelCount: 1),
                to: InputRouteSignature(deviceID: 73, sampleRate: 48000, channelCount: 2)
            )
        )
    }

    func testTheSameDeviceComingBackWithADifferentIDForcesARebuild() {
        XCTAssertTrue(
            AudioRecorder.inputRouteChanged(
                from: InputRouteSignature(deviceID: 73, sampleRate: 48000, channelCount: 1),
                to: InputRouteSignature(deviceID: 91, sampleRate: 48000, channelCount: 1)
            )
        )
    }

    func testTheFirstRecordingHasNothingToCompareAgainstAndDoesNotRebuild() {
        XCTAssertFalse(
            AudioRecorder.inputRouteChanged(
                from: nil,
                to: InputRouteSignature(deviceID: 73, sampleRate: 48000, channelCount: 1)
            ),
            "A fresh engine is already correct for whatever route exists now."
        )
    }

    func testAnUnreadableRouteIsNotTreatedAsAChange() {
        XCTAssertFalse(
            AudioRecorder.inputRouteChanged(
                from: InputRouteSignature(deviceID: 73, sampleRate: 48000, channelCount: 1),
                to: nil
            ),
            "Failing to read the device tells us nothing, and guessing 'changed' would rebuild on every hotkey press whenever the read is flaky."
        )
    }

    // CODEX ROUND 2, P1, 2026-08-09. The comparison above is only as good as the
    // baseline it compares against, and the baseline was being thrown away in
    // two places: `rebuildEngine()` cleared it, and `prewarm()` never set one.
    // Either way the NEXT recording had nothing to compare against, so a profile
    // flip in that window went undetected and the stale graph was reused — the
    // original failure, one recording later. These tests drive the baseline
    // through the injected route provider so they do not depend on whatever
    // microphone the test host happens to have.

    private func recorder(onRoute route: InputRouteSignature?) -> AudioRecorder {
        let recorder = AudioRecorder()
        recorder.routeSignatureProvider = { _ in route }
        return recorder
    }

    func testPrewarmingRecordsTheRouteTheEngineWasBoundTo() {
        let route = InputRouteSignature(deviceID: 73, sampleRate: 48000, channelCount: 1)
        let recorder = recorder(onRoute: route)

        recorder.prewarm()

        XCTAssertEqual(
            recorder.engineBuiltForRoute,
            route,
            "Without a baseline at prewarm, a flip between launch and the first dictation is invisible."
        )
    }

    func testTheBaselineSurvivesARebuildSoTheVeryNextRecordingCanStillDetectAFlip() {
        let route = InputRouteSignature(deviceID: 73, sampleRate: 48000, channelCount: 1)
        let recorder = recorder(onRoute: route)
        recorder.prewarm()

        recorder.invalidateEngine(reason: "the machine woke from sleep")
        recorder.rebuildEngineIfInvalidated()

        XCTAssertEqual(
            recorder.engineBuiltForRoute,
            route,
            "A rebuild binds a new engine to the current route. Clearing the baseline blinds the next recording."
        )
    }

    func testAFlipImmediatelyAfterARebuildIsStillCaught() {
        let recorder = AudioRecorder()
        var route = InputRouteSignature(deviceID: 73, sampleRate: 48000, channelCount: 1)
        recorder.routeSignatureProvider = { _ in route }
        recorder.prewarm()
        recorder.invalidateEngine(reason: "the machine woke from sleep")
        recorder.rebuildEngineIfInvalidated()

        route = InputRouteSignature(deviceID: 73, sampleRate: 24000, channelCount: 1)
        recorder.invalidateIfRouteChanged()

        XCTAssertEqual(
            recorder.pendingEngineInvalidationReason,
            "the input route changed shape (48000Hz/1ch → 24000Hz/1ch)"
        )
    }

    func testAStableRouteAfterARebuildDoesNotRebuildAgain() {
        let route = InputRouteSignature(deviceID: 73, sampleRate: 48000, channelCount: 1)
        let recorder = recorder(onRoute: route)
        recorder.prewarm()
        recorder.invalidateEngine(reason: "the machine woke from sleep")
        recorder.rebuildEngineIfInvalidated()
        let generationAfterRebuild = recorder.engineGeneration

        recorder.invalidateIfRouteChanged()
        recorder.rebuildEngineIfInvalidated()

        XCTAssertEqual(
            recorder.engineGeneration,
            generationAfterRebuild,
            "Rebuilding twice for one event would cost the prewarm on the hotkey press right after a wake."
        )
    }

    // MARK: - Mid-recording watchdog
    //
    // The capture report says what happened AFTER he lets go. That is too late
    // to save the words: on 2026-08-09 he spoke for 103 seconds into a dead
    // microphone and learned nothing until he stopped. The meeting path has had
    // a live "your microphone stopped sending audio" warning since 2026-07-29;
    // dictation, which is the product, has never had one.
    //
    // Two failure shapes, kept apart deliberately. Frames that never arrive mean
    // the engine's input path is dead. Frames that arrive as exact zeroes mean
    // the route is alive and the microphone is not — STATE.md Phase 1 items 5
    // and 6, still unexplained, and this is the trap that catches them.

    func testTheWatchdogAllowsTheMicrophoneTimeToComeUp() {
        XCTAssertEqual(
            CaptureHealth.verdict(elapsedSinceStart: 0.5, elapsedSinceLastTapCallback: nil, elapsedSinceLastChunk: nil, continuousSilence: 0),
            .healthy,
            "Measured hotkey-to-mic-live ran to 914 ms on a bad night. Warning inside that window would cry wolf on every press."
        )
    }

    func testTheWatchdogReportsAMicrophoneThatNeverStartedDelivering() {
        XCTAssertEqual(
            CaptureHealth.verdict(elapsedSinceStart: 1.5, elapsedSinceLastTapCallback: nil, elapsedSinceLastChunk: nil, continuousSilence: 0),
            .noFramesArriving
        )
    }

    func testAFlowingCaptureIsHealthy() {
        XCTAssertEqual(
            CaptureHealth.verdict(elapsedSinceStart: 40, elapsedSinceLastTapCallback: 0.02, elapsedSinceLastChunk: 0.02, continuousSilence: 0),
            .healthy
        )
    }

    func testTheWatchdogReportsACaptureThatStoppedPartWayThrough() {
        XCTAssertEqual(
            CaptureHealth.verdict(elapsedSinceStart: 40, elapsedSinceLastTapCallback: 1.5, elapsedSinceLastChunk: 1.5, continuousSilence: 0),
            .noFramesArriving,
            "A route that dies mid-sentence loses the rest of the sentence, and he has to know while he is still speaking."
        )
    }

    // CODEX ROUND 4, P2. A tap that keeps firing while conversion fails is a
    // THIRD failure, and calling it "no frames arriving" sends him to Settings
    // to re-pick a microphone that was never the problem.
    func testConversionFailingIsNotReportedAsADeadMicrophone() {
        XCTAssertEqual(
            CaptureHealth.verdict(
                elapsedSinceStart: 5,
                elapsedSinceLastTapCallback: 0.02,
                elapsedSinceLastChunk: 1.5,
                continuousSilence: 0
            ),
            .conversionFailing,
            "The tap is alive and the converter is not. Re-picking the mic would not fix it."
        )
    }

    func testADeadTapIsReportedAheadOfAConversionFailure() {
        XCTAssertEqual(
            CaptureHealth.verdict(
                elapsedSinceStart: 5,
                elapsedSinceLastTapCallback: 2.0,
                elapsedSinceLastChunk: 2.0,
                continuousSilence: 0
            ),
            .noFramesArriving
        )
    }

    func testTheWatchdogReportsFramesThatArriveAsDigitalSilence() {
        XCTAssertEqual(
            CaptureHealth.verdict(elapsedSinceStart: 5, elapsedSinceLastTapCallback: 0.02, elapsedSinceLastChunk: 0.02, continuousSilence: 3.0),
            .digitalSilence
        )
    }

    func testABriefPauseInSpeechIsNotDigitalSilence() {
        XCTAssertEqual(
            CaptureHealth.verdict(elapsedSinceStart: 5, elapsedSinceLastTapCallback: 0.02, elapsedSinceLastChunk: 0.02, continuousSilence: 2.9),
            .healthy,
            "He pauses mid-thought constantly. Anything under three seconds of exact zeroes is him thinking, not a dead mic."
        )
    }

    func testADeadRouteIsReportedAheadOfSilenceWhenBothLookTrue() {
        XCTAssertEqual(
            CaptureHealth.verdict(elapsedSinceStart: 10, elapsedSinceLastTapCallback: 5.0, elapsedSinceLastChunk: 5.0, continuousSilence: 5.0),
            .noFramesArriving,
            "Frames that stopped arriving is the more specific diagnosis, and naming it silence would send him to the wrong fix."
        )
    }

    func testTheWatchdogWarnsOnceAndThenStaysQuietForTheRestOfTheRecording() {
        var verdicts: [CaptureHealth.Verdict] = []
        var tracker = CaptureHealthTracker()

        verdicts.append(contentsOf: tracker.evaluate(.noFramesArriving))
        verdicts.append(contentsOf: tracker.evaluate(.noFramesArriving))
        verdicts.append(contentsOf: tracker.evaluate(.noFramesArriving))

        XCTAssertEqual(verdicts, [.noFramesArriving], "A warning that repeats twice a second is noise he will learn to ignore.")
    }

    func testTheWatchdogWillStillReportADifferentFailureLater() {
        var verdicts: [CaptureHealth.Verdict] = []
        var tracker = CaptureHealthTracker()

        verdicts.append(contentsOf: tracker.evaluate(.digitalSilence))
        verdicts.append(contentsOf: tracker.evaluate(.digitalSilence))
        verdicts.append(contentsOf: tracker.evaluate(.noFramesArriving))

        XCTAssertEqual(verdicts, [.digitalSilence, .noFramesArriving])
    }

    func testAHealthyCaptureNeverWarns() {
        var tracker = CaptureHealthTracker()

        XCTAssertTrue(tracker.evaluate(.healthy).isEmpty)
        XCTAssertTrue(tracker.evaluate(.healthy).isEmpty)
    }

    // CODEX ROUND 4, P2. `DispatchSourceTimer.cancel()` does not wait for a
    // handler that is already queued or running, and AppState keeps
    // `isRecording` true while it awaits `stopRecording()`. So a poll could land
    // after he let go and warn him about a capture that was already over. The
    // clock is injected here so the whole lifecycle is deterministic rather than
    // a sleep-and-hope test.

    func testTheWatchdogWarnsWhenNoFramesArriveWithinTheGracePeriod() {
        let recorder = AudioRecorder()
        var fired: [CaptureHealth.Verdict] = []
        recorder.onCaptureUnhealthy = { fired.append($0) }
        var now: UInt64 = 0
        recorder.nowNanoseconds = { now }

        recorder.armCaptureWatchdog()
        now = 1_500_000_000
        recorder.pollCaptureHealth()

        XCTAssertEqual(fired, [.noFramesArriving])
    }

    func testAPollThatLandsAfterStopDoesNotWarnAboutARecordingThatIsOver() {
        let recorder = AudioRecorder()
        var fired: [CaptureHealth.Verdict] = []
        recorder.onCaptureUnhealthy = { fired.append($0) }
        var now: UInt64 = 0
        recorder.nowNanoseconds = { now }

        recorder.armCaptureWatchdog()
        now = 1_500_000_000
        recorder.stopCaptureWatchdog()
        recorder.pollCaptureHealth()

        XCTAssertTrue(
            fired.isEmpty,
            "He let go of the key. Warning him now is about a recording that no longer exists."
        )
    }

    func testTheNextRecordingStartsWithACleanWatchdog() {
        let recorder = AudioRecorder()
        var fired: [CaptureHealth.Verdict] = []
        recorder.onCaptureUnhealthy = { fired.append($0) }
        var now: UInt64 = 0
        recorder.nowNanoseconds = { now }

        recorder.armCaptureWatchdog()
        now = 1_500_000_000
        recorder.pollCaptureHealth()
        recorder.stopCaptureWatchdog()

        now = 2_000_000_000
        recorder.armCaptureWatchdog()
        now = 3_500_000_000
        recorder.pollCaptureHealth()

        XCTAssertEqual(
            fired,
            [.noFramesArriving, .noFramesArriving],
            "Warned once per recording, not once per lifetime: the second dictation into a dead mic must warn too."
        )
    }

    // MARK: - Capture telemetry
    //
    // On 2026-08-09 the single most diagnostic number — how many samples the tap
    // actually delivered — went to `print`, and a GUI app launched from Finder
    // has stdout on /dev/null. The unified log had no GhostPepper output at all.
    // So the six failed dictations left behind a durable log that recorded the
    // hotkey, the recording, and the empty result, and nothing that said the
    // microphone had delivered zero frames. These tests pin the line that gets
    // written instead.

    func testCaptureSummaryNamesADeadMicrophoneWhenNoCallbacksArrived() {
        let report = CaptureReport(
            inputFormatDescription: "48000Hz/1ch",
            holdDuration: 103.0,
            tapCallbacks: 0,
            convertedChunks: 0,
            sampleCount: 0,
            maxAmplitude: 0
        )

        XCTAssertTrue(
            report.summary.contains("delivered no audio"),
            "A 103-second hold with zero tap callbacks must say the microphone delivered nothing. Got: \(report.summary)"
        )
    }

    func testCaptureSummaryDistinguishesSilenceFromADeadMicrophone() {
        let report = CaptureReport(
            inputFormatDescription: "48000Hz/1ch",
            holdDuration: 9.19,
            tapCallbacks: 460,
            convertedChunks: 460,
            sampleCount: 147_040,
            maxAmplitude: 0
        )

        XCTAssertTrue(
            report.summary.contains("digital silence"),
            "Frames that arrive but are all zeroes are a different defect from frames that never arrive, and the log has to tell them apart. Got: \(report.summary)"
        )
        XCTAssertFalse(report.summary.contains("delivered no audio"))
    }

    func testCaptureSummaryCarriesTheNumbersNeededToDebugItWithoutTheApp() {
        let report = CaptureReport(
            inputFormatDescription: "24000Hz/1ch",
            holdDuration: 4.5,
            tapCallbacks: 225,
            convertedChunks: 225,
            sampleCount: 72_000,
            maxAmplitude: 0.31
        )

        let summary = report.summary
        XCTAssertTrue(summary.contains("24000Hz/1ch"), summary)
        XCTAssertTrue(summary.contains("callbacks=225"), summary)
        XCTAssertTrue(summary.contains("samples=72000"), summary)
        XCTAssertTrue(summary.contains("hold=4.50s"), summary)
    }

    func testConvertedChunksAreCountedForTheCaptureReport() {
        let recorder = AudioRecorder()

        recorder.test_convert(samples: [0.1, 0.2])
        recorder.test_convert(samples: [0.3, 0.4])

        XCTAssertEqual(recorder.convertedChunkCount, 2)
    }

    func testCaptureCountersResetSoOneRecordingCannotInheritTheLastOnesNumbers() {
        let recorder = AudioRecorder()
        recorder.test_convert(samples: [0.1, 0.2])

        recorder.resetCaptureCounters()

        XCTAssertEqual(recorder.convertedChunkCount, 0)
        XCTAssertEqual(recorder.tapCallbackCount, 0)
    }

    /// The observers are the whole fix, so a recorder that has been deallocated
    /// must not leave them behind posting into freed memory.
    func testObserversAreTornDownWithTheRecorder() {
        weak var weakRecorder: AudioRecorder?

        autoreleasepool {
            let recorder = AudioRecorder()
            weakRecorder = recorder
            XCTAssertNotNil(weakRecorder)
        }

        XCTAssertNil(weakRecorder, "A retained observer closure would keep the recorder alive forever.")
    }
}
