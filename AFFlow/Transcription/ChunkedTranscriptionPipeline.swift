import Foundation

/// A transcribed segment from one audio stream chunk.
struct ChunkedTranscriptResult {
    let source: AudioStreamSource
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

/// Accumulates audio from DualStreamCapture in per-stream buffers, drains them
/// every `chunkInterval` seconds, transcribes each chunk, and emits results.
///
/// Memory, stated as what it actually is rather than as a ceiling. Each drain
/// holds the audio it drained until its last piece has been transcribed, plus one
/// piece copied out at a time. Drains queue on a serial transcription queue, so if
/// inference falls behind real time SEVERAL drains are resident at once, not one.
/// In normal operation that is a chunk pair or two, about 3.7 MB each.
///
/// It is written this way because the comment here used to promise a fixed
/// "one chunk pair (~3.7 MB)" and the 2026-07-29 recording held about 390 MB. No
/// backpressure is applied yet: dropping audio to save memory would be the wrong
/// trade for a meeting recorder, and bounding it properly means bounding inference
/// time, which is recorded as open work rather than claimed here.
final class ChunkedTranscriptionPipeline {
    /// Called on the main queue when a new transcript segment is available.
    var onSegmentTranscribed: ((ChunkedTranscriptResult) -> Void)?

    /// Called when chunk audio is saved to disk, with the capture time the chunk
    /// starts at (for optional post-meeting diarization).
    var onChunkSaved: ((URL, AudioStreamSource, TimeInterval) -> Void)?

    /// Reports what the pipeline is actually doing, so a stall can never again be
    /// invisible. See `noteDrain` for what is worth a line and what is not.
    var onDiagnostic: ((String) -> Void)?

    /// Reports a channel that was delivering audio and has stopped, once per
    /// outage. See `quietDrainsBeforeReporting`.
    var onSourceWentQuiet: ((AudioStreamSource) -> Void)?

    private let chunkInterval: TimeInterval

    /// Audio re-fed at the head of the next chunk so a word spoken across a
    /// boundary is not cut in half.
    ///
    /// This was declared and never read until 2026-07-29, so every boundary in
    /// every meeting he had recorded was a hard cut.
    ///
    /// The duplicate this creates is then removed by `deduplicateOverlap`, WHERE IT
    /// CAN BE: that matcher needs at least two identical whitespace-separated
    /// words, so a boundary that repeats a single word, or repeats it with
    /// different punctuation, can still show the word twice. That is the lesser of
    /// the two failures, since the alternative is losing the word entirely, and it
    /// is written down here rather than claimed away.
    private let overlapDuration: TimeInterval = 1.0

    /// The most audio that may ever reach the model in ONE inference call.
    ///
    /// `TranscriptionScheduler` promises that a dictation "still waits for a
    /// background chunk that is already RUNNING" and that "the wait is bounded by
    /// one chunk rather than by the queue behind it". That sentence was true and
    /// the bound it promised was not, because nothing limited how long a chunk
    /// could BE. On 2026-07-29 one drain handed the model 31 minutes of audio and
    /// Andrew's 8-second dictation took 16 minutes 3 seconds to come back.
    ///
    /// So the bound is stated in seconds here rather than assumed from the drain
    /// cadence. However late a drain runs, and however much audio has piled up
    /// behind it, no single inference can exceed this.
    private let maxInferenceDuration: TimeInterval

    private let bufferLock = NSLock()
    private var micBuffer = SourceBuffer()
    private var systemBuffer = SourceBuffer()
    private var chunkIndex: Int = 0

    /// A run of contiguous audio and the capture time of its first sample.
    private struct AudioSpan {
        var samples: [Float]
        var startTime: TimeInterval
    }

    /// Audio held for one source, as one or more contiguous spans.
    ///
    /// SPANS RATHER THAN ONE ARRAY, because a channel can stop and come back and
    /// both halves matter. The first version of this fix re-anchored by clearing
    /// the buffer, which threw away any audio captured after the last drain and
    /// before the gap. That is losing his words to fix a bug about losing his
    /// words, and the review caught it. Each span carries its own start time, so a
    /// gap costs nothing but a boundary.
    private struct SourceBuffer {
        var spans: [AudioSpan] = []
        /// How many samples at the head of the first span are carried over from
        /// the previous drain for overlap. Without this a buffer holding only its
        /// own overlap tail would look like fresh audio and drain forever.
        var carriedOverlap: Int = 0

