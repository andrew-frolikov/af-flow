import Foundation
import CryptoKit

/// Static helpers for locating and counting index dossier files.
///
/// This used to be a class conforming to `IndexBuilding`, driving an agentic
/// index build through a cloud provider. That conformance and every instance
/// member are gone: nothing ever constructed it, and `LocalWikiEngine` is the
/// on-device implementation the app actually resolves. What remains is a
/// namespace of pure filesystem and hashing helpers with no network access.
@MainActor
enum IndexBuilder {
    // The instance path of this builder is removed. It held an
    // `AnthropicProvider` and a `ClaudeAPIModel`, drove an agentic index build
    // against them, and nothing in the app ever called its initializer, so the
    // whole path was dead code whose only effect was to keep a cloud provider
    // type referenced from live, compiled source.
    //
    // Found by widening the cloud check to match the bare identifier: the old
    // pattern required a `.` or `(` after the name and so could not see a
    // stored property or a parameter type. Only the static helpers below were
    // ever used (hashPrompt, coveredMeetings, countExistingEntries,
    // allMeetingPaths, indexingToolDefinitions), and they touch no network.

    nonisolated static func hashPrompt(_ prompt: String) -> String {
        let digest = SHA256.hash(data: Data(prompt.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // augmentGeneration was removed with the rest of the instance path:
    // it stamped model metadata written by the cloud-driven build, had no
    // callers once that path was gone, and referenced instance state that
    // no longer exists.
    // MARK: - Apply: merge new content into an existing dossier body

    /// Single-shot LLM merge. Reads the existing dossier body from disk,
    /// hands it plus the freshly-generated `newContent` to the model with a
    /// merge instruction, and returns the merged body text. No tools used —
    /// pure generation, fast and cheap. Caller is responsible for writing
    /// the result back to disk.
    nonisolated static func coveredMeetings(in saveDir: URL, kind: IndexKind) -> Set<String> {
        let root = MarkdownArchivePaths.indexRoot(in: saveDir, kind: kind)
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var covered: Set<String> = []
        for url in files where url.pathExtension == "md" && !url.lastPathComponent.hasPrefix("_") {
            if let entry = try? IndexEntryFile.read(from: url) {
                for meeting in entry.sourceMeetings {
                    covered.insert(meeting)
                }
            }
        }
        return covered
    }

    nonisolated static func countExistingEntries(in saveDir: URL, kind: IndexKind) -> Int {
        let root = MarkdownArchivePaths.indexRoot(in: saveDir, kind: kind)
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix("_") }.count
    }

    // MARK: - Full build

    /// One-shot full build. Streams progress and writes a fresh manifest at the end.
    nonisolated static func indexingToolDefinitions() -> [LLMTool] {
        let qa = MeetingQAAgent.qaToolDefinitions()
        let writeFile = LLMTool(
            name: "write_file",
            description: "Write or overwrite a dossier .md file in the index directory. Path must be a flat <slug>.md filename (no subdirectories), not starting with '.' or '_'. Returns 'Wrote N bytes to <path>' on success.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Flat filename ending in .md, e.g. 'john-smith.md'."],
                    "content": ["type": "string", "description": "Full file contents including YAML frontmatter and body."],
                ] as [String: Any],
                "required": ["path", "content"],
            ]
        )
        return qa + [writeFile]
    }

    private static func summarizeIndexInput(name: String, input: [String: Any]) -> String {
        switch name {
        case "write_file":
            let path = (input["path"] as? String) ?? "?"
            let bytes = (input["content"] as? String)?.utf8.count ?? 0
            return "\(path) (\(bytes) bytes)"
        default:
            return MeetingQAAgent.summarizeQAInput(name: name, input: input)
        }
    }

    private static func summarizeIndexOutput(name: String, output: String, isError: Bool) -> String {
        if isError { return "ERROR: \(output.prefix(120))" }
        if name == "write_file" { return output }
        return "\(output.split(separator: "\n").count) lines"
    }

    /// Returns paths like "2026-04-28/standup.md" for every .md file in date-folders.
    /// Skips dot-prefixed folders (so `.indexes/` is excluded).
    nonisolated static func allMeetingPaths(in saveDir: URL) -> [String] {
        let fm = FileManager.default
        guard let dateFolders = try? fm.contentsOfDirectory(
            at: saveDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var paths: [String] = []
        for folder in dateFolders {
            let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "md" {
                paths.append("\(folder.lastPathComponent)/\(file.lastPathComponent)")
            }
        }
        return paths.sorted()
    }

    private static func relativePath(of url: URL, in saveDir: URL) -> String? {
        let fullPath = url.standardizedFileURL.path
        let rootPath = saveDir.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard fullPath.hasPrefix(prefix) else { return nil }
        return String(fullPath.dropFirst(prefix.count))
    }

    /// Extracts the slug (filename without extension) from a write_file result
    /// like "Wrote 1234 bytes to john-smith.md".
    private static func extractWrittenSlug(from summary: String) -> String? {
        guard let toRange = summary.range(of: " to ") else { return nil }
        let path = summary[toRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard path.hasSuffix(".md") else { return nil }
        return String(path.dropLast(3))
    }

    private static func fullBuildInitialMessage(kind: IndexKind, meetings: [String]) -> String {
        if meetings.isEmpty {
            return "Build the \(kind.displayName) index. The archive currently has no meetings; write nothing and stop."
        }
        let preview = meetings.prefix(20).joined(separator: "\n")
        let suffix = meetings.count > 20 ? "\n... and \(meetings.count - 20) more." : ""
        return """
        Build the \(kind.displayName) index for the meeting archive. There are \(meetings.count) meetings in total. \
        First few paths:

        \(preview)\(suffix)

        Use `list_dir` and `grep` to explore the rest yourself, then `write_file` one dossier per canonical \(kind.spec.entityNoun).
        """
    }
}

extension Notification.Name {
    static let indexUpdated = Notification.Name("indexUpdated")
}
