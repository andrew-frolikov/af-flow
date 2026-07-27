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
