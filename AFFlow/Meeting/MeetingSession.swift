import AppKit
import Foundation

/// Where a meeting's chunk audio lives, and how long it stays.
///
/// It used to live in `FileManager.default.temporaryDirectory`, which macOS clears
/// whenever it likes. That is why the 51-minute recording of 2026-07-29 had to be
/// copied out by hand before it vanished, and why a meeting interrupted by a crash
/// or a force quit was unrecoverable.
///
/// Andrew chose durable storage with a 7-day retention on 2026-07-29. Two-channel
/// meeting audio is roughly 230 MB an hour, so a week is the trade he picked between
/// being able to recover a meeting and letting the disk fill up quietly.
enum MeetingAudioStore {
    static let retentionDays = 7

    static var root: URL {
        return AppSupportDirectory.url
            .appendingPathComponent("meeting-audio")
    }

    static func chunkDirectory(forSession sessionID: UUID) -> URL {
        root
            .appendingPathComponent("meeting-\(sessionID.uuidString)")
            .appendingPathComponent("chunks")
    }

    /// Whether a directory name is one this store created, and may therefore delete.
    ///
    /// Checked rather than assumed, because this function calls `removeItem` in a loop.
    /// A prune that trusts whatever it finds is one symlink or one stray folder away
    /// from deleting something that is not its own.
    static func isOwnRecordingDirectory(_ name: String) -> Bool {
        guard name.hasPrefix("meeting-") else { return false }
        return UUID(uuidString: String(name.dropFirst("meeting-".count))) != nil
    }

    /// Deletes recordings older than the retention window. Called at launch, off the
    /// main thread.
    static func pruneRecordings(olderThan days: Int = retentionDays, in directory: URL = root) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in entries {
            guard isOwnRecordingDirectory(entry.lastPathComponent) else { continue }
            guard let values = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
            ) else {
                continue
            }
            // A symlink is never followed and never deleted: following one would take
            // this loop outside its own directory.
            guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
            guard let modified = values.contentModificationDate, modified < cutoff else { continue }

