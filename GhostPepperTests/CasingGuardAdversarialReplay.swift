import XCTest
@testable import GhostPepper

/// **Proves the casing guard on the input shapes his archive does NOT contain.**
///
/// A reviewer made the case on 2026-08-24 and it is right: replaying the guard
/// over his archive shows what happened on the population that archive holds,
/// and says nothing about the population it lacks. Measured across the 50
/// archived dictations, the entire punctuation inventory of the raw
/// transcriptions is `. , ? ' - %` — **zero** quotes, brackets, guillemets,
/// dashes or newlines, **zero** `period + punctuation + word` shapes, and
/// **zero** lowercase-initial-with-a-later-capital tokens in 1,835 tokens.
///
/// Every one of the three defects found in review was invisible to that replay.
/// A clean replay was fully compatible with all of them being live. All 50
/// dictations came from Whisper turbo, and Settings steers him to Parakeet v3
/// for non-English, which punctuates differently — so this is one model switch
/// from mattering.
///
/// So this synthesises the missing shapes from HIS OWN transcriptions rather
/// than from invented sentences: his vocabulary, his languages, his sentence
/// boundaries, with the punctuation the archive happens not to contain injected
/// at those boundaries. It turns "never observed" into "cannot happen here".
///
/// Skips silently without `AF_FLOW_LAB_ARCHIVE`, because his transcripts are
/// never committed. Run it with `scripts/casing-guard-replay.sh`.
final class CasingGuardAdversarialReplay: XCTestCase {

    /// Characters the archive never puts between a full stop and the next word.
    ///
    /// TRANSPARENT characters only. The first version also injected `\u{2026}`,
    /// and all 87 remaining leaks were that one case — correctly, because an
    /// ellipsis ENDS a sentence, so the word after it really is sentence-initial
    /// and restoring its capital is right. A terminator is not a mask, and
    /// putting one in this list made the test assert the opposite of the design.
    private static let masks = ["\"", "\u{00AB}", "(", "\u{2014}", "- "]

    func testAMergedSentenceIsNeverRecapitalisedOnHisOwnVocabulary() throws {
        let transcriptions = try archiveTranscriptions()
        var checked = 0
        var leaked: [String] = []

        for raw in transcriptions {
            for variant in mergeVariants(of: raw) {
                checked += 1
                let result = TextCleaner.restoringCapitalsLoweredFromSpeech(
                    variant.cleaned,
                    spokenInput: variant.spoken,
                    afterDictionary: variant.spoken
                )
                if result != variant.cleaned {
                    leaked.append("\(variant.label): \(firstDifference(variant.cleaned, result))")
                }
            }
        }

        XCTAssertGreaterThan(checked, 0, "no merge shapes could be synthesised, so this proves nothing")
        XCTAssertTrue(
            leaked.isEmpty,
            "\(leaked.count) of \(checked) synthesised merges had a positional capital dragged mid-sentence:\n"
                + leaked.prefix(10).joined(separator: "\n")
        )
        print("ADVERSARIAL-REPLAY merges checked: \(checked), leaked: \(leaked.count)")
    }

    /// The other direction: the repair he actually needs must still fire on his
    /// own words. A guard that declines everything would pass the test above.
    func testACapitalHeSaidMidSentenceIsStillRestoredOnHisOwnVocabulary() throws {
        let transcriptions = try archiveTranscriptions()
        var checked = 0
        var missed: [String] = []

        for raw in transcriptions {
            guard let lowered = loweringMidSentenceCapitals(in: raw) else { continue }
            checked += 1
            let result = TextCleaner.restoringCapitalsLoweredFromSpeech(
                lowered,
                spokenInput: raw,
                afterDictionary: raw
            )
            if result != raw {
                missed.append(firstDifference(raw, result))
            }
        }

        XCTAssertGreaterThan(checked, 0, "no mid-sentence capitals found, so this proves nothing")
        XCTAssertTrue(
            missed.isEmpty,
            "\(missed.count) of \(checked) dictations did not get his capitals back:\n"
                + missed.prefix(10).joined(separator: "\n")
        )
        print("ADVERSARIAL-REPLAY restorations checked: \(checked), missed: \(missed.count)")
    }

    // MARK: - Synthesis

    private struct Variant {
        let label: String
        let spoken: String
        let cleaned: String
    }

