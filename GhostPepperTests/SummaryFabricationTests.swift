import XCTest
@testable import GhostPepper

/// Calibration for `SummaryFabrication`, on synthetic material only.
///
/// Andrew's real transcripts are the eval corpus (see `MeetingSummaryEvalTests`),
/// and they are never committed. Everything here is invented for the test, and it
/// deliberately reproduces the SHAPES that made the real checker hard rather than
/// his content: a Russian transcript, an English summary, transliterated place
/// names, a number spoken as a word, and a quarter marker that shares a digit with
/// something genuinely said.
///
/// A checker that is wrong on honest output gets ignored inside a day. So the honest
/// cases here matter more than the fabricated one.
final class SummaryFabricationTests: XCTestCase {

    /// INVENTED, and deliberately not a paraphrase of anything he said. The first
    /// draft rewrote one of his own sentences almost word for word, which is a
    /// transcript in a committed file wearing a disguise. His decision of 2026-08-21
    /// is that his transcripts are the eval corpus and are never committed; the eval
    /// reads them from outside the repo (`MeetingSummaryEvalTests`). Place names are
    /// not transcript content, so they stay: they are what the transliteration check
    /// needs.
    ///
    /// THE TIMESTAMPS ARE CHOSEN, not decoration. The first draft carried "[01:10]",
    /// and the number check indexed it, so the test asserting that "10 minutes" was
    /// invented failed on its own fixture. Codex found the same thing from the other
    /// end on 2026-08-21, and the checker changed rather than the fixture: clock
    /// readings no longer support anything. These stay distinct anyway, so that a
    /// regression in the stripping cannot hide behind a lucky fixture.
    static let transcript = """
    **[00:00] Me:** привет как дела давно не виделись наверное месяц прошел
    **[00:22] Others:** нормально чинил велосипед две недели возился с ним
    **[00:47] Me:** на выходных поеду из Торонто в Ванкувер поездом это долго
    **[01:19] Others:** там сейчас как в Калифорнии по времени да
    """

    /// The failure shape from 2026-08-19: the prompt's example headings, filled in.
    static let fabricatedSummary = """
    ### Product Update
    *   **Duration:** 10 minutes.

    ### Hiring Plan
    *   The meeting focused on the recruitment of a team member from Poland.

    ### Q3 Budget
    *   The budget for Q3 was discussed and approved.

    ### Next Steps
    *   [ ] Review Q3 budget details with the finance team.
    """

    /// Honest, and deliberately full of the things that trip a naive matcher:
    /// transliterated place names and a number that was spoken as a Russian word.
    static let honestSummary = """
    ### The trip
    *   He is taking the train from Toronto to Vancouver at the weekend.

    ### The bicycle
    *   The other person spent 2 weeks repairing a bicycle.
    """

    static let promptWithExamples = """
    - Use ### headings for each major topic discussed (e.g., "### Product Update", "### Hiring Plan", "### Q3 Budget")
    """

    private func check(_ summary: String, _ transcript: String = SummaryFabricationTests.transcript) -> SummaryFabrication.Report {
        SummaryFabrication.check(summary: summary, transcript: transcript, prompt: Self.promptWithExamples)
    }

    // MARK: - The defect

    func testCatchesTheFabricationShapeFrom20260819() {
        let report = check(Self.fabricatedSummary)
        XCTAssertFalse(report.confirmed(.promptExampleHeading).isEmpty,
                       "the prompt's own example headings, echoed verbatim, must be caught")
        XCTAssertFalse(report.confirmed(.unsupportedQuarter).isEmpty,
                       "Q3 was never said")
        XCTAssertFalse(report.confirmed(.unsupportedNumber).isEmpty,
                       "a duration of 10 minutes was never said")
        XCTAssertFalse(report.confirmed(.unsupportedBusinessConcept).isEmpty,
                       "budget, recruitment and finance were never said, in either language")
    }

    // MARK: - Honest output must score zero

