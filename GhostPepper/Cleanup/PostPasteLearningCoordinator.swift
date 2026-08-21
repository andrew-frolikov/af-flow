import CoreGraphics
import os
import Foundation

struct PostPasteLearningObservation: Equatable, Sendable {
    let text: String
}

final class PostPasteLearningCoordinator {
    typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    typealias Revisit = @Sendable (PasteSession) async -> PostPasteLearningObservation?

    static let observationWindow: TimeInterval = 15
    static let pollInterval: TimeInterval = 1
    static let quiescencePeriod: TimeInterval = 2
    private static let maximumReplacementWordCount = 2
    private static let maximumPollCount = Int(observationWindow / pollInterval) + 1
    private static let requiredStablePollCount = Int(quiescencePeriod / pollInterval)

    /// Give up after this many consecutive polls that find nothing readable.
    ///
    /// The accessibility read is the expensive part, and where it fails it
    /// generally fails for the whole window: a game, a canvas, a browser that
    /// exposes nothing. Polling sixteen times to learn nothing sixteen times is
    /// pure cost on his most common action, and it runs after EVERY dictation.
    ///
    /// Six rather than three, because `revisit` also returns nil when the
    /// frontmost app is not the paste target. Glancing at another window for a
    /// few seconds before correcting a word is ordinary, and
    /// `testCoordinatorCanLearnAfterLateInitialSnapshotCapture` documents late
    /// capture as supported. Three polls would have quietly withdrawn that.
    private static let maximumUnreadablePollCount = 6

    /// Incremented on every paste. Polls carry the value they started with, so
    /// a new paste silently retires the previous session's remaining polls.
    ///
    /// Without this, two dictations inside the fifteen-second window ran two
    /// full polling loops at once, each reading the accessibility tree once a
    /// second. He dictates in bursts, so overlapping was the normal case rather
    /// than the exception.
    private let generation = LearningGeneration()

    var learningEnabled: Bool
    var onLearnedCorrection: ((MisheardReplacement) -> Void)?

    private let correctionStore: CorrectionStore
    private let scheduler: Scheduler
    private let revisit: Revisit
    /// Injected like every other dependency here. Reaching for
    /// `AccessibilityFunctionCheck.run()` inline made this class answer
    /// differently depending on where it ran, and broke two existing tests
    /// because the sandboxed test host always reports `broken`.
    private let accessibilityVerdict: () -> AccessibilityFunctionCheck.Verdict

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    init(
        correctionStore: CorrectionStore,
        learningEnabled: Bool = true,
        scheduler: @escaping Scheduler = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        accessibilityVerdict: @escaping () -> AccessibilityFunctionCheck.Verdict = {
            AccessibilityFunctionCheck.run()
        },
        revisit: @escaping Revisit
    ) {
        self.correctionStore = correctionStore
        self.learningEnabled = learningEnabled
        self.scheduler = scheduler
        self.accessibilityVerdict = accessibilityVerdict
        self.revisit = revisit
    }

    /// Whether reading the focused field can possibly succeed.
    ///
    /// This feature reads another app's text through Accessibility, which the
    /// App Sandbox blocks entirely. His log holds roughly 1,200 polls across
    /// every day this has ever run and not one ever read a field. Six failed
    /// polls and seven log lines per dictation, forever.
    ///
    /// `.inconclusive` still runs: nothing was established, and an unanswered
    /// question is not a no.
    static func canObserveFocusedField(accessibility: AccessibilityFunctionCheck.Verdict) -> Bool {
        switch accessibility {
        case .working, .inconclusive: return true
        case .broken, .notTrusted: return false
        }
    }

    func handlePaste(_ session: PasteSession) {
        guard learningEnabled else {
            debugLogger?(.cleanup, "Post-paste learning skipped because it is disabled.")
            return
        }

        // RETIRE ANY SESSION ALREADY RUNNING FIRST. Codex, 2026-08-21: skipping
        // before this left an earlier paste's polling loop live, so it would go
        // on comparing against a baseline that no longer described what is on
        // screen. A new paste ends the old session whether or not this one polls.
        let startedGeneration = generation.next()

        guard Self.canObserveFocusedField(accessibility: accessibilityVerdict()) else {
            debugLogger?(
                .cleanup,
                "Post-paste learning skipped: this build cannot read another app's text field, so polling would never succeed."
            )
            return
        }

        debugLogger?(.cleanup, "Scheduled post-paste learning polling session.")
        schedulePoll(
            for: session,
            progress: LearningProgress(
                baselineText: Self.normalizedText(session.focusedElementText),
                latestObservedText: nil,
                stablePollCount: 0,
                completedPollCount: 0,
                generation: startedGeneration
            ),
            delay: 0
        )
    }

