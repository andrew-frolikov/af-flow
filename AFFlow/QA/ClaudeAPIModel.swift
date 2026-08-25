import Foundation

enum ClaudeAPIModel: String, CaseIterable, Identifiable {
    case opus = "claude-opus-4-7"
    case sonnet = "claude-sonnet-4-6"
    case haiku = "claude-haiku-4-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus: return "Claude Opus 4.7 (best quality)"
        case .sonnet: return "Claude Sonnet 4.6 (balanced)"
        case .haiku: return "Claude Haiku 4.5 (fastest)"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .opus: return "Opus 4.7"
        case .sonnet: return "Sonnet 4.6"
        case .haiku: return "Haiku 4.5"
        }
    }
}
