import Foundation

/// Streaming parser for the Qwen3 / Hermes-2-Pro tool-call wire format.
///
///   Plain text passes through as `.text(String)`.
///   `<tool_call>{ ... JSON ... }</tool_call>` is buffered and parsed at the
///   close tag, then emitted as `.toolCall(name:input:)`.
///
/// Built as a character-level state machine so token boundaries from the
/// model don't matter — `<`, `<tool_`, `<tool_call>`, and the closing tag
/// can all arrive split arbitrarily across chunks. On parse failure the
/// raw text falls through as `.text` so the agent loop treats it as a
/// final answer instead of crashing.
final class QwenToolCallParser {
    enum Output: Equatable {
        case text(String)
        case toolCall(name: String, input: [String: Any])

        static func == (lhs: Output, rhs: Output) -> Bool {
            switch (lhs, rhs) {
            case (.text(let a), .text(let b)):
                return a == b
            case (.toolCall(let na, _), .toolCall(let nb, _)):
                return na == nb
            default:
                return false
            }
        }
    }

    private enum State {
        case text
        case openTag         // accumulating possible "<tool_call>" or "<think>"
        case toolCall        // inside body, accumulating JSON
        case closeTag        // accumulating possible "</tool_call>"
        case thinkBlock      // inside <think>...</think>, content discarded
        case thinkCloseTag   // accumulating possible "</think>"
    }

    private static let openMarker = "<tool_call>"
    private static let closeMarker = "</tool_call>"
    private static let thinkOpenMarker = "<think>"
    private static let thinkCloseMarker = "</think>"

    private var state: State = .text
    private var pendingTag = ""
    private var jsonBuffer = ""

    /// Feeds a chunk of tokens through the parser. Returns whatever became
    /// resolvable as a result of this chunk; partial text/tags continue to
    /// buffer until more arrives.
    func consume(_ chunk: String) -> [Output] {
        var outputs: [Output] = []
        var textRun = ""
        for ch in chunk {
            switch state {
            case .text:
                if ch == "<" {
                    if !textRun.isEmpty {
                        outputs.append(.text(textRun))
                        textRun = ""
                    }
                    state = .openTag
                    pendingTag = "<"
                } else {
                    textRun.append(ch)
                }

            case .openTag:
                pendingTag.append(ch)
                if pendingTag == Self.openMarker {
                    state = .toolCall
                    jsonBuffer = ""
                    pendingTag = ""
                } else if pendingTag == Self.thinkOpenMarker {
                    // entering a think block — flush accumulated text first
                    if !textRun.isEmpty {
                        outputs.append(.text(textRun))
                        textRun = ""
                    }
                    state = .thinkBlock
                    pendingTag = ""
                } else if Self.openMarker.hasPrefix(pendingTag) || Self.thinkOpenMarker.hasPrefix(pendingTag) {
                    // still a possible prefix of either — keep buffering
                } else {
                    // matched neither — emit accumulated as plain text
                    textRun.append(pendingTag)
                    pendingTag = ""
                    state = .text
                }

            case .thinkBlock:
                if ch == "<" {
                    state = .thinkCloseTag
                    pendingTag = "<"
                }
                // else: silently discard — think content is hidden from the user

            case .thinkCloseTag:
                pendingTag.append(ch)
                if pendingTag == Self.thinkCloseMarker {
                    // exit the think block; pendingTag is also discarded
                    state = .text
                    pendingTag = ""
                } else if Self.thinkCloseMarker.hasPrefix(pendingTag) {
                    // still possibly the close tag — keep buffering
                } else {
                    // not the close tag — discard pendingTag (still inside think)
                    state = .thinkBlock
                    pendingTag = ""
                }

            case .toolCall:
                if ch == "<" {
                    state = .closeTag
                    pendingTag = "<"
                } else {
                    jsonBuffer.append(ch)
                }

            case .closeTag:
                pendingTag.append(ch)
                if pendingTag == Self.closeMarker {
                    if let parsed = Self.parseToolCallJSON(jsonBuffer) {
                        if !textRun.isEmpty {
                            outputs.append(.text(textRun))
                            textRun = ""
                        }
                        outputs.append(.toolCall(name: parsed.name, input: parsed.input))
                    } else {
                        // malformed — surface raw payload as text so the user sees something
                        textRun.append(Self.openMarker + jsonBuffer + Self.closeMarker)
                    }
                    state = .text
                    jsonBuffer = ""
                    pendingTag = ""
                } else if Self.closeMarker.hasPrefix(pendingTag) {
                    // still possibly a close tag — keep buffering
                } else {
                    // not a close tag — those bytes belong to the JSON body
                    jsonBuffer.append(pendingTag)
                    pendingTag = ""
                    state = .toolCall
                }
            }
        }
        if !textRun.isEmpty {
            outputs.append(.text(textRun))
        }
        return outputs
    }

    /// Flushes any in-flight buffers when the upstream stream ends. Partial
    /// tags become literal text; an unclosed `<tool_call>` becomes the raw
    /// payload (no parse attempted).
    func finish() -> [Output] {
        var outputs: [Output] = []
        switch state {
        case .text:
            break
        case .openTag:
            outputs.append(.text(pendingTag))
        case .toolCall:
            outputs.append(.text(Self.openMarker + jsonBuffer))
        case .closeTag:
            outputs.append(.text(Self.openMarker + jsonBuffer + pendingTag))
        case .thinkBlock, .thinkCloseTag:
            // unclosed think block — discard, don't surface internal reasoning
            break
        }
        state = .text
        pendingTag = ""
        jsonBuffer = ""
        return outputs
    }

    private static func parseToolCallJSON(_ raw: String) -> (name: String, input: [String: Any])? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let name = obj["name"] as? String else { return nil }
        let arguments = obj["arguments"] as? [String: Any] ?? [:]
        return (name, arguments)
    }
}