        var totalSamples: Int { spans.reduce(0) { $0 + $1.samples.count } }
        var hasFreshAudio: Bool { totalSamples > carriedOverlap }
    }

    private var chunkTimer: DispatchSourceTimer?

    /// Keeps App Nap and idle sleep off while a meeting is being recorded.
    ///
    /// Nothing in this app had ever declared that it was doing work, and the
    /// drain schedule used to depend on the main run loop being serviced. Both
    /// halves of that are fixed: the timer below is a dispatch timer that owes
    /// nothing to any run loop, and this tells the system the work is real.
    private var activityToken: NSObjectProtocol?

    private var isRunning = false
    private var drainCount = 0
    private var sourcesSeen: Set<String> = []

    /// How many consecutive drains a live channel may deliver nothing for before
    /// it is called dead. Three at the default interval is 90 seconds, which is
    /// long enough that a genuinely quiet room never trips it and short enough
    /// that he is told inside two minutes rather than after nineteen.
    private static let quietDrainsBeforeReporting = 3
    private var quietDrains: [String: Int] = [:]
    private var reportedQuiet: Set<String> = []

    private var previousMicTail: String = ""
    private var previousSystemTail: String = ""

    /// Serial queue for transcription tasks to prevent race conditions on tail state.
    private let transcriptionQueue = DispatchQueue(label: "com.whispercat.chunked-transcription", qos: .userInitiated)

    /// The pipeline's own timer queue. The drain schedule lives here rather than
    /// on a run loop, which is the whole point: on 2026-07-29 the drain ran once
    /// in 51 minutes because it was a `Timer` on the main run loop.
    private let timerQueue = DispatchQueue(label: "com.whispercat.chunk-timer", qos: .utility)

    private let transcriptionSemaphore = DispatchSemaphore(value: 1)
    private let transcriptionGroup = DispatchGroup()
    private let transcribeChunk: ([Float]) async -> String?

    /// Directory for saving chunk WAV files.
    private let chunkDirectory: URL

    private let sampleRate: Double = 16000

    /// Below this RMS a chunk is treated as silence and never reaches the model.
    ///
    /// Whisper does not return nothing for silence, it INVENTS. Its favourite
    /// inventions are "Thank you.", "Thanks for watching!" and similar, because
    /// that is what ends the videos it was trained on. Andrew's first real
    /// meeting recording, made alone with no other participants, produced
    /// exactly that: a line reading `Others: Thank you.` in a call where nobody
    /// else spoke at all.
    ///
    /// That is worse than a missing transcript. A meeting record that contains
    /// words nobody said, attributed to other people, is a record he cannot
    /// trust, and the failure is invisible because the invented text is fluent
    /// and plausible.
    ///
    /// The threshold matches the one `MeetingSession` already uses to decide
    /// whether it is hearing anything at all, so the two agree about what
    /// silence means rather than each having an opinion.
    private static let silenceRMSThreshold: Float = 0.001

    static func isEffectivelySilent(_ samples: [Float]) -> Bool {
        rms(of: samples) < silenceRMSThreshold
    }

    /// Above this RMS a chunk the model could not transcribe is marked in the
    /// transcript. Roughly -40 dBFS: comfortably below normal speech and well above
    /// typing, rustling and room tone, so the marker keeps meaning something.
    private static let markMissingRMSThreshold: Float = 0.01

    static func isLoudEnoughToMarkAsMissing(_ samples: [Float]) -> Bool {
        rms(of: samples) >= markMissingRMSThreshold
    }