    func testHonestSummaryIsClean() {
        let report = check(Self.honestSummary)
        XCTAssertTrue(report.confirmed.isEmpty,
                      "an honest summary was flagged, which is how a checker gets ignored:\n\(report.detail)")
    }

    func testTranscriptCheckedAgainstItselfIsClean() {
        // A transcript is entirely supported by itself, by definition. This is the
        // false-positive measurement that needs no judgement about what the meeting
        // was "really" about.
        //
        // Timestamps are stripped from the pseudo-summary because a raw transcript is
        // not summary-shaped: the question here is whether honest CONTENT scores zero,
        // not whether a transcript obeys the summary's formatting rules.
        let report = check(SummaryFabrication.strippingTimestamps(from: Self.transcript))
        XCTAssertTrue(report.confirmed.isEmpty, "self-check found a fabrication:\n\(report.detail)")
    }

    func testHonestAbstentionIsClean() {
        let report = check("No decisions, facts or commitments were found in the transcript.")
        XCTAssertTrue(report.confirmed.isEmpty, report.detail)
    }

    // MARK: - The specific traps

    func testTransliteratedPlaceNamesCountAsSupported() {
        // "Британскую Колумбию" and "British Columbia" are the same place. A checker
        // that cannot see that flags every summary of a Russian meeting.
        let index = SummaryFabrication.SupportIndex(transcript: Self.transcript)
        XCTAssertTrue(index.supports(word: "toronto"), "Торонто should support Toronto")
        XCTAssertTrue(index.supports(word: "vancouver"), "Ванкувер should support Vancouver")
        XCTAssertTrue(index.supports(word: "california"), "Калифорнии should support California")
    }

    func testANumberSpokenAsARussianWordSupportsItsDigits() {
        let index = SummaryFabrication.SupportIndex(transcript: Self.transcript)
        XCTAssertTrue(index.supports(number: 2), "две недели was said, so \"2 weeks\" is not invented")
        XCTAssertFalse(index.supports(number: 10), "nothing in this transcript says or shows ten")
    }

    func testAClockReadingDoesNotSupportANumber() {
        // The prompt forbids the model from writing timestamps at all, so the digits
        // in one are not material it may use. A summary claiming "10 minutes" over a
        // transcript whose only 10 is a clock reading is inventing a duration.
        let index = SummaryFabrication.SupportIndex(transcript: "**[00:10] Me:** привет")
        XCTAssertFalse(index.supports(number: 10), "a timestamp is not a fact that was stated")
    }

    func testATimestampInTheSummaryIsItsOwnFinding() {
        // His 2026-07-27 summary carried "[01:35]" in a meeting that never reached
        // 1:35. Reported as a timestamp rather than as a stray unsupported number,
        // because that is what it is.
        let report = check("[01:35] Me: something was said")
        XCTAssertEqual(report.confirmed(.timestampInSummary).count, 1, report.detail)
        XCTAssertTrue(report.confirmed(.unsupportedNumber).isEmpty,
                      "a clock reading must be reported once, not twice:\n\(report.detail)")
    }

    func testATwoWordNumberSupportsItsCombinedValue() {
        // "twenty five" and "двадцать пять" are one number said as two words. Indexed
        // separately they support 20 and 5, and an honest summary writing 25 reads as
        // invented. Codex, 2026-08-21.
        let russian = SummaryFabrication.SupportIndex(transcript: "мы ждали двадцать пять минут")
        XCTAssertTrue(russian.supports(number: 25))
        let english = SummaryFabrication.SupportIndex(transcript: "we waited twenty five minutes")
        XCTAssertTrue(english.supports(number: 25))
        let hundreds = SummaryFabrication.SupportIndex(transcript: "there were six hundred people")
        XCTAssertTrue(hundreds.supports(number: 600))
    }

