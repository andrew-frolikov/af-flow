import XCTest
import WhisperKit
@testable import GhostPepper

/// The 2026-08-05 defect: half a dictation lost, silently.
///
/// He said "I was saying something in Russian and it cut like 30% of my
/// transcript". It was worse than 30%: 43.5 seconds of continuous speech, RMS
/// 500 to 1100 in every 2-second slice with no silence anywhere, produced 193
/// characters ending mid-phrase.
///
/// Two fixes, because they address different things:
///
/// 1. **`chunkingStrategy = .vad`** stops it happening. Chosen by measurement,
///    not taste: across all 39 of his recordings over five seconds, vad was
///    better on one and worse on none, while the other candidate that fixed the
///    same file made a different recording worse.
/// 2. **`looksTruncated`** notices it when it happens anyway. The bug survived
///    because the app reported success — the real defect was the silence, not
///    the loss, and the next cause of truncation will not be this one.
///
/// The fixtures below are his actual recordings from that evening.
final class DictationTruncationTests: XCTestCase {

    // MARK: - The fix

    func testDictationDecodesWithVoiceActivityChunking() {
        let options = ModelManager.applyDictationChunking(to: DecodingOptions())

        XCTAssertEqual(options.chunkingStrategy, .vad)
    }

    /// The language decision happens before chunking is applied and must survive
    /// it. Losing it would reopen the 99-language door that pasted Urdu.
    func testApplyingChunkingKeepsTheChosenLanguage() {
        var incoming = DecodingOptions()
        incoming.language = "ru"

        let options = ModelManager.applyDictationChunking(to: incoming)

        XCTAssertEqual(options.language, "ru")
        XCTAssertEqual(options.chunkingStrategy, .vad)
    }

    // MARK: - Noticing it next time

    /// The recording he lost: 43.5 s, 193 characters, 4.4 per second.
    func testTheRecordingHeLostIsFlagged() {
        XCTAssertTrue(
            SpeechTranscriber.looksTruncated(text: String(repeating: "a", count: 193),
                                             audioDuration: 43.5)
        )
    }

    /// Every healthy recording from the same evening must NOT be flagged, or the
    /// warning becomes noise and gets ignored. These are his real pairs.
    func testHisHealthyDictationsAreNotFlagged() {
        let healthy: [(duration: TimeInterval, characters: Int)] = [
            (74.6, 667),   // Russian, 8.9/s
            (28.8, 314),   // Russian, 10.9/s
            (16.6, 197),   // English, 11.9/s
            (62.3, 443),   // English, 7.1/s
            (28.6, 299),   // English, 10.5/s
            (18.1, 109),   // Russian, 6.0/s — the slowest healthy one he has
            (15.7, 124),   // English, 7.9/s
            (14.8, 152)    // Russian, 10.3/s
        ]

        for row in healthy {
            XCTAssertFalse(
                SpeechTranscriber.looksTruncated(
                    text: String(repeating: "a", count: row.characters),
                    audioDuration: row.duration
                ),
                "\(row.duration)s / \(row.characters) chars is a healthy recording and must not be flagged"
            )
        }
    }

    /// 6.0 per second is his slowest healthy recording and 4.4 is the failure.
    /// The threshold has to sit between them, and this pins that it does rather
    /// than trusting the constant.
    func testTheThresholdSitsBetweenHisSlowestHealthyAndHisFailure() {
        let slowestHealthy = SpeechTranscriber.looksTruncated(
            text: String(repeating: "a", count: 109), audioDuration: 18.1
        )
        let theFailure = SpeechTranscriber.looksTruncated(
            text: String(repeating: "a", count: 193), audioDuration: 43.5
        )

        XCTAssertFalse(slowestHealthy)
        XCTAssertTrue(theFailure)
    }

    /// A short utterance has too much variance to judge. "Yes." is 4 characters
    /// in two seconds and perfectly correct.
    func testShortUtterancesAreNeverFlagged() {
        XCTAssertFalse(SpeechTranscriber.looksTruncated(text: "Yes.", audioDuration: 2.0))
        XCTAssertFalse(SpeechTranscriber.looksTruncated(text: "Okay.", audioDuration: 9.9))
    }

    /// An empty result is the "no text at all" case, which the probe already
    /// reports separately. Flagging it here too would double-count it.
    func testAnEmptyResultIsNotReportedAsTruncation() {
        XCTAssertFalse(SpeechTranscriber.looksTruncated(text: "", audioDuration: 30))
        XCTAssertFalse(SpeechTranscriber.looksTruncated(text: "   ", audioDuration: 30))
    }

    /// A long recording that produced almost nothing is the strongest case.
    func testAVeryLongRecordingWithAlmostNoTextIsFlagged() {
        XCTAssertTrue(
            SpeechTranscriber.looksTruncated(text: String(repeating: "a", count: 40),
                                             audioDuration: 120)
        )
    }
}
