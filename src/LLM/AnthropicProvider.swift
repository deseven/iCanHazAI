// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The Anthropic Messages API provider strategy.
///
/// Builds Anthropic Messages request bodies and parses the corresponding SSE
/// event and error shapes. Notable details:
///
/// - `input_schema` is **raw JSON Schema** — the MCP tool's `inputSchema`
///   string is parsed and embedded verbatim.
/// - `tool_use` `input` is a **raw JSON object** — the tool call's
///   `arguments` string is parsed to a JSON object and embedded directly.
/// - `max_tokens` is **required** — `buildRequestBody` ensures it's present,
///   defaulting to 4096 if not supplied in `requestParameters`.
///
/// Emits incremental `.toolCallDelta` chunks as argument fragments arrive.
struct AnthropicProvider: LLMProvider {
    let provider: ConnectionProvider = .anthropic
    let defaultBaseUrl = "https://api.anthropic.com/v1"
    let chatPath = "/messages"
    /// Anthropic exposes a models endpoint at `/v1/models`. The response
    /// includes per-model capability info (e.g. `image_input`), which the
    /// connection wizard uses to auto-set the `imageInput` flag.
    let modelsPath: String? = "/models"

    /// The Anthropic API version header value.
    private static let apiVersion = "2023-06-01"

