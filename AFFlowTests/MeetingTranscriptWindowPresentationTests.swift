import AppKit
import XCTest
@testable import AFFlow

final class MeetingTranscriptWindowPresentationTests: XCTestCase {

    /// HE COULD NOT SEE THE FACE OF THE PERSON HE WAS TALKING TO.
    ///
    /// Starting a meeting from the menu called `NSApp.activate(ignoringOtherApps:)`
    /// and `makeKeyAndOrderFront`, which pulls AF Flow in front of Zoom, and the
    /// window is 960 points wide and the full height of the screen, and floating was
    /// on by default so it stayed above the call. Bug 11 of sixteen.
    ///
    /// Opening the window because a recording started is not a request to look at it.
    func testStartingARecordingDoesNotStealFocusFromTheCall() {
        XCTAssertFalse(
            MeetingTranscriptWindowPresentation.shouldActivateApp(for: .recordingStarted),
            "Starting a recording pulled AF Flow in front of his video call."
        )
    }

    /// But when he opens the window himself, it must come to the front. A window that
    /// will not show itself when asked is a worse bug than the one above.
    func testOpeningTheWindowHimselfDoesBringItToTheFront() {
        XCTAssertTrue(MeetingTranscriptWindowPresentation.shouldActivateApp(for: .userOpened))
        XCTAssertTrue(MeetingTranscriptWindowPresentation.shouldOrderAboveOtherApps(for: .userOpened))
    }

    /// THE HALF OF BUG 11 THE FIRST FIX MISSED.
    ///
    /// Not activating the app stopped the keyboard being stolen and did nothing about the
    /// covering, because `orderFrontRegardless()` is documented to place an inactive
    /// app's window in front of the active app's window. So the 960-point full-height
    /// window still sat over Zoom and he still could not see the face of the person he
    /// was talking to. Codex caught it.
    func testStartingARecordingDoesNotPutTheWindowOverTheCall() {
        XCTAssertFalse(
            MeetingTranscriptWindowPresentation.shouldOrderAboveOtherApps(for: .recordingStarted),
            "The window was still ordered above his call, which is the actual complaint."
        )
    }

    /// The prune only ever deletes directories it created.
    func testPruningOnlyRecognisesItsOwnDirectories() {
        XCTAssertTrue(MeetingAudioStore.isOwnRecordingDirectory("meeting-\(UUID().uuidString)"))
        XCTAssertFalse(MeetingAudioStore.isOwnRecordingDirectory("meeting-not-a-uuid"))
        XCTAssertFalse(MeetingAudioStore.isOwnRecordingDirectory("Documents"))
        XCTAssertFalse(MeetingAudioStore.isOwnRecordingDirectory(""))
    }

    /// And it must not float over the call unless he asks for that.
    func testFloatingOverTheCallIsNotTheDefault() {
        XCTAssertFalse(
            MeetingTranscriptWindowPresentation.floatsWhileRecordingDefault,
            "A full-height window floating above everything is what covered his call."
        )
    }

    /// THE SUMMARY PRINTED ITS OWN INSTRUCTIONS INTO HIS TRANSCRIPT.
    ///
    /// "Part 2" of the summary in `Meetings/2026-07-29/zoom-10-21-am.md` is the
    /// summarisation prompt, word for word, starting "Extract only what was decided".
    /// `runLLM` concatenated the prompt onto the front of the transcript and passed
    /// the whole thing as the text to CLEAN UP, with the prompt argument nil. So the
    /// model was told to tidy up a block of text that began with instructions, and it
    /// did exactly that. The 0.8B model was not imitating a shape; it was obeying.
    /// Bug 13 of sixteen.
    func testTheSummaryPromptIsSentAsThePromptAndNotAsTheTextToCleanUp() {
        let prompt = "Extract only what was decided, agreed, or committed to in this meeting excerpt."
        let transcript = "Meeting transcript:\n\n[00:00] Me: we agreed to ship on Friday"

        let request = MeetingSummaryGenerator.cleanupRequest(input: transcript, prompt: prompt)

        XCTAssertEqual(request.prompt, prompt, "the instructions belong in the prompt")
        XCTAssertEqual(request.text, transcript, "and the text must be only the transcript")
        XCTAssertFalse(
            request.text.contains(prompt),
            "The instructions were inside the text to clean up, which is why they came back as his summary."
        )
    }