    private func schedulePoll(for session: PasteSession, progress: LearningProgress, delay: TimeInterval) {
        scheduler(delay) {
            Task {
                await self.poll(session: session, progress: progress)
            }
        }
    }

    private func poll(session: PasteSession, progress: LearningProgress) async {
        guard learningEnabled else {
            debugLogger?(.cleanup, "Post-paste learning skipped because it is disabled.")
            return
        }

        // A newer paste has taken over. Stop rather than running two polling
        // loops against the accessibility tree at once.
        guard generation.isCurrent(progress.generation) else {
            debugLogger?(.cleanup, "Post-paste learning poll retired: a newer paste superseded it.")
            return
        }

        var nextProgress = progress
        nextProgress.completedPollCount += 1

        if let observation = await revisit(session),
           let observedText = Self.normalizedText(observation.text) {
            if nextProgress.baselineText == nil {
                nextProgress.baselineText = observedText
                nextProgress.latestObservedText = observedText
                debugLogger?(.cleanup, "Post-paste learning captured initial text-field snapshot during polling.")
            } else if !Self.stringsMatch(observedText, nextProgress.latestObservedText ?? "") {
                nextProgress.latestObservedText = observedText
                nextProgress.stablePollCount = 0
                debugLogger?(.cleanup, "Post-paste learning observed text-field edits and is waiting for them to settle.")
            } else if nextProgress.latestObservedText != nil {
                nextProgress.stablePollCount += 1
                debugLogger?(
                    .cleanup,
                    "Post-paste learning observed \(nextProgress.stablePollCount)s of text-field quiescence."
                )
            }
            nextProgress.unreadablePollCount = 0
        } else {
            nextProgress.unreadablePollCount += 1
            debugLogger?(.cleanup, "Post-paste learning poll found no readable focused text field.")

            // Where the field cannot be read it usually stays unreadable for the
            // whole window, so continuing costs accessibility reads a second
            // apart and can never learn anything.
            if nextProgress.baselineText == nil,
               nextProgress.unreadablePollCount >= Self.maximumUnreadablePollCount {
                debugLogger?(
                    .cleanup,
                    "Post-paste learning gave up: nothing readable after \(nextProgress.unreadablePollCount) polls."
                )
                return
            }
        }

        // Checked again AFTER the await. A paste landing while `revisit` was in
        // flight would otherwise let a retired session store a correction
        // learned from the previous target's text field.
        guard generation.isCurrent(progress.generation) else {
            debugLogger?(.cleanup, "Post-paste learning poll retired mid-observation: a newer paste superseded it.")
            return
        }

        if let baselineText = nextProgress.baselineText,
           let observedText = nextProgress.latestObservedText,
           nextProgress.stablePollCount >= Self.requiredStablePollCount {
            await learn(from: baselineText, to: observedText, pastedText: session.pastedText)
            return
        }

        if nextProgress.completedPollCount >= Self.maximumPollCount {
            debugLogger?(.cleanup, "Post-paste learning skipped because the polling window expired without a stable correction.")
            return
        }

        schedulePoll(for: session, progress: nextProgress, delay: Self.pollInterval)
    }

    private func learn(from baselineText: String, to observedText: String, pastedText: String) async {
        guard let replacement = Self.inferredReplacement(
            from: baselineText,
            to: observedText,
            constrainedTo: pastedText
        ) else {
            debugLogger?(.cleanup, "Post-paste learning skipped because no narrow correction could be inferred.")
            return
        }

        guard learningEnabled else {
            debugLogger?(.cleanup, "Post-paste learning skipped because it was disabled before storing.")
            return
        }

        await MainActor.run {
            guard self.learningEnabled else {
                self.debugLogger?(.cleanup, "Post-paste learning skipped because it was disabled before storing.")
                return
            }

            self.store(replacement)
        }
    }

    private func store(_ replacement: MisheardReplacement) {
        correctionStore.appendCommonlyMisheard(replacement)
        debugLogger?(.cleanup, "Post-paste learning learned replacement: \(replacement.wrong) -> \(replacement.right)")
        onLearnedCorrection?(replacement)
    }

