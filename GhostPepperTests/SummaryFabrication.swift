import Foundation

/// Measures whether a meeting summary asserts material the transcript never contained.
///
/// WHY THIS EXISTS. On 2026-08-19 a personal conversation in Russian was summarised
/// as a Q3 budget approval, a hiring decision about Poland, and an action item owned by
/// a finance team. None of it was said. The cause was in `MeetingSummaryGenerator.finalSummaryPrompt`, which handed
/// the model three example headings ("### Product Update", "### Hiring Plan",
/// "### Q3 Budget"); the model emitted all three verbatim and then invented content
/// to fill them. The same three headings lead the 2026-08-11 summary too, so the
/// leak is two for two on every summary in his archive that used that prompt.
///
/// A prompt change cannot ship on taste. This is the instrument that says whether it
/// worked, and it has to be trustworthy in both directions: a checker that cries
/// fabrication on honest output gets ignored within a day, which is exactly what the
/// truncation detector did before it was withdrawn on 2026-08-21.
///
/// SO THE CHECKS ARE SPLIT BY WHAT THEY CAN ACTUALLY PROVE.
///
/// `confirmed` findings are language-independent and mechanical. A numeral, a quarter
/// marker, or a corporate concept either is or is not present in the transcript, and
/// Russian inflection cannot hide it because every concept carries its Russian forms.
///
/// `advisory` findings are the proper-noun check. It transliterates Cyrillic and
/// matches on stems, which handles "Британскую Колумбию" -> "British Columbia" and
/// "Карпатами" -> "Carpathian", but it CANNOT handle translation: "Польшей" ->
/// "Poland" shares no letters. Those findings are for human eyes and are never
/// counted as fabrication.
///
/// THE SUPPORT SET IS THE TRANSCRIPT, AND ONLY THE TRANSCRIPT. Not the prompt. If the
/// prompt counted as support then "Q3", which the prompt names, would be supported
/// forever, and the check would go blind to the exact defect it exists to catch.
enum SummaryFabrication {

    // MARK: - Findings

    enum Kind: String {
        /// A heading the prompt named as an example, whose words the transcript does not carry.
        case promptExampleHeading
        /// "Q3" and friends, with no quarter of any kind anywhere in the transcript.
        case unsupportedQuarter
        /// A numeral the transcript never contained, in digits or in words, in either language.
        case unsupportedNumber
        /// A corporate concept ("budget", "recruitment", "finance") absent from the transcript in every form.
        case unsupportedBusinessConcept
        /// A capitalised Latin word with no transliterated match in the transcript. ADVISORY.
        case unsupportedProperNoun
        /// A clock reading in the summary. The prompt forbids them outright, and the
        /// one in his 2026-07-27 summary was invented: a "[01:35]" in a meeting that
        /// never reached 1:35.
        case timestampInSummary
    }

    enum Confidence: String {
        case confirmed
        case advisory
    }

    struct Finding: CustomStringConvertible {
        let kind: Kind
        let confidence: Confidence
        let token: String
        let line: String

        var description: String {
            "[\(confidence.rawValue)] \(kind.rawValue): \"\(token)\"  in: \(line.prefix(110))"
        }
    }

    struct Report {
        let findings: [Finding]

        var confirmed: [Finding] { findings.filter { $0.confidence == .confirmed } }
        var advisory: [Finding] { findings.filter { $0.confidence == .advisory } }

        func confirmed(_ kind: Kind) -> [Finding] {
            confirmed.filter { $0.kind == kind }
        }

        var summaryLine: String {
            "\(confirmed.count) confirmed, \(advisory.count) advisory"
        }

        var detail: String {
            findings.isEmpty ? "  (none)" : findings.map { "  \($0)" }.joined(separator: "\n")
        }
    }

    // MARK: - Entry point

    /// - Parameters:
    ///   - summary: the model's summary text.
    ///   - transcript: everything the model was shown, timestamps and speaker prefixes included.
    ///     They are part of the input, so material drawn from them is not invented.
    ///   - prompt: the summarisation prompt, read ONLY to learn which headings it offers
    ///     as examples. It never contributes support.
    static func check(summary: String, transcript: String, prompt: String) -> Report {
        let support = SupportIndex(transcript: transcript)
        let exampleHeadings = Self.exampleHeadings(in: prompt) + Self.historicallyLeakedHeadings

        var findings: [Finding] = []
        findings += timestampFindings(summary: summary)
        findings += headingFindings(summary: summary, support: support, examples: exampleHeadings)
        findings += quarterFindings(summary: summary, support: support)
        findings += numberFindings(summary: summary, support: support)
        findings += conceptFindings(summary: summary, support: support)
        findings += properNounFindings(summary: summary, support: support)
        return Report(findings: findings)
    }