    func buildHeaders(connection: Connection) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "anthropic-version": Self.apiVersion,
            "User-Agent": AppInfo.userAgent,
        ]
        if let apiKey = connection.apiKey, !apiKey.isEmpty {
            headers["x-api-key"] = apiKey
        }
        // Custom headers are applied last so they can override anything,
        // including auth and User-Agent. An empty-string value removes the
        // header entirely (cheap way to suppress a default).
        if let custom = connection.headers {
            for (key, value) in custom {
                if value.isEmpty {
                    headers.removeValue(forKey: key)
                } else {
                    headers[key] = value
                }
            }
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
        // Separate system prompt from conversation messages. Anthropic
        // carries the system prompt in a top-level `system` field rather
        // than as a message.
        var systemText: String?
        var conversationMessages: [ChatMessage] = []
        for msg in messages {
            if msg.role == .system {
                systemText = msg.content
            } else {
                conversationMessages.append(msg)
            }
        }

        var body: [String: Any] = [
            "model": connection.model,
            "messages": conversationMessages.map {
                anthropicMessage($0, chatFilename: chatFilename, imageInput: connection.imageInput)
            },
        ]
        if let systemText { body["system"] = systemText }

        if let tools, !tools.isEmpty {
            body["tools"] = tools.map { def in
                var tool: [String: Any] = ["name": def.namespacedName]
                if let desc = def.description { tool["description"] = desc }
                if let schemaData = def.inputSchema.data(using: .utf8),
                    let schema = try? JSONSerialization.jsonObject(with: schemaData)
                {
                    tool["input_schema"] = schema
                } else {
                    tool["input_schema"] = ["type": "object"] as [String: Any]
                }
                return tool
            }
        }

        if let params = connection.requestParameters {
            for (key, value) in params {
                body[key] = value.anyValue
            }
        }

        // Anthropic requires max_tokens on every request. Default to 4096
        // if not supplied in requestParameters.
        if body["max_tokens"] == nil {
            body["max_tokens"] = 4096
        }

        if stream { body["stream"] = true }
        return body
    }

    // MARK: - Message mapping

    /// Maps a [`ChatMessage`](src/Chat/Models.swift) to the Anthropic message JSON shape.
    private func anthropicMessage(_ msg: ChatMessage, chatFilename: String, imageInput: Bool) -> [String: Any] {
        let role = (msg.role == .user || msg.role == .tool) ? "user" : "assistant"

        if msg.role == .user, let attachments = msg.attachments, !attachments.isEmpty {
            return anthropicAttachmentMessage(
                msg, attachments: attachments, role: role, chatFilename: chatFilename, imageInput: imageInput)
        }
        if msg.role == .assistant, let calls = msg.toolCalls, !calls.isEmpty {
            var blocks: [[String: Any]] = []
            if !msg.content.isEmpty {
                blocks.append(["type": "text", "text": msg.content])
            }
            for call in calls {
                var input: Any = [String: Any]()
                if let data = call.arguments.data(using: .utf8),
                    let parsed = try? JSONSerialization.jsonObject(with: data)
                {
                    input = parsed
                }
                blocks.append(
                    [
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": input,
                    ] as [String: Any])
            }
            return ["role": role, "content": blocks] as [String: Any]
        }
        if msg.role == .tool, let results = msg.toolResults, !results.isEmpty {
            var blocks: [[String: Any]] = []
            for r in results {
                // A tool result carrying a processed image (from read_file on
                // an image) is sent as an image block on vision-capable
                // connections, or as the classification+OCR fallback text on
                // vision-incapable ones — exactly like user-attached images.
                if let image = r.image {
                    if imageInput {
                        blocks.append(
                            [
                                "type": "tool_result",
                                "tool_use_id": r.callID,
                                "content": [
                                    [
                                        "type": "image",
                                        "source": [
                                            "type": "base64",
                                            "media_type": image.mimeType,
                                            "data": image.data,
                                        ] as [String: Any],
                                    ] as [String: Any]
                                ],
                            ] as [String: Any])
                    } else {
                        blocks.append(
                            [
                                "type": "tool_result",
                                "tool_use_id": r.callID,
                                "content": image.fallback,
                            ] as [String: Any])
                    }
                } else {
                    blocks.append(
                        [
                            "type": "tool_result",
                            "tool_use_id": r.callID,
                            "content": r.content,
                        ] as [String: Any])
                }
            }
            return ["role": role, "content": blocks] as [String: Any]
        }
        return ["role": role, "content": msg.content] as [String: Any]
    }

    /// Builds an Anthropic message dict with multipart content: text blocks,
    /// image blocks (base64 sources) for image attachments on vision-capable
    /// connections, the synthesized text fallback for images on
    /// vision-incapable connections, and text blocks wrapping extracted content
    /// for text/document attachments.
    private func anthropicAttachmentMessage(
        _ msg: ChatMessage,
        attachments: [Attachment],
        role: String,
        chatFilename: String,
        imageInput: Bool
    ) -> [String: Any] {
        var blocks: [[String: Any]] = []
        if !msg.content.isEmpty {
            blocks.append(["type": "text", "text": msg.content])
        }
        for attachment in attachments {
            switch attachment.kind {
            case .image:
                if imageInput {
                    guard
                        let data = EnvironmentManager.shared.loadAttachmentData(attachment, chatFilename: chatFilename)
                    else { continue }
                    blocks.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": attachment.mimeType,
                            "data": data.base64EncodedString(),
                        ] as [String: Any],
                    ])
                } else if let fallback = attachment.text, !fallback.isEmpty {
                    blocks.append(["type": "text", "text": fallback])
                }
            case .text, .document:
                if let text = attachment.text, !text.isEmpty,
                    let block = AttachmentRequestBuilder.block(for: attachment)
                {
                    blocks.append(["type": "text", "text": block])
                }
            }
        }
        return ["role": role, "content": blocks] as [String: Any]
    }

    // MARK: - Stream chunk parsing

    func parseStreamChunk(_ data: Data, accumulator: ToolCallAccumulator) -> [StreamChunk] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            return []
        }
        var chunks: [StreamChunk] = []
        switch type {
        case "content_block_start":
            if let block = json["content_block"] as? [String: Any],
                (block["type"] as? String) == "tool_use",
                let index = json["index"] as? Int,
                let id = block["id"] as? String,
                let name = block["name"] as? String
            {
                accumulator.addDelta(index: index, id: id, name: name, argumentsDelta: nil)
                chunks.append(.toolCallDelta(index: index, id: id, name: name, argumentsDelta: ""))
            }
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any] {
                let deltaType = delta["type"] as? String
                if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String {
                    chunks.append(.thinking(thinking))
                } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                    if let index = json["index"] as? Int {
                        accumulator.addDelta(index: index, id: nil, name: nil, argumentsDelta: partial)
                        chunks.append(.toolCallDelta(index: index, id: nil, name: nil, argumentsDelta: partial))
                    }
                } else if let text = delta["text"] as? String {
                    chunks.append(.content(text))
                }
            }
        case "message_start":
            if let message = json["message"] as? [String: Any],
                let input = message["usage"] as? [String: Any],
                let inputTokens = input["input_tokens"] as? Int,
                let outputTokens = input["output_tokens"] as? Int
            {
                let cached = input["cache_read_input_tokens"] as? Int ?? 0
                let creation = input["cache_creation_input_tokens"] as? Int ?? 0
                let total = inputTokens + cached + outputTokens
                accumulator.setInputTokens(inputTokens, cached: cached, creation: creation)
                // Anthropic sometimes reports full usage in message_start already.
                chunks.append(
                    .usage(
                        TokenUsage(
                            tokensUsed: total,
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            cachedInputTokens: cached,
                            cacheCreationTokens: creation
                        )))
            }
        case "message_delta":
            if let delta = json["delta"] as? [String: Any],
                let reason = delta["stop_reason"] as? String
            {
                chunks.append(.finishReason(reason))
            }
            if let usage = json["usage"] as? [String: Any],
                let outputTokens = usage["output_tokens"] as? Int
            {
                let (input, cached, creation) = accumulator.getInputTokens()
                let total = input + cached + outputTokens
                chunks.append(
                    .usage(
                        TokenUsage(
                            tokensUsed: total,
                            inputTokens: input,
                            outputTokens: outputTokens,
                            cachedInputTokens: cached,
                            cacheCreationTokens: creation
                        )))
            }
        default:
            break
        }
        return chunks
    }

    // MARK: - Non-streaming response

    func parseCompleteResponse(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]]
        else {
            return ""
        }
        for block in content {
            if (block["type"] as? String) == "text", let text = block["text"] as? String {
                return text
            }
        }
        return ""
    }

    // MARK: - Models listing

    func parseModelsResponse(_ data: Data) -> [ModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["data"] as? [[String: Any]]
        else {
            return []
        }
        // Anthropic returns `{"data":[{"id":"...","capabilities":{"image_input":{"supported":true}}}, ...]}`.
        return models.compactMap { entry -> ModelInfo? in
            guard let id = entry["id"] as? String else { return nil }
            var imageInput: Bool?
            if let caps = entry["capabilities"] as? [String: Any],
                let imageCap = caps["image_input"] as? [String: Any],
                let supported = imageCap["supported"] as? Bool
            {
                imageInput = supported
            }
            return ModelInfo(id: id, imageInput: imageInput)
        }
    }

    // MARK: - Error parsing

    func parseError(_ data: Data, statusCode: Int) -> LLMError {
        .parseAnthropic(data, statusCode: statusCode)
    }
}
