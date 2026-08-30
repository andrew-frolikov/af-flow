import Foundation

/// One timed run on this Mac, on a clip that ships with the app.
struct TierBenchmarkMeasurement: Equatable {
    let tier: QualityTier
    /// How much speech was in the clip.
    let audioSeconds: Double
    /// How long the machine took to transcribe it, end to end.
    let elapsedSeconds: Double

    /// Seconds this machine spends per `TierBenchmark.referenceSpeechSeconds`
    /// of speech, or nil when the measurement is not one.
    ///
    /// **Nil rather than a number, on purpose.** A clip of no length is a
    /// failed measurement, not an infinitely fast Mac, and dividing by it puts
    /// an infinity on a friend's screen. Same for a run that reports no
    /// elapsed time: that run did not happen.
    var secondsPerReferenceSpeech: Double? {
        guard audioSeconds > 0, elapsedSeconds > 0 else { return nil }
        let perSecond = elapsedSeconds / audioSeconds
        guard perSecond.isFinite else { return nil }
        return perSecond * TierBenchmark.referenceSpeechSeconds
    }
}

/// What the model screen is allowed to say about a tier's speed.
///
/// **Three states, never two.** This project's most expensive mistakes have
/// been numbers carrying more confidence than they had: a fabrication rate
/// quoted without its calibration, a p90 improvement quoted off 16 dictations,
/// a lean measured over the wrong population. A speed on a screen looks
/// measured whether or not it is, so the type makes the difference impossible
/// to lose.
enum TierBenchmarkEstimate: Equatable {
    /// Timed on this machine, just now.
    case measured(Double)
    /// Extrapolated from a calibration ratio. Always says so.
    case estimated(Double)
    /// No calibration exists for this tier. Says that, in words, with no
    /// number anywhere in it.
    case unknown

    /// The sentence the screen shows. Kept beside the cases so a new case
    /// cannot be added without deciding what it says.
    var sentence: String {
        switch self {
        case .measured(let seconds):
            return String(format: "About %.1f seconds for 5 seconds of speech, timed on this Mac.",
                          seconds)
        case .estimated(let seconds):
            return String(format: "Estimated at about %.1f seconds for 5 seconds of speech.",
                          seconds)
        case .unknown:
            return "Not measured on a Mac like this one yet, so there is no "
                 + "honest number to show."
        }
    }
}

/// A clip that ships inside the app for the benchmark to run on.
struct TierBenchmarkClip: Equatable {
    let resourceName: String
    let fileExtension: String
    let language: String
}

enum TierBenchmark {
    /// The screen talks in "seconds per five seconds of speech", so every
    /// measurement is normalised to this and the clip's own length divides out.
    /// The two bundled clips are 4.4 s and 6.4 s, because that is what the
    /// sentences came out at, and neither number should reach a user.
    static let referenceSpeechSeconds: Double = 5

    /// **Synthesised with `say`, not recorded.**
    ///
    /// The launch plan asks for "one EN and one RU" clip. Recording Andrew
    /// would put his voice inside a public DMG on GitHub, permanently, for a
    /// timing measurement that does not need a human: this benchmark measures
    /// how long a model takes per second of audio, and synthetic speech
    /// exercises the same path. `say -v Samantha` and `say -v Milena`, both
    /// shipped with macOS, converted to the 16 kHz mono the speech models
    /// consume. No personal data, no third-party licence, reproducible from
    /// two commands.
    ///
    /// One English and one Russian, deliberately: the plan's words are that
    /// the Russian number is the honest one for this audience.
    static let bundledClips: [TierBenchmarkClip] = [
        TierBenchmarkClip(resourceName: "benchmark-en", fileExtension: "wav", language: "en"),
        TierBenchmarkClip(resourceName: "benchmark-ru", fileExtension: "wav", language: "ru"),
    ]

    /// How much slower a tier is than the tier that was actually timed.
    ///
    /// **EMPTY, and that is the current true state.** The plan calls for these
    /// to be measured once on Andrew's Macs; that has not happened. An empty
    /// table means every tier except the measured one reports `.unknown`, and
    /// the screen says so in words. Filling this in with a plausible-looking
    /// ratio would produce exactly the kind of number this file exists to
    /// prevent.
    static let calibrationRatios: [QualityTier: Double] = [:]

    /// The text behind "Ask your AI about these results".
    ///
    /// Advice only, and one-way by design: the settled decision of 2026-08-29
    /// dropped the AI round trip from the model screen, so this composes a
    /// question and nothing in the app ever parses an answer. There is no
    /// paste-back field anywhere.
    ///
    /// **It carries the unknown state through rather than dropping it.** A
    /// prompt that silently omitted the tier it could not measure would ask the
    /// reader's AI to advise on half the ladder while looking complete, and the
    /// answer would come back confident. Saying "not measured" is the useful
    /// input.
    static func advicePrompt(
        for measurement: TierBenchmarkMeasurement,
        physicalMemory: UInt64,
        ratios: [QualityTier: Double] = calibrationRatios
    ) -> String {
        let gigabytes = Double(physicalMemory) / 1_073_741_824
        var lines = [
            "I am choosing a quality level in AF Flow, a local dictation app for macOS.",
            "Everything runs on my own Mac; nothing is sent anywhere.",
            "",
            String(format: "This Mac has %.0f GB of memory.", gigabytes),
            "",
            "How each level performed:",
        ]
        for tier in QualityTier.allCases {
            let estimate = estimate(for: tier, from: measurement, ratios: ratios)
            lines.append("- \(tier.displayName): \(tier.oneLine) \(estimate.sentence)")
        }
        lines += [
            "",
            "Which level would you pick, and why? Answer in plain words.",
            "Do not ask me to run Terminal commands.",
        ]
        return lines.joined(separator: "\n")
    }

    static func estimate(
        for tier: QualityTier,
        from measurement: TierBenchmarkMeasurement,
        ratios: [QualityTier: Double] = calibrationRatios
    ) -> TierBenchmarkEstimate {
        guard let measured = measurement.secondsPerReferenceSpeech else { return .unknown }
        if tier == measurement.tier { return .measured(measured) }
        let ratio = ratios[tier] ?? 3.0  // MUTATION
        let extrapolated = measured * ratio
        guard extrapolated.isFinite else { return .unknown }
        return .estimated(extrapolated)
    }
}
