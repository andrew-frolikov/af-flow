import Foundation

/// LOOP.md Tier C: the objective verifier for transcription quality.
///
/// Built at C2 start on 2026-07-20, because it did not exist. The Lab stored
/// audio and transcriptions but had no reference text and no scoring of any
/// kind, so it was a manual review tool rather than a scorer, and C1 therefore
/// closed with no machine rubric line at all.
///
/// The metric set is chosen against Andrew's stated priorities, in his order:
/// **Russian word endings first, punctuation second.**
///
/// That order is corrected, not restated. This file recorded it backwards
/// until 2026-07-24, when he was asked directly and confirmed endings first.
/// The consequence was not cosmetic: it is the argument for which column the
/// report leads with, and for whether C2 can close at all if punctuation turns
/// out to be unmeasurable on his fixtures, which it nearly was.
///
/// A single WER number would answer neither question, so this reports several
/// separate things and refuses to collapse them into one score.
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

    /// Is this model hearing the WRONG WORDS, or the RIGHT words with the WRONG
    /// ENDINGS? Andrew's first question about Russian, and neither WER nor CER
    /// answers it alone.
    ///
    /// **Why the raw "WER minus CER gap" is unreadable, and why reporting it as
    /// the answer would have been a trap.** CER is smaller than WER for a
    /// reason that has nothing to do with quality: a Russian word runs five or
    /// six characters, so any error at all is a smaller fraction of the
    /// characters than of the words. A model scoring WER 30 and CER 8 looks
    /// like it has "a large gap", but so does every model, always, including a
    /// model whose every error is a completely different word. The gap is an
    /// artefact of the units, and a decision taken on it would be taken on
    /// arithmetic rather than on the audio.
    ///
    /// The readable signal is the RATIO `CER/WER`, placed between two endpoints
    /// computed from the reference itself:
    ///
    /// - **floor**, `N/M`: what the ratio reads when every error is a single
    ///   wrong character inside an otherwise correct word. Pure inflection.
    /// - **ceiling**, `(M-N+1)/M`: what it reads when every error is a whole
    ///   word replaced by an unrelated word of typical length. Pure
    ///   substitution.
    ///
    /// where `N` is reference words and `M` is reference characters after the
    /// same normalisation WER and CER use. `substitutionShare` places the
    /// observed ratio between them: **0 is pure inflection, 1 is pure
    /// substitution.** That number is the C2 decision, because inflection needs
    /// a better acoustic model and nothing else, while substitution is much
    /// cheaper to attack in the dictionary layer.
    static func inflectionDiagnostic(hypothesis: String, reference: String) -> InflectionDiagnostic {
        let wer = wordErrorRate(hypothesis: hypothesis, reference: reference)
        let cer = characterErrorRate(hypothesis: hypothesis, reference: reference)

        let normalisedReference = normalise(reference, stripPunctuation: true, foldCase: true)
        let words = normalisedReference.split(separator: " ").count
        let characters = normalisedReference.count

        return InflectionDiagnostic(
            wer: wer,
            cer: cer,
            referenceWords: words,
            referenceCharacters: characters
        )
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
            hypothesis: boundaryCount(in: hypothesis),
            reference: boundaryCount(in: reference)
        )
    }

    /// One boundary per RUN of terminators, not per terminator character.
    ///
    /// Counting characters made `...` three sentence endings and `?!` two.
    /// That matters here rather than being pedantic: this metric reports a
    /// DIRECTION, merged versus split, and it is the project's
    /// most-confirmed defect. A reference written with an ellipsis against a
    /// hypothesis written with a single full stop would have reported the
    /// model as having merged two sentences it never merged, which is a
    /// false confirmation of the finding the whole voice layer is being
    /// designed around. Andrew dictates ellipses; the models emit them too.
    static func boundaryCount(in text: String) -> Int {
        var count = 0
        var insideRun = false
        for character in text {
            if sentenceTerminators.contains(character) {
                if !insideRun { count += 1 }
                insideRun = true
            } else {
                insideRun = false
            }
        }
        return count
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

        // **Counted, not set-membership, and the difference is the whole
        // metric.** This compared against a `Set`, so one surviving occurrence
        // of a term covered every occurrence of it. The example this function
        // was written for is exactly that shape and it scored as a clean pass:
        // in the C1 clip "prompt" survived in Latin script ONCE and was
        // Cyrillicised elsewhere in the SAME utterance, which is the finding
        // the docstring below cites as the reason the metric exists. A set
        // could never see it.
        //
        // Multiset matching makes each reference occurrence consume one
        // hypothesis occurrence, so two expected and one delivered reports one
        // lost rather than none.
        var available: [String: Int] = [:]
        for term in latinRuns(in: hypothesis) {
            available[term.lowercased(), default: 0] += 1
        }

        var missing: [String] = []
        for term in referenceTerms {
            let key = term.lowercased()
            if let remaining = available[key], remaining > 0 {
                available[key] = remaining - 1
            } else {
                missing.append(term)
            }
        }
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

        /// **An empty denominator is NOT a perfect score, and it used to print
        /// as one.** `total` is the reference length, so `total == 0` means the
        /// reference had nothing of this kind to compare against, not that the
        /// hypothesis was right. Returning 0 there turned "unmeasurable" into
        /// "0.0%", which reads as the best possible result.
        ///
        /// This was live on the real fixtures, and on the metric Andrew ranked
        /// second: two of the five drafts carried no punctuation at all, one of
        /// them across 58 words, so `punctuationErrorRate` would have reported
        /// every model, and the cloud incumbent, as flawless. An empty
        /// `.reference.txt` did the same thing to WER and CER at once.
        var isMeasurable: Bool { total > 0 }

        var value: Double { total == 0 ? 0 : Double(errors) / Double(total) }

        /// Never prints a number that was not measured. `n/a` is ugly in a
        /// table and that is the point: it has to be impossible to skim past.
        var percent: String {
            guard isMeasurable else { return errors == 0 ? "n/a" : "n/a (\(errors) unmatched)" }
            return String(format: "%.1f%%", value * 100)
        }
    }

    /// The WER-to-CER reading, with its own endpoints attached so the number is
    /// interpretable without the reader redoing the arithmetic.
    struct InflectionDiagnostic {
        let wer: Rate
        let cer: Rate
        let referenceWords: Int
        let referenceCharacters: Int

        /// What CER/WER reads when every error is one wrong character.
        var inflectionFloor: Double {
            referenceCharacters == 0 ? 0 : Double(referenceWords) / Double(referenceCharacters)
        }

        /// What CER/WER reads when every error is a whole unrelated word.
        /// Derives the mean word length from the reference rather than assuming
        /// one, because Andrew's Russian and his English differ on it.
        var substitutionCeiling: Double {
            guard referenceCharacters > 0 else { return 0 }
            return Double(referenceCharacters - referenceWords + 1) / Double(referenceCharacters)
        }

        var ratio: Double { wer.value == 0 ? 0 : cer.value / wer.value }

        /// 0 = every error is an ending, 1 = every error is a different word.
        ///
        /// Clamped, because insertions and deletions of whole words, or wrong
        /// words much longer than the reference average, can push the raw ratio
        /// past the ceiling. `ratio` is reported alongside so the clamp is
        /// visible rather than silently absorbed.
        var substitutionShare: Double {
            let span = substitutionCeiling - inflectionFloor
            guard wer.value > 0, span > 0 else { return 0 }
            return min(1, max(0, (ratio - inflectionFloor) / span))
        }

        /// Named in the vocabulary the project already uses for this defect,
        /// so the table reads as an answer rather than as three more numbers.
        ///
        /// Guards on `isMeasurable` BEFORE `wer.value > 0`. Those differ in
        /// exactly the case that matters: an empty reference makes `wer.value`
        /// zero, and reading that as "no errors" would report a clip nobody
        /// could score as a clip every engine got right.
        var verdict: String {
            guard wer.isMeasurable else { return "not measurable" }
            guard wer.value > 0 else { return "no errors" }
            if substitutionShare < 0.35 { return "endings" }
            if substitutionShare > 0.65 { return "wrong words" }
            return "mixed"
        }

        var summary: String {
            guard wer.isMeasurable else { return "not measurable" }
            guard wer.value > 0 else { return "no errors" }
            return String(format: "%.2f %@", substitutionShare, verdict)
        }
    }

    struct BoundaryCount {
        let hypothesis: Int
        let reference: Int

        var delta: Int { hypothesis - reference }

        /// The same zero-denominator trap as `Rate`, one level over, and it
        /// survived the fix to `Rate` because that fix was aimed at the
        /// instance rather than the class. Codex found it in the very next
        /// review: with a reference carrying no sentence endings at all, this
        /// rendered `0/0 matches`, and "matches" reads as the model having got
        /// it right when nothing was compared. Two of the five real drafts had
        /// zero terminators.
        ///
        /// This is LOOP.md's own rule turned on the person applying it: when a
        /// gate is widened in response to a finding, ask what the widened gate
        /// still does not observe.
        var isMeasurable: Bool { reference > 0 }

        /// Named rather than inferred at the call site, so the merging finding
        /// is reported in the vocabulary the project already uses for it.
        var verdict: String {
            guard isMeasurable else { return "n/a" }
            if delta == 0 { return "matches" }
            return delta < 0 ? "merged \(-delta)" : "split \(delta)"
        }
    }

    struct TermPreservation {
        let expected: [String]
        let missing: [String]

        var preserved: Int { expected.count - missing.count }

        /// The fourth site in this file with the same shape. See the note on
        /// `Rate.isMeasurable`: a reference containing no Latin terms at all
        /// rendered `0/0`, which reads as "kept everything" when nothing was
        /// asked for. Most of Andrew's Russian clips have few borrowed terms
        /// and some have none, so this is the common case rather than the edge.
        var isMeasurable: Bool { !expected.isEmpty }

        var summary: String {
            guard isMeasurable else { return "n/a" }
            return missing.isEmpty
                ? "\(preserved)/\(expected.count)"
                : "\(preserved)/\(expected.count), lost: \(missing.joined(separator: ", "))"
        }
    }
}
