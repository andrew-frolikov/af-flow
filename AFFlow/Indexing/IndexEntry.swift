import Foundation

/// One entry in an index — e.g. one person's dossier under `.indexes/people/<slug>.md`.
/// Persisted as markdown with YAML frontmatter; see `IndexEntryFile` for the file format.
struct IndexEntry: Equatable {
    let kind: IndexKind
    var canonicalName: String
    var aliases: [String]
    var sourceMeetings: [String]
    var lastUpdated: Date
    var body: String
    /// Provenance for the most recent generation pass that produced this
    /// entry's body — model, named prompt kind, prompt content hash, and
    /// when. Hidden in the file's frontmatter; surfaced subtly at the foot
    /// of the rendered dossier so the user can audit how the content was
    /// produced and which prompt revision wrote it.
    var generation: GenerationMetadata?

    var slug: String { MarkdownArchivePaths.slugForIndexEntry(canonicalName) }
}

struct GenerationMetadata: Equatable {
    /// Claude API model identifier, e.g. "claude-sonnet-4-6".
    let model: String
    /// Logical name of the prompt template used, e.g. "people-index-full-build",
    /// "people-index-incremental", "merge-dossier-body".
    let promptKind: String
    /// First 12 hex chars of SHA-256(prompt). Lets us tell which prompt
    /// revision generated this entry; if we change a prompt, the hash changes.
    let promptHash: String
    /// When the generation happened.
    let generatedAt: Date
}