    func testAQuarterIsRecognisedInEitherCase() {
        // A transcript saying "q3" supports a summary saying "Q3", and a summary
        // saying "q3" is still checked. Codex, 2026-08-21.
        let supported = SummaryFabrication.check(
            summary: "*   The Q3 plan.",
            transcript: "**[00:00] Me:** we talked about the q3 plan",
            prompt: Self.promptWithExamples
        )
        XCTAssertTrue(supported.confirmed(.unsupportedQuarter).isEmpty, supported.detail)

        let lowercase = check("*   the q3 plan was agreed")
        XCTAssertEqual(lowercase.confirmed(.unsupportedQuarter).count, 1, lowercase.detail)
    }

    func testQuarterMarkerIsNotSupportedByASharedDigit() {
        // The trap that made the quarter its own check: "три"/"две" put small digits
        // into the support set, and Q3 would have ridden in on one of them.
        let transcript = "**[00:00] Me:** мы три недели это делали"
        let report = SummaryFabrication.check(
            summary: "*   The Q3 budget was approved.",
            transcript: transcript,
            prompt: Self.promptWithExamples
        )
        XCTAssertEqual(report.confirmed(.unsupportedQuarter).count, 1,
                       "Q3 must not be supported by the digit 3 in \"три недели\"")
    }

    func testAQuarterThatWasActuallyDiscussedIsNotFlagged() {
        let report = SummaryFabrication.check(
            summary: "*   The Q3 budget was approved.",
            transcript: "**[00:00] Me:** мы обсудили бюджет на третий квартал, Q3",
            prompt: Self.promptWithExamples
        )
        XCTAssertTrue(report.confirmed(.unsupportedQuarter).isEmpty, report.detail)
    }

    func testACorporateConceptSaidInRussianIsSupported() {
        let report = SummaryFabrication.check(
            summary: "*   The budget was approved and the team agreed.",
            transcript: "**[00:00] Me:** мы утвердили бюджет и вся команда согласна",
            prompt: Self.promptWithExamples
        )
        XCTAssertTrue(report.confirmed(.unsupportedBusinessConcept).isEmpty,
                      "бюджет, команда and утвердили support budget, team and approval:\n\(report.detail)")
    }

    func testMarkdownStructureIsNotCountedAsAnInventedNumber() {
        let report = check("""
        1. First point.
        2. Second point.
        - [ ] A task
        """)
        XCTAssertTrue(report.confirmed(.unsupportedNumber).isEmpty,
                      "list markers are the shape the prompt asked for, not invented numbers:\n\(report.detail)")
    }

    func testAConceptNamedOnlyToSayItWasAbsentIsNotAFabrication() {
        // "no tasks, owners, or deadlines were mentioned" is the model abstaining.
        // Reporting that as an invented deadline punishes exactly the behaviour this
        // change exists to encourage. Found in the 2026-08-21 measurement.
        let report = check("*   [ ] No action items were assigned; no tasks, owners, or deadlines were mentioned.")
        XCTAssertTrue(report.confirmed(.unsupportedBusinessConcept).isEmpty, report.detail)
    }

    func testTheSameConceptAssertedElsewhereIsStillCaught() {
        let report = check("""
        *   No deadlines were mentioned.
        *   The deadline is Friday.
        """)
        XCTAssertEqual(report.confirmed(.unsupportedBusinessConcept).count, 1, report.detail)
    }

    func testTheGeneratorsOwnPartLabelIsNotAnInventedNumber() {
        // Long meetings are fed in pieces headed "Meeting transcript (part 3 of 5)".
        // A summary echoing "(Part 3)" is leaking scaffolding, not inventing a number.
        // Numbers ONLY inside the part labels, so a failure here can only mean the
        // labels were scanned. The first draft of this test used "**2." and "**3."
        // list prefixes and failed on those instead, which would have proved nothing.
        let report = check("*   Budget allocation (Part 7)\n*   Video plan (Part 8 of 9)")
        XCTAssertTrue(report.confirmed(.unsupportedNumber).isEmpty, report.detail)
    }