    private static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    init(
        transcriber: SpeechTranscriber,
        chunkDirectory: URL,
        chunkInterval: TimeInterval = 30.0,
        maxInferenceDuration: TimeInterval = 30.0
    ) {
        self.transcribeChunk = { samples -> String? in
            // The silence gate is NOT here any more, it is in `processChunk`, so
            // that a nil from this closure means one thing: the model was asked and
            // gave nothing back. See the gate there and `silenceRMSThreshold`.
            //
            // Meeting chunks yield to push-to-talk, which he is waiting on.
            await transcriber.transcribe(audioBuffer: samples, priority: .background)
        }
        self.chunkDirectory = chunkDirectory
        self.chunkInterval = chunkInterval
        self.maxInferenceDuration = maxInferenceDuration
    }

    init(
        transcribeChunk: @escaping ([Float]) async -> String?,
        chunkDirectory: URL,
        chunkInterval: TimeInterval = 30.0,
        maxInferenceDuration: TimeInterval = 30.0
    ) {
        self.transcribeChunk = transcribeChunk
        self.chunkDirectory = chunkDirectory
        self.chunkInterval = chunkInterval
        self.maxInferenceDuration = maxInferenceDuration
    }

    /// Start the chunked pipeline. Call this after DualStreamCapture.start().
    func start() {
        guard !isRunning else { return }
        isRunning = true
        bufferLock.lock()
        chunkIndex = 0
        // The buffers are DELIBERATELY not cleared here.
        //
        // `MeetingSession` wires the capture callback and starts capture before it
        // starts this pipeline, so audio can already have arrived by now. Resetting
        // the buffers, which the first version of this did as a tidy-up, silently
        // threw away everything captured during startup. The review caught it. A
        // fresh pipeline has empty buffers anyway, so the reset bought nothing and
        // cost the first words of the meeting.
        bufferLock.unlock()
        drainCount = 0
        sourcesSeen = []
        previousMicTail = ""
        previousSystemTail = ""

        // Create chunk directory.
        try? FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "AF Flow is transcribing a meeting"
        )

        // A dispatch timer on the pipeline's own queue, NOT a run-loop Timer.
        //
        // The failure this replaces: `Timer.scheduledTimer` attaches to whatever
        // run loop `start()` happened to be called from, and a run loop that is
        // not being serviced does not fire timers. On 2026-07-29 this drained
        // once in 51 minutes while 31 minutes of audio accumulated in memory,
        // and nothing anywhere said so.
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(
            deadline: .now() + chunkInterval,
            repeating: chunkInterval,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            self?.drainAndTranscribe()
        }
        timer.activate()
        chunkTimer = timer
    }

    /// How long `stop()` will wait for transcription to finish before finalising
    /// anyway.
    ///
    /// The bound exists because of what an unbounded wait now costs. A single
    /// inference that never returns would leave `MeetingSession.isDraining` true
    /// forever, and the "one meeting at a time" guard would then refuse every
    /// future recording until he quit the app: a hang in one meeting would take
    /// away the feature. Finalising late and saying so is better than that.
    ///
    /// WHAT IT DOES NOT DO, so nobody reads more into it than it earns. It bounds
    /// the WAIT, not the inference: it covers the whole queued backlog rather than
    /// one chunk, so a model running far slower than real time could expire it and
    /// finalise a transcript that is still missing its last segments. And a
    /// genuinely hung inference still holds `TranscriptionScheduler`, so dictation
    /// would stay blocked even though the meeting finalised. Real cancellation is
    /// open work, recorded in PROGRESS.md, not something this timeout provides.
    private static let transcriptionDrainTimeout: DispatchTimeInterval = .seconds(180)

    /// Releases the timer and the process activity assertion. Idempotent, and
    /// called from both `stop()` and `deinit`, because a pipeline that is dropped
    /// without a completed stop would otherwise keep idle sleep disabled and keep
    /// a timer firing against a dead meeting.
    private func releaseTimerAndActivity() {
        chunkTimer?.cancel()
        chunkTimer = nil
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    deinit {
        releaseTimerAndActivity()
    }

    /// Stop the pipeline and process any remaining audio.
    func stop() async {
        guard isRunning else { return }
        isRunning = false
        releaseTimerAndActivity()

        // Serialised against the timer's own handler by running on its queue, so
        // the final drain cannot interleave with a drain already in flight.
        timerQueue.sync {
            drainAndTranscribe(isFinal: true)
        }

        // Waited for OFF the main thread: `DispatchGroup.wait` blocks its caller,
        // and this is awaited from the main actor.
        let finishedInTime: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [transcriptionGroup] in
                let result = transcriptionGroup.wait(timeout: .now() + Self.transcriptionDrainTimeout)
                continuation.resume(returning: result == .success)
            }
        }
        if !finishedInTime {
            onDiagnostic?("Meeting transcription did not finish within \(Self.transcriptionDrainTimeout) of the stop. Finalising anyway so the app is not left unable to record.")
        }

