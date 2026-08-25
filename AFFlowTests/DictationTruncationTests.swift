import XCTest
import WhisperKit
@testable import AFFlow

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

    // MARK: - Meeting channels
    //
    // MEASURED 2026-08-21. This guard produced 202 warnings, 192 of them on
    // exactly 30.0-second meeting chunks, and EVERY ONE WAS A FALSE POSITIVE.
    //
    // The proof: all 16 chunks of his 2026-08-19 Zoom were re-decoded from the
    // durable WAVs and totalled 1,349 characters. The transcript AF Flow stored
    // on the day held 1,338. Nothing was lost — 0.8% apart.
    //
    // The arithmetic is what is wrong. A meeting is captured as two channels,
    // and each one is silent whenever the other person is talking. `chunk-0-mic`
    // is 30 seconds of audio holding 7 seconds of speech, and 110 characters of
    // it. Against wall-clock that is 3.7/s and looks like 85% loss; against the
    // speech it actually contains it is about 15/s, which is faster than his
    // healthy range.
    //
    // A warning that fires 202 times without ever being right is worse than no
    // warning, because it trains the reader to skip the line that was supposed
    // to catch real loss. It cost an hour of investigation on 2026-08-21.
    // CODEX, 2026-08-21. The speech denominator fixes meetings and would BREAK
    // dictation: the threshold was calibrated against whole recordings, so
    // dividing by voiced time raises every rate and lets the 2026-08-05 loss
    // through. It applies to background work only.
    func testDictationIsStillJudgedAgainstWallClock() {
        XCTAssertFalse(ModelManager.usesSpeechDurationForTruncation(.dictation))
    }

    func testMeetingChunksAreJudgedAgainstSpeech() {
        XCTAssertTrue(ModelManager.usesSpeechDurationForTruncation(.background))
    }

    /// The concrete case Codex raised: a dictation with pauses must still be
    /// flagged, and would not be if voiced time were the denominator.
    func testAPausedDictationIsStillFlagged() {
        XCTAssertTrue(
            SpeechTranscriber.looksTruncated(
                text: String(repeating: "a", count: 80),
                audioDuration: 20.0,
                speechDuration: nil
            ),
            "80 characters in 20 seconds is 4.0/s and must stay flagged. Against 15 voiced seconds it would read 5.3/s and escape."
        )
    }

    /// HIS REAL CHUNKS, MEASURED. Codex proposed raising the voiced threshold on
    /// the grounds that room tone would still trip three of the four known false
    /// positives. The voiced durations it computed match this code exactly; the
    /// character counts it paired them with did not belong to those chunks. The
    /// 10-character result was `chunk-2-system`, 0.3 s of speech, which Whisper
    /// read as English at 61.4% — what near-silence looks like.
    ///
    /// So the numbers below are the measured pairs from his 2026-08-19 Zoom, at
    /// the shipped `silenceRMSThreshold` of 0.001, with the character counts each
    /// chunk actually produced. None may be flagged. A future threshold change
    /// that reintroduces the false positives fails here.
    func testNoneOfHisRealMeetingChunksAreFlagged() {
        let measured: [(name: String, characters: Int, voicedSeconds: Double)] = [
            ("chunk-0-mic", 110, 9.0),
            ("chunk-1-system", 211, 13.8),
            ("chunk-2-system", 8, 0.3),
            ("chunk-3-mic", 329, 27.5),
            ("chunk-6-system", 25, 2.8),
            ("chunk-7-mic", 286, 23.4),
            ("chunk-10-system", 70, 5.3),
            ("chunk-11-mic", 194, 21.2),
        ]

        for chunk in measured {
            XCTAssertFalse(
                SpeechTranscriber.looksTruncated(
                    text: String(repeating: "a", count: chunk.characters),
                    audioDuration: 30.0,
                    speechDuration: chunk.voicedSeconds
                ),
                "\(chunk.name): \(chunk.characters) characters over \(chunk.voicedSeconds)s of speech is "
                + "\(String(format: "%.1f", Double(chunk.characters) / chunk.voicedSeconds))/s. "
                + "Re-decoding the whole meeting proved nothing was lost, so this must not be flagged."
            )
        }
    }

    func testSpeechDurationCountsOnlyTheVoicedFrames() {
        let sampleRate = 16_000.0
        let frame = Int(sampleRate * 0.02)
        // One second of speech, then one second of digital silence.
        var samples = [Float](repeating: 0.2, count: frame * 50)
        samples += [Float](repeating: 0, count: frame * 50)

        XCTAssertEqual(
            ModelManager.speechDuration(of: samples),
            1.0,
            accuracy: 0.05,
            "Two seconds of audio holding one second of speech must measure one second."
        )
    }

    func testSpeechDurationIsZeroForDigitalSilence() {
        let samples = [Float](repeating: 0, count: 16_000 * 30)

        XCTAssertEqual(ModelManager.speechDuration(of: samples), 0, accuracy: 0.001)
    }

    func testAMostlySilentMeetingChannelIsNotTruncated() {
        // chunk-0-mic: 30 s of audio, 7.05 s voiced, 110 characters.
        XCTAssertFalse(
            SpeechTranscriber.looksTruncated(
                text: String(repeating: "a", count: 110),
                audioDuration: 30.0,
                speechDuration: 7.05
            ),
            "110 characters over 7 seconds of speech is 15.6/s, faster than his healthy range. Only the silence made it look thin."
        )
    }

    func testRealLossIsStillCaughtWhenTheAudioIsMostlySpeech() {
        // His 2026-08-05 dictation: 43.5 s, continuous speech, 193 characters.
        XCTAssertTrue(
            SpeechTranscriber.looksTruncated(
                text: String(repeating: "a", count: 193),
                audioDuration: 43.5,
                speechDuration: 42.0
            ),
            "The recording this guard exists for must still trip it."
        )
    }

    func testAChannelThatIsAlmostEntirelySilenceIsNeverJudged() {
        // chunk-2-system: 30 s of audio, 0.8% voiced, 8 characters.
        XCTAssertFalse(
            SpeechTranscriber.looksTruncated(
                text: String(repeating: "a", count: 8),
                audioDuration: 30.0,
                speechDuration: 0.24
            ),
            "A quarter of a second of speech is far too little to judge a rate from."
        )
    }

    /// Unknown speech duration must fall back to the old behaviour rather than
    /// silently disabling the guard: dictation callers that do not measure it
    /// still need the 2026-08-05 protection.
    func testAnUnknownSpeechDurationStillJudgesAgainstTheAudio() {
        XCTAssertTrue(
            SpeechTranscriber.looksTruncated(
                text: String(repeating: "a", count: 193),
                audioDuration: 43.5,
                speechDuration: nil
            )
        )
    }
}