    /// And the two defaults for the stored summary prompt must agree.
    ///
    /// `AppState` defaulted the `meetingSummaryPrompt` key to the CHUNK prompt while
    /// the meeting window defaulted the same key to the FINAL prompt, so which text he
    /// saw in the editor depended on which object read the key first. The key is
    /// passed as the final prompt, so the final prompt is what it defaults to.
    func testTheStoredSummaryPromptDefaultsToTheFinalPrompt() {
        XCTAssertEqual(
            MeetingSummaryGenerator.storedSummaryPromptDefault,
            MeetingSummaryGenerator.finalSummaryPrompt
        )
        XCTAssertNotEqual(
            MeetingSummaryGenerator.defaultPrompt,
            MeetingSummaryGenerator.finalSummaryPrompt,
            "these are two genuinely different prompts, which is what made one key holding either of them a bug"
        )
    }

    /// MEETING AUDIO MUST OUTLIVE THE TEMP FOLDER.
    ///
    /// Chunk WAVs went to `FileManager.default.temporaryDirectory`, which macOS can
    /// clear whenever it likes. That is why the 51-minute recording of 2026-07-29 had
    /// to be copied out by hand before it disappeared. Andrew chose durable storage
    /// with a 7-day retention on 2026-07-29.
    func testMeetingAudioIsNotStoredInTheTemporaryDirectory() {
        let directory = MeetingAudioStore.chunkDirectory(forSession: UUID())
        XCTAssertFalse(
            directory.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "meeting audio is still somewhere macOS can delete: \(directory.path)"
        )
        XCTAssertTrue(directory.path.contains("Application Support"))
        XCTAssertTrue(directory.lastPathComponent == "chunks")
    }

    func testPruningKeepsRecentRecordingsAndDeletesOldOnes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AFFlowTests-\(UUID().uuidString)")
        // Named the way production names them, because the prune now refuses to delete
        // anything that is not a "meeting-<uuid>" directory it created.
        let recent = root.appendingPathComponent("meeting-\(UUID().uuidString)")
        let old = root.appendingPathComponent("meeting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: recent.appendingPathComponent("chunk-0-mic.wav"))
        try Data([1, 2, 3]).write(to: old.appendingPathComponent("chunk-0-mic.wav"))
        // Backdate the old one past the retention window.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: old.path
        )

        MeetingAudioStore.pruneRecordings(olderThan: 7, in: root)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recent.path),
            "a recording from this week was deleted, which is the whole point of keeping it"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: old.path),
            "a recording older than the retention window was kept, so the folder grows without limit"
        )

        try? FileManager.default.removeItem(at: root)
    }

    func testTheRetentionWindowIsTheOneHeChose() {
        XCTAssertEqual(MeetingAudioStore.retentionDays, 7)
    }

    func testWindowStaysNormalWhenFloatingPreferenceIsDisabled() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.windowLevel(
                shouldFloatWhileRecording: false,
                hasActiveRecording: true
            ),
            .normal
        )
    }

    func testWindowFloatsWhenRecordingAndFloatingPreferenceIsEnabled() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.windowLevel(
                shouldFloatWhileRecording: true,
                hasActiveRecording: true
            ),
            .floating
        )
    }

    func testWindowReturnsToNormalWhenNoMeetingIsRecording() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.windowLevel(
                shouldFloatWhileRecording: true,
                hasActiveRecording: false
            ),
            .normal
        )
    }
}

