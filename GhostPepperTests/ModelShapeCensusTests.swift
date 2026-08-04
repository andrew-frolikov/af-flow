import XCTest
@testable import GhostPepper

/// The census line that records WhisperKit's raw return.
///
/// Observability item 2. Every other log line in `ModelManager` records this
/// app's INTERPRETATION of the model, and an interpretation cannot disagree with
/// the assumption that produced it. The language prior lived its entire life
/// that way. These tests pin the two facts that would have ended that bug in a
/// day, both of which are properties of the raw return rather than of the code
/// reading it: how many languages were scored, and how many scores were positive.
final class ModelShapeCensusTests: XCTestCase {
    private func census(_ probs: [String: Float], _ reported: String?) -> String {
        ModelManager.rawDetectionCensus(probabilities: probs, reportedLanguage: reported)
    }

    /// The single-entry map is what production actually emits, and `n` is what
    /// makes it visible without anyone having to read the values.
    func testASingleEntryMapIsRecordedAsSuchAndAsAllNegative() {
        let line = census(["en": -0.00074300944], "en")

        XCTAssertTrue(line.contains("\"n\":1"), line)
        XCTAssertTrue(line.contains("\"positive\":0"), line)
    }

    /// The whole bug in one field. Linear probabilities would give positive
    /// values; log probabilities never can. A census that could not tell these
    /// apart would be worth nothing.
    func testLinearAndLogProbabilitiesAreDistinguishable() {
        let logProbs = census(["en": -0.02, "ru": -2.15], "en")
        let linearProbs = census(["en": 0.92, "ru": 0.08], "en")

        XCTAssertTrue(logProbs.contains("\"positive\":0"), logProbs)
        XCTAssertTrue(linearProbs.contains("\"positive\":2"), linearProbs)
    }

    /// `raw: ur` on 2026-08-02 was a language WhisperKit reported while the map
    /// held no score for it. That mismatch is the third-language door, so it is
    /// stated in the line rather than left to be inferred.
    func testAReportedLanguageWithNoScoreIsFlagged() {
        let line = census(["en": -0.5], "ur")

        XCTAssertTrue(line.contains("\"reportedIsScored\":false"), line)
    }

    func testAReportedLanguageThatIsScoredIsFlaggedAsSuch() {
        let line = census(["en": -0.5], "en")

        XCTAssertTrue(line.contains("\"reportedIsScored\":true"), line)
    }

    /// Every key and value survives unmodified. The point of a census is that it
    /// does not normalise, round or filter: `normalisedProbability` is exactly
    /// the sort of reading that hid the defect.
    func testEveryKeyAndValueIsRecordedUnmodified() {
        let line = census(["ru": -2.1541884, "en": -0.02031345], "ru")

        XCTAssertTrue(line.contains("\"ru\":-2.1541884"), line)
        XCTAssertTrue(line.contains("\"en\":-0.02031345"), line)
    }

    /// Deterministic key order, so two successive lines diff cleanly and a
    /// change in the model's output is visible rather than mistaken for
    /// dictionary ordering.
    func testKeysAreInAStableOrder() {
        let first = census(["ru": -2.0, "en": -0.1, "de": -9.0], "en")
        let second = census(["de": -9.0, "en": -0.1, "ru": -2.0], "en")

        XCTAssertEqual(first, second)

        // Search inside the probs object, not the whole line. The first version
        // of this searched the whole string and failed against CORRECT code,
        // because `"en"` also appears earlier as the reported language. A test
        // that reads the wrong span is the same defect as code that does.
        guard let probsStart = first.range(of: "\"probs\":{") else {
            return XCTFail("no probs object in \(first)")
        }
        let probs = String(first[probsStart.upperBound...])
        guard let de = probs.range(of: "\"de\""), let en = probs.range(of: "\"en\"") else {
            return XCTFail("expected both keys in \(probs)")
        }
        XCTAssertLessThan(de.lowerBound, en.lowerBound)
    }

    /// An empty map is the case `detectRestrictedLanguage` exists to survive, and
    /// the census must say so plainly rather than emit something unparseable.
    func testAnEmptyMapIsRecordedRatherThanSkipped() {
        let line = census([:], "ru")

        XCTAssertTrue(line.contains("\"n\":0"), line)
        XCTAssertTrue(line.contains("\"probs\":{}"), line)
        XCTAssertTrue(line.contains("\"reportedIsScored\":false"), line)
    }

    /// The line has to survive `JSONSerialization`, because a census nobody can
    /// parse is a census nobody will read.
    func testTheLineIsValidJSONAfterItsPrefix() throws {
        let prefix = "RAW detectLanguage "
        let line = census(["en": -0.02031345, "ru": -2.1541884], "en")
        XCTAssertTrue(line.hasPrefix(prefix), line)

        let json = String(line.dropFirst(prefix.count))
        let parsed = try JSONSerialization.jsonObject(
            with: Data(json.utf8)
        ) as? [String: Any]

        XCTAssertEqual(parsed?["language"] as? String, "en")
        XCTAssertEqual(parsed?["n"] as? Int, 2)
        XCTAssertEqual(parsed?["positive"] as? Int, 0)
        XCTAssertEqual((parsed?["probs"] as? [String: Any])?.count, 2)
    }

    /// A nil reported language must still produce parseable JSON, not the string
    /// "Optional(...)" or a bare `nil`.
    func testANilReportedLanguageIsRecordedAsJSONNull() throws {
        let line = census(["en": -0.5], nil)
        let json = String(line.dropFirst("RAW detectLanguage ".count))
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]

        XCTAssertTrue(parsed?["language"] is NSNull)
        XCTAssertEqual(parsed?["reportedIsScored"] as? Bool, false)
    }
}
