import XCTest
@testable import GhostPepper

final class MeetingWindowHeuristicsTests: XCTestCase {
    func testBestAutoUpdateTitleIgnoresTitlesFromDifferentAppBundle() {
        XCTAssertNil(
            MeetingWindowHeuristics.bestAutoUpdateTitle(
                in: ["AF Flow Settings"],
                appName: "Zoom",
                observedBundleIdentifier: "com.github.matthartman.ghostpepper",
                monitoredBundleIdentifier: "us.zoom.xos"
            )
        )
    }

    func testBestMeetingTitlePrefersNamedZoomMeetingOverUtilityWindows() {
        XCTAssertEqual(
            MeetingWindowHeuristics.bestMeetingTitle(
                in: ["Settings", "Zoom Meeting", "Team Weekly Standup - Zoom"],
                appName: "Zoom"
            ),
            "Team Weekly Standup"
        )
    }

    func testZoomMeetingStillAppearsActiveForGenericMeetingWindow() {
        XCTAssertTrue(
            MeetingWindowHeuristics.indicatesActiveMeeting(
                in: ["Zoom Meeting", "Settings"],
                appName: "Zoom"
            )
        )
    }

    func testZoomMeetingAppearsEndedWhenOnlyUtilityWindowsRemain() {
        XCTAssertFalse(
            MeetingWindowHeuristics.indicatesActiveMeeting(
                in: ["Settings", "Home", "Zoom Workplace"],
                appName: "Zoom"
            )
        )
    }
}

/// A REGRESSION I INTRODUCED ON 2026-07-27, which ended a real meeting of his
/// after 76 seconds.
///
/// The window-title check moved from every 5 seconds to every 60 seconds, and in
/// the same edit its threshold moved from two consecutive misses to one. Two
/// strikes at 5 seconds was about ten seconds of tolerance. One strike at 60
/// seconds is none, so a single failed Accessibility read of Zoom's window tree
/// ends the recording. His log for 2026-07-29: meeting started 10:03:49,
/// auto-stopped 10:05:05.
///
/// Changing an interval and a threshold together changes the thing they jointly
/// control, and I reasoned about only one of them.
final class MeetingAutoStopToleranceTests: XCTestCase {

    func testOneBadWindowReadDoesNotEndTheMeeting() {
        XCTAssertFalse(
            MeetingSession.shouldAutomaticallyStop(afterConsecutiveInactivePolls: 1),
            "One failed read of Zoom's window titles ended his meeting after 76 seconds."
        )
    }

    func testTwoConsecutiveBadReadsDoEndTheMeeting() {
        XCTAssertTrue(
            MeetingSession.shouldAutomaticallyStop(afterConsecutiveInactivePolls: 2),
            "A call that really has ended must still stop, or the app records and transcribes over nothing."
        )
    }

    func testZeroMissesNeverEndsTheMeeting() {
        XCTAssertFalse(MeetingSession.shouldAutomaticallyStop(afterConsecutiveInactivePolls: 0))
    }

    // 2026-08-19. His 10:03 Zoom was cut off after 2 minutes 13 seconds, and the
    // trace is exact: started 09:03:13, poll at 09:04:13 failed, poll at 09:05:13
    // failed, auto-stopped 09:05:26.
    //
    // The polls did not fail because the meeting had ended. They failed because
    // `AccessibilityWindowTitles.all` asks the Accessibility API for Zoom's
    // window titles and returns `[]` when the call itself fails — and AF Flow's
    // Accessibility grant has been broken since the 2026-08-10 install
    // (`AXError -25204` on every query). An empty list from a broken API is
    // indistinguishable, to the caller, from "Zoom has no meeting window".
    //
    // ABSENCE OF EVIDENCE IS NOT EVIDENCE OF ABSENCE. A signal the app cannot
    // read must not end a recording he is still in. The same shape killed his
    // 10:03 meeting on 2026-07-29 after 76 seconds, recorded in the comment above
    // `shouldAutomaticallyStop`.
    // A window can legitimately have no title. An Accessibility call that FAILS
    // is a different thing, and conflating them put the 2026-08-19 auto-stop bug
    // one layer below where it was first fixed.
    func testAWindowWithNoTitleIsNotAReadFailure() {
        XCTAssertFalse(AccessibilityWindowTitles.isReadFailure(.success))
        XCTAssertFalse(AccessibilityWindowTitles.isReadFailure(.attributeUnsupported))
        XCTAssertFalse(AccessibilityWindowTitles.isReadFailure(.noValue))
    }

    func testABrokenAccessibilityGrantIsAReadFailure() {
        XCTAssertTrue(
            AccessibilityWindowTitles.isReadFailure(.cannotComplete),
            "AXError -25204, which is what his broken grant returned on every query since 2026-08-10."
        )
        XCTAssertTrue(AccessibilityWindowTitles.isReadFailure(.apiDisabled))
        XCTAssertTrue(AccessibilityWindowTitles.isReadFailure(.invalidUIElement))
        XCTAssertTrue(AccessibilityWindowTitles.isReadFailure(.notImplemented))
    }