    func testABoldNumberedListMarkerIsNotAnInventedNumber() {
        // The model writes "**3. Video Recording Plan**". The leading asterisks used
        // to hide the list number from the ordered-list stripper, and it was reported
        // as an invented 3.
        let report = check("**7. Video Recording Plan (Part 8)**")
        XCTAssertTrue(report.confirmed(.unsupportedNumber).isEmpty, report.detail)
    }

    func testANumberInTheBodyIsStillCaughtOnABoldLine() {
        let report = check("**Time Spent:** 30 minutes")
        XCTAssertEqual(report.confirmed(.unsupportedNumber).count, 1, report.detail)
    }

    // MARK: - Heading handling

    func testExampleHeadingsAreParsedFromThePrompt() {
        XCTAssertEqual(
            SummaryFabrication.exampleHeadings(in: Self.promptWithExamples),
            ["Product Update", "Hiring Plan", "Q3 Budget"]
        )
    }

    func testAnExampleHeadingWhoseWordsWereActuallySaidIsOnlyAdvisory() {
        // A meeting really can be about a product update. Being one of the prompt's
        // examples is not proof on its own.
        let report = SummaryFabrication.check(
            summary: "### Product Update\n*   The product ships on Tuesday.",
            transcript: "**[00:00] Me:** the product update ships on Tuesday",
            prompt: Self.promptWithExamples
        )
        XCTAssertTrue(report.confirmed(.promptExampleHeading).isEmpty, report.detail)
        XCTAssertEqual(report.advisory.filter { $0.kind == .promptExampleHeading }.count, 1)
    }

    func testADecoratedExampleHeadingStillMatches() {
        // The model wrote "### Q3 Budget (Q3)". It decorates headings; it does not
        // rename them, so a prefix has to count as a match.
        let report = check("### Q3 Budget (Q3)")
        XCTAssertEqual(report.confirmed(.promptExampleHeading).count, 1, report.detail)
    }

    func testTheHistoricalHeadingsStayArmedWhenThePromptNamesNoExamples() {
        // After the fix the prompt offers no examples. If the check derived its list
        // only from the prompt it would go quiet at exactly that moment, and quiet
        // would read as success.
        let report = SummaryFabrication.check(
            summary: "### Q3 Budget",
            transcript: Self.transcript,
            prompt: "Write a summary. Use ### headings named after what was actually discussed."
        )
        XCTAssertEqual(report.confirmed(.promptExampleHeading).count, 1, report.detail)
    }

    // MARK: - Which model summarises

    func testTheSummaryLadderPrefersTheLargestDownloadedModel() {
        let all = MeetingSummaryGenerator.summaryModelKind { _ in true }
        XCTAssertEqual(all, .qwen35_4b_q4_k_m, "the 4B measured 2 findings against the 0.8B's 10")

        let noFourB = MeetingSummaryGenerator.summaryModelKind { $0 != .qwen35_4b_q4_k_m }
        XCTAssertEqual(noFourB, .qwen35_2b_q4_k_m)
    }

    func testTheSummaryLadderNeverAsksForAModelThatIsNotOnDisk() {
        // `TextCleanupManager.loadModel(kind:)` DOWNLOADS a missing model. Naming one
        // here without checking the disk would pull 2.8 GB behind his back the first
        // time a meeting ended.
        let none = MeetingSummaryGenerator.summaryModelKind { _ in false }
        XCTAssertNil(none, "with nothing downloaded, the manager's own selection must be used")
    }

    // MARK: - Findings from the 2026-08-21 independent review

    func testALineBeginningWithAConceptWordDoesNotCrash() {
        // `index(before:)` used to be evaluated before the startIndex guard, so any
        // summary line starting with a concept word trapped and aborted the process
        // rather than failing a test. On a Russian transcript nearly every concept is
        // unsupported, so this was the common case.
        for opener in ["Budget was approved yesterday.",
                       "Team members agreed to meet again.",
                       "Deadline: Friday.",
                       "Contract terms were not discussed."] {
            _ = check(opener)
        }
    }

