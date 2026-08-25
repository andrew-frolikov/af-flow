import Foundation

enum AnthropicProviderError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(status: Int, message: String)
    case decodeError(String)
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "This feature isn't available in AF Flow."
        case .invalidResponse: return "Invalid response from Claude API."
        case .httpError(let status, let message): return "Claude API error \(status): \(message)"
        case .decodeError(let detail): return "Failed to decode Claude response: \(detail)"
        case .streamError(let detail): return "Stream error: \(detail)"
        }
    }
}

/// Accumulates Anthropic SSE events into provider-neutral ProviderEvents.
/// Critical contract: tool_use input arrives across multiple input_json_delta chunks,
/// so we buffer per content-block-index and parse only at content_block_stop.
struct AnthropicSSEAccumulator {
    private var jsonBuffers: [Int: String] = [:]
    private var toolUseStarts: [Int: (id: String, name: String)] = [:]
    private var pendingStopReason: StopReason?
    private var usage: ProviderUsage = .zero
    let onEvent: (ProviderEvent) -> Void

    init(onEvent: @escaping (ProviderEvent) -> Void) {
        self.onEvent = onEvent
    }

    mutating func handle(eventJSON: String) throws {
        guard let data = eventJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            throw AnthropicProviderError.streamError("malformed SSE payload: \(eventJSON.prefix(120))")
        }

        switch type {
        case "message_start":
            if let msg = json["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] {
                usage = ProviderUsage(
                    inputTokens: u["input_tokens"] as? Int ?? 0,
                    outputTokens: u["output_tokens"] as? Int ?? 0,
                    cacheReadTokens: u["cache_read_input_tokens"] as? Int ?? 0,
                    cacheWriteTokens: u["cache_creation_input_tokens"] as? Int ?? 0
                )
            }

        case "content_block_start":
            guard let index = json["index"] as? Int,
                  let block = json["content_block"] as? [String: Any] else { return }
            if (block["type"] as? String) == "tool_use",
               let id = block["id"] as? String,
               let name = block["name"] as? String {
                toolUseStarts[index] = (id, name)
                jsonBuffers[index] = ""
            }

        case "content_block_delta":
            guard let index = json["index"] as? Int,
                  let delta = json["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return }
            switch deltaType {
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty {
                    onEvent(.textDelta(text))
                }
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String {
                    jsonBuffers[index, default: ""] += partial
                }
            default:
                break
            }

        case "content_block_stop":
            guard let index = json["index"] as? Int else { return }
            if let start = toolUseStarts[index] {
                let buffer = jsonBuffers[index] ?? "{}"
                let inputData = buffer.isEmpty ? Data("{}".utf8) : Data(buffer.utf8)
                let parsed = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] ?? [:]
                onEvent(.toolUse(id: start.id, name: start.name, input: parsed))
                toolUseStarts.removeValue(forKey: index)
                jsonBuffers.removeValue(forKey: index)
            }

        case "message_delta":
            if let delta = json["delta"] as? [String: Any] {
                if let raw = delta["stop_reason"] as? String {
                    pendingStopReason = Self.parseStopReason(raw)
                }
            }
            if let u = json["usage"] as? [String: Any] {
                if let v = u["output_tokens"] as? Int { usage = ProviderUsage(inputTokens: usage.inputTokens, outputTokens: v, cacheReadTokens: usage.cacheReadTokens, cacheWriteTokens: usage.cacheWriteTokens) }
                if let v = u["input_tokens"] as? Int { usage = ProviderUsage(inputTokens: v, outputTokens: usage.outputTokens, cacheReadTokens: usage.cacheReadTokens, cacheWriteTokens: usage.cacheWriteTokens) }
                if let v = u["cache_read_input_tokens"] as? Int { usage = ProviderUsage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, cacheReadTokens: v, cacheWriteTokens: usage.cacheWriteTokens) }
                if let v = u["cache_creation_input_tokens"] as? Int { usage = ProviderUsage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, cacheReadTokens: usage.cacheReadTokens, cacheWriteTokens: v) }
            }

        case "message_stop":
            let reason = pendingStopReason ?? .other("missing_stop_reason")
            onEvent(.stop(reason: reason, usage: usage))

        case "error":
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                throw AnthropicProviderError.streamError(msg)
            }
            throw AnthropicProviderError.streamError("unknown stream error")

        default:
            break
        }
    }

    private static func parseStopReason(_ raw: String) -> StopReason {
        switch raw {
        case "end_turn": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens": return .maxTokens
        default: return .other(raw)
        }
    }
}

struct AnthropicProvider: LLMProvider {
    static let keychainKey = "claudeAPIKey"

    let model: ClaudeAPIModel
    let apiKey: String

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func complete(
        system: String,
        messages: [LLMMessage],
        tools: [LLMTool]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = Self.buildRequestBody(model: model, system: system, messages: messages, tools: tools)
                    var request = URLRequest(url: Self.endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.timeoutInterval = 600
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AnthropicProviderError.invalidResponse
                    }
                    if http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        let detail = String(data: data, encoding: .utf8) ?? "<no body>"
                        throw AnthropicProviderError.httpError(status: http.statusCode, message: detail)
                    }

                    var accumulator = AnthropicSSEAccumulator { event in
                        continuation.yield(event)
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        try accumulator.handle(eventJSON: payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func buildRequestBody(
        model: ClaudeAPIModel,
        system: String,
        messages: [LLMMessage],
        tools: [LLMTool]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 4096,
            "stream": true,
            "system": [
                [
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"],
                ],
            ],
            "messages": messages.map(encodeMessage(_:)),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema,
                ]
            }
        }
        return body
    }

    /// Calls Anthropic's `count_tokens` endpoint to estimate input tokens for a
    /// given prompt + messages + tools, without actually running a completion.
    /// Used for pre-flight cost estimates on index builds.
    func countInputTokens(system: String, messages: [LLMMessage], tools: [LLMTool]) async throws -> Int {
        let url = URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!
        var body: [String: Any] = [
            "model": model.rawValue,
            "system": [["type": "text", "text": system]],
            "messages": messages.map(Self.encodeMessage(_:)),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description, "input_schema": tool.inputSchema]
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicProviderError.invalidResponse
        }
        if http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? "<no body>"
            throw AnthropicProviderError.httpError(status: http.statusCode, message: detail)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inputTokens = json["input_tokens"] as? Int else {
            throw AnthropicProviderError.invalidResponse
        }
        return inputTokens
    }

    private static func encodeMessage(_ message: LLMMessage) -> [String: Any] {
        let role: String = (message.role == .user) ? "user" : "assistant"
        let blocks: [[String: Any]] = message.content.map { block in
            switch block {
            case .text(let s):
                return ["type": "text", "text": s]
            case .toolUse(let id, let name, let input):
                return ["type": "tool_use", "id": id, "name": name, "input": input]
            case .toolResult(let toolUseId, let content, let isError):
                return [
                    "type": "tool_result",
                    "tool_use_id": toolUseId,
                    "content": content,
                    "is_error": isError,
                ]
            }
        }
        return ["role": role, "content": blocks]
    }
}