@MainActor
final class MeetingWindowStateRecordingRequestTests: XCTestCase {
    private let skipConsentKey = "skipConsentDialog"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(false, forKey: skipConsentKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: skipConsentKey)
        super.tearDown()
    }

    func testAdHocMeetingDoesNotReuseCanceledCalendarEvent() {
        let state = MeetingWindowState()
        let event = CalendarEvent(
            id: "calendar-1",
            title: "Scheduled Call",
            startTime: "10:00 AM",
            startDate: nil,
            endDate: nil,
            isAllDay: false,
            attendees: [MeetingAttendee(name: "Alice Example")],
            attendeeCount: 1,
            organizer: nil,
            meetLink: nil
        )

        state.startCalendarMeeting(event)
        XCTAssertEqual(state.pendingCalendarEvent?.id, "calendar-1")

        state.cancelRecording()
        state.startAdHocCall()

        XCTAssertNil(state.pendingCalendarEvent)
        XCTAssertNil(state.pendingSourceURL)
        XCTAssertNil(state.pendingDetectedMeeting)
        XCTAssertTrue(state.pendingRecordingName?.hasPrefix("Ad Hoc Meeting") == true)
        XCTAssertTrue(state.showConsentDialog)
    }

    func testNewRecordingRequestClearsPreviousPendingContext() {
        let state = MeetingWindowState()
        state.pendingRecordingName = "Old"
        state.pendingSourceURL = "https://meet.example/old"
        state.pendingCalendarEvent = CalendarEvent(
            id: "old-event",
            title: "Old Calendar Event",
            startTime: "9:00 AM",
            startDate: nil,
            endDate: nil,
            isAllDay: false,
            attendees: [],
            attendeeCount: 0,
            organizer: nil,
            meetLink: nil
        )

        state.requestRecording(name: "Fresh Ad Hoc Meeting")

        XCTAssertEqual(state.pendingRecordingName, "Fresh Ad Hoc Meeting")
        XCTAssertNil(state.pendingSourceURL)
        XCTAssertNil(state.pendingDetectedMeeting)
        XCTAssertNil(state.pendingCalendarEvent)
    }

    func testConfirmRecordingKeepsConsentOpenWhenStartupFails() {
        let state = MeetingWindowState()
        state.onStartRecording = { _, _ in
            throw MeetingRecordingStartError.unavailable("Screen Recording permission is required.")
        }

        state.requestRecording(name: "Scheduled Meeting")
        state.confirmRecording()

        XCTAssertTrue(state.showConsentDialog)
        XCTAssertEqual(state.pendingRecordingName, "Scheduled Meeting")
        XCTAssertEqual(state.recordingStartError, "Screen Recording permission is required.")
        XCTAssertTrue(state.tabs.isEmpty)
    }

    func testSkipConsentStartupFailureOpensConsentWithError() {
        UserDefaults.standard.set(true, forKey: skipConsentKey)

        let state = MeetingWindowState()
        state.onStartRecording = { _, _ in
            throw MeetingRecordingStartError.unavailable("Speech model is still loading.")
        }

        state.requestRecording(name: "Ad Hoc Meeting", skipConsent: true)

        XCTAssertTrue(state.showConsentDialog)
        XCTAssertEqual(state.pendingRecordingName, "Ad Hoc Meeting")
        XCTAssertEqual(state.recordingStartError, "Speech model is still loading.")
        XCTAssertTrue(state.tabs.isEmpty)
    }
}

@MainActor
final class MeetingTranscriptSpeakerLabelTests: XCTestCase {
    func testReplaceSpeakerDisplayNameUpdatesMatchingRemoteSegmentsOnly() {
        let transcript = MeetingTranscript(meetingName: "Speaker Review")
        transcript.segments = [
            TranscriptSegment(
                id: UUID(),
                speaker: .remote(name: "Speaker 1"),
                startTime: 0,
                endTime: 1,
                text: "First turn"
            ),
            TranscriptSegment(
                id: UUID(),
                speaker: .remote(name: "Speaker 2"),
                startTime: 2,
                endTime: 3,
                text: "Second turn"
            ),
            TranscriptSegment(
                id: UUID(),
                speaker: .me,
                startTime: 4,
                endTime: 5,
                text: "Mic turn"
            )
        ]

        transcript.replaceSpeakerDisplayName("Speaker 1", with: "Alice Example")

        XCTAssertEqual(transcript.segments[0].speaker, .remote(name: "Alice Example"))
        XCTAssertEqual(transcript.segments[1].speaker, .remote(name: "Speaker 2"))
        XCTAssertEqual(transcript.segments[2].speaker, .me)
    }
}

@MainActor
final class CommandKSearchRankingTests: XCTestCase {
    func testTitleMatchesRankAboveWikiBodyMatches() {
        let root = URL(fileURLWithPath: "/tmp/CommandKSearchRankingTests")
        let directMatch = GeneratedWikiSidebarItem(
            title: "Example Contact",
            type: "person",
            fileURL: root.appendingPathComponent("example-contact.md")
        )
        let bodyOnlyMatch = GeneratedWikiSidebarItem(
            title: "Reference Note",
            type: "person",
            fileURL: root.appendingPathComponent("reference-note.md")
        )

        let results = CommandKResults.compute(
            haystack: [
                CommandKHaystackEntry(
                    title: bodyOnlyMatch.title,
                    titleLower: bodyOnlyMatch.title.lowercased(),
                    subtitle: "People",
                    contentLower: "worked with example on matrix diligence.",
                    dateFolderLower: "",
                    id: "wiki-\(bodyOnlyMatch.fileURL.path)",
                    kind: .wiki(bodyOnlyMatch, folderTitle: "People")
                ),
                CommandKHaystackEntry(
                    title: directMatch.title,
                    titleLower: directMatch.title.lowercased(),
                    subtitle: "People",
                    contentLower: "",
                    dateFolderLower: "",
                    id: "wiki-\(directMatch.fileURL.path)",
                    kind: .wiki(directMatch, folderTitle: "People")
                )
            ],
            query: "example"
        )

        XCTAssertEqual(results.wiki.map(\.title), ["Example Contact", "Reference Note"])
        XCTAssertEqual(results.wiki.last?.subtitle, "People • content match")
    }
}