    func testAVisibleMeetingWindowWinsEvenIfAnotherWindowFailedToRead() {
        XCTAssertEqual(
            MeetingSession.classify(titles: ["Zoom Meeting"], failed: true, appName: "Zoom"),
            .active,
            "A meeting window we can see means the call is running. One unreadable sibling window changes nothing."
        )
    }

    func testAPartialFailureWithNoMeetingWindowIsUnreadableNotInactive() {
        XCTAssertEqual(
            MeetingSession.classify(titles: ["Settings"], failed: true, appName: "Zoom"),
            .unreadable
        )
    }

    func testACleanReadWithNoMeetingWindowIsInactive() {
        XCTAssertEqual(
            MeetingSession.classify(titles: ["Settings"], failed: false, appName: "Zoom"),
            .inactive
        )
    }

    func testAnUnreadableWindowListDoesNotCountAgainstTheMeeting() {
        XCTAssertEqual(
            MeetingSession.nextInactivePollCount(current: 1, reading: .unreadable),
            1,
            "A failed Accessibility read tells us nothing about whether he is still in the call."
        )
    }

    func testAWindowListReadSuccessfullyWithNoMeetingWindowDoesCount() {
        XCTAssertEqual(
            MeetingSession.nextInactivePollCount(current: 1, reading: .inactive),
            2,
            "Reading Zoom's windows and finding no meeting is real evidence the call ended."
        )
    }

    func testSeeingAnActiveMeetingClearsTheStrikes() {
        XCTAssertEqual(MeetingSession.nextInactivePollCount(current: 1, reading: .active), 0)
    }

    func testAnUnreadableListCanNeverAccumulateToAStop() {
        var polls = 0
        for _ in 0..<50 {
            polls = MeetingSession.nextInactivePollCount(current: polls, reading: .unreadable)
        }

        XCTAssertFalse(
            MeetingSession.shouldAutomaticallyStop(afterConsecutiveInactivePolls: polls),
            "Fifty minutes of a broken Accessibility grant must not end a meeting he is still in."
        )
    }
}

/// SPEAKER TAGGING MUST NEVER DELETE WORDS SOMEBODY SAID.
///
/// `transcriptSegments(byApplyingRemoteSpeakerTags:to:)` kept only the segments
/// that already had a name, then added whatever the tagger returned. So every
/// unnamed Others segment was thrown away on the assumption that the tagged result
/// replaced all of them. When the tagger covers only part of the meeting, which is
/// the normal case for a diarizer that ran out of evidence, the rest of the far
/// side's words are simply gone from his record. Bug 7 of sixteen.
@MainActor
final class RemoteSpeakerTaggingSafetyTests: XCTestCase {

