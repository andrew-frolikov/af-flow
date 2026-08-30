import XCTest
@testable import AFFlow

/// The benchmark may not invent a number.
///
/// `docs/launch-v1-plan.md`, settled 2026-08-29: the model screen times the
/// bundled model on a bundled clip, extrapolates the bigger tiers by ratios
/// calibrated once on Andrew's Macs, and **labels them estimated**.
///
/// That last word is the whole design. This project's most expensive mistakes
/// have been numbers presented with more confidence than they had: a
/// fabrication rate quoted without its calibration, a p90 improvement quoted
/// off 16 dictations, a "33 of 33" lean measured over the wrong population.
/// A benchmark screen is exactly the surface where that happens again, because
/// a number on screen looks measured whether or not it is.
///
/// So there are three states here and never two: **measured** on this machine,
/// **estimated** from a calibration ratio, and **unknown**, which is what an
/// uncalibrated tier gets. Unknown renders as words, never as a figure.
final class TierBenchmarkTests: XCTestCase {

    private func measurement(audio: Double, elapsed: Double) -> TierBenchmarkMeasurement {
        TierBenchmarkMeasurement(tier: .starter, audioSeconds: audio, elapsedSeconds: elapsed)
    }

    // MARK: - Normalising, so clip length is not part of the answer

    /// The two bundled clips are 4.41 s and 6.44 s, because that is what the
    /// sentences came out at. The screen talks in "seconds per 5 seconds of
    /// speech", so the clip's own length must divide out completely.
    func testTheAnswerDoesNotDependOnHowLongTheClipIs() throws {
        let short = try XCTUnwrap(measurement(audio: 4.41, elapsed: 4.41 * 0.4).secondsPerReferenceSpeech)
        let long = try XCTUnwrap(measurement(audio: 6.44, elapsed: 6.44 * 0.4).secondsPerReferenceSpeech)
        XCTAssertEqual(short, long, accuracy: 0.0001,
                       "the same machine at the same speed gave two answers "
                       + "because the clips are different lengths")
        XCTAssertEqual(short, 5 * 0.4, accuracy: 0.0001)
    }

    /// A clip of no length is a failed measurement, not an infinitely fast Mac.
    func testAZeroLengthClipIsRefusedRatherThanDividedBy() {
        XCTAssertNil(measurement(audio: 0, elapsed: 1).secondsPerReferenceSpeech)
        XCTAssertNil(measurement(audio: -3, elapsed: 1).secondsPerReferenceSpeech)
    }

    /// A run that reports no elapsed time did not run.
    func testAZeroElapsedMeasurementIsRefused() {
        XCTAssertNil(measurement(audio: 5, elapsed: 0).secondsPerReferenceSpeech)
        XCTAssertNil(measurement(audio: 5, elapsed: -1).secondsPerReferenceSpeech)
    }

    // MARK: - The three states

    func testTheTierThatWasActuallyTimedIsReportedAsMeasured() {
        let m = measurement(audio: 5, elapsed: 2)
        guard case .measured(let seconds) = TierBenchmark.estimate(for: .starter, from: m) else {
            return XCTFail("the tier that was timed came back as something other than measured")
        }
        XCTAssertEqual(seconds, 2, accuracy: 0.0001)
    }

    /// **The state that matters.** No calibration ratio has been measured yet,
    /// so Full has no number, and the code must say so rather than reach for
    /// a plausible one.
    func testAnUncalibratedTierIsUnknownRatherThanAGuess() {
        let m = measurement(audio: 5, elapsed: 2)
        let estimate = TierBenchmark.estimate(
            for: .full, from: m, ratios: [:])
        guard case .unknown = estimate else {
            return XCTFail("an uncalibrated tier produced \(estimate) instead of unknown")
        }
    }

    func testACalibratedTierIsEstimatedFromTheRatio() {
        let m = measurement(audio: 5, elapsed: 2)
        let estimate = TierBenchmark.estimate(
            for: .full, from: m, ratios: [.full: 3.5])
        guard case .estimated(let seconds) = estimate else {
            return XCTFail("a calibrated tier produced \(estimate) instead of estimated")
        }
        XCTAssertEqual(seconds, 7, accuracy: 0.0001)
    }

