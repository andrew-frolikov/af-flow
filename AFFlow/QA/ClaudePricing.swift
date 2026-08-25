import Foundation

// Hardcoded Anthropic pricing (USD per 1M tokens). Review against
// https://docs.anthropic.com/en/docs/about-claude/pricing each release.
// Cache write is billed at 1.25x input rate; cache read at 0.10x input rate.
// The 1M-context Opus tier (input >200k) is intentionally not modeled here —
// cross-meeting Q&A context stays well below that threshold.
enum ClaudePricing {
    struct Rates {
        let inputPerMTok: Double
        let outputPerMTok: Double
    }

    static let cacheWriteMultiplier: Double = 1.25
    static let cacheReadMultiplier: Double = 0.10

    static func rates(for model: ClaudeAPIModel) -> Rates {
        switch model {
        case .opus:   return Rates(inputPerMTok: 15.00, outputPerMTok: 75.00)
        case .sonnet: return Rates(inputPerMTok:  3.00, outputPerMTok: 15.00)
        case .haiku:  return Rates(inputPerMTok:  1.00, outputPerMTok:  5.00)
        }
    }

    static func estimateCostUSD(
        model: ClaudeAPIModel,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    ) -> Double {
        let r = rates(for: model)
        let regularInput = max(0, inputTokens)
        let inputCost = Double(regularInput) * r.inputPerMTok / 1_000_000.0
        let cacheReadCost = Double(cacheReadTokens) * r.inputPerMTok * cacheReadMultiplier / 1_000_000.0
        let cacheWriteCost = Double(cacheWriteTokens) * r.inputPerMTok * cacheWriteMultiplier / 1_000_000.0
        let outputCost = Double(outputTokens) * r.outputPerMTok / 1_000_000.0
        return inputCost + cacheReadCost + cacheWriteCost + outputCost
    }

    /// Pre-flight cost estimate for an index build. Returns a range because
    /// real cost depends on how much the agent's iteration loop grows context,
    /// which is not knowable in advance. The per-meeting coefficients are
    /// calibrated against observed runs; treat as order-of-magnitude.
    static func estimateBuildCostRange(model: ClaudeAPIModel, meetingCount: Int) -> (low: Double, high: Double) {
        let perMeeting: (low: Double, high: Double)
        switch model {
        case .haiku:  perMeeting = (0.002, 0.006)
        case .sonnet: perMeeting = (0.005, 0.018)
        case .opus:   perMeeting = (0.025, 0.075)
        }
        let n = Double(meetingCount)
        // Floor the lower bound at a few cents so 10-meeting archives don't
        // claim to cost $0.02 (there's still some baseline overhead).
        let low = max(0.05, perMeeting.low * n)
        let high = max(0.15, perMeeting.high * n)
        return (low, high)
    }
}
