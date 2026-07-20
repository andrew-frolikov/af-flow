import Foundation

/// LOOP.md Tier C: the objective verifier for transcription quality.
///
/// Built at C2 start on 2026-07-20, because it did not exist. The Lab stored
/// audio and transcriptions but had no reference text and no scoring of any
/// kind, so it was a manual review tool rather than a scorer, and C1 therefore
/// closed with no machine rubric line at all.
///
/// The metric set is chosen against Andrew's stated priorities, in his order:
/// Russian punctuation first, word endings second. A single WER number would
/// answer neither question, so this reports five separate things and refuses to
/// collapse them into one score.
enum TextScoring {

    // MARK: - Normalisation

    /// Sentence-terminating marks, tracked separately from other punctuation
    /// because the sentence-merging defect is the highest-confidence finding in
    /// the whole project, confirmed three independent ways.
    static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]

    /// Unicode's own punctuation category rather than a hand-listed table.
    ///
    /// The first version of this enumerated marks by hand and tripped the rule 9
    /// sweep, because listing an em dash as a character to *detect* is
    /// indistinguishable, to a scanner, from writing one in user-facing copy.
    /// The tempting fix was an allowlist entry like the one ReaderCapture.swift
    /// has. The gate was right and the table was wrong: a hand-rolled list was
    /// always going to miss marks, and it already did. Deferring to
    /// `CharacterSet.punctuationCharacters` picks up the guillemets Russian uses
    /// for quotation, every dash width, and the ellipsis, with no table to
    /// maintain and no exception to ratify.
    static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    /// Unicode normalisation matters more here than in an English-only project.
    /// Cyrillic text arrives from different engines in different composed forms,
    /// and "\u{0439}" can be one code point or two. Without this, two identical
    /// strings can score as different.
    ///
    /// The Russian-specific case: "\u{0451}" versus "\u{0435}". Russians write both
    /// interchangeably and ASR engines disagree, so treating them as distinct
    /// would report a difference of orthographic convention as a transcription
    /// error. Folded by default, and the fold is reported so the choice is
    /// visible rather than buried.
    static func normalise(
        _ text: String,
        stripPunctuation: Bool,
        foldCase: Bool,
        foldYo: Bool = true
    ) -> String {
        var result = text.precomposedStringWithCanonicalMapping

        if foldYo {
            result = result
                .replacingOccurrences(of: "\u{0451}", with: "\u{0435}")
                .replacingOccurrences(of: "\u{0401}", with: "\u{0415}")
        }

        if foldCase {
            result = result.lowercased()
        }

        if stripPunctuation {
            result = String(result.map { isPunctuation($0) ? " " : $0 })
        }

        return result
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Edit distance

    /// Standard Levenshtein. Kept generic over Equatable so the same routine
    /// scores words, characters and punctuation sequences, rather than three
    /// near-identical copies drifting apart.
    static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                let insertion = current[j - 1] + 1
                let deletion = previous[j] + 1
                current[j] = min(substitution, insertion, deletion)
            }
            swap(&previous, &current)
        }

        return previous[b.count]
    }

    // MARK: - Metrics

    /// Word error rate, punctuation stripped and case folded.
    ///
    /// Deliberately blind to punctuation and casing: those are measured
    /// separately below, and mixing them in would let a model with good
    /// punctuation hide bad word recognition behind one averaged number.
    static func wordErrorRate(hypothesis: String, reference: String) -> Rate {
        let hyp = normalise(hypothesis, stripPunctuation: true, foldCase: true)
            .split(separator: " ").map(String.init)
        let ref = normalise(reference, stripPunctuation: true, foldCase: true)
            .split(separator: " ").map(String.init)
        return Rate(errors: editDistance(hyp, ref), total: ref.count)
    }

    /// Character error rate, punctuation stripped and case folded.
    ///
    /// This is the word-endings metric, and it is the reason CER is reported
    /// alongside WER rather than instead of it. Russian inflection errors change
    /// one or two characters of an otherwise correct word. WER scores that as a
    /// whole word wrong and so cannot distinguish "heard the wrong word" from
    /// "heard the right word with the wrong ending", which are different
    /// problems with different fixes. A large WER-to-CER gap means endings; a
    /// small gap means the model is mishearing words outright.
    static func characterErrorRate(hypothesis: String, reference: String) -> Rate {
        let hyp = Array(normalise(hypothesis, stripPunctuation: true, foldCase: true))
        let ref = Array(normalise(reference, stripPunctuation: true, foldCase: true))
        return Rate(errors: editDistance(hyp, ref), total: ref.count)
    }

    /// Punctuation error rate over the ordered sequence of marks.
    ///
    /// Andrew's first priority. Scored as a sequence rather than as counts,
    /// because a model can emit the right number of commas in the wrong places.
    static func punctuationErrorRate(hypothesis: String, reference: String) -> Rate {
        let hyp = hypothesis.filter { isPunctuation($0) }.map { $0 }
        let ref = reference.filter { isPunctuation($0) }.map { $0 }
        return Rate(errors: editDistance(hyp, ref), total: ref.count)
    }

    /// Sentence-boundary count, hypothesis versus reference.
    ///
    /// This exists as its own metric because the sentence-merging defect is the
    /// single most confirmed finding in the project: an 18-to-3 lean in the
    /// Wispr archive, run-ons in his English messages, and worse again in the
    /// C1 Russian clip. A rate would hide the direction, and direction is the
    /// whole point. Fewer boundaries than reference means merging, which is the
    /// predicted failure. More means splitting, which would be new information.
    static func sentenceBoundaries(hypothesis: String, reference: String) -> BoundaryCount {
        BoundaryCount(
            hypothesis: hypothesis.filter { sentenceTerminators.contains($0) }.count,
            reference: reference.filter { sentenceTerminators.contains($0) }.count
        )
    }

    /// Whether a period is followed by a space.
    ///
    /// Narrow, mechanical, and included because the C1 Russian clip produced
    /// "\u{043F}\u{0440}\u{0438}\u{043B}\u{043E}\u{0436}\u{0435}\u{043D}\u{0438}\u{044F}.\u{0422}\u{0430}\u{043A}\u{0436}\u{0435}" with no space after the period. If that recurs across
    /// models it is an engine artifact worth a deterministic fix; if it appears
    /// in only one, it is a reason to not pick that engine.
    static func missingSpaceAfterPeriod(in text: String) -> Int {
        let characters = Array(text)
        var count = 0
        for index in characters.indices.dropLast() where sentenceTerminators.contains(characters[index]) {
            let next = characters[index + 1]
            if !next.isWhitespace && !isPunctuation(next) && !next.isNumber {
                count += 1
            }
        }
        return count
    }

    /// Latin-script runs preserved in the hypothesis, against those in the
    /// reference.
    ///
    /// This is the code-switching metric, and it is the one with a real failing
    /// example already on record: "prompt" survived correctly in Latin script
    /// once and became "\u{043F}\u{0440}\u{043E}\u{043C}\u{043F}\u{0443}\u{0442}" elsewhere in the same clip. T5's whole
    /// purpose is that his register borrows English technical vocabulary into
    /// Russian sentences, and a model that Cyrillicises those terms is failing
    /// at the thing he most needs, however good its WER looks.
    static func latinTermsPreserved(hypothesis: String, reference: String) -> TermPreservation {
        let referenceTerms = latinRuns(in: reference)
        let hypothesisTerms = Set(latinRuns(in: hypothesis).map { $0.lowercased() })
        let missing = referenceTerms.filter { !hypothesisTerms.contains($0.lowercased()) }
        return TermPreservation(expected: referenceTerms, missing: missing)
    }

    private static func latinRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.isLetter, character.unicodeScalars.allSatisfy({ $0.value < 0x0250 }) {
                current.append(character)
            } else {
                if current.count > 1 { runs.append(current) }
                current = ""
            }
        }
        if current.count > 1 { runs.append(current) }
        return runs
    }

    // MARK: - Result types

    struct Rate {
        let errors: Int
        let total: Int

        var value: Double { total == 0 ? 0 : Double(errors) / Double(total) }
        var percent: String { String(format: "%.1f%%", value * 100) }
    }

    struct BoundaryCount {
        let hypothesis: Int
        let reference: Int

        var delta: Int { hypothesis - reference }

        /// Named rather than inferred at the call site, so the merging finding
        /// is reported in the vocabulary the project already uses for it.
        var verdict: String {
            if delta == 0 { return "matches" }
            return delta < 0 ? "merged \(-delta)" : "split \(delta)"
        }
    }

    struct TermPreservation {
        let expected: [String]
        let missing: [String]

        var preserved: Int { expected.count - missing.count }
        var summary: String {
            missing.isEmpty
                ? "\(preserved)/\(expected.count)"
                : "\(preserved)/\(expected.count), lost: \(missing.joined(separator: ", "))"
        }
    }
}