            do {
                try FileManager.default.removeItem(at: entry)
                print("MeetingAudioStore: pruned \(entry.lastPathComponent), older than \(days) days")
            } catch {
                print("MeetingAudioStore: could not prune \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}

/// Orchestrates a single meeting transcription session.
/// Owns DualStreamCapture + ChunkedTranscriptionPipeline + MeetingTranscript.
@MainActor
final class MeetingSession: ObservableObject {
    typealias CaptureStartOverride = @MainActor () async throws -> Void
    typealias RemoteSpeakerTagger = (_ sessionID: UUID, _ audioBuffer: [Float]) async -> SpeakerTaggedTranscript?

    private struct SavedChunkRecord {
        let url: URL
        let source: AudioStreamSource
        /// When this chunk's audio was captured, in seconds since the meeting
        /// started. Used to be derived from the chunk's ordinal times a fixed 30
        /// seconds, which assumed a drain schedule that on 2026-07-29 fired once
        /// in 51 minutes.
        let startTime: TimeInterval
    }

    @Published var isActive = false
    @Published private(set) var isStarting = false
    @Published private(set) var isDraining = false
    @Published var fileURL: URL?
    @Published var noAudioDetected = false
    /// Set when the "Others" channel stops mid-meeting, for example because the
    /// output device changed. The microphone keeps recording, so the meeting
    /// continues in a degraded state, and the UI can say which.
    @Published var captureDegradedMessage: String?

    /// Set when the transcript file cannot be written. A recording whose transcript
    /// can never be saved must say so while he can still do something about it.
    @Published var saveFailureMessage: String?
    @Published private(set) var isTaggingRemoteSpeakers = false

    @Published var transcript: MeetingTranscript

    var onAutoStopRequested: ((MeetingSession) -> Void)?

    /// Whether this session has already been written out and summarised.
    ///
    /// More than one finalisation path calls into the same code, and on 2026-07-29
    /// both ran for one stop: his log records "auto-stopped" and "stopped" in the same
    /// second and then two summaries, at 11:12:59 and 11:13:08, with six cleanup-model
    /// calls between them. Bug 12 of sixteen.
    private(set) var isFinalised = false

    /// Claims the finalisation. Returns false if it has already been claimed, so the
    /// second caller does nothing rather than summarising, logging, notifying and
    /// re-indexing the same meeting again.
    ///
    /// Safe without a lock because every caller is on the main actor, and the check
    /// and the set happen together with no await between them.
    func markFinalised() -> Bool {
        guard !isFinalised else { return false }
        isFinalised = true
        return true
    }

    /// Carries the pipeline's own account of what it is doing into the app's
    /// debug log. On 2026-07-29 the drain schedule failed silently for 51
    /// minutes; the log is the only place that could have said so.
    var onDiagnostic: ((String) -> Void)?

    private let capture: any MeetingAudioCapturing
    private var pipeline: ChunkedTranscriptionPipeline?
    private let transcriber: SpeechTranscriber
    private let saveDirectory: URL
    private let detectedMeetingAppName: String?
    private let detectedMeetingBundleIdentifier: String?
    private let remoteSpeakerTagger: RemoteSpeakerTagger?

    /// How often to auto-save the markdown file (matches chunk interval).
    private var silenceCheckTimer: Timer?
    private var meetingEndCheckTimer: Timer?
    private var appTerminationObserver: NSObjectProtocol?

    deinit {
        // The run loop retains a repeating Timer and NotificationCenter retains
        // a block observer until each is explicitly removed, so a session that
        // is dropped without a normal or automatic stop would keep both alive
        // and keep firing against a dead meeting.
        //
        // `deinit` on a @MainActor class is nonisolated and runs on whichever
        // thread drops the last reference, so the teardown is hopped to main
        // rather than touching Timer and NSWorkspace from an arbitrary one.
        let timer = meetingEndCheckTimer
        let observer = appTerminationObserver
        let silenceTimer = silenceCheckTimer
        Task { @MainActor in
            timer?.invalidate()
            silenceTimer?.invalidate()
            if let observer {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
        }
    }
    private var savedChunkRecords: [SavedChunkRecord] = []
    private var hasReceivedAudio = false
    private var hasAutoUpdatedTitle = false
    private var skipCalendarAutoMatch = false
    private let originalName: String
    private let ocrService: FrontmostWindowOCRService
    private let captureStartOverride: CaptureStartOverride?
    private var inactiveMeetingPollCount = 0
    private var consecutiveUnreadableWindowPolls = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopRequested = false

    init(
        meetingName: String,
        detectedMeeting: DetectedMeeting? = nil,
        transcriber: SpeechTranscriber,
        saveDirectory: URL,
        ocrService: FrontmostWindowOCRService = FrontmostWindowOCRService(),
        captureStartOverride: CaptureStartOverride? = nil,
        remoteSpeakerTagger: RemoteSpeakerTagger? = nil,
        capture: any MeetingAudioCapturing = DualStreamCapture()
    ) {
        self.transcript = MeetingTranscript(meetingName: meetingName)
        self.transcriber = transcriber
        self.saveDirectory = saveDirectory
        self.originalName = meetingName
        self.ocrService = ocrService
        self.detectedMeetingAppName = detectedMeeting?.appName
        self.detectedMeetingBundleIdentifier = detectedMeeting?.bundleIdentifier
        self.captureStartOverride = captureStartOverride
        self.remoteSpeakerTagger = remoteSpeakerTagger
        self.capture = capture
    }

    /// Start dual-stream capture and chunked transcription.
    func start() async throws {
        guard !isActive, !isDraining, !isStarting, !stopRequested else { return }
        isStarting = true
        defer {
            isStarting = false
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        let chunkDir = MeetingAudioStore.chunkDirectory(forSession: transcript.sessionID)

        let newPipeline = ChunkedTranscriptionPipeline(
            transcriber: transcriber,
            chunkDirectory: chunkDir
        )

        newPipeline.onSegmentTranscribed = { [weak self] result in
            guard let self = self else { return }
            let speaker: SpeakerLabel = result.source == .mic ? .me : .remote(name: nil)
            let segment = TranscriptSegment(
                id: UUID(),
                speaker: speaker,
                startTime: result.startTime,
                endTime: result.endTime,
                text: result.text
            )
            // Drop microphone bleed rather than recording it as him.
            //
            // Without headphones his mic hears his speakers, so everything the
            // far side says arrives twice: once correctly as Others, and once
            // attributed to HIM. The second copy is not merely duplication, it
            // is wrong about who spoke.
            if MeetingEchoFilter.isEcho(candidate: segment, against: self.transcript.segments) {
                print("MeetingSession: dropped a microphone echo of the other channel")
                return
            }

            self.transcript.appendSegment(segment)
            self.autoSave()
        }

        // Called on the main queue by the pipeline, in order, and flushed by its
        // `stop()`. It used to hop through a detached Task, which is not ordered
        // against the segment deliveries and could still have been pending when
        // the speaker tagger asked for the chunks.
        newPipeline.onChunkSaved = { [weak self] url, source, startTime in
            self?.recordSavedChunk(url: url, source: source, startTime: startTime)
        }

        newPipeline.onDiagnostic = { [weak self] note in
            Task { @MainActor [weak self] in
                self?.onDiagnostic?(note)
                print("MeetingSession: \(note)")
            }
        }

        // A channel that dies mid-meeting is now said out loud.
        //
        // On 2026-07-29 his microphone stopped delivering audio 32 minutes into a
        // 51-minute call and the app carried on as though it were recording. The
        // system channel had `onCaptureInterrupted` for this; the microphone had
        // nothing, and the only silence check covers the first ten seconds.
        newPipeline.onSourceWentQuiet = { [weak self] source in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                let message = source == .mic
                    ? "Your microphone stopped sending audio. The other side is still being recorded."
                    : "The Others channel stopped sending audio. Your microphone is still being recorded."
                self.captureDegradedMessage = message
                self.onDiagnostic?("Meeting capture degraded: \(message)")
                print("MeetingSession: capture degraded: \(message)")
            }
        }

        capture.onCaptureDegraded = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.captureDegradedMessage = message
                print("MeetingSession: capture degraded: \(message)")
            }
        }

        capture.onAudioChunk = { [weak self, weak newPipeline] chunk in
            newPipeline?.appendAudio(chunk)
            if let self = self, !self.hasReceivedAudio {
                // Check if chunk has actual audio (not silence)
                let rms = sqrt(chunk.samples.map { $0 * $0 }.reduce(0, +) / max(Float(chunk.samples.count), 1))
                if rms > 0.001 {
                    Task { @MainActor in
                        self.hasReceivedAudio = true
                        self.noAudioDetected = false
                        self.silenceCheckTimer?.invalidate()
                    }
                }
            }
        }

        pipeline = newPipeline

        if let captureStartOverride {
            try await captureStartOverride()
        } else {
            try await capture.start()
        }
        newPipeline.start()
        isActive = true

        // Initial save creates the file immediately.
        autoSave()

        // Check for silence after 10 seconds — if no audio detected, warn the user.
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isActive, !self.hasReceivedAudio else { return }
                self.noAudioDetected = true
                print("MeetingSession: no audio detected after 10 seconds")
            }
        }

        // Check Google Calendar for current meeting (if connected)
        Task {
            await populateFromCalendar()
        }

        // Title refresh, once, shortly after the call starts.
        //
        // This used to run four times over the first minute and also call
        // `captureAttendees()`, which OCRs the meeting window through
        // `WindowCaptureService`. That service is permanently stubbed to return
        // nil, because reading the screen would need the screen-capture
        // permission this app does not take. So the attendee passes were pure
        // cost with a guaranteed nil result, four times a meeting, and they are
        // gone rather than retried.
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.autoUpdateTitleFromDetectedMeetingApp()
            }
        }

        startMeetingEndMonitorIfNeeded()

        print("MeetingSession: started '\(transcript.meetingName)'")
    }

    /// Stop capture, process remaining audio, finalize transcript.
    func stop() async {
        if isDraining {
            await withCheckedContinuation { continuation in
                stopWaiters.append(continuation)
            }
            return
        }

        guard isActive || isStarting || pipeline != nil else {
            stopRequested = true
            return
        }
        if isStarting {
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
            guard !isDraining, isActive || pipeline != nil else { return }
        }

        isDraining = true
        isActive = false
        defer {
            isDraining = false
            let waiters = stopWaiters
            stopWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        _ = await capture.stop()
        await pipeline?.stop()

        await applyRemoteSpeakerTaggingIfAvailable()

        transcript.endDate = Date()

        // Final save with end date.
        autoSave()

        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil
        meetingEndCheckTimer?.invalidate()
        meetingEndCheckTimer = nil
        if let appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
        }
        appTerminationObserver = nil
        inactiveMeetingPollCount = 0

        print("MeetingSession: stopped '\(transcript.meetingName)': \(transcript.segments.count) segments, \(transcript.formattedDuration)")
    }

    private func recordSavedChunk(url: URL, source: AudioStreamSource, startTime: TimeInterval) {
        savedChunkRecords.append(SavedChunkRecord(url: url, source: source, startTime: startTime))
    }

    private func applyRemoteSpeakerTaggingIfAvailable() async {
        guard let remoteSpeakerTagger,
              let systemAudioBuffer = timelineAlignedAudioBuffer(for: .system),
              systemAudioBuffer.isEmpty == false else {
            return
        }

        isTaggingRemoteSpeakers = true
        defer { isTaggingRemoteSpeakers = false }

        guard let speakerTaggedTranscript = await remoteSpeakerTagger(
            transcript.sessionID,
            systemAudioBuffer
        ) else {
            return
        }

        let updatedSegments = Self.transcriptSegments(
            byApplyingRemoteSpeakerTags: speakerTaggedTranscript,
            to: transcript.segments
        )
        guard Self.segmentsDiffer(updatedSegments, transcript.segments) else {
            return
        }

        transcript.segments = updatedSegments
        autoSave()
    }

    private func timelineAlignedAudioBuffer(for source: AudioStreamSource) -> [Float]? {
        let records = savedChunkRecords
            .filter { $0.source == source }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.url.path < rhs.url.path
                }
                return lhs.startTime < rhs.startTime
            }
        guard records.isEmpty == false else {
            return nil
        }

        var output: [Float] = []
        for record in records {
            guard let data = try? Data(contentsOf: record.url),
                  let samples = try? AudioRecorder.deserializeArchivedAudioBuffer(from: data),
                  samples.isEmpty == false else {
                continue
            }

            // Align on the capture time the chunk actually carries. Chunks now
            // overlap by a second and a late drain can produce several at once,
            // so ordinal times a fixed interval no longer describes where any of
            // them sit on the timeline.
            let startIndex = max(0, Int((record.startTime * Self.sampleRate).rounded(.down)))
            if output.count < startIndex {
                output.append(contentsOf: repeatElement(Float.zero, count: startIndex - output.count))
            }
            if startIndex < output.count {
                // Overlapping chunk: keep what is already there and append only
                // the part that extends the timeline, so a word is not doubled in
                // the buffer the speaker tagger sees.
                let alreadyCovered = output.count - startIndex
                guard alreadyCovered < samples.count else { continue }
                output.append(contentsOf: samples[alreadyCovered...])
            } else {
                output.append(contentsOf: samples)
            }
        }

        return output.isEmpty ? nil : output
    }

    static func transcriptSegments(
        byApplyingRemoteSpeakerTags speakerTaggedTranscript: SpeakerTaggedTranscript,
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let taggedSegments = remoteTranscriptSegments(from: speakerTaggedTranscript)
        guard taggedSegments.isEmpty == false else {
            return segments
        }

        // A SEGMENT IS ONLY REMOVED IF SOMETHING REPLACES IT.
        //
        // This used to drop every unnamed Others segment and add whatever the
        // tagger returned, on the assumption that the tagged result covered all of
        // them. When the tagger covers only part of a meeting, which is the normal
        // outcome for a diarizer that ran out of evidence, the rest of the far
        // side's words were deleted from his record with no warning and no way to
        // get them back. A transcript with an unnamed speaker is worth far more
        // than no transcript.
        // AND ONLY IF THE REPLACEMENT COVERS THE WHOLE OF IT.
        //
        // Removing on any overlap at all was still wrong, and Codex caught that too:
        // a thirty-second unnamed segment that the tagger managed one second of would
        // have lost the other twenty-nine. So an original is dropped only when the
        // tagged segments account for nearly all of its duration.
        //
        // The cost of this rule is a possible duplicate when coverage is partial: the
        // original stays and the tagged fragment is added beside it. That is the right
        // way round for this project. `MeetingEchoFilter` is built to under-remove for
        // the same reason, and a duplicated line is something he can see and delete,
        // while a deleted line is something he cannot know was ever there.
        let replacedRanges = taggedSegments.map { ($0.startTime, max($0.endTime, $0.startTime)) }
        let survivingSegments = segments.filter { segment in
            switch segment.speaker {
            case .remote(let name):
                guard name == nil else { return true }
                return Self.isFullyReplaced(segment, by: replacedRanges) == false
            case .me:
                return true
            }
        }

        return (survivingSegments + taggedSegments).sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.endTime < rhs.endTime
            }
            return lhs.startTime < rhs.startTime
        }
    }

    /// Whether tagged output accounts for essentially all of an original segment.
    ///
    /// Ninety per cent, not all of it, because a diarizer's boundaries are its own
    /// estimate and will not line up to the millisecond with the chunk boundaries
    /// these segments came from. Anything less covered than this keeps the original.
    nonisolated static func isFullyReplaced(
        _ segment: TranscriptSegment,
        by replacedRanges: [(TimeInterval, TimeInterval)]
    ) -> Bool {
        let duration = segment.endTime - segment.startTime
        guard duration > 0 else {
            // A zero-length segment is replaced if anything covers its instant.
            return replacedRanges.contains { start, end in
                segment.startTime >= start && segment.startTime <= end
            }
        }

        // Merge the overlapping parts of the replacement ranges before measuring, or
        // two overlapping tagged segments would each be counted in full.
        let clipped = replacedRanges
            .map { (max($0.0, segment.startTime), min($0.1, segment.endTime)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }

        var covered: TimeInterval = 0
        var cursor: TimeInterval = segment.startTime
        for (start, end) in clipped {
            let from = max(start, cursor)
            guard end > from else { continue }
            covered += end - from
            cursor = end
        }

        return covered >= duration * 0.9
    }

    private static func remoteTranscriptSegments(from speakerTaggedTranscript: SpeakerTaggedTranscript) -> [TranscriptSegment] {
        var speakerLabelsByID: [String: String] = [:]
        var orderedSpeakerIDs: [String] = []

        func fallbackLabel(for speakerID: String) -> String {
            if let existing = speakerLabelsByID[speakerID] {
                return existing
            }
            orderedSpeakerIDs.append(speakerID)
            let label = "Speaker \(orderedSpeakerIDs.count)"
            speakerLabelsByID[speakerID] = label
            return label
        }

        return speakerTaggedTranscript.segments.compactMap { segment in
            let text = SpeechTranscriber.removeArtifacts(from: segment.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else {
                return nil
            }

            let displayName = usableDisplayName(from: segment.attribution.displayName)
                ?? fallbackLabel(for: segment.speakerID)
            return TranscriptSegment(
                id: UUID(),
                speaker: .remote(name: displayName),
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: text
            )
        }
    }

    private static func usableDisplayName(from displayName: String?) -> String? {
        guard let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              displayName.isEmpty == false else {
            return nil
        }
        return displayName.hasPrefix("Recognized Voice ") ? nil : displayName
    }

    private static func segmentsDiffer(_ lhs: [TranscriptSegment], _ rhs: [TranscriptSegment]) -> Bool {
        guard lhs.count == rhs.count else {
            return true
        }
        return zip(lhs, rhs).contains { lhs, rhs in
            lhs.speaker != rhs.speaker ||
                abs(lhs.startTime - rhs.startTime) > 0.0001 ||
                abs(lhs.endTime - rhs.endTime) > 0.0001 ||
                lhs.text != rhs.text
        }
    }

    private static let sampleRate: Double = 16_000

    /// Elapsed time since meeting started.
    var elapsed: TimeInterval {
        capture.elapsed
    }

    // MARK: - Auto-update title

    /// Known meeting app bundle IDs to scan when no specific app was detected.
    /// Native meeting apps are checked first, browsers last (to avoid grabbing Slack tabs etc.)
    private static let nativeMeetingAppBundleIDs = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp",
    ]

    private static let browserBundleIDs = [
        "com.brave.Browser",
        "com.google.Chrome",
        "company.thebrowser.Browser",  // Arc
        "com.apple.Safari",
        "org.mozilla.firefox",
    ]

    /// Try to update the meeting title from the detected meeting app,
    /// or by scanning known meeting apps if none was detected.
    private func autoUpdateTitleFromDetectedMeetingApp() {
        guard !hasAutoUpdatedTitle, isActive else { return }
        // Only update if user hasn't edited the name
        guard transcript.meetingName == originalName else { return }

        // Try the detected app first, then fall back to scanning known meeting apps
        let appsToCheck: [(app: NSRunningApplication, name: String)]
        if let detectedMeetingBundleIdentifier,
           let detectedMeetingAppName,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: detectedMeetingBundleIdentifier).first {
            appsToCheck = [(app, detectedMeetingAppName)]
        } else {
            appsToCheck = (Self.nativeMeetingAppBundleIDs + Self.browserBundleIDs).compactMap { bundleID in
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
                return (app, app.localizedName ?? "Meeting")
            }
        }

        for (meetingApp, appName) in appsToCheck {
            let titles = AccessibilityWindowTitles.all(for: meetingApp)
            if let cleaned = MeetingWindowHeuristics.bestAutoUpdateTitle(
                in: titles,
                appName: appName,
                observedBundleIdentifier: meetingApp.bundleIdentifier,
                monitoredBundleIdentifier: meetingApp.bundleIdentifier
            ) {
                hasAutoUpdatedTitle = true
                transcript.meetingName = cleaned
                print("MeetingSession: auto-updated title to '\(cleaned)' from \(appName)")
                autoSave()
                return
            }
        }
    }

    // MARK: - Calendar integration

    /// Apply a user-chosen calendar event: lock the title and attendees, and skip
    /// the time-based auto-match so we don't override their explicit choice.
    func applyCalendarEvent(_ event: CalendarEvent) {
        skipCalendarAutoMatch = true
        hasAutoUpdatedTitle = true
        if !event.attendees.isEmpty {
            transcript.attendees = event.attendees
        }
        autoSave()
        let declinedCount = event.attendees.filter { $0.declined }.count
        print("MeetingSession: applied user-chosen calendar event '\(event.title)' (\(event.attendees.count) attendees, \(declinedCount) declined)")
    }

    /// Calendar auto-match is removed. This used to reach
    /// `GoogleCalendarService.shared` on every meeting start, which is a live
    /// cloud client that makes real `URLSession` requests, so a code path that
    /// begins every recording by calling out to Google is exactly what
    /// CLAUDE.md hard rule 1 forbids.
    ///
    /// Codex round 8 found this while the sweep reported clean, because the
    /// gate only matched construction with parentheses and this is singleton
    /// access. The gate now matches the service identifier itself.
    ///
    /// The `CalendarEvent` struct it returned is left alone deliberately: it is
    /// a plain `Codable` value type with no networking, and the UI still passes
    /// it around. Banning a data struct would be theatre. Banning the object
    /// that owns the URLSession is the control that does real work.
    private func populateFromCalendar() async {
        return
    }

    /// Manually trigger title detection and attendee capture.
    /// Briefly activates the meeting app so OCR captures its window, not AF Flow's.
    func refreshTitleAndAttendees() {
        // Reset the flag so title detection retries
        hasAutoUpdatedTitle = false
        autoUpdateTitleFromDetectedMeetingApp()

        // Find the meeting app to bring to front for OCR.
        // Priority: detected app > native meeting apps > browsers > frontmost app.
        let meetingApp: NSRunningApplication? = {
            if let bundleID = detectedMeetingBundleIdentifier {
                return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            }
            // Check native meeting apps first (Zoom, Teams, FaceTime, Webex)
            for bundleID in Self.nativeMeetingAppBundleIDs {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    return app
                }
            }
            // Fall back to browsers (for Google Meet, Zoom Web)
            for bundleID in Self.browserBundleIDs {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    return app
                }
            }
            return nil
        }()

        Task {
            // The attendee half is deliberately gone.
            //
            // It used to steal focus with `activateIgnoringOtherApps`, sleep
            // 800 ms, OCR the meeting window, then yank focus back. That OCR
            // runs through `WindowCaptureService`, which is permanently stubbed
            // because reading the screen needs a permission this app does not
            // take, so the whole sequence interrupted whatever he was doing to
            // obtain a guaranteed nil. The title refresh below needs no focus
            // change at all.
            _ = meetingApp
        }
    }

    // MARK: - Attendee capture

    /// OCR the meeting window to extract participant names.
    /// Retries will merge new names with existing ones (people join late).
    private func captureAttendees() async {
        guard isActive else { return }

        guard let context = await ocrService.captureContext(customWords: []) else {
            print("MeetingSession: attendee OCR returned no context")
            return
        }
        let text = context.windowContents
        print("MeetingSession: attendee OCR captured \(text.count) chars from window")
        print("MeetingSession: OCR text preview: \(String(text.prefix(300)))")

        let names = Self.extractAttendeeNames(from: text)
        print("MeetingSession: extracted \(names.count) names: \(names)")
        guard !names.isEmpty else { return }

        // Merge with existing attendees (preserving order, no duplicates by name).
        // OCR-detected attendees default to declined=false; if the same name was already
        // added (declined or not) from calendar, keep the calendar version.
        let existingNames = Set(transcript.attendees.map { $0.name })
        let newAttendees = names.filter { !existingNames.contains($0) }.map { MeetingAttendee(name: $0) }
        if !newAttendees.isEmpty {
            transcript.attendees.append(contentsOf: newAttendees)
            print("MeetingSession: captured attendees: \(transcript.attendees.map { $0.name }.joined(separator: ", "))")
            autoSave()
        }
    }

    /// Parse attendee names from OCR text of a meeting window.
    /// Zoom shows names as labels on video tiles, Teams shows them in participant panels.
    /// Heuristic: look for lines that look like person names (2-3 capitalized words, no special chars).
    static func extractAttendeeNames(from ocrText: String) -> [String] {
        let lines = ocrText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var names: [String] = []
        let namePattern = /^[A-Z][a-zA-Z'-]+(?:\s[A-Z][a-zA-Z'-]+){0,3}$/

        // Words that indicate a line is UI text, not a person's name
        let uiWords: Set<String> = [
            "mute", "unmute", "share", "screen", "chat", "record", "recording",
            "participants", "leave", "end", "meeting", "settings", "audio",
            "video", "gallery", "speaker", "view", "reactions", "more",
            "invite", "security", "breakout", "rooms", "host", "co-host",
            "waiting", "room", "zoom", "teams", "join", "start", "stop",
            "raise", "hand", "rename", "remove", "admit", "close", "minimize",
        ]

        for line in lines {
            // Strip parenthesized suffixes: pronouns, (You), (Host), etc.
            var candidate = line
            while let range = candidate.range(of: #"\s*\([^)]*\)"#, options: .regularExpression) {
                candidate.removeSubrange(range)
            }
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip single words (likely UI elements)
            let words = candidate.split(separator: " ")
            guard words.count >= 2, words.count <= 4 else { continue }

            // Skip lines with UI keywords
            let lower = candidate.lowercased()
            if uiWords.contains(where: { lower.contains($0) }) { continue }

            // Skip lines with numbers, special chars (timestamps, IDs, etc.)
            if candidate.contains(where: { $0.isNumber }) { continue }
            if candidate.contains("@") || candidate.contains("http") || candidate.contains("://") { continue }

            // Match name pattern: capitalized words
            if candidate.wholeMatch(of: namePattern) != nil {
                if !candidate.isEmpty && !names.contains(candidate) {
                    names.append(candidate)
                }
            }
        }

        return names
    }

    // MARK: - Auto-save

    private func autoSave() {
        do {
            let url = try MeetingMarkdownWriter.write(
                transcript: transcript,
                to: saveDirectory,
                existingFileURL: fileURL
            )
            if fileURL == nil {
                fileURL = url
                print("MeetingSession: transcript file created at \(url.path)")
            }
            saveFailureMessage = nil
        } catch {
            // SAID OUT LOUD, not printed to a console nobody is watching.
            //
            // This used to `print` and carry on, so a meeting could record for an
            // hour with every single save failing and nothing on screen to suggest
            // the transcript was never going to exist. He would find out when he
            // went looking for the file. Bug 6 of sixteen.
            let message = "The transcript could not be saved to \(saveDirectory.path): \(error.localizedDescription)"
            saveFailureMessage = message
            onDiagnostic?(message)
            print("MeetingSession: \(message)")
        }
    }

    /// Watches for the call ending, WITHOUT the five-second accessibility walk
    /// this used to run for the whole meeting.
    ///
    /// Codex caught the claim: `startMeetingTranscriptionFromMenu` was
    /// documented as doing detection once on demand, while this timer walked
    /// Zoom's window tree every five seconds behind it. That is the poll Andrew
    /// had removed on 2026-07-27, reintroduced by the feature that promised not
    /// to reintroduce it.
    ///
    /// The app quitting is the signal that actually matters and it arrives as a
    /// notification, so nothing needs polling. A window-title check still runs,
    /// but once a minute rather than twelve times a minute, and only to catch a
    /// call that ended while Zoom stayed open.
    private func startMeetingEndMonitorIfNeeded() {
        guard supportsAutomaticEndDetection else { return }

        meetingEndCheckTimer?.invalidate()
        if let existing = appTerminationObserver {
            // Replacing without removing leaks the previous registration.
            NSWorkspace.shared.notificationCenter.removeObserver(existing)
            appTerminationObserver = nil
        }

        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier
            else { return }

            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                guard bundleID == self.detectedMeetingBundleIdentifier else { return }
                self.requestAutomaticStop(reason: "Zoom is no longer running")
            }
        }

        meetingEndCheckTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForMeetingEnd()
            }
        }
    }

    private var supportsAutomaticEndDetection: Bool {
        detectedMeetingAppName == "Zoom" &&
            (detectedMeetingBundleIdentifier?.hasPrefix("us.zoom.") ?? false)
    }

    /// What one poll of the meeting app's windows actually told us.
    enum MeetingActivityReading: Equatable {
        /// A meeting window is on screen.
        case active
        /// The windows were read and none of them is a meeting.
        case inactive
        /// The Accessibility call failed, so this poll learned nothing.
        case unreadable
    }

    /// The strike count after one poll.
    ///
    /// `unreadable` deliberately leaves the count alone. On 2026-08-19 an
    /// unreadable poll was counted as a strike and his Zoom call was ended after
    /// 2 minutes 13 seconds while he was still in it, because AF Flow's
    /// Accessibility grant had been broken by an install and every read failed.
    /// Turns one poll into a reading. Positive evidence wins.
    ///
    /// Codex, 2026-08-19, P1: classifying ANY partial Accessibility failure as
    /// unreadable threw away a meeting title that had been read perfectly well.
    /// Worse, it left an earlier inactive strike standing, so one later inactive
    /// poll could reach two and stop a live recording on misses that were never
    /// consecutive. If a meeting window is visible, the meeting is running, and
    /// nothing else about the read matters.
    nonisolated static func classify(titles: [String], failed: Bool, appName: String) -> MeetingActivityReading {
        if MeetingWindowHeuristics.indicatesActiveMeeting(in: titles, appName: appName) {
            return .active
        }

        return failed ? .unreadable : .inactive
    }

    nonisolated static func nextInactivePollCount(current: Int, reading: MeetingActivityReading) -> Int {
        switch reading {
        case .active: return 0
        case .inactive: return current + 1
        case .unreadable: return current
        }
    }

    private func checkForMeetingEnd() {
        guard isActive,
              let detectedMeetingAppName,
              let detectedMeetingBundleIdentifier else { return }

        guard let meetingApp = NSRunningApplication.runningApplications(withBundleIdentifier: detectedMeetingBundleIdentifier).first else {
            requestAutomaticStop(reason: "Zoom is no longer running")
            return
        }

        let windows = AccessibilityWindowTitles.reading(for: meetingApp)
        let reading = Self.classify(
            titles: windows.titles,
            failed: windows.failed,
            appName: detectedMeetingAppName
        )

        if reading == .unreadable {
            consecutiveUnreadableWindowPolls += 1
            // Codex round 2, P3: a single failure can be a 0.5 s timeout or a
            // window closing mid-read, and saying "check your permission" on one
            // of those would misdiagnose a healthy grant. Two in a row is a
            // standing condition worth naming, and it is said once per session
            // rather than once a minute.
            if consecutiveUnreadableWindowPolls == 2 {
                onDiagnostic?(
                    "Could not read \(detectedMeetingAppName)'s windows on two checks in a row, so this meeting will not auto-stop on window state. If it keeps happening, check AF Flow's Accessibility permission."
                )
            }
        } else {
            consecutiveUnreadableWindowPolls = 0
        }

        inactiveMeetingPollCount = Self.nextInactivePollCount(
            current: inactiveMeetingPollCount,
            reading: reading
        )
        guard Self.shouldAutomaticallyStop(afterConsecutiveInactivePolls: inactiveMeetingPollCount) else { return }
        requestAutomaticStop(reason: "meeting windows no longer look active")
    }

    /// How many consecutive polls that fail to see an active meeting window it
    /// takes to end the recording.
    ///
    /// TWO, not one, and the reason is a regression I caused on 2026-07-27. The
    /// poll moved from every 5 seconds to every 60 seconds and the threshold
    /// moved from two strikes to one IN THE SAME EDIT, and I justified the
    /// threshold change in terms of the grace period being too long while having
    /// made the interval twelve times longer. At one strike a single failed
    /// Accessibility read of Zoom's window tree ends the recording, which is what
    /// killed his 10:03 meeting after 76 seconds on 2026-07-29.
    ///
    /// Two strikes at 60 seconds is up to two minutes of recording after a call
    /// really has ended. That is the cost, it is paid only when Zoom stays open
    /// after the call, and it is far cheaper than ending a meeting he is still in:
    /// the fast path for a call that is genuinely over is
    /// `didTerminateApplicationNotification`, which needs no polling at all.
    nonisolated static func shouldAutomaticallyStop(afterConsecutiveInactivePolls polls: Int) -> Bool {
        polls >= 2
    }

    private func requestAutomaticStop(reason: String) {
        guard isActive else { return }
        meetingEndCheckTimer?.invalidate()
        meetingEndCheckTimer = nil
        if let appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
        }
        appTerminationObserver = nil
        inactiveMeetingPollCount = 0
        print("MeetingSession: automatic stop requested: \(reason)")
        if let onAutoStopRequested {
            onAutoStopRequested(self)
            return
        }

        Task { @MainActor [weak self] in
            await self?.stop()
        }
    }
}