@MainActor
final class MeetingMarkdownWriterParsingTests: XCTestCase {
    func testParsePreservesGranolaSpeakerLabelsAndContinuationLines() throws {
        let fileURL = try writeMarkdown(
            """
            # Imported Meeting

            ## Transcript

            **Alice Example:** We should preserve the speaker.
            This wrapped line is still Alice.

            **Bob Example:** Agreed on the next step.
            """
        )

        let transcript = try MeetingMarkdownWriter.parse(from: fileURL)

        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].speaker, .remote(name: "Alice Example"))
        XCTAssertEqual(
            transcript.segments[0].text,
            "We should preserve the speaker.\nThis wrapped line is still Alice."
        )
        XCTAssertEqual(transcript.segments[1].speaker, .remote(name: "Bob Example"))
        XCTAssertEqual(transcript.segments[1].text, "Agreed on the next step.")
    }

    func testParsePreservesPlainAndTimestampedSpeakerLabels() throws {
        let fileURL = try writeMarkdown(
            """
            # Timestamped Meeting

            ## Transcript

            [00:12] Me: I opened the discussion.
            [00:17] Alpha Person: Then Alpha replied.
            **[01:02] Others:** The room responded.
            Facilitator: Final plain speaker line.
            """
        )

        let transcript = try MeetingMarkdownWriter.parse(from: fileURL)

        XCTAssertEqual(transcript.segments.count, 4)
        XCTAssertEqual(transcript.segments[0].speaker, .me)
        XCTAssertEqual(transcript.segments[0].startTime, 12)
        XCTAssertEqual(transcript.segments[1].speaker, .remote(name: "Alpha Person"))
        XCTAssertEqual(transcript.segments[1].startTime, 17)
        XCTAssertEqual(transcript.segments[2].speaker, .remote(name: nil))
        XCTAssertEqual(transcript.segments[2].startTime, 62)
        XCTAssertEqual(transcript.segments[3].speaker, .remote(name: "Facilitator"))
        XCTAssertEqual(transcript.segments[3].text, "Final plain speaker line.")
    }

    func testParseRestoresGranolaFrontmatterDateAndAttendees() throws {
        let fileURL = try writeMarkdown(
            """
            ---
            title: "Imported Meeting"
            date: "2026-07-16T14:30:00.000Z"
            attendees: ["Alice Example", "Bob, Jr.", "Casey \\\"CJ\\\" Stone"]
            imported_from: granola
            ---

            # Imported Meeting

            ## Transcript

            **Alice Example:** We should preserve metadata.
            """
        )

        let transcript = try MeetingMarkdownWriter.parse(from: fileURL)

        XCTAssertEqual(transcript.importedFrom, "granola")
        XCTAssertEqual(
            transcript.attendees.map(\.name),
            ["Alice Example", "Bob, Jr.", "Casey \"CJ\" Stone"]
        )
        XCTAssertEqual(
            Int(transcript.startDate.timeIntervalSince1970),
            Int(ISO8601DateFormatter().date(from: "2026-07-16T14:30:00Z")!.timeIntervalSince1970)
        )
    }

    func testParseRestoresVisibleAttendeesLine() throws {
        let fileURL = try writeMarkdown(
            """
            # Imported Meeting

            **Attendees:** Alice Example, Bob Example

            ## Transcript

            **Alice Example:** We should preserve attendee names.
            """
        )

        let transcript = try MeetingMarkdownWriter.parse(from: fileURL)

        XCTAssertEqual(transcript.attendees.map(\.name), ["Alice Example", "Bob Example"])
    }

    private func writeMarkdown(_ markdown: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AFFlowMeetingMarkdownWriterTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("meeting.md")
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}

final class GranolaImporterTranscriptExtractionTests: XCTestCase {
    func testExtractTranscriptPreservesTimestampsAndNestedSpeakers() {
        let transcriptData: [Any] = [
            [
                "start_time": 12.8,
                "speaker": ["name": "Alice Example"],
                "text": "First speaker turn."
            ],
            [
                "timestamp_ms": 62_000,
                "participant": ["displayName": "Bob Example"],
                "content": "Second speaker turn."
            ]
        ]

        let markdown = GranolaImporter.extractTranscript(from: transcriptData)

        XCTAssertEqual(
            markdown,
            """
            **[00:12] Alice Example:** First speaker turn.

            **[01:02] Bob Example:** Second speaker turn.
            """
        )
    }