    /// A ratio that is not a ratio is a broken calibration, and a broken
    /// calibration must not become a number on his friend's screen.
    func testANonsenseRatioIsUnknownRatherThanNonsense() {
        let m = measurement(audio: 5, elapsed: 2)
        for bad in [0.0, -1.0, Double.nan, Double.infinity] {
            let estimate = TierBenchmark.estimate(for: .full, from: m, ratios: [.full: bad])
            guard case .unknown = estimate else {
                return XCTFail("ratio \(bad) produced \(estimate) instead of unknown")
            }
        }
    }

    // MARK: - What reaches the screen

    func testAnEstimateAlwaysSaysItIsAnEstimate() {
        let text = TierBenchmark.estimate(for: .full,
                                          from: measurement(audio: 5, elapsed: 2),
                                          ratios: [.full: 3.5]).sentence
        XCTAssertTrue(text.lowercased().contains("estimat"),
                      "an extrapolated number reached the screen without saying "
                      + "it was estimated: \(text)")
    }

    func testAMeasuredNumberDoesNotClaimToBeAnEstimate() {
        let text = TierBenchmark.estimate(for: .starter,
                                          from: measurement(audio: 5, elapsed: 2)).sentence
        XCTAssertFalse(text.lowercased().contains("estimat"),
                       "a number timed on this machine is described as estimated: \(text)")
    }

    /// The unknown sentence is the one most likely to be quietly replaced by a
    /// number later, so it is pinned: it says what is missing, and it contains
    /// no digits at all.
    func testTheUnknownSentenceCarriesNoNumber() {
        let text = TierBenchmark.estimate(for: .full,
                                          from: measurement(audio: 5, elapsed: 2),
                                          ratios: [:]).sentence
        XCTAssertFalse(text.contains(where: \.isNumber),
                       "the unknown state put a number on screen: \(text)")
        XCTAssertFalse(text.isEmpty)
    }

    // MARK: - The prompt behind "Ask your AI about these results"

    /// A prompt that quietly dropped the tier it could not measure would ask
    /// the reader's AI to advise on half the ladder while looking complete.
    func testTheAdvicePromptCarriesTheUnknownStateThrough() {
        let text = TierBenchmark.advicePrompt(
            for: measurement(audio: 5, elapsed: 2),
            physicalMemory: 16 * 1024 * 1024 * 1024,
            ratios: [:])
        for tier in QualityTier.allCases {
            XCTAssertTrue(text.contains(tier.displayName),
                          "\(tier.displayName) is missing from the prompt")
        }
        XCTAssertTrue(text.contains("Not measured"),
                      "the uncalibrated tier was dropped instead of reported:\n\(text)")
    }

    /// The settled decision of 2026-08-29 dropped the AI round trip: this is
    /// advice-only and nothing parses a reply. The prompt must not invite one
    /// in a format the app would then be expected to read.
    func testTheAdvicePromptAsksForPlainWordsAndNoTerminal() {
        let text = TierBenchmark.advicePrompt(
            for: measurement(audio: 5, elapsed: 2),
            physicalMemory: 8 * 1024 * 1024 * 1024)
        XCTAssertTrue(text.lowercased().contains("plain words"))
        XCTAssertTrue(text.lowercased().contains("do not ask me to run terminal"))
        XCTAssertTrue(text.contains("8 GB"), "the prompt does not say what Mac this is")
    }

    // MARK: - The clips the benchmark runs on

    /// Registered in the pbxproj by hand, so verified in the bundle rather than
    /// assumed from the project file.
    func testBothBenchmarkClipsAreInTheBundle() {
        for clip in TierBenchmark.bundledClips {
            XCTAssertNotNil(Bundle(for: Self.self).url(forResource: clip.resourceName,
                                                       withExtension: clip.fileExtension)
                            ?? Bundle.main.url(forResource: clip.resourceName,
                                               withExtension: clip.fileExtension),
                            "\(clip.resourceName).\(clip.fileExtension) is not in the bundle")
        }
    }

    /// One English, one Russian, deliberately. The plan's words: the Russian
    /// number is the honest one for this audience.
    func testTheClipsCoverBothOfHisLanguages() {
        let languages = Set(TierBenchmark.bundledClips.map(\.language))
        XCTAssertEqual(languages, ["en", "ru"])
    }
}