    /// Turns ". Word" into ", word" — the shape the model produces when it
    /// merges two sentences — and separately injects each character the archive
    /// never contains between the terminator and the word.
    private func mergeVariants(of raw: String) -> [Variant] {
        // THE ORACLE HAS TO BE EXACT, and the first version's was not.
        //
        // It demoted any capitalised word after a full stop and demanded the
        // guard leave it lower case. 185 of 984 "leaked" — and nearly all were
        // the guard being RIGHT. English `I` is capitalised everywhere, so it is
        // attested mid-sentence all through his text, and by the guard's own
        // rule an attested capital is his spelling rather than the sentence's.
        // The test was wrong, not the code.
        //
        // So the boundary word must occur EXACTLY ONCE in the transcription.
        // Then it cannot be attested anywhere else, the guard has no licence to
        // restore it, and "stays lower case" is the only correct answer. This
        // narrows the sample and makes the oracle unambiguous, which is the
        // trade worth making.
        guard let boundary = try? NSRegularExpression(pattern: "\\.\\s+(\\p{Lu}\\p{L}+)") else { return [] }
        let range = NSRange(raw.startIndex..., in: raw)
        var chosen: (whole: Range<String.Index>, word: String)? = nil
        for match in boundary.matches(in: raw, range: range) {
            guard let wordRange = Range(match.range(at: 1), in: raw),
                  let wholeRange = Range(match.range, in: raw) else { continue }
            let word = String(raw[wordRange])
            if occurrences(of: word, in: raw) == 1 {
                chosen = (wholeRange, word)
                break
            }
        }
        guard let (wholeRange, capital) = chosen else { return [] }
        var variants: [Variant] = []

        var merged = raw
        merged.replaceSubrange(wholeRange, with: ", " + capital.lowercased())
        variants.append(Variant(label: "plain merge", spoken: raw, cleaned: merged))

        for mask in Self.masks {
            var maskedSpoken = raw
            maskedSpoken.replaceSubrange(wholeRange, with: ". " + mask + capital)
            var maskedCleaned = raw
            maskedCleaned.replaceSubrange(wholeRange, with: ", " + mask + capital.lowercased())
            variants.append(
                Variant(label: "merge behind \(mask.trimmingCharacters(in: .whitespaces))",
                        spoken: maskedSpoken,
                        cleaned: maskedCleaned)
            )
        }

        var abbreviated = raw
        abbreviated.replaceSubrange(wholeRange, with: " \u{0442}.\u{0434}., " + capital.lowercased())
        var abbreviatedSpoken = raw
        abbreviatedSpoken.replaceSubrange(wholeRange, with: " \u{0442}.\u{0434}. " + capital)
        variants.append(Variant(label: "abbreviation then comma", spoken: abbreviatedSpoken, cleaned: abbreviated))

        return variants
    }

    /// Lower-cases every capitalised token that is NOT at a sentence start, so
    /// the guard has something real to put back.
    private func loweringMidSentenceCapitals(in raw: String) -> String? {
        // Unambiguously mid-sentence: preceded by a LOWER-CASE letter and a
        // space, so no terminator can be involved. And exactly one occurrence,
        // so there is a single form and the guard is not asked to choose.
        guard let words = try? NSRegularExpression(pattern: "\\p{Ll} (\\p{Lu}\\p{L}+)") else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        let matches = words.matches(in: raw, range: range)

        var lowered = raw
        var changed = false
        for match in matches.reversed() {
            guard let wordRange = Range(match.range(at: 1), in: lowered) else { continue }
            let word = String(lowered[wordRange])
            guard occurrences(of: word, in: raw) == 1 else { continue }
            lowered.replaceSubrange(wordRange, with: word.lowercased())
            changed = true
        }
        return changed ? lowered : nil
    }

    private func occurrences(of word: String, in text: String) -> Int {
        guard let expression = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])",
            options: [.caseInsensitive]
        ) else { return 0 }
        return expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    // MARK: - Archive

    private func archiveTranscriptions() throws -> [String] {
        guard let path = ProcessInfo.processInfo.environment["AF_FLOW_LAB_ARCHIVE"] else {
            throw XCTSkip("AF_FLOW_LAB_ARCHIVE not set; his transcripts are never committed.")
        }
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        var transcriptions: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["rawTranscription"] as? String,
                  !raw.isEmpty else {
                continue
            }
            transcriptions.append(raw)
        }
        return transcriptions
    }

    private func firstDifference(_ expected: String, _ actual: String) -> String {
        let e = Array(expected), a = Array(actual)
        for index in 0..<min(e.count, a.count) where e[index] != a[index] {
            let start = max(0, index - 25)
            let end = min(min(e.count, a.count), index + 25)
            return "…\(String(a[start..<end]))… (expected \(e[index]), got \(a[index]))"
        }
        return "lengths differ"
    }
}