    static func inferredReplacement(
        from original: String,
        to observed: String,
        constrainedTo pastedText: String
    ) -> MisheardReplacement? {
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedObserved = observed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOriginal.isEmpty,
              !trimmedObserved.isEmpty,
              trimmedOriginal.caseInsensitiveCompare(trimmedObserved) != .orderedSame else {
            return nil
        }

        let originalWords = words(in: trimmedOriginal)
        let observedWords = words(in: trimmedObserved)
        let sharedPrefixCount = sharedPrefixLength(between: originalWords, and: observedWords)
        let sharedSuffixCount = sharedSuffixLength(
            between: originalWords,
            and: observedWords,
            excludingPrefix: sharedPrefixCount
        )

        guard sharedPrefixCount > 0 || sharedSuffixCount > 0 else {
            return nil
        }

        let originalEndIndex = originalWords.count - sharedSuffixCount
        let observedEndIndex = observedWords.count - sharedSuffixCount
        let wrong = originalWords[sharedPrefixCount..<originalEndIndex].joined(separator: " ")
        let right = observedWords[sharedPrefixCount..<observedEndIndex].joined(separator: " ")

        guard !wrong.isEmpty,
              !right.isEmpty,
              !stringsDifferOnlyByPunctuation(wrong, right),
              wordCount(in: wrong) <= maximumReplacementWordCount,
              wordCount(in: right) <= maximumReplacementWordCount,
              containsWordSequence(wrong, in: pastedText) else {
            return nil
        }

        return MisheardReplacement(wrong: wrong, right: right)
    }

    private static func sharedPrefixLength(between lhs: [String], and rhs: [String]) -> Int {
        let limit = min(lhs.count, rhs.count)
        var index = 0
        while index < limit && unchangedBoundaryWordsMatch(lhs[index], rhs[index]) {
            index += 1
        }
        return index
    }

    private static func sharedSuffixLength(
        between lhs: [String],
        and rhs: [String],
        excludingPrefix prefixLength: Int
    ) -> Int {
        let limit = min(lhs.count, rhs.count) - prefixLength
        guard limit > 0 else {
            return 0
        }

        var count = 0
        while count < limit &&
                unchangedBoundaryWordsMatch(lhs[lhs.count - count - 1], rhs[rhs.count - count - 1]) {
            count += 1
        }
        return count
    }

    private static func unchangedBoundaryWordsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs
    }

    private static func stringsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func stringsDifferOnlyByPunctuation(_ lhs: String, _ rhs: String) -> Bool {
        normalizedComparisonText(lhs) == normalizedComparisonText(rhs)
    }

    private static func normalizedText(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        return text
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalizedComparisonText(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return " "
            }

            return " "
        }

        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func wordCount(in text: String) -> Int {
        words(in: text).count
    }

    private static func containsWordSequence(_ needle: String, in haystack: String) -> Bool {
        let needleWords = words(in: needle)
        let haystackWords = words(in: haystack)
        guard !needleWords.isEmpty, needleWords.count <= haystackWords.count else {
            return false
        }

        let lastStartIndex = haystackWords.count - needleWords.count
        for startIndex in 0...lastStartIndex {
            let candidate = Array(haystackWords[startIndex..<(startIndex + needleWords.count)])
            if zip(candidate, needleWords).allSatisfy(stringsMatch) {
                return true
            }
        }

        return false
    }
}

private struct LearningProgress: Sendable {
    var baselineText: String?
    var latestObservedText: String?
    var stablePollCount: Int
    var completedPollCount: Int
    /// Which paste this poll belongs to. A poll from an older paste stops.
    var generation: UInt64 = 0
    /// Consecutive polls that found nothing readable to watch.
    var unreadablePollCount: Int = 0
}

enum PostPasteLearningObservationProvider {
    static func captureObservation(
        for session: PasteSession,
        locator: FocusedElementLocator = FocusedElementLocator()
    ) async -> PostPasteLearningObservation? {
        let currentBundleIdentifier = locator.frontmostApplicationBundleIdentifier()
        let currentWindow = locator.frontmostWindowReference()
        let currentFocusedFrame = locator.focusedElementFrame()

        guard isEligibleObservation(
                for: session,
                currentBundleIdentifier: currentBundleIdentifier,
                currentWindowReference: currentWindow,
                currentFocusedFrame: currentFocusedFrame
              ),
              let text = locator.focusedElementText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return PostPasteLearningObservation(text: text)
    }

    static func isEligibleObservation(
        for session: PasteSession,
        currentBundleIdentifier: String?,
        currentWindowReference: FrontmostWindowReference?,
        currentFocusedFrame: CGRect?
    ) -> Bool {
        _ = currentWindowReference
        _ = currentFocusedFrame
        return currentBundleIdentifier == session.frontmostAppBundleIdentifier
    }
}


/// The current paste generation, readable from any thread.
///
/// The counter was previously a plain field written on the main thread by
/// `handlePaste` and read from a detached `Task` in `poll`. The entire
/// retirement mechanism rested on that one field, unsynchronised.
private final class LearningGeneration: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: UInt64(0))

    func next() -> UInt64 {
        lock.withLock { value in
            value &+= 1
            return value
        }
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        lock.withLock { $0 == candidate }
    }
}
