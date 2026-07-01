// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The OpenAI-compatible provider strategy.
///
/// Builds Chat Completions API request bodies and parses the corresponding
/// streaming chunk and error shapes. Works with any OpenAI-compatible
/// endpoint (OpenAI, DeepSeek, Grok, OpenRouter, local servers, etc.) —
/// provider-specific parameters are supplied via
/// [`Connection.requestParameters`](src/Models.swift) and merged into the
/// request body root.
///
/// Emits incremental `.toolCallDelta` chunks as argument fragments arrive
/// (see [`StreamChunk`](src/ChatService.swift)).
struct OpenAIProvider: LLMProvider {
    let provider: ConnectionProvider = .openai
    /// The base URL includes the API version path segment. Custom endpoints
    /// (OpenRouter, DeepSeek, local servers) supply their own baseUrl
    /// including whatever path prefix they use (e.g. `/api/v1`).
    let defaultBaseUrl = "https://api.openai.com/v1"
    let chatPath = "/chat/completions"
    let modelsPath: String? = "/models"

    func buildHeaders(connection: Connection) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        ]
        if let apiKey = connection.apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        return headers
    }

    func buildRequestBody(
        connection: Connection,
        messages: [ChatMessage],
        chatFilename: String,
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": connection.model,
            "messages": messages.map { openAIMessage($0, chatFilename: chatFilename) },
        ]

        // Tools — each MCP tool becomes a function tool whose name is the
        // namespaced `mcp__{server}__{tool}` identifier. The input schema is
        // parsed from the MCP tool's JSON string and embedded verbatim.
        if let tools, !tools.isEmpty {
            body["tools"] = tools.map { def -> [String: Any] in
                var function: [String: Any] = ["name": def.namespacedName]
                if let desc = def.description { function["description"] = desc }
                // Parse the raw JSON Schema string into an object.
                if let schemaData = def.inputSchema.data(using: .utf8),
                   let schema = try? JSONSerialization.jsonObject(with: schemaData) {
                    function["parameters"] = schema
                }
                return [
                    "type": "function",
                    "function": function,
                ] as [String: Any]
            }
        }

        // Merge provider-specific requestParameters into the root.
        if let params = connection.requestParameters {
            for (key, value) in params {
                body[key] = value.anyValue
            }
        }

        if stream { body["stream"] = true }
        return body
    }

    // MARK: - Message mapping

    /// Maps a [`ChatMessage`](src/Models.swift) to the OpenAI message JSON shape.
    private func openAIMessage(_ msg: ChatMessage, chatFilename: String) -> [String: Any] {
        // User message with images → multipart content (text + image_url parts).
        if msg.role == .user, let images = msg.images, !images.isEmpty {
            return openAIImageMessage(msg, images: images, chatFilename: chatFilename)
        }
        // Assistant message with tool calls → assistant message carrying tool_calls.
        if msg.role == .assistant, let calls = msg.toolCalls, !calls.isEmpty {
            var dict: [String: Any] = ["role": "assistant"]
            if !msg.content.isEmpty {
                dict["content"] = msg.content
            } else {
                dict["content"] = NSNull()
            }
            dict["tool_calls"] = calls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments,
                    ] as [String: Any],
                ] as [String: Any]
            }
            return dict
        }
        // Tool-result message → tool role message with tool_call_id.
        if msg.role == .tool, let results = msg.toolResults, !results.isEmpty {
            // OpenAI expects one tool message per tool_call_id. If a single
            // ChatMessage carries multiple results (unusual), we emit the
            // first; the loop normally creates one message per result.
            let r = results[0]
            return [
                "role": "tool",
                "content": r.content,
                "tool_call_id": r.callID,
            ] as [String: Any]
        }
        // Plain message.
        return [
            "role": msg.role.rawValue,
            "content": msg.content,
        ] as [String: Any]
    }

    /// Builds an OpenAI user message dict with multipart content
    /// (text + image_url parts). Images are base64-encoded data URLs.
    private func openAIImageMessage(
        _ msg: ChatMessage,
        images: [ImageAttachment],
        chatFilename: String
    ) -> [String: Any] {
        var parts: [[String: Any]] = []
        // Text first (if any), then images.
        if !msg.content.isEmpty {
            parts.append(["type": "text", "text": msg.content])
        }
        for img in images {
            guard let data = EnvironmentManager.shared.loadImageData(img, chatFilename: chatFilename) else { continue }
            let url = "data:\(img.mimeType);base64,\(data.base64EncodedString())"
            parts.append([
                "type": "image_url",
                "image_url": ["url": url, "detail": "auto"] as [String: Any],
            ])
        }
        return ["role": "user", "content": parts] as [String: Any]
    }

    // MARK: - Stream chunk parsing

    func parseStreamChunk(_ data: Data, accumulator: ToolCallAccumulator) -> [StreamChunk] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]] else {
            return []
        }
        var chunks: [StreamChunk] = []
        for choice in choices {
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            // Content.
            if let content = delta["content"] as? String {
                chunks.append(.content(content))
            }
            // Reasoning content from providers like DeepSeek/Grok/OpenRouter/Gemini.
            // Two alternate keys are seen in the wild.
            if let reasoning = delta["reasoning"] as? String {
                chunks.append(.thinking(reasoning))
            } else if let reasoning = delta["reasoning_content"] as? String {
                chunks.append(.thinking(reasoning))
            }
            // Tool-call deltas. OpenAI streams a tool call across multiple
            // chunks: the first carries the id + function name, later ones
            // carry argument JSON fragments. Keyed by `index`.
            if let toolCallDeltas = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCallDeltas {
                    guard let index = tc["index"] as? Int else { continue }
                    let id = tc["id"] as? String
                    var name: String?
                    var argsDelta: String?
                    if let fn = tc["function"] as? [String: Any] {
                        if let n = fn["name"] as? String, !n.isEmpty { name = n }
                        if let a = fn["arguments"] as? String { argsDelta = a }
                    }
                    accumulator.addDelta(index: index, id: id, name: name, argumentsDelta: argsDelta)
                    // Emit the incremental delta for live UI updates.
                    chunks.append(.toolCallDelta(index: index, id: id, name: name, argumentsDelta: argsDelta ?? ""))
                }
            }
            // Finish reason (emitted on the final chunk).
            if let reason = choice["finish_reason"] as? String {
                chunks.append(.finishReason(reason))
            }
        }
        return chunks
    }

    // MARK: - Non-streaming response

    func parseCompleteResponse(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            return ""
        }
        return (message["content"] as? String) ?? ""
    }

    // MARK: - Models listing

    func parseModelsResponse(_ data: Data) -> [ModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            return []
        }
        // OpenAI-compatible endpoints return `{"data":[{"id":"..."}, ...]}`.
        // They don't report image-input capability, so it stays nil.
        return models.compactMap { $0["id"] as? String }
            .map { ModelInfo(id: $0, imageInput: nil) }
    }

    // MARK: - Error parsing

    func parseError(_ data: Data, statusCode: Int) -> LLMError {
        .parseOpenAI(data, statusCode: statusCode)
    }
}
