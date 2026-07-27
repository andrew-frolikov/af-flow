import XCTest
@testable import GhostPepper

/// Without headphones, Andrew's microphone hears his speakers, so everything the
/// far side says is captured twice: once correctly as "Others", and once
/// attributed to HIM. The second copy is not merely duplication, it is wrong
/// about who spoke.
///
/// The fixtures below are his real first two-channel recording, verbatim.
final class MeetingEchoFilterTests: XCTestCase {

    private func segment(
        _ text: String,
        speaker: SpeakerLabel,
        start: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(),
            speaker: speaker,
            startTime: start,
            endTime: start + 30,
            text: text
        )
    }

    /// His real transcript. The two channels heard the same video and differ in
    /// punctuation, in one word ("брызу" against "брынзу"), and by a trailing
    /// English fragment the microphone picked up. A comparison that demanded
    /// exact text would catch none of this.
    private let heardByMicrophone = "Ребята, как дела? Отлично. Кого-то будете благодарить? Мы выражаем благодарность народному депутату Украины Дмитрию Голубову. Но он нам сказал, если вы не выиграете, то я вам яйца. Творог, брызу, яблоки. Больше в дорогу никогда не передам. I'm going to go."
    private let heardBySystemAudio = "Ребята, как дела? Отлично. Кого-то будете благодарить? Мы выражаем благодарность народному депутату Украины Дмитрию Голубову. Но он нам сказал, если вы не выиграете, то я вам яйца. Творог, брынзу, яблоки. Больше в дорогу никогда не передам."

    func testMicrophoneBleedOfTheOtherChannelIsDropped() {
        let system = segment(heardBySystemAudio, speaker: .remote(name: nil), start: 30)
        let mic = segment(heardByMicrophone, speaker: .me, start: 30)

        XCTAssertTrue(
            MeetingEchoFilter.isEcho(candidate: mic, against: [system]),
            "This is his real recording. The same sentence appeared twice, and the microphone copy claimed he said it."
        )
    }

    /// The clean source must never be removed in favour of a microphone copy.
    func testTheSystemCopyIsNeverTreatedAsTheEcho() {
        let mic = segment(heardByMicrophone, speaker: .me, start: 30)
        let system = segment(heardBySystemAudio, speaker: .remote(name: nil), start: 30)

        XCTAssertFalse(
            MeetingEchoFilter.isEcho(candidate: system, against: [mic]),
            "Dropping the system copy would delete the far side of the call and keep the muffled version."
        )
    }

    /// Dropping something he really said is worse than leaving a duplicate, so
    /// these are the tests that matter most.
    func testHisOwnDistinctSpeechSurvives() {
        let system = segment(heardBySystemAudio, speaker: .remote(name: nil), start: 30)
        let his = segment(
            "хорошо это я сейчас и это мой голос сейчас будем включать youtube",
            speaker: .me,
            start: 0
        )

        XCTAssertFalse(
            MeetingEchoFilter.isEcho(candidate: his, against: [system]),
            "That is his own sentence from his real recording and must never be dropped."
        )
    }

    func testTheSameWordsFarApartInTimeAreNotAnEcho() {
        let system = segment(heardBySystemAudio, speaker: .remote(name: nil), start: 30)
        let muchLater = segment(heardByMicrophone, speaker: .me, start: 30 + MeetingEchoFilter.matchWindow + 60)

        XCTAssertFalse(
            MeetingEchoFilter.isEcho(candidate: muchLater, against: [system]),
            "Repeating a point minutes later is a person talking, not an echo."
        )
    }

    /// Short utterances collide by accident and must never be dropped.
    func testShortAgreementsAreNeverTreatedAsEchoes() {
        let system = segment("Yes, absolutely.", speaker: .remote(name: nil), start: 10)
        let mic = segment("Yes, absolutely.", speaker: .me, start: 10)

        XCTAssertFalse(
            MeetingEchoFilter.isEcho(candidate: mic, against: [system]),
            "Two people agreeing is the most ordinary thing in a meeting. Dropping his 'yes' would be silently editing him out."
        )
    }

    func testTalkingAboutTheSameTopicIsNotAnEcho() {
        let system = segment(
            "We should ship the pricing page before the end of the quarter, probably next week.",
            speaker: .remote(name: nil),
            start: 30
        )
        let mic = segment(
            "I agree about the pricing page, but I would rather wait until the quarter closes.",
            speaker: .me,
            start: 35
        )

        XCTAssertFalse(
            MeetingEchoFilter.isEcho(candidate: mic, against: [system]),
            "He is responding, not echoing. Shared vocabulary is not the same speech."
        )
    }

    func testWithHeadphonesNothingIsDropped() {
        // No bleed: only the system channel has the far side.
        let system = segment(heardBySystemAudio, speaker: .remote(name: nil), start: 30)
        let his = segment("Right, that makes sense to me, let us do that.", speaker: .me, start: 60)

        XCTAssertFalse(MeetingEchoFilter.isEcho(candidate: his, against: [system]))
    }

    func testSimilarityIgnoresPunctuationAndCase() {
        let lhs = MeetingEchoFilter.normalizedWords("Hello, THERE! How are you?")
        let rhs = MeetingEchoFilter.normalizedWords("hello there how are you")
        XCTAssertEqual(MeetingEchoFilter.similarity(lhs, rhs), 1.0, accuracy: 0.0001)
    }
}