        // FLUSH THE DELIVERIES, not just the inference.
        //
        // Segments and saved chunks are handed to the main queue rather than
        // awaited on it, which is what stopped a busy main actor from throttling
        // the pipeline. Without this barrier `stop()` could return before the last
        // segment had been appended, and the caller's final save, speaker tagging
        // and summary would then run against a transcript missing its own ending:
        // the exact class of loss this session exists to fix. The main queue is
        // FIFO, so one block enqueued here runs after every delivery enqueued
        // before it.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    /// Feed audio chunks from DualStreamCapture into the pipeline.
    func appendAudio(_ chunk: TaggedAudioChunk) {
        bufferLock.lock()
        switch chunk.source {
        case .mic:
            Self.append(chunk, to: &micBuffer, sampleRate: sampleRate)
        case .system:
            Self.append(chunk, to: &systemBuffer, sampleRate: sampleRate)
        }
        bufferLock.unlock()
    }

    // MARK: - Private

    /// How far the arriving audio's own capture time may differ from where the
    /// buffer thinks it is before the buffer is treated as discontinuous.
    ///
    /// Capture timestamps are taken when a buffer is DELIVERED, so they run a
    /// little ahead of the audio inside it and jitter by a buffer's worth. A
    /// second and a half absorbs that and is far below any real outage.
    private static let discontinuityTolerance: TimeInterval = 1.5

    private static func append(_ chunk: TaggedAudioChunk, to buffer: inout SourceBuffer, sampleRate: Double) {
        // Continue the current span when this audio follows on from it, and START A
        // NEW SPAN when the stream has clearly skipped.
        //
        // Anchoring only on an empty buffer was not enough once an overlap tail is
        // retained, because the buffer is then never empty and every later capture
        // time was ignored. A channel that dies and comes back, which is exactly
        // what his microphone did on 2026-07-29, would have had its returning audio
        // stamped as though it had continued without a gap, compressing the
        // timeline and misaligning the speaker tagger against it.
        if let lastIndex = buffer.spans.indices.last {
            let last = buffer.spans[lastIndex]
            let expected = last.startTime + Double(last.samples.count) / sampleRate
            if abs(chunk.timestamp - expected) <= discontinuityTolerance {
                // Mutated through the subscript, not through a copy, so appending
                // does not duplicate the whole span on every incoming buffer.
                buffer.spans[lastIndex].samples.append(contentsOf: chunk.samples)
                return
            }
        }
        buffer.spans.append(AudioSpan(samples: chunk.samples, startTime: chunk.timestamp))
    }

    /// One inference call's worth of a drained buffer, held as a range rather than
    /// a copy so a large backlog is not materialised twice over.
    private struct AudioPiece {
        let source: AudioStreamSource
        /// Which contiguous span of the drained buffer this piece cuts from.
        let spanIndex: Int
        let range: Range<Int>
        let startTime: TimeInterval
    }

    /// Takes every span buffered for one source, leaving the tail of the last span
    /// behind as the next chunk's overlap.
    private func takeBuffered(_ buffer: inout SourceBuffer) -> [AudioSpan]? {
        guard buffer.hasFreshAudio, let last = buffer.spans.last else { return nil }
        let spans = buffer.spans

        let overlapSamples = min(Int(overlapDuration * sampleRate), last.samples.count)
        buffer.spans = [
            AudioSpan(
                samples: Array(last.samples.suffix(overlapSamples)),
                startTime: last.startTime + Double(last.samples.count - overlapSamples) / sampleRate
            )
        ]
        buffer.carriedOverlap = overlapSamples

        return spans
    }

