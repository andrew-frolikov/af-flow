import Foundation

/// One unit of activity emitted by the agent loop, consumed by the UI.
enum QAEvent {
    case status(String)
    case toolCall(id: String, name: String, inputSummary: String, fullInput: [String: Any])
    case toolResult(id: String, summary: String, fullOutput: String, isError: Bool)
    case text(String)
    case usage(QAUsage)
    case error(String)
}

struct QAUsage: Equatable {
    let modelDisplayName: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let estimatedCostUSD: Double
    let isLocal: Bool
}

extension QAUsage {
    static func local(modelDisplayName: String, inputTokens: Int, outputTokens: Int) -> QAUsage {
        QAUsage(
            modelDisplayName: modelDisplayName,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            estimatedCostUSD: 0,
            isLocal: true
        )
    }
}
