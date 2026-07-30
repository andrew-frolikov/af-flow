import Foundation

/// Generates meeting summaries using the local LLM via chunked summarization.
///
/// Strategy: The transcript is split into chunks that fit the model's context window.
/// Each chunk is summarized into bullet points. Then the bullet points are combined
/// into a final summary with key topics, action items, and a TL;DR.
@MainActor
final class MeetingSummaryGenerator {
    private let cleanupManager: TextCleanupManager

    /// Maximum characters per chunk sent to the LLM (~1500 tokens ≈ 6000 chars).
    private let chunkCharLimit = 5000

    /// Rewritten 2026-07-27 after Andrew's first real summary restated the
    /// transcript almost verbatim and invented a timestamp of "[01:35]" in a
    /// two-minute meeting.
    ///
    /// A 0.8B model copies rather than abstracts unless told very plainly not
    /// to, and it will imitate whatever shape it sees: fed lines that begin
    /// "[00:30] Me:", it produced lines that begin "[01:35] Me:". So the ban on
    /// timestamps and speaker prefixes is explicit, and the instruction leads
    /// with what to DO rather than what to avoid, because small models follow
    /// positive instructions far better than negative ones.
    static let defaultPrompt = """
    Extract only what was decided, agreed, or committed to in this meeting excerpt.

    Write short bullet points. Each bullet states one fact, decision, number, name, \
    date, or task, and who it belongs to if that is clear.

    Do not copy sentences from the transcript. Do not write timestamps. Do not write \
    speaker prefixes such as "Me:" or "Others:". Do not repeat the same point twice.

    If the excerpt contains no decisions, facts or commitments, output nothing at all.
    """

    static let finalSummaryPrompt = """
    You are summarizing a meeting. You will receive a transcript and optionally the user's own notes \
    taken during the meeting. Read both carefully, then produce a structured summary organized by topic.

    Rules:
    - If the user wrote notes, treat them as a guide. They highlight what mattered most. Ensure those topics are covered prominently and expand on them with details from the transcript.
    - Use ### headings for each major topic discussed (e.g., "### Product Update", "### Hiring Plan", "### Q3 Budget")
    - Under each topic, use concise bullet points capturing key facts, decisions, numbers, names, and dates
    - Include a "### Next Steps" section at the end with any action items or follow-ups mentioned, using checkbox format: - [ ] Task - Owner
    - If the meeting is a 1:1 or introductory call, organize by the person/company discussed and what was learned
    - If the meeting is a group discussion or brainstorm, organize by the themes that emerged
    - Do NOT use generic headings like "Discussion Points" or "Key Takeaways". Use specific topic names from the actual conversation
    - Do NOT include filler, pleasantries, or off-topic chatter
    - Keep bullets factual and specific
    - Write in present tense for facts, past tense for what happened
    - NEVER write timestamps such as [00:30], and NEVER write speaker prefixes such as "Me:" or "Others:". A summary that repeats the transcript's shape is not a summary.
    - NEVER restate a transcript line close to word for word. If a point cannot be said more briefly than it was spoken, leave it out.
    - If the meeting is too short or too thin to contain decisions or facts, say only that, in one line. Do not pad.
    """

    /// What the stored `meetingSummaryPrompt` setting defaults to.
    ///
    /// ONE DEFAULT, because there were two. `AppState` defaulted that key to
    /// `defaultPrompt`, the per-chunk prompt, while the meeting window's editor
    /// defaulted the same key to `finalSummaryPrompt`. So the text he saw depended on
    /// which object read the key first, and neither default was wrong on its own.
    /// The key is passed as the FINAL prompt, so this is the final prompt.
    static let storedSummaryPromptDefault = finalSummaryPrompt

    init(cleanupManager: TextCleanupManager) {
        self.cleanupManager = cleanupManager
    }

    /// Generate a full summary for a completed meeting transcript.
    /// Returns the summary as markdown text, or nil if generation fails.
    func generateSummary(
        transcript: MeetingTranscript,
        chunkPrompt: String = MeetingSummaryGenerator.defaultPrompt,
        finalPrompt: String = MeetingSummaryGenerator.finalSummaryPrompt
    ) async -> String? {
        let segments = transcript.segments
        guard !segments.isEmpty else { return nil }

        // Build the full transcript text
        let fullText = segments.map { segment in
            "[\(segment.formattedTimestamp)] \(segment.speaker.displayName): \(segment.text)"
        }.joined(separator: "\n")

        // Split into chunks
        let chunks = splitIntoChunks(fullText)

        // Include user notes if available
        let notesText = transcript.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesPrefix = notesText.isEmpty ? "" : "User's notes during the meeting:\n\n\(notesText)\n\n"

        if chunks.count == 1 {
            // Short meeting — summarize directly with the final prompt
            let input = "\(notesPrefix)Meeting transcript:\n\n\(chunks[0])"
            return await runLLM(text: input, prompt: finalPrompt)
        }

        // Multi-chunk: summarize each chunk, then combine
        var chunkSummaries: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let input = "Meeting transcript (part \(i + 1) of \(chunks.count)):\n\n\(chunk)"
            if let summary = await runLLM(text: input, prompt: chunkPrompt) {
                chunkSummaries.append(summary)
            }
        }

        guard !chunkSummaries.isEmpty else { return nil }

        // Combine chunk summaries into final summary
        let combined = chunkSummaries.enumerated().map { i, s in
            "Part \(i + 1):\n\(s)"
        }.joined(separator: "\n\n")

        let finalInput = "\(notesPrefix)Combined meeting notes:\n\n\(combined)"
        return await runLLM(text: finalInput, prompt: finalPrompt)
    }

    // MARK: - Private

    private func splitIntoChunks(_ text: String) -> [String] {
        guard text.count > chunkCharLimit else { return [text] }

        var chunks: [String] = []
        let lines = text.components(separatedBy: "\n")
        var current = ""

        for line in lines {
            if current.count + line.count + 1 > chunkCharLimit && !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    /// Splits a summarisation call into the two things the model needs kept apart.
    ///
    /// THE INSTRUCTIONS ARE NOT INPUT. This used to build `prompt + "\n\n" + text` and
    /// hand the whole thing over as the text to CLEAN UP, with the prompt argument nil,
    /// so the cleanup model was told to tidy up a block that began with instructions and
    /// did exactly that. "Part 2" of his 2026-07-29 summary is the summarisation prompt
    /// word for word. The 0.8B model was not imitating a shape it had been shown; it was
    /// obeying the instruction it was actually given.
    nonisolated static func cleanupRequest(input: String, prompt: String) -> (text: String, prompt: String?) {
        (text: input, prompt: prompt)
    }

    private func runLLM(text: String, prompt: String) async -> String? {
        do {
            let request = Self.cleanupRequest(input: text, prompt: prompt)
            let result = try await cleanupManager.clean(text: request.text, prompt: request.prompt)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            print("MeetingSummaryGenerator: LLM failed: \(error.localizedDescription)")
            return nil
        }
    }
}