    func testExtractTranscriptFallsBackToSpeakerIDsAndWordLists() {
        let transcriptData: [Any] = [
            [
                "speaker_id": "1",
                "start": "00:03",
                "words": [
                    ["word": "Hello"],
                    ["text": "there"]
                ]
            ]
        ]

        let markdown = GranolaImporter.extractTranscript(from: transcriptData)

        XCTAssertEqual(markdown, "**[00:03] Speaker 1:** Hello there")
    }
}

@MainActor
final class MeetingSessionSpeakerTaggingTests: XCTestCase {
    func testApplyingRemoteSpeakerTagsReplacesGenericRemoteSegmentsAndKeepsMicSegments() {
        let originalSegments = [
            TranscriptSegment(
                id: UUID(),
                speaker: .me,
                startTime: 0,
                endTime: 30,
                text: "Mic side"
            ),
            TranscriptSegment(
                id: UUID(),
                speaker: .remote(name: nil),
                startTime: 0,
                endTime: 30,
                text: "Generic remote side"
            )
        ]
        let taggedTranscript = SpeakerTaggedTranscript(
            segments: [
                SpeakerTaggedTranscript.Segment(
                    speakerID: "Speaker 0",
                    startTime: 1,
                    endTime: 4,
                    text: "Remote speaker one"
                ),
                SpeakerTaggedTranscript.Segment(
                    speakerID: "Speaker 1",
                    startTime: 5,
                    endTime: 8,
                    text: "Remote speaker two"
                )
            ]
        )

        let updated = MeetingSession.transcriptSegments(
            byApplyingRemoteSpeakerTags: taggedTranscript,
            to: originalSegments
        )

        // THIS TEST USED TO ASSERT THE DATA LOSS, and it is corrected here rather
        // than worked around.
        //
        // It expected 3 segments: the 30-second "Generic remote side" DELETED and
        // replaced by two 3-second tagged fragments. The tags cover 6 seconds of 30,
        // so the assertion was that 22 seconds of the far side's words should
        // disappear from his record. A passing test was pinning the bug, which is why
        // bug 7 of 2026-07-29 survived a suite of 534 tests.
        //
        // The rule now: a segment is removed only when the tagged output accounts for
        // nearly all of it. Partial coverage keeps the original alongside the tagged
        // fragments, because a visible duplicate is recoverable and a deletion is not.
        XCTAssertEqual(updated.count, 4)
        let texts = Set(updated.map(\.text))
        XCTAssertTrue(texts.contains("Mic side"))
        XCTAssertTrue(
            texts.contains("Generic remote side"),
            "the untagged remainder of the far side was deleted again"
        )
        XCTAssertTrue(texts.contains("Remote speaker one"))
        XCTAssertTrue(texts.contains("Remote speaker two"))
        let speakers = updated.map(\.speaker)
        XCTAssertTrue(speakers.contains(.me))
        XCTAssertTrue(speakers.contains(.remote(name: nil)))
        XCTAssertTrue(speakers.contains(.remote(name: "Speaker 1")))
        XCTAssertTrue(speakers.contains(.remote(name: "Speaker 2")))
    }

    func testApplyingRemoteSpeakerTagsUsesSavedDisplayNameWhenPresent() {
        let taggedTranscript = SpeakerTaggedTranscript(
            segments: [
                SpeakerTaggedTranscript.Segment(
                    speakerID: "Speaker 0",
                    startTime: 0,
                    endTime: 2,
                    text: "Known voice",
                    attribution: SpeakerTaggedTranscript.Attribution(
                        speakerID: "Speaker 0",
                        recognizedVoiceID: UUID(),
                        displayName: "Alice Example",
                        confidence: 0.9,
                        evidenceDuration: 2,
                        source: .diarization
                    )
                ),
                SpeakerTaggedTranscript.Segment(
                    speakerID: "Speaker 1",
                    startTime: 3,
                    endTime: 4,
                    text: "Unlabeled voice",
                    attribution: SpeakerTaggedTranscript.Attribution(
                        speakerID: "Speaker 1",
                        recognizedVoiceID: UUID(),
                        displayName: "Recognized Voice 4",
                        confidence: 0.9,
                        evidenceDuration: 1,
                        source: .diarization
                    )
                )
            ]
        )

        let updated = MeetingSession.transcriptSegments(
            byApplyingRemoteSpeakerTags: taggedTranscript,
            to: []
        )

        XCTAssertEqual(updated.map(\.speaker), [
            .remote(name: "Alice Example"),
            .remote(name: "Speaker 1")
        ])
    }
}