    /// Splits every span of a drained buffer into pieces no longer than
    /// `maxInferenceDuration`, overlapping each piece with the last so a split
    /// cannot cut a word either. Spans are never merged across a gap.
    private func pieces(in spans: [AudioSpan], source: AudioStreamSource) -> [AudioPiece] {
        var result: [AudioPiece] = []
        for (spanIndex, span) in spans.enumerated() {
            let count = span.samples.count
            guard count > 0 else { continue }
            let maxSamples = max(1, Int(maxInferenceDuration * sampleRate))
            guard count > maxSamples else {
                result.append(
                    AudioPiece(source: source, spanIndex: spanIndex, range: 0..<count, startTime: span.startTime)
                )
                continue
            }

            // Bounded below by 1 so the loop always advances even if maxSamples is 1.
            let step = max(1, maxSamples - min(Int(overlapDuration * sampleRate), maxSamples / 2))
            var offset = 0
            while offset < count {
                let end = min(offset + maxSamples, count)
                result.append(
                    AudioPiece(
                        source: source,
                        spanIndex: spanIndex,
                        range: offset..<end,
                        startTime: span.startTime + Double(offset) / sampleRate
                    )
                )
                if end == count { break }
                offset += step
            }
        }
        return result
    }

    private func drainAndTranscribe(isFinal: Bool = false) {
        bufferLock.lock()
        let mic = takeBuffered(&micBuffer)
        let system = takeBuffered(&systemBuffer)
        bufferLock.unlock()

        let micSpans = mic ?? []
        let systemSpans = system ?? []
        let micPieces = pieces(in: micSpans, source: .mic)
        let systemPieces = pieces(in: systemSpans, source: .system)

        noteDrain(
            mic: mic.map { spans in spans.reduce(0) { $0 + $1.samples.count } },
            system: system.map { spans in spans.reduce(0) { $0 + $1.samples.count } },
            micPieces: micPieces.count,
            systemPieces: systemPieces.count,
            isFinal: isFinal
        )

        guard mic != nil || system != nil else { return }

        // MERGED BY CAPTURE TIME, not by source.
        //
        // Processing every microphone piece and then every system piece put the
        // transcript out of order the moment a drain produced more than one piece
        // each: `MeetingTranscript.appendSegment` appends, it does not sort, so a
        // 90-second backlog would have read me 0s, me 30s, me 60s, others 0s,
        // others 30s, others 60s. Merging here keeps one ordering rule for both
        // channels while the dedup tails below stay per-channel.
        //
        // On a tie the SYSTEM piece goes first, and that is not arbitrary.
        // `MeetingEchoFilter` drops a microphone segment that repeats what the
        // system channel already said, so it can only ever work if the system copy
        // is in the transcript before the microphone copy of the same moment
        // arrives. Microphone-first, which is what this code did in every version
        // before now, made the filter unable to catch the bleed it exists for.
        let ordered = (micPieces + systemPieces).sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.source == .system && rhs.source == .mic
            }
            return lhs.startTime < rhs.startTime
        }

        // Serialize transcription to prevent races on previousMicTail/previousSystemTail.
        transcriptionGroup.enter()
        transcriptionQueue.async { [weak self, transcriptionSemaphore, transcriptionGroup] in
            guard let self = self else {
                transcriptionGroup.leave()
                return
            }
            transcriptionSemaphore.wait()
            let task = Task { [weak self, transcriptionGroup] in
                defer {
                    transcriptionSemaphore.signal()
                    transcriptionGroup.leave()
                }
                guard let self = self else { return }

                for piece in ordered {
                    // One piece is copied out at a time and released when it is
                    // done, so a late drain costs its own backlog plus one piece
                    // rather than the backlog twice over.
                    let source = piece.source
                    let spans = source == .mic ? micSpans : systemSpans
                    guard piece.spanIndex < spans.count else { continue }
                    let samples = Array(spans[piece.spanIndex].samples[piece.range])
                    await self.processChunk(
                        samples: samples,
                        startTime: piece.startTime,
                        source: source,
                        previousTail: source == .mic ? self.previousMicTail : self.previousSystemTail,
                        updateTail: { [weak self] tail in
                            if source == .mic {
                                self?.previousMicTail = tail
                            } else {
                                self?.previousSystemTail = tail
                            }
                        }
                    )
                }
            }
            _ = task
        }
    }

    /// What is worth a log line and what is noise.
    ///
    /// The debug log holds a bounded number of entries, so a line per drain would
    /// evict everything else in a long meeting and cost the forensic value that
    /// found these bugs in the first place. These four cases are the ones that
    /// would have made 2026-07-29 obvious within a minute.
    private func noteDrain(mic: Int?, system: Int?, micPieces: Int, systemPieces: Int, isFinal: Bool) {
        drainCount += 1

        if mic != nil { sourcesSeen.insert("mic") }
        if system != nil { sourcesSeen.insert("system") }

        // A channel is only judged once it has proved it can deliver, so a
        // meeting with no system audio at all is not reported as a dead channel.
        var wentQuiet: [AudioStreamSource] = []
        for (label, delivered, source) in [("mic", mic, AudioStreamSource.mic), ("system", system, AudioStreamSource.system)] {
            guard sourcesSeen.contains(label) else { continue }
            if delivered != nil {
                quietDrains[label] = 0
                reportedQuiet.remove(label)
                continue
            }
            let count = (quietDrains[label] ?? 0) + 1
            quietDrains[label] = count
            if count >= Self.quietDrainsBeforeReporting, !reportedQuiet.contains(label) {
                reportedQuiet.insert(label)
                wentQuiet.append(source)
            }
        }

        let deadSource = wentQuiet.isEmpty == false
        let backlogLimit = Int(chunkInterval * 2 * sampleRate)
        let lateDrain = (mic ?? 0) > backlogLimit || (system ?? 0) > backlogLimit

        if onDiagnostic != nil,
           drainCount == 1 || isFinal || lateDrain || deadSource || drainCount % 10 == 0 {
            func seconds(_ count: Int?) -> String {
                guard let count else { return "none" }
                return String(format: "%.1fs", Double(count) / sampleRate)
            }
            var note = "Meeting chunk drain \(drainCount): mic=\(seconds(mic)) system=\(seconds(system)) pieces=\(micPieces + systemPieces)"
            if lateDrain {
                note += ". LATE: more than \(Int(chunkInterval * 2))s of audio had accumulated, so the drain schedule is not keeping up."
            }
            if deadSource {
                note += ". A channel that was delivering audio has stopped: \(wentQuiet.map { $0 == .mic ? "microphone" : "system" }.joined(separator: ", "))."
            }
            if isFinal {
                note += " (final drain)"
            }
            onDiagnostic?(note)
        }

        for source in wentQuiet {
            onSourceWentQuiet?(source)
        }
    }

    private func processChunk(
        samples: [Float],
        startTime: TimeInterval,
        source: AudioStreamSource,
        previousTail: String,
        updateTail: @escaping (String) -> Void
    ) async {
        let endTime = startTime + Double(samples.count) / sampleRate

        bufferLock.lock()
        let index = chunkIndex
        chunkIndex += 1
        bufferLock.unlock()

        // Save chunk audio to disk for crash resilience and optional post-meeting
        // diarization.
        //
        // ATOMICALLY, AND ONLY REPORTED WHEN IT WORKED. This was `try?` with
        // `onChunkSaved` firing regardless, so the session recorded chunks it might
        // later be asked to read back for speaker tagging and which may never have
        // existed. A half-written WAV is also worse than none: it would be read back
        // as truncated audio and silently misalign everything after it.
        let sourceLabel = source == .mic ? "mic" : "system"
        let chunkFile = chunkDirectory.appendingPathComponent("chunk-\(index)-\(sourceLabel).wav")
        do {
            let wavData = try AudioRecorder.serializePlayableArchiveAudioBuffer(samples)
            try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
            try wavData.write(to: chunkFile, options: .atomic)
            // Delivered on the main queue like the segments, so `stop()` can flush
            // both with one barrier and the speaker tagger cannot run before the
            // chunks it needs have been recorded.
            let saved = onChunkSaved
            DispatchQueue.main.async {
                saved?(chunkFile, source, startTime)
            }
        } catch {
            onDiagnostic?("Meeting chunk audio could not be written to \(chunkFile.path): \(error.localizedDescription). The transcript is unaffected; the audio for this chunk is not recoverable.")
        }

        // SILENCE IS DECIDED HERE, so that nil from the model means one thing.
        //
        // The silence gate used to live inside the injected closure, which made a
        // nil result mean either "this was silence, we never asked" or "the model
        // failed", and the pipeline could not tell them apart. That is why a failed
        // chunk vanished: it looked exactly like a pause. The audio is still written
        // above either way, so a silent chunk is still recoverable.
        guard !Self.isEffectivelySilent(samples) else { return }

        var transcribed = await transcribeChunk(samples)
        if transcribed == nil {
            onDiagnostic?("A meeting chunk at \(Int(startTime))s returned nothing from the model. Trying once more.")
            transcribed = await transcribeChunk(samples)
        }

        guard let rawText = transcribed else {
            // A GAP MUST NOT READ LIKE A PAUSE.
            //
            // Marked only when the audio was loud enough to have been somebody
            // speaking. A meeting is full of quiet non-speech, typing and rustling,
            // and marking all of it would make the marker mean nothing, which is
            // how a warning stops being read.
            guard Self.isLoudEnoughToMarkAsMissing(samples) else { return }
            onDiagnostic?("A meeting chunk at \(Int(startTime))s could not be transcribed after a retry. Marked in the transcript.")
            let marker = ChunkedTranscriptResult(
                source: source,
                startTime: startTime,
                endTime: endTime,
                text: "[audio not transcribed]"
            )
            let deliver = onSegmentTranscribed
            DispatchQueue.main.async {
                deliver?(marker)
            }
            return
        }
        let cleaned = SpeechTranscriber.removeArtifacts(from: rawText)
        guard !cleaned.isEmpty else { return }

        // Deduplicate overlap with previous chunk.
        let deduped = deduplicateOverlap(previous: previousTail, current: cleaned)
        guard !deduped.isEmpty else { return }

        // Update tail for next chunk's dedup.
        let words = deduped.split(separator: " ")
        let tail = words.suffix(10).joined(separator: " ")
        updateTail(tail)

        let result = ChunkedTranscriptResult(
            source: source,
            startTime: startTime,
            endTime: endTime,
            text: deduped
        )

        // Handed to the main queue rather than AWAITED on it.
        //
        // This used to be `await MainActor.run { ... }`, inside the region that
        // serialises transcription, so a busy main actor stopped the pipeline
        // dead: chunk N held the transcription semaphore until the main thread
        // was free, and chunks N+1 onward queued behind it. Moving the drain off
        // the run loop fixed the SCHEDULE and left that second coupling in place,
        // which a test with the main thread blocked found immediately: the
        // pipeline completed exactly one chunk.
        //
        // `DispatchQueue.main.async` keeps the documented contract (the callback
        // still arrives on the main queue) and keeps segments in order, because
        // the main queue is FIFO and these are enqueued from the serialised
        // region. It just no longer makes transcription wait for the UI.
        let deliver = onSegmentTranscribed
        DispatchQueue.main.async {
            deliver?(result)
        }
    }

    /// Remove overlapping text between the tail of the previous chunk and the head of the current chunk.
    private func deduplicateOverlap(previous: String, current: String) -> String {
        guard !previous.isEmpty else { return current }

        let prevWords = previous.lowercased().split(separator: " ")
        let currWords = current.split(separator: " ")
        let currWordsLower = currWords.map { $0.lowercased() }

        // Try matching the last N words of previous with the first N words of current.
        let maxOverlap = min(prevWords.count, currWordsLower.count, 8)

        for overlapLen in stride(from: maxOverlap, through: 2, by: -1) {
            let prevTail = prevWords.suffix(overlapLen)
            let currHead = currWordsLower.prefix(overlapLen)

            if Array(prevTail) == Array(currHead).map({ Substring($0) }) {
                // Found overlap — remove the duplicate head from current.
                let remaining = currWords.dropFirst(overlapLen)
                return remaining.joined(separator: " ")
            }
        }

        return current
    }
}