    private func segment(_ speaker: SpeakerLabel, _ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), speaker: speaker, startTime: start, endTime: end, text: text)
    }

    private func tagged(_ name: String, _ text: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerTaggedTranscript.Segment {
        SpeakerTaggedTranscript.Segment(
            speakerID: name,
            startTime: start,
            endTime: end,
            text: text,
            attribution: SpeakerTaggedTranscript.Attribution(
                speakerID: name,
                displayName: name,
                confidence: 0.9,
                evidenceDuration: end - start,
                source: .diarization
            )
        )
    }

    func testAPartialTaggingResultDoesNotDeleteTheUntaggedRemainder() {
        let original = [
            segment(.me, "my bit", 0, 10),
            segment(.remote(name: nil), "the first thing they said", 10, 20),
            segment(.remote(name: nil), "the second thing they said", 30, 40),
        ]
        // The tagger only managed the first of the two remote segments.
        let result = MeetingSession.transcriptSegments(
            byApplyingRemoteSpeakerTags: SpeakerTaggedTranscript(segments: [tagged("Maya", "the first thing they said", 10, 20)]),
            to: original
        )

        let text = result.map(\.text).joined(separator: " | ")
        XCTAssertTrue(
            text.contains("the second thing they said"),
            "Tagging deleted a segment it had no replacement for. What survived: \(text)"
        )
        XCTAssertTrue(text.contains("my bit"))
        XCTAssertTrue(text.contains("the first thing they said"))
    }

    /// THE CASE THE FIRST FIX STILL GOT WRONG.
    ///
    /// Codex found it: removing on ANY overlap meant a thirty-second unnamed segment
    /// the tagger managed one second of lost the other twenty-nine. Partial coverage
    /// must keep the original, even at the price of a visible duplicate.
    func testATagCoveringOnlyPartOfASegmentDoesNotDeleteTheRest() {
        let original = [
            segment(.remote(name: nil), "a long stretch of things they said over thirty seconds", 0, 30),
        ]
        let result = MeetingSession.transcriptSegments(
            byApplyingRemoteSpeakerTags: SpeakerTaggedTranscript(segments: [tagged("Maya", "things they said", 0, 1)]),
            to: original
        )

        let text = result.map(\.text).joined(separator: " | ")
        XCTAssertTrue(
            text.contains("a long stretch of things they said over thirty seconds"),
            "One second of tagging deleted a thirty-second segment. What survived: \(text)"
        )
    }

    func testCoverageIsMeasuredWithoutDoubleCountingOverlappingTags() {
        let segment = TranscriptSegment(
            id: UUID(),
            speaker: .remote(name: nil),
            startTime: 0,
            endTime: 10,
            text: "ten seconds"
        )
        // Two tags that overlap each other cover 5 seconds between them, not 8.
        XCTAssertFalse(
            MeetingSession.isFullyReplaced(segment, by: [(0, 4), (1, 5)]),
            "overlapping tags were counted twice, which would delete a segment they do not cover"
        )
        XCTAssertTrue(MeetingSession.isFullyReplaced(segment, by: [(0, 5), (5, 10)]))
    }

    /// And the point of the feature must still work: where the tagger DID produce a
    /// name, the untagged copy of that same moment must not be left behind as a
    /// duplicate.
    func testTheTaggedSegmentReplacesTheUntaggedCopyOfTheSameMoment() {
        let original = [
            segment(.remote(name: nil), "hello there", 10, 20),
        ]
        let result = MeetingSession.transcriptSegments(
            byApplyingRemoteSpeakerTags: SpeakerTaggedTranscript(segments: [tagged("Maya", "hello there", 10, 20)]),
            to: original
        )

        XCTAssertEqual(result.count, 1, "the same moment must not appear twice")
        XCTAssertEqual(result.first?.speaker, .remote(name: "Maya"))
    }

    /// An empty result changes nothing, which was already true and is worth pinning.
    func testAnEmptyTaggingResultLeavesTheTranscriptAlone() {
        let original = [segment(.remote(name: nil), "they said this", 0, 5)]
        let result = MeetingSession.transcriptSegments(
            byApplyingRemoteSpeakerTags: SpeakerTaggedTranscript(segments: []),
            to: original
        )
        XCTAssertEqual(result.map(\.text), ["they said this"])
    }

    /// A transcript that can never be written must say so while he can still act.
    ///
    /// `autoSave` caught the error and printed it, so recording continued happily
    /// with every save failing and nothing on screen. He would find out when he went
    /// looking for the file. Bug 6 of sixteen.
    func testASessionThatCannotSaveItsTranscriptSaysSo() async {
        let session = MeetingSession(
            meetingName: "Nowhere to write",
            transcriber: SpeechTranscriber(modelManager: ModelManager()),
            // A path under an existing FILE, so no directory can be created here.
            saveDirectory: URL(fileURLWithPath: "/etc/hosts/af-flow-cannot-save-here"),
            captureStartOverride: {}
        )

        try? await session.start()
        let message = session.saveFailureMessage
        await session.stop()

        XCTAssertNotNil(
            message,
            "The transcript could not be written and the session reported nothing, so he would record a whole meeting into nowhere."
        )
        XCTAssertNil(session.fileURL, "and it must not claim a file it does not have")
    }

    /// And the message must reach the view, and must clear when saving works again.
    ///
    /// Round two of the review caught `captureDegradedMessage` being set since
    /// 2026-07-27 while nothing read it. The same trap applies here, so this observes
    /// through the tab the window actually watches rather than through the session.
    func testTheSaveFailureReachesTheTabAndClearsWhenSavingWorks() async throws {
        let session = MeetingSession(
            meetingName: "Nowhere then somewhere",
            transcriber: SpeechTranscriber(modelManager: ModelManager()),
            saveDirectory: URL(fileURLWithPath: "/etc/hosts/af-flow-cannot-save-here"),
            captureStartOverride: {}
        )
        let tab = OpenMeetingTab(transcript: session.transcript, session: session)

        try? await session.start()
        XCTAssertNotNil(
            tab.saveFailureMessage,
            "the failure never reached the tab the meeting window observes, so no banner could ever appear"
        )

        await session.stop()
    }

    func testTheSaveFailureIsAbsentWhenSavingWorks() async throws {
        let session = MeetingSession(
            meetingName: "Somewhere writable",
            transcriber: SpeechTranscriber(modelManager: ModelManager()),
            saveDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("GhostPepperTests-\(UUID().uuidString)"),
            captureStartOverride: {}
        )
        let tab = OpenMeetingTab(transcript: session.transcript, session: session)

        try await session.start()
        XCTAssertNil(tab.saveFailureMessage, "a working save must not raise a warning")
        XCTAssertNotNil(session.fileURL)

        await session.stop()
    }
}
