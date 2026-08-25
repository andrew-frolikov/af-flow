import Foundation

/// Decides whether a newly transcribed meeting segment is an echo of one that
/// was already captured on the other channel.
///
/// ## Why this exists
///
/// Meeting capture has two channels: the microphone, labelled "Me", and the
/// system audio tap, labelled "Others". When Andrew is NOT wearing headphones,
/// his microphone also hears his speakers, so everything the far side says is
/// captured twice: once genuinely as "Others", and once as bleed that gets
/// attributed to HIM.
///
/// His first real two-channel test showed exactly that. He played a video aloud
/// and the same Russian sentence appeared twice in the transcript, once under
/// "Me" and once under "Others". In a real call that means every remote
/// participant is transcribed twice, and half of those copies claim he said it.
/// A record that attributes other people's words to him is worse than a
/// duplicate; it is wrong about who spoke.
///
/// ## The rule, and which copy survives
///
/// When a microphone segment closely matches a system segment from around the
/// same moment, the MICROPHONE copy is the echo and is dropped. The system copy
/// is kept because it is the clean source: it comes straight from the audio
/// stream rather than through speakers, a room, and a microphone, and it carries
/// the correct speaker.
///
/// ## What it deliberately will not do
///
/// It compares only against segments from the OTHER channel, and only within a
/// short window. Two people saying "yes" a minute apart is not an echo, and
/// Andrew genuinely agreeing with something the far side just said, in his own
/// words, is not an echo either. The similarity bar is high for that reason:
/// dropping something he really said is a worse failure than leaving a
/// duplicate, so the filter is built to under-remove rather than over-remove.
enum MeetingEchoFilter {

    /// How far apart two segments can be and still be the same speech.
    ///
    /// Chunks are transcribed in 30-second blocks and the two channels are not
    /// aligned, so the same words can land a chunk apart.
    static let matchWindow: TimeInterval = 45

    /// Fraction of words that must be shared before this is called an echo.
    ///
    /// Deliberately high. The two channels transcribe the same sound through
    /// different paths, so an echo is usually near-identical; anything that is
    /// merely similar is far more likely to be two people talking about the same
    /// thing, which must survive.
    static let similarityThreshold: Double = 0.75

    /// The shortest text worth comparing, in words.
    ///
    /// Short utterances collide by accident. "Yes", "okay" and "thank you" match
    /// each other perfectly and mean nothing, so they are never treated as
    /// echoes.
    static let minimumWordCount = 5

    /// Whether `candidate` is an echo of something already captured on the other
    /// channel.
    static func isEcho(
        candidate: TranscriptSegment,
        against existing: [TranscriptSegment]
    ) -> Bool {
        // Only microphone bleed is dropped. The system channel is the clean
        // source and is never removed in favour of a microphone copy.
        guard candidate.speaker == .me else { return false }

        let candidateWords = normalizedWords(candidate.text)
        guard candidateWords.count >= minimumWordCount else { return false }

        for other in existing {
            guard other.speaker != .me else { continue }
            guard abs(other.startTime - candidate.startTime) <= matchWindow else { continue }

            let otherWords = normalizedWords(other.text)
            guard otherWords.count >= minimumWordCount else { continue }

            if similarity(candidateWords, otherWords) >= similarityThreshold {
                return true
            }
        }

        return false
    }

    /// Words, lowercased, stripped of punctuation.
    ///
    /// The two channels hear the same sound through different paths, so they
    /// disagree on punctuation and casing constantly. Comparing raw strings
    /// would miss almost every real echo.
    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Jaccard similarity over word sets: shared words divided by total distinct
    /// words.
    ///
    /// Set-based rather than sequence-based on purpose. The two channels
    /// routinely drop or add a word at the edges of a chunk, so an order-strict
    /// comparison would score real echoes too low to catch.
    static func similarity(_ lhs: [String], _ rhs: [String]) -> Double {
        let left = Set(lhs)
        let right = Set(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        let shared = left.intersection(right).count
        let total = left.union(right).count
        guard total > 0 else { return 0 }

        return Double(shared) / Double(total)
    }
}