    // MARK: - Prompt example headings

    /// Headings the prompt itself offers, however they are written.
    ///
    /// THE RULE IS CAPITALISATION, NOT QUOTING. The first version matched only
    /// `"### Product Update"` in double quotes, so all of these slipped past it and
    /// the regression guard passed green:
    ///
    ///     e.g. ### Product Update, ### Hiring Plan
    ///     e.g. '### Product Update' or `### Hiring Plan`
    ///
    /// which is the most natural way to write them and exactly how someone reflowing
    /// the old line would end up writing them. A `###` followed by a CAPITALISED word
    /// is an instance of a heading; a `###` followed by a lowercase word is the prompt
    /// talking about headings ("use ### headings", "as a ### heading"), which is what
    /// it is supposed to do.
    static func exampleHeadings(in prompt: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "#{1,6}\\s*([A-ZА-Я][^\"'`,)\\n]*)")
        let range = NSRange(prompt.startIndex..., in: prompt)
        return pattern.matches(in: prompt, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: prompt) else { return nil }
            let text = String(prompt[r]).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
    }

    /// The three that actually leaked into Andrew's vault, kept after the prompt stops
    /// naming them. Without this the check would be vacuous the moment the fix lands:
    /// no examples in the prompt means nothing to compare against, and a check that
    /// tests nothing is worse than no check, because it still reports success.
    static let historicallyLeakedHeadings = ["Product Update", "Hiring Plan", "Q3 Budget"]

    private static func headingFindings(summary: String, support: SupportIndex, examples: [String]) -> [Finding] {
        let normalisedExamples = Set(examples.map(normaliseHeading))
        guard !normalisedExamples.isEmpty else { return [] }

        var findings: [Finding] = []
        for line in summary.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            let normalised = normaliseHeading(text)
            guard !normalised.isEmpty else { continue }

            // "Q3 Budget (Q3)" must still match the example "Q3 Budget", so a prefix
            // counts. The model decorates headings; it does not rename them.
            let matched = normalisedExamples.contains { normalised == $0 || normalised.hasPrefix($0) }
            guard matched else { continue }

            // A meeting really can be about a product update. The heading is only
            // evidence of fabrication when the transcript carries none of its words.
            //
            // STRICT MATCHING HERE, not the transliterating one. At a four-character
            // stem "продолжим" ("let's continue") transliterates to "prodolzhim" and
            // supports "product", and "план" supports "plan", so the leading
            // "### Product Update" of the 2026-08-19 summary would have been downgraded
            // to advisory over a Russian transcript and vanished from the number this
            // whole change is judged on. Heading words are English common nouns:
            // transliteration cannot establish their Russian equivalents anyway, so it
            // has nothing to offer here except collisions.
            let words = contentWords(of: text)
            let anySupported = words.contains { support.supportsStrictly(word: $0) }
            findings.append(Finding(
                kind: .promptExampleHeading,
                confidence: anySupported ? .advisory : .confirmed,
                token: text,
                line: trimmed
            ))
        }
        return findings
    }

    private static func normaliseHeading(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Quarters

    /// "Q3" is its own class rather than a number, because the transcript says "три"
    /// ("three") and that would otherwise make Q3 supported by a word about weeks.
    private static let quarterPattern = try! NSRegularExpression(pattern: "\\bQ[1-4]\\b", options: [.caseInsensitive])

    private static func quarterFindings(summary: String, support: SupportIndex) -> [Finding] {
        guard !support.hasQuarterMarker else { return [] }
        var findings: [Finding] = []
        var seen = Set<String>()
        for line in summary.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            for match in quarterPattern.matches(in: line, range: range) {
                guard let r = Range(match.range, in: line) else { continue }
                let token = String(line[r])
                guard seen.insert(token + line).inserted else { continue }
                findings.append(Finding(
                    kind: .unsupportedQuarter,
                    confidence: .confirmed,
                    token: token,
                    line: line.trimmingCharacters(in: .whitespaces)
                ))
            }
        }
        return findings
    }

    // MARK: - Timestamps

    /// The prompt says "NEVER write timestamps such as [00:30]". A summary that
    /// carries one is quoting the transcript's shape at best and inventing a clock
    /// reading at worst, and it is judged here rather than through the number check:
    /// the transcript's own timestamps are stripped from the support set, so a
    /// summary timestamp would otherwise surface as a mysterious unsupported number.
    private static func timestampFindings(summary: String) -> [Finding] {
        let pattern = try! NSRegularExpression(pattern: "\\[\\d{1,2}:\\d{2}(?::\\d{2})?\\]")
        var findings: [Finding] = []
        for line in summary.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            for match in pattern.matches(in: line, range: range) {
                guard let r = Range(match.range, in: line) else { continue }
                findings.append(Finding(
                    kind: .timestampInSummary,
                    confidence: .confirmed,
                    token: String(line[r]),
                    line: line.trimmingCharacters(in: .whitespaces)
                ))
            }
        }
        return findings
    }

    // MARK: - Numbers

    private static func numberFindings(summary: String, support: SupportIndex) -> [Finding] {
        var findings: [Finding] = []
        var seen = Set<Int>()

        for rawLine in strippingTimestamps(from: summary).components(separatedBy: .newlines) {
            var line = strippingMarkdownStructure(rawLine)
            line = partLabelPattern.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: " "
            )
            // A quarter marker's digit is judged by the quarter check, not here.
            let scannable = quarterPattern.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: ""
            )
            for token in scannable.split(whereSeparator: { !$0.isNumber }) {
                guard let value = Int(token) else { continue }
                // 0 and 1 are structure, not content: list markers, "1:1", "one of".
                // Flagging them buys nothing and costs the whole check its credibility.
                guard value >= 2 else { continue }
                guard !support.supports(number: value) else { continue }
                guard seen.insert(value).inserted else { continue }
                findings.append(Finding(
                    kind: .unsupportedNumber,
                    confidence: .confirmed,
                    token: String(token),
                    line: rawLine.trimmingCharacters(in: .whitespaces)
                ))
            }
        }
        return findings
    }

    /// `MeetingSummaryGenerator` feeds long meetings in pieces, each headed
    /// "Meeting transcript (part 3 of 5)". A summary that comes back saying "(Part 3)"
    /// is leaking that scaffolding, which is a different fault from inventing a
    /// number, and counting it as fabrication overstates the count. Measured on
    /// 2026-08-21: two of thirteen remaining findings were exactly this.
    private static let partLabelPattern = try! NSRegularExpression(
        pattern: "\\bparts?\\s+\\d+(\\s+of\\s+\\d+)?",
        options: [.caseInsensitive]
    )

    private static let orderedListMarker = try! NSRegularExpression(pattern: "^\\d+[.)]\\s")

    /// Markdown the model was told to emit is not something it made up.
    ///
    /// The bullet and emphasis run is stripped BEFORE the ordered-list marker is
    /// looked for, because the model writes "**3. Video Recording Plan**" and the
    /// leading asterisks hid the list number from the check. Measured 2026-08-21: two
    /// of twelve remaining findings were list numbers reported as invented facts.
    private static func strippingMarkdownStructure(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- [ ]", "- [x]", "* [ ]", "* [x]"] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
        }
        while let first = text.first, first == "*" || first == "-" || first == "+" || first == ">" || first == " " {
            text = String(text.dropFirst())
        }
        if let first = orderedListMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(first.range, in: text) {
            text = String(text[r.upperBound...])
        }
        return text
    }

    // MARK: - Corporate concepts

    /// Concepts a small model reaches for when it has been handed a corporate-shaped
    /// heading and nothing real to put under it.
    ///
    /// EVERY CONCEPT CARRIES ITS RUSSIAN FORMS, and a concept is supported if ANY form
    /// appears in the transcript. That is what stops this being a check that fires on
    /// every Russian meeting: if he really did discuss a budget he said "бюджет", and
    /// the concept is supported. Matching is by token PREFIX, so "бюджета",
    /// "бюджетом" and "budgetary" all support "budget" without a stemmer.
    struct Concept {
        let label: String
        let forms: [String]
    }

    static let concepts: [Concept] = [
        Concept(label: "budget", forms: ["budget", "бюджет"]),
        Concept(label: "finance", forms: ["financ", "финанс", "бухгалт"]),
        Concept(label: "expenses", forms: ["expens", "expenditure", "расход", "затрат", "трат"]),
        Concept(label: "revenue", forms: ["revenue", "profit", "margin", "выручк", "прибыл", "маржа", "доход"]),
        Concept(label: "invoice", forms: ["invoice", "инвойс", "счет", "счёт"]),
        Concept(label: "recruitment", forms: ["recruit", "hiring", "hire", "hired", "onboarding", "candidate",
                                             "наним", "нанял", "найм", "рекрут", "ваканс", "собеседов", "кандидат", "онбординг"]),
        Concept(label: "headcount", forms: ["headcount", "штат"]),
        Concept(label: "team", forms: ["team", "команд", "сотрудник", "коллег"]),
        Concept(label: "stakeholder", forms: ["stakeholder", "стейкхолдер"]),
        Concept(label: "quarterly", forms: ["quarter", "квартал"]),
        Concept(label: "roadmap", forms: ["roadmap", "роадмап", "дорожн"]),
        Concept(label: "sprint", forms: ["sprint", "спринт"]),
        Concept(label: "milestone", forms: ["milestone", "веха", "вех"]),
        Concept(label: "deadline", forms: ["deadline", "дедлайн", "срок"]),
        Concept(label: "contract", forms: ["contract", "контракт", "договор"]),
        Concept(label: "approval", forms: ["approv", "одобр", "утверд", "согласов"]),
        Concept(label: "kpi", forms: ["kpi", "okr", "кипиай"]),
    ]

    /// Words that turn a mention into a denial. Checked only to the LEFT of the term.
    private static let negationCues = [
        "no ", "not ", "n't", "none", "nothing", "never", "without", "absent",
        "не ", "нет", "без ",
    ]

    private static func conceptFindings(summary: String, support: SupportIndex) -> [Finding] {
        var findings: [Finding] = []
        for concept in concepts {
            guard !concept.forms.contains(where: { support.contains(form: $0) }) else { continue }
            // A CONCEPT NAMED ONLY TO SAY IT WAS ABSENT IS NOT A FABRICATION.
            // "no tasks, owners, or deadlines were mentioned" is the model abstaining,
            // which is the behaviour this whole change exists to encourage, and the
            // first version of this check reported it as an invented deadline. A
            // checker that punishes honesty is worse than no checker.
            let lines = linesAsserting(concept, in: summary)
            guard let line = lines.first else { continue }
            findings.append(Finding(
                kind: .unsupportedBusinessConcept,
                confidence: .confirmed,
                token: concept.label,
                line: line
            ))
        }
        return findings
    }

    /// Lines where the concept appears as a claim rather than as a denial.
    private static func linesAsserting(_ concept: Concept, in summary: String) -> [String] {
        var results: [String] = []
        for raw in summary.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lowered = line.lowercased()
            guard let range = firstOccurrence(of: concept, in: lowered) else { continue }
            let before = String(lowered[lowered.startIndex..<range])
            guard !negationCues.contains(where: { before.contains($0) }) else { continue }
            results.append(line)
        }
        return results
    }

    private static func firstOccurrence(of concept: Concept, in lowered: String) -> String.Index? {
        var earliest: String.Index?
        for form in concept.forms {
            guard let found = lowered.range(of: form) else { continue }
            // Token prefix, not substring: "hir" must not match inside "third".
            //
            // The guard has to come BEFORE `index(before:)`, not after it. Written the
            // other way round this traps on any line beginning with a concept word
            // ("Budget was approved yesterday."), which on a Russian transcript is the
            // common case rather than a corner one, and it aborts the process instead
            // of failing a test.
            if found.lowerBound != lowered.startIndex {
                let preceding = lowered[lowered.index(before: found.lowerBound)]
                if preceding.isLetter || preceding.isNumber { continue }
            }
            if earliest == nil || found.lowerBound < earliest! { earliest = found.lowerBound }
        }
        return earliest
    }

    // MARK: - Proper nouns (ADVISORY ONLY)

    /// ONLY MID-SENTENCE CAPITALS COUNT.
    ///
    /// The first draft of this check flagged 21 words on the 2026-08-19 summary, of
    /// which two were real: "Combined", "Part", "Write", "Each", "Outcome", "Review",
    /// "Scope" and the rest are ordinary English words that a heading, a bold label or
    /// the start of a sentence happened to capitalise. A check that is wrong nineteen
    /// times out of twenty-one is the truncation detector again, and that one cost an
    /// hour before it was withdrawn.
    ///
    /// A word capitalised in the MIDDLE of a sentence is a name, a place or an
    /// acronym. That is the only position where capitalisation carries information,
    /// so it is the only position this check looks at.
    private static func properNounFindings(summary: String, support: SupportIndex) -> [Finding] {
        var findings: [Finding] = []
        var seen = Set<String>()
        for line in summary.components(separatedBy: .newlines) {
            for word in midSentenceCapitals(in: line) {
                let lower = word.lowercased()
                guard !properNounStopWords.contains(lower) else { continue }
                guard !support.supports(word: lower) else { continue }
                guard seen.insert(lower).inserted else { continue }
                findings.append(Finding(
                    kind: .unsupportedProperNoun,
                    confidence: .advisory,
                    token: word,
                    line: line.trimmingCharacters(in: .whitespaces)
                ))
            }
        }
        return findings
    }

    /// Words that follow markdown structure are not sentence-initial in the ordinary
    /// sense, but they are capitalised for the same reason, so they are excluded too.
    private static let properNounStopWords: Set<String> = [
        "me", "others", "the", "and", "but", "for", "with",
    ]

    /// Capitalised words that are neither sentence-initial nor part of a Title Case
    /// run, on lines that are not headings.
    ///
    /// TITLE CASE IS THE NOISE. "Financial Planning", "Finance Team", "Next Steps",
    /// "Budget Manager" and "Onboarding Process" are capitalised because they sit in a
    /// heading or behind a bold label, not because anyone named anything. Every one of
    /// them was a false positive in the first draft. A capitalised word standing ALONE
    /// between lowercase words is the shape that carries information: "from Poland
    /// and", "referring to Ukraine or".
    static func midSentenceCapitals(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return [] }

        var words: [(text: String, startsSentence: Bool, capitalised: Bool)] = []
        var atSentenceStart = true
        var current = ""
        var currentStartsSentence = true

        func flush() {
            defer {
                // A completed word leaves the next position mid-sentence. Without
                // this, the "*" on a bullet line kept every word on that line looking
                // sentence-initial, and the check silently stopped examining anything
                // after a list marker.
                if !current.isEmpty { atSentenceStart = false }
                current = ""
            }
            guard !current.isEmpty else { return }
            let capitalised = current.first.map { $0.isUppercase && $0.isASCII } ?? false
            words.append((current, currentStartsSentence, capitalised))
        }

        for character in line {
            if character.isLetter || character == "'" {
                if current.isEmpty { currentStartsSentence = atSentenceStart }
                current.append(character)
                continue
            }
            flush()
            switch character {
            case ".", "!", "?", ":", ";", "|", ">", "#", "*", "-", "_", "(", "[", "/", "\u{2014}":
                // Structure and sentence ends both restore "start" position. An opening
                // bracket counts because "(Hiring)" and "(likely ...)" begin there.
                atSentenceStart = true
            case " ", "\t", ",", "\"", "&", "\u{2019}":
                break
            default:
                atSentenceStart = false
            }
        }
        flush()

        var results: [String] = []
        for (index, word) in words.enumerated() {
            guard word.capitalised, !word.startsSentence, word.text.count >= 3 else { continue }
            let previousCapitalised = index > 0 && words[index - 1].capitalised
            let nextCapitalised = index + 1 < words.count && words[index + 1].capitalised
            guard !previousCapitalised, !nextCapitalised else { continue }
            results.append(word.text)
        }
        return results
    }

    // MARK: - Support index

    /// Everything the transcript can vouch for, in a form Russian inflection cannot hide.
    struct SupportIndex {
        private let lowered: String
        private let tokens: Set<String>
        private let loosePrefixes: Set<String>
        private let looseForms: Set<String>
        private let numbers: Set<Int>
        let hasQuarterMarker: Bool

        /// The stem length. Shorter and "car" starts matching "Carpathian" by accident;
        /// longer and "Колумбию" stops reaching "Columbia".
        static let stemLength = 4

        init(transcript: String) {
            var tokens = Set<String>()
            var loosePrefixes = Set<String>()
            var looseForms = Set<String>()
            var numbers = Set<Int>()

            // TIMESTAMPS ARE STRIPPED BEFORE ANYTHING IS INDEXED.
            //
            // The transcript the model sees is "[01:10] Me: ...", so it would be easy
            // to argue that 1 and 10 are material it was given. They are not material
            // it may USE: this same prompt says "NEVER write timestamps", and a
            // summary asserting "10 minutes" over a transcript whose only 10 is a
            // clock reading is inventing a duration. Codex caught this on 2026-08-21;
            // with timestamps indexed, a fabricated number was hidden whenever it
            // happened to collide with a minute or a second.
            let lowered = SummaryFabrication.strippingTimestamps(from: transcript).lowercased()
            var run: [Int] = []
            for raw in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let token = String(raw)
                tokens.insert(token)
                let loose = SummaryFabrication.looseForm(token)
                looseForms.insert(loose)
                if loose.count >= Self.stemLength {
                    loosePrefixes.insert(String(loose.prefix(Self.stemLength)))
                }
                if let value = Int(token) { numbers.insert(value) }
                if let value = SummaryFabrication.numberValue(for: token) {
                    numbers.insert(value)
                    run.append(value)
                } else if !run.isEmpty {
                    numbers.formUnion(SummaryFabrication.compositions(of: run))
                    run.removeAll()
                }
            }

            if !run.isEmpty { numbers.formUnion(SummaryFabrication.compositions(of: run)) }

            self.lowered = lowered
            self.tokens = tokens
            self.loosePrefixes = loosePrefixes
            self.looseForms = looseForms
            self.numbers = numbers
            self.hasQuarterMarker = SummaryFabrication.quarterPattern
                .firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)) != nil
                || tokens.contains { $0.hasPrefix("quarter") || $0.hasPrefix("квартал") }
        }

        func supports(number: Int) -> Bool { numbers.contains(number) }

        /// Exact token, or a same-script inflection of it. No transliteration.
        /// Used where a cross-script guess would cost more than it buys: see
        /// `headingFindings`.
        func supportsStrictly(word: String) -> Bool {
            let lower = word.lowercased()
            if tokens.contains(lower) { return true }
            guard lower.count >= 5 else { return false }
            let prefix = String(lower.prefix(5))
            return tokens.contains { $0.hasPrefix(prefix) }
        }

        /// A word is supported if the transcript carries it, an inflection of it, or a
        /// transliteration of it.
        func supports(word: String) -> Bool {
            let lower = word.lowercased()
            if tokens.contains(lower) { return true }
            let stem = SummaryFabrication.looseForm(lower)
            if looseForms.contains(stem) { return true }
            guard stem.count >= Self.stemLength else { return false }
            return loosePrefixes.contains(String(stem.prefix(Self.stemLength)))
        }

        /// Multi-word forms are matched as substrings; single words by token prefix,
        /// which is what makes "бюджета" support "бюджет".
        func contains(form: String) -> Bool {
            if form.contains(" ") {
                return lowered.contains(form)
            }
            return tokens.contains { $0.hasPrefix(form) }
        }
    }

    /// Removes `[MM:SS]` and `[H:MM:SS]` clock readings. See `SupportIndex.init`.
    static func strippingTimestamps(from text: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "\\[\\d{1,2}:\\d{2}(?::\\d{2})?\\]")
        return pattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
    }

    /// Cyrillic transliterated to Latin, then folded so that spelling conventions
    /// stop mattering: k and c, y and i. "Колумбию" and "Columbia" meet here.
    /// It does NOT bridge translation, which is why the proper-noun check is advisory:
    /// "Польшей" and "Poland" have nothing in common to match on.
    static func looseForm(_ token: String) -> String {
        var out = ""
        for character in token.lowercased() {
            out += cyrillicToLatin[character] ?? String(character)
        }
        out = out.replacingOccurrences(of: "kh", with: "h")
        var folded = ""
        var previous: Character?
        for character in out {
            var c = character
            if c == "k" { c = "c" }
            if c == "y" { c = "i" }
            if c == previous { continue }
            folded.append(c)
            previous = c
        }
        return folded
    }

    private static let cyrillicToLatin: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
        "ж": "zh", "з": "z", "и": "i", "й": "i", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    ]

    /// Every value a run of spoken number words can add up to.
    ///
    /// "две тысячи девятнадцатом" is 2019, "сто двадцать" is 120, "twenty five" is 25.
    /// Indexed word by word they support 2, 1000, 19, 100, 20 and 5 and none of the
    /// totals, so an honest summary writing the digits reads as invented. Found by an
    /// independent reviewer on 2026-08-21, with four worked examples.
    ///
    /// Every intermediate is inserted, not just the total, because a summary may
    /// legitimately write either. The number table only ever ADDS support, so being
    /// generous here can weaken detection slightly and can never manufacture a false
    /// positive. That is the correct direction for a check whose credibility is the
    /// whole point.
    static func compositions(of run: [Int]) -> Set<Int> {
        var values = Set<Int>()
        var total = 0
        var current = 0
        for value in run {
            if value >= 1000 {
                current = max(current, 1) * value
                total += current
                current = 0
            } else if value >= 100 {
                current = max(current, 1) * value
            } else {
                current += value
            }
            values.insert(total + current)
        }
        values.insert(total + current)
        return values
    }

    /// The value of a spoken number word, cardinal or ordinal, in either language.
    ///
    /// Russian ordinals inflect too heavily to enumerate ("первый", "первого",
    /// "первом", "первую"), so the long unambiguous stems are matched by prefix and
    /// only the short or colliding ones are listed exactly. Longest stem wins, so
    /// "пятьдесят" cannot be swallowed by "пят".
    static func numberValue(for token: String) -> Int? {
        if let value = numberWords[token] { return value }
        var best: (length: Int, value: Int)?
        for (stem, value) in numberStems where token.hasPrefix(stem) {
            if best == nil || stem.count > best!.length { best = (stem.count, value) }
        }
        return best?.value
    }

    /// Stems long enough that a prefix match cannot collide with an ordinary word.
    static let numberStems: [String: Int] = [
        "одиннадцат": 11, "двенадцат": 12, "тринадцат": 13, "четырнадцат": 14,
        "пятнадцат": 15, "шестнадцат": 16, "семнадцат": 17, "восемнадцат": 18,
        "девятнадцат": 19, "двадцат": 20, "тридцат": 30, "сорока": 40,
        "пятьдесят": 50, "пятидесят": 50, "шестьдесят": 60, "шестидесят": 60,
        "семьдесят": 70, "семидесят": 70, "восемьдесят": 80, "восьмидесят": 80,
        "девяност": 90, "тысяч": 1000, "миллион": 1_000_000,
        "первый": 1, "первого": 1, "первое": 1, "первом": 1, "первая": 1, "первую": 1,
        "второй": 2, "второго": 2, "вторая": 2, "втором": 2,
        "третий": 3, "третьего": 3, "третья": 3, "третьем": 3,
        "четверт": 4, "пятого": 5, "пятый": 5, "шестого": 6, "шестой": 6,
        "седьмо": 7, "восьмо": 8, "девято": 9, "десято": 10,
    ]

    /// Numbers he SAID rather than wrote. Without this, a transcript saying "три
    /// недели" makes the summary's "3 weeks" look invented, which it is not.
    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100,
        "thousand": 1000, "million": 1_000_000,

        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
        "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
        "hundredth": 100, "thousandth": 1000,

        "один": 1, "одна": 1, "одно": 1, "два": 2, "две": 2, "три": 3, "четыре": 4,
        "пять": 5, "шесть": 6, "семь": 7, "восемь": 8, "девять": 9, "десять": 10,
        "одиннадцать": 11, "двенадцать": 12, "тринадцать": 13, "четырнадцать": 14,
        "пятнадцать": 15, "шестнадцать": 16, "семнадцать": 17, "восемнадцать": 18,
        "девятнадцать": 19, "двадцать": 20, "тридцать": 30, "сорок": 40,
        "пятьдесят": 50, "шестьдесят": 60, "семьдесят": 70, "восемьдесят": 80,
        "девяносто": 90, "сто": 100, "ста": 100, "сот": 100, "сотня": 100, "сотен": 100,
        "тысяча": 1000, "тысячи": 1000, "тысяч": 1000, "миллион": 1_000_000,
        "двух": 2, "трех": 3, "трёх": 3, "четырех": 4, "четырёх": 4, "пяти": 5,
        "шести": 6, "семи": 7, "восьми": 8, "девяти": 9, "десяти": 10, "одного": 1,
    ]

    /// Words a heading carries because the prompt asked for that shape, not because
    /// the meeting was about them. A heading made only of these tells us nothing.
    private static let structuralHeadingWords: Set<String> = [
        "next", "steps", "step", "action", "items", "item", "owner", "key", "facts",
        "decisions", "decision", "topic", "topics", "summary", "meeting", "notes",
        "note", "task", "tasks", "the", "and", "for",
    ]

    private static func contentWords(of text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !structuralHeadingWords.contains($0) }
    }
}
