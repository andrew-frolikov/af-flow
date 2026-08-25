import Foundation

// Driver for `scripts/summary-fabrication-report.sh`. Compiled together with
// AFFlowTests/SummaryFabrication.swift, so the numbers this prints come from
// the SAME checker the test suite runs. Two implementations would drift, and the
// one that drifts is always the one nobody is watching.
//
// PRINTS HIS REAL MEETING CONTENT. Never redirect this into the repo.

struct MeetingNote {
    let name: String
    let summary: String
    /// The transcript PLUS whatever he typed under `## Notes`. The prompt explicitly
    /// permits the model to use facts from the notes, so a note-only date or number is
    /// not invented. Codex, 2026-08-21: reading the transcript alone counted those as
    /// fabrication.
    let support: String
}

func section(_ text: String, heading: String, nextHeadings: [String]) -> String? {
    let lines = text.components(separatedBy: .newlines)
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) else { return nil }
    var body: [String] = []
    for line in lines[(start + 1)...] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if nextHeadings.contains(trimmed) { break }
        if trimmed.hasPrefix("## ") { break }
        body.append(line)
    }
    let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return joined.isEmpty ? nil : joined
}

func loadNotes(in directory: String) -> [MeetingNote] {
    let url = URL(fileURLWithPath: directory)
    guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
    var notes: [MeetingNote] = []
    for case let file as URL in walker where file.pathExtension == "md" {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        guard let summary = section(text, heading: "## Summary", nextHeadings: ["## Transcript"]),
              let transcript = section(text, heading: "## Transcript", nextHeadings: []) else { continue }
        guard summary != "*No summary.*", transcript != "*No transcript.*" else { continue }
        var written = section(text, heading: "## Notes", nextHeadings: ["## Summary"]) ?? ""
        if written == "*No notes.*" { written = "" }
        notes.append(MeetingNote(
            name: file.path.replacingOccurrences(of: url.path + "/", with: ""),
            summary: summary,
            support: transcript + "\n" + written
        ))
    }
    return notes.sorted { $0.name < $1.name }
}

// The prompt that produced the summaries currently in his vault. Passed in so the
// report can be re-run against a changed prompt without editing this file.
let promptPath = ProcessInfo.processInfo.environment["AF_FLOW_SUMMARY_PROMPT_FILE"]
let prompt: String = promptPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    ?? #"""
    - Use ### headings for each major topic discussed (e.g., "### Product Update", "### Hiring Plan", "### Q3 Budget")
    """#

let directories = CommandLine.arguments.dropFirst().isEmpty
    ? [ProcessInfo.processInfo.environment["AF_FLOW_MEETING_NOTES"] ?? ""]
    : Array(CommandLine.arguments.dropFirst())

var notes: [MeetingNote] = []
for directory in directories where !directory.isEmpty {
    notes += loadNotes(in: directory)
}

guard !notes.isEmpty else {
    FileHandle.standardError.write(Data("""
    no meeting notes with BOTH a Summary and a Transcript were found in: \(directories)
    A run that measured nothing must not look like a clean result.

    """.utf8))
    exit(2)
}

print("### Summaries in his archive, checked against their own transcripts")
print("prompt example headings seen by the checker: \(SummaryFabrication.exampleHeadings(in: prompt))")
print()

var totalConfirmed = 0
for note in notes {
    let report = SummaryFabrication.check(summary: note.summary, transcript: note.support, prompt: prompt)
    totalConfirmed += report.confirmed.count
    print("\(note.name)  ->  \(report.summaryLine)")
    print(report.detail)
    print()
}
print("TOTAL over \(notes.count) summaries: \(totalConfirmed) confirmed fabrication finding(s)")
print()

// CALIBRATION 1: a transcript is, by definition, entirely supported by itself.
// Anything the checker flags here is a false positive, measured without any
// human judgement about what the meeting was "really" about.
print("### Calibration 1: transcript checked against itself. Every finding is a false positive.")
var selfConfirmed = 0
for note in notes {
    // Timestamps are stripped from the pseudo-summary: a raw transcript is not
    // summary-shaped, and this calibration asks whether honest CONTENT scores zero,
    // not whether a transcript obeys the summary's formatting rules.
    let selfSummary = SummaryFabrication.strippingTimestamps(from: note.support)
    let report = SummaryFabrication.check(summary: selfSummary, transcript: note.support, prompt: prompt)
    selfConfirmed += report.confirmed.count
    print("\(note.name)  ->  \(report.summaryLine)")
    for finding in report.confirmed { print("  FALSE POSITIVE \(finding)") }
}
print("false positives: \(selfConfirmed) over \(notes.count) transcripts")
print()

// CALIBRATION 2: a summary of one meeting checked against a DIFFERENT meeting's
// transcript is fabrication by construction. Reported PER SUMMARY rather than as a
// mean, because one heavily-fabricated summary scores high against every transcript
// including its own and drags a mean to the point where it says nothing.
print("### Calibration 2: each summary against every OTHER meeting's transcript. Findings are true by construction.")
var discriminated = 0
for note in notes {
    let same = SummaryFabrication.check(summary: note.summary, transcript: note.support, prompt: prompt).confirmed.count
    var crossCounts: [Int] = []
    for other in notes where other.name != note.name {
        crossCounts.append(SummaryFabrication.check(summary: note.summary, transcript: other.support, prompt: prompt).confirmed.count)
    }
    let crossMean = Double(crossCounts.reduce(0, +)) / Double(max(crossCounts.count, 1))
    let verdict = crossMean > Double(same) ? "discriminates"
        : (crossMean == Double(same) ? "flat" : "INVERTED, the checker prefers a foreign transcript")
    if crossMean > Double(same) { discriminated += 1 }
    print(String(format: "%-46@  own: %d   foreign transcripts mean: %.1f   %@",
                 note.name as NSString, same, crossMean, verdict as NSString))
}
print("\(discriminated) of \(notes.count) summaries score strictly higher against a foreign transcript than their own.")
print("A \"flat\" row is a summary with nothing to discriminate: either it is honest and scores zero everywhere, or it is fabricated against every transcript including its own.")
print()

// CALIBRATION 3: an honestly abstaining summary must score zero.
let honest = "No decisions, facts or commitments were found in the transcript."
for note in notes.prefix(1) {
    let report = SummaryFabrication.check(summary: honest, transcript: note.support, prompt: prompt)
    print("### Calibration 3: the honest abstention line -> \(report.summaryLine)")
    for finding in report.confirmed { print("  FALSE POSITIVE \(finding)") }
}
