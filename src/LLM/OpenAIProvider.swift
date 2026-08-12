// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The OpenAI-compatible provider strategy.
///
/// Builds Chat Completions API request bodies and parses the corresponding
/// streaming chunk and error shapes. Works with any OpenAI-compatible
/// endpoint (OpenAI, DeepSeek, Grok, OpenRouter, local servers, etc.) —
/// provider-specific parameters are supplied via
/// [`Connection.requestParameters`](src/Chat/Models.swift) and merged into the
/// request body root.
///
/// Emits incremental `.toolCallDelta` chunks as argument fragments arrive
/// (see [`StreamChunk`](src/Chat/ChatService.swift)).
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
            "User-Agent": AppInfo.userAgent,
        ]
        if let apiKey = connection.apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
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
        var body: [String: Any] = [
            "model": connection.model,
            "messages": messages.map {
                openAIMessage($0, chatFilename: chatFilename, imageInput: connection.imageInput)
            },
        ]

        if let tools, !tools.isEmpty {
            body["tools"] = tools.map { def -> [String: Any] in
                var function: [String: Any] = ["name": def.namespacedName]
                if let desc = def.description { function["description"] = desc }
                if let schemaData = def.inputSchema.data(using: .utf8),
                    let schema = try? JSONSerialization.jsonObject(with: schemaData)
                {
                    function["parameters"] = schema
                }
                return [
                    "type": "function",
                    "function": function,
                ] as [String: Any]
            }
        }

        if let params = connection.requestParameters {
            for (key, value) in params {
                body[key] = value.anyValue
            }
        }

        if stream {
            body["stream"] = true
            // Request a final chunk carrying token usage so we can display
            // the provider-reported totals instead of estimating.
            body["stream_options"] = ["include_usage": true]
        }
        return body
    }

    // MARK: - Message mapping

    /// Maps a [`ChatMessage`](src/Chat/Models.swift) to the OpenAI message JSON shape.
    private func openAIMessage(_ msg: ChatMessage, chatFilename: String, imageInput: Bool) -> [String: Any] {
        if msg.role == .user, let attachments = msg.attachments, !attachments.isEmpty {
            return openAIAttachmentMessage(
                msg, attachments: attachments, chatFilename: chatFilename, imageInput: imageInput)
        }
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
        if msg.role == .tool, let results = msg.toolResults, !results.isEmpty {
            let r = results[0]
            // A tool result carrying a processed image (from read_file on an
            // image) is sent as an image_url part on vision-capable
            // connections, or as the classification+OCR fallback text on
            // vision-incapable ones — exactly like user-attached images.
            if let image = r.image {
                if imageInput {
                    let url = "data:\(image.mimeType);base64,\(image.data)"
                    return [
                        "role": "tool",
                        "content": [
                            [
                                "type": "image_url",
                                "image_url": ["url": url, "detail": "auto"] as [String: Any],
                            ] as [String: Any]
                        ],
                        "tool_call_id": r.callID,
                    ] as [String: Any]
                } else {
                    return [
                        "role": "tool",
                        "content": image.fallback,
                        "tool_call_id": r.callID,
                    ] as [String: Any]
                }
            }
            return [
                "role": "tool",
                "content": r.content,
                "tool_call_id": r.callID,
            ] as [String: Any]
        }
        return [
            "role": msg.role.rawValue,
            "content": msg.content,
        ] as [String: Any]
    }

    /// Builds an OpenAI user message dict with multipart content: text parts,
    /// image_url parts (base64 data URLs) for image attachments on
    /// vision-capable connections, the synthesized text fallback for images on
    /// vision-incapable connections, and text parts wrapping extracted content
    /// for text/document attachments.
    private func openAIAttachmentMessage(
        _ msg: ChatMessage,
        attachments: [Attachment],
        chatFilename: String,
        imageInput: Bool
    ) -> [String: Any] {
        var parts: [[String: Any]] = []
        if !msg.content.isEmpty {
            parts.append(["type": "text", "text": msg.content])
        }
        for attachment in attachments {
            switch attachment.kind {
            case .image:
                if imageInput {
                    guard
                        let data = EnvironmentManager.shared.loadAttachmentData(attachment, chatFilename: chatFilename)
                    else { continue }
                    let url = "data:\(attachment.mimeType);base64,\(data.base64EncodedString())"
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": url, "detail": "auto"] as [String: Any],
                    ])
                } else if let fallback = attachment.text, !fallback.isEmpty {
                    parts.append(["type": "text", "text": fallback])
                }
            case .text, .document:
                if let text = attachment.text, !text.isEmpty,
                    let block = AttachmentRequestBuilder.block(for: attachment)
                {
                    parts.append(["type": "text", "text": block])
                }
            }
        }
        return ["role": "user", "content": parts] as [String: Any]
    }

    // MARK: - Stream chunk parsing

    func parseStreamChunk(_ data: Data, accumulator: ToolCallAccumulator) -> [StreamChunk] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let usage = json["usage"] as? [String: Any],
            let total = usage["total_tokens"] as? Int,
            let promptTokens = usage["prompt_tokens"] as? Int,
            let completionTokens = usage["completion_tokens"] as? Int
        {
            let cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            return [
                .usage(
                    TokenUsage(
                        tokensUsed: total,
                        inputTokens: promptTokens - cached,
                        outputTokens: completionTokens,
                        cachedInputTokens: cached,
                        cacheCreationTokens: 0
                    ))
            ]
        }
        guard let choices = json["choices"] as? [[String: Any]] else {
            return []
        }
        var chunks: [StreamChunk] = []
        for choice in choices {
            guard let delta = choice["delta"] as? [String: Any] else { continue }
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
                    chunks.append(.toolCallDelta(index: index, id: id, name: name, argumentsDelta: argsDelta ?? ""))
                }
            }
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
            let message = first["message"] as? [String: Any]
        else {
            return ""
        }
        return (message["content"] as? String) ?? ""
    }

    // MARK: - Models listing

    func parseModelsResponse(_ data: Data) -> [ModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["data"] as? [[String: Any]]
        else {
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