    func testSpokenOrdinalsAndCompoundNumbersSupportTheirDigits() {
        // Four of these came from the reviewer. An honest summary writing the digits
        // of a date he spoke aloud must not read as invented.
        let cases: [(String, Int)] = [
            ("давай встретимся двадцать первого августа", 21),
            ("we agreed on the twenty-first", 21),
            ("там было сто двадцать человек", 120),
            ("я переехал в две тысячи девятнадцатом году", 2019),
            ("we waited twenty five minutes", 25),
            ("there were six hundred people", 600),
        ]
        for (transcript, value) in cases {
            XCTAssertTrue(
                SummaryFabrication.SupportIndex(transcript: transcript).supports(number: value),
                "\(value) was spoken in: \(transcript)"
            )
        }
        XCTAssertFalse(
            SummaryFabrication.SupportIndex(transcript: "привет как дела").supports(number: 47),
            "the composition must not start supporting numbers nobody said"
        )
    }

    func testAnExampleHeadingIsFoundHoweverItIsQuoted() {
        // The guard used to require double quotes, so reintroducing the examples in
        // any other form left it green. The rule is capitalisation, not quoting.
        for prompt in ["- e.g. \"### Product Update\", \"### Hiring Plan\"",
                       "- e.g. ### Product Update, ### Hiring Plan",
                       "- e.g. '### Product Update' or `### Hiring Plan`"] {
            XCTAssertEqual(
                SummaryFabrication.exampleHeadings(in: prompt),
                ["Product Update", "Hiring Plan"],
                "missed the examples in: \(prompt)"
            )
        }
    }

    func testThePromptTalkingAboutHeadingsIsNotAnExample() {
        XCTAssertTrue(SummaryFabrication.exampleHeadings(
            in: "Use ### headings for each topic. End with a Next Steps section, as a ### heading."
        ).isEmpty)
    }

    func testAnEnglishHeadingIsNotSupportedByATransliterationCollision() {
        // "продолжим" transliterates to "prodolzhim", whose four-character stem
        // "prod" matched "product", and "план" matched "plan". That downgraded the
        // exact 2026-08-19 signature to advisory and dropped it out of the number the
        // whole change is judged on.
        let report = SummaryFabrication.check(
            summary: "### Product Update",
            transcript: "**[00:00] Me:** давай продолжим план",
            prompt: Self.promptWithExamples
        )
        XCTAssertEqual(report.confirmed(.promptExampleHeading).count, 1, report.detail)
    }

    // MARK: - Proper nouns (advisory)

    func testTitleCaseAndSentenceStartsAreNotTreatedAsNames() {
        // These were 19 of the first draft's 21 findings on the real summary.
        XCTAssertEqual(SummaryFabrication.midSentenceCapitals(in: "### Next Steps (Action Items)"), [])
        XCTAssertEqual(SummaryFabrication.midSentenceCapitals(in: "*   **Owner:** Finance Team / Budget Manager"), [])
        XCTAssertEqual(SummaryFabrication.midSentenceCapitals(in: "*   Outcome: Successfully completed the task."), [])
        XCTAssertEqual(SummaryFabrication.midSentenceCapitals(in: "Combined meeting notes:"), [])
    }

    func testASingleCapitalisedWordMidSentenceIsTreatedAsAName() {
        XCTAssertEqual(
            SummaryFabrication.midSentenceCapitals(in: "*   a team member from Poland and beyond"),
            ["Poland"]
        )
    }

    func testProperNounFindingsAreNeverCountedAsFabrication() {
        // The proper-noun check cannot bridge translation: "Польшей" and "Poland"
        // share no letters. It is for human eyes, so it must never raise the
        // confirmed count that the prompt change is judged on.
        let report = SummaryFabrication.check(
            summary: "*   a team member from Poland and beyond",
            transcript: "**[00:00] Me:** это было с Польшей",
            prompt: Self.promptWithExamples
        )
        XCTAssertTrue(report.confirmed.allSatisfy { $0.kind != .unsupportedProperNoun })
    }
}
