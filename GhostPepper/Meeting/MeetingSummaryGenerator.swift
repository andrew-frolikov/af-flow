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

    /// NO EXAMPLE HEADINGS. Rewritten 2026-08-21.
    ///
    /// This prompt used to end one of its rules with
    /// `(e.g., "### Product Update", "### Hiring Plan", "### Q3 Budget")`. On
    /// 2026-08-19 a personal conversation in Russian came back under all three of those
    /// headings, with a Q3 budget approval, a hiring decision about Poland and an action
    /// item owned by a finance team invented to fill them. The 2026-08-11 summary opens with "### Product
    /// Update" too, so the leak was two for two on every summary the prompt produced.
    ///
    /// Two lines further down this same prompt said "Do NOT use generic headings...
    /// Use specific topic names from the actual conversation", and the examples beat
    /// it. That is the point: a 0.8B model copies material far more reliably than it
    /// obeys a rule about that material. It is the same failure as the Whisper
    /// `initial_prompt`, where a list of terms meant as guidance came back as output.
    ///
    /// So the rules DESCRIBE the shape of a TOPIC heading and never name an instance
    /// of one: "Discussion Points" and "Key Takeaways" are gone from the rule that
    /// used to forbid them by name, because naming a heading is what made the model
    /// write it. `MeetingSummaryEvalTests` fails if a capitalised `### Something`
    /// reappears anywhere in this text, in any quoting.
    ///
    /// "Next Steps" is the deliberate exception and the model WILL copy it, which is
    /// the intent: it is a required structural section rather than a topic, and the
    /// fabrication risk there is an invented action item, which the rule addresses
    /// directly. It is written in prose ("as a ### heading") so that the guard above
    /// stays a bright line with no exceptions carved into it.
    ///
    /// The traceability rule leads, because a small model weights the first rule
    /// most, and because everything else here is a formatting concern next to it.
    static let finalSummaryPrompt = """
    You are summarizing a meeting. You will receive a transcript and optionally the user's own notes \
    taken during the meeting. Read both carefully, then produce a structured summary organized by topic.

    Rules:
    - Every fact, name, number, date, place and decision in the summary must have been said in the transcript or written in the notes. If it was not said, leave it out. Do not infer it, do not imply it, and never fill a section with what a meeting like this usually contains.
    - If the user wrote notes, treat them as a guide. They highlight what mattered most. Ensure those topics are covered prominently and expand on them with details from the transcript.
    - Use ### headings for each major topic discussed. Name each heading after a subject the speakers actually raised, in their own words where you can. Never choose a heading first and then look for something to put under it.
    - Under each topic, use concise bullet points capturing key facts, decisions, numbers, names, and dates
    - End with a Next Steps section, as a ### heading, holding only action items someone actually committed to, in checkbox format: - [ ] Task - Owner. If nobody committed to anything, leave that section out rather than inventing a task or an owner.
    - If the meeting is a 1:1 or introductory call, organize by the person/company discussed and what was learned
    - If the meeting is a group discussion or brainstorm, organize by the themes that emerged
    - Do NOT use a generic heading. A heading that would fit any meeting is the wrong heading; name the actual subject.
    - Do NOT include filler, pleasantries, or off-topic chatter
    - Keep bullets factual and specific
    - Write in present tense for facts, past tense for what happened
    - NEVER write timestamps such as [00:30], and NEVER write speaker prefixes such as "Me:" or "Others:". A summary that repeats the transcript's shape is not a summary.
    - NEVER restate a transcript line close to word for word. If a point cannot be said more briefly than it was spoken, leave it out.
    - If the meeting is too short or too thin to contain decisions or facts, say only that, in one line. Do not pad.
    """

    /// The prompt this replaced, kept ONLY so the migration in `AppState` can
    /// recognise a stored copy of it and replace that too.
    ///
    /// `meetingSummaryPrompt` is an `@AppStorage` key whose default is
    /// `storedSummaryPromptDefault`. A default only applies while the key is absent,
    /// so any install that once opened the prompt editor is holding a frozen copy of
    /// the old text and would never see this fix. That is exactly how
    /// `TextCleanupManager.init` froze his cleanup model, and it was found the second
    /// time only because someone went looking.
    static let supersededSummaryPromptWithExampleHeadings = """
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

    /// Which model summarises, measured rather than chosen.
    ///
    /// Over his nine real meetings on 2026-08-21, same prompt, same corpus, counting
    /// only mechanically confirmed inventions:
    ///
    ///     Qwen 3.5 0.8B   10 findings, and 3 of 9 meetings summarised to nothing at all
    ///     Qwen 3.5 2B      7 findings, 9 of 9 summarised
    ///     Qwen 3.5 4B      2 findings, 8 of 9 summarised
    ///
    /// The prompt fix did the heavy lifting: the same corpus on 0.8B with the old
    /// prompt scored 57. But 0.8B still asserted a $1,647 conversion, a budget range
    /// of $10M to $25M and two meeting durations that nobody stated, and it returned
    /// an empty summary for three meetings. Andrew authorised escalating the local
    /// ladder for summaries specifically, on 2026-08-21, on the grounds that summaries
    /// are not latency-critical the way push-to-talk is. The 4B run took 2 minutes 11
    /// seconds for all nine.
    ///
    /// NEVER A DOWNLOAD. `TextCleanupManager.loadModel(kind:)` fetches a missing model,
    /// so naming a model here without checking the disk first would pull 2.8 GB behind
    /// his back the first time a meeting ended. Only an already-downloaded model is
    /// chosen; otherwise this returns nil and the manager's own selection is used,
    /// which is exactly today's behaviour.
    ///
    /// The DeepSeek R1 7B is deliberately not on this ladder: it emits `<think>` blocks
    /// and its cleanup quality is recorded as unverified, so it is untested here.
    static let summaryModelLadder: [LocalCleanupModelKind] = [
        .qwen35_4b_q4_k_m,
        .qwen35_2b_q4_k_m,
    ]

    nonisolated static func summaryModelKind(
        isDownloaded: (LocalCleanupModelKind) -> Bool
    ) -> LocalCleanupModelKind? {
        summaryModelLadder.first(where: isDownloaded)
    }

    /// Set by the eval so that it can measure one rung of the ladder at a time.
    /// Left nil everywhere else, which means "walk the ladder".
    private let preferredModelKind: LocalCleanupModelKind?

    init(cleanupManager: TextCleanupManager, preferredModelKind: LocalCleanupModelKind? = nil) {
        self.cleanupManager = cleanupManager
        self.preferredModelKind = preferredModelKind
    }

    private func modelKindForSummaries() -> LocalCleanupModelKind? {
        preferredModelKind ?? Self.summaryModelKind(isDownloaded: TextCleanupManager.isModelDownloaded)
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

        // PUT HIS DICTATION MODEL BACK.
        //
        // `TextCleanupManager` holds ONE loaded model, so summarising on the 4B
        // evicts whatever dictation was using. Without this, the first dictation
        // after a meeting pays for reloading the 0.8B while he is holding the key.
        // STATE.md records dictation dead for 16 minutes on 2026-07-29 because a
        // meeting held the shared model, and "dictation is the product; meetings are
        // second" is a standing decision. Summarising happens after a meeting ends,
        // off any path he is waiting on, so the reload is free here and not free there.
        let modelBefore = cleanupManager.activeLoadedModelKind
        defer {
            if let modelBefore, modelBefore != modelKindForSummaries() {
                Task { @MainActor [cleanupManager] in
                    await cleanupManager.loadModel(kind: modelBefore)
                }
            }
        }

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
            let result = try await cleanupManager.clean(
                text: request.text,
                prompt: request.prompt,
                modelKind: modelKindForSummaries()
            )
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            print("MeetingSummaryGenerator: LLM failed: \(error.localizedDescription)")
            return nil
        }
    }
}
