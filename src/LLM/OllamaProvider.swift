// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Ollama's native chat API (`POST /api/chat`), as opposed to its OpenAI layer.
///
/// What differs from the OpenAI strategy:
///
/// - The body is NDJSON, not SSE (`framing`), and its last event (`done: true`)
///   carries the usage and the stop reason.
/// - Sampling and context settings live in `options`; thinking is `think`
///   (a bool or a model-defined level). Nothing is sent for them by default.
/// - Message `content` is a plain string; images are base64 strings in `images`.
/// - A tool call arrives **whole** in one event with its arguments as a JSON
///   object, and has no id of its own. Results are paired by `tool_name` and
///   order, so the engine's ids never go over the wire.
///
/// Not sent back: the assistant's thinking (the chat doesn't keep it).
struct OllamaProvider: LLMProvider {
    let wire: LLMWire = .ollama
    let chatPath = "/chat"
    let framing: StreamFraming = .ndjson

    func buildHeaders(model: ResolvedModel) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/x-ndjson",
            "User-Agent": AppInfo.userAgent,
        ]
        // Only Ollama's cloud wants a key; a local server is given none.
        if !model.apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(model.apiKey)"
        }
        if let custom = model.headers {
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
        model: ResolvedModel,
        messages: [ChatMessage],
        chatFilename: String,
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.modelID,
            "messages": Self.ollamaMessages(messages, chatFilename: chatFilename, imageInput: model.imageInput),
            "stream": stream,
        ]

        if let tools, !tools.isEmpty {
            body["tools"] = tools.map { def -> [String: Any] in
                var function: [String: Any] = ["name": def.namespacedName]
                if let desc = def.description { function["description"] = desc }
                let schema = def.inputSchema.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                // `parameters` is required by the API, even for a tool without arguments.
                function["parameters"] = schema ?? ["type": "object", "properties": [String: Any]()] as [String: Any]
                return ["type": "function", "function": function] as [String: Any]
            }
        }

        Self.applyReasoning(to: &body, model: model)

        if let params = model.requestParameters {
            for (key, value) in params {
                body[key] = value.anyValue
            }
        }
        return body
    }

    /// `off` → `think: false`, `on` → `think: true`, an effort level → that level (the names come from
    /// the model's own `/api/show` metadata). Nothing is sent when the setting is nil or the model doesn't
    /// think, so the model's default applies.
    static func applyReasoning(to body: inout [String: Any], model: ResolvedModel) {
        guard let setting = model.reasoning, model.capabilities.reasoning.supported else { return }
        switch setting {
        case ReasoningSetting.off: body["think"] = false
        case ReasoningSetting.on: body["think"] = true
        default: body["think"] = setting
        }
    }

    // MARK: - Message mapping

    /// Maps the history to Ollama messages. The results of one assistant message's tool calls are put in
    /// the order of the calls, since that order is all that pairs them with the calls.
    static func ollamaMessages(_ messages: [ChatMessage], chatFilename: String, imageInput: Bool) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var index = 0
        while index < messages.count {
            let msg = messages[index]
            index += 1
            if msg.role == .assistant, let calls = msg.toolCalls, !calls.isEmpty {
                result.append(assistantMessage(msg, calls: calls))
                var answers: [ToolResult] = []
                while index < messages.count, messages[index].role == .tool {
                    answers += messages[index].toolResults ?? []
                    index += 1
                }
                let order = Dictionary(
                    calls.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
                let names = Dictionary(
                    calls.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                let sorted = answers.enumerated().sorted { lhs, rhs in
                    let l = order[lhs.element.callID] ?? Int.max
                    let r = order[rhs.element.callID] ?? Int.max
                    return l == r ? lhs.offset < rhs.offset : l < r
                }
                for (_, answer) in sorted {
                    result.append(
                        toolMessage(answer, name: names[answer.callID] ?? "tool", imageInput: imageInput))
                }
                continue
            }
            if msg.role == .tool {
                // A result whose call isn't in the history (a trimmed or hand-edited chat): the API wants
                // a name, and there is none to give.
                for answer in msg.toolResults ?? [] {
                    result.append(toolMessage(answer, name: "tool", imageInput: imageInput))
                }
                continue
            }
            result.append(plainMessage(msg, chatFilename: chatFilename, imageInput: imageInput))
        }
        return result
    }

    private static func assistantMessage(_ msg: ChatMessage, calls: [ToolCall]) -> [String: Any] {
        let toolCalls = calls.enumerated().map { offset, call -> [String: Any] in
            var arguments: Any = [String: Any]()
            if let data = call.arguments.data(using: .utf8),
                let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                arguments = parsed
            }
            return [
                "function": ["index": offset, "name": call.name, "arguments": arguments] as [String: Any]
            ]
        }
        return ["role": "assistant", "content": msg.content, "tool_calls": toolCalls]
    }

    /// A tool result. An image it carries (from `read_file`) goes along as `images` on vision models, with
    /// the classification and OCR text as the content either way.
    private static func toolMessage(_ result: ToolResult, name: String, imageInput: Bool) -> [String: Any] {
        var message: [String: Any] = ["role": "tool", "tool_name": name]
        if let image = result.image {
            message["content"] = result.content.isEmpty ? image.fallback : result.content
            if imageInput { message["images"] = [image.data] }
        } else {
            message["content"] = result.content
        }
        return message
    }

    /// A system, user or plain assistant message. Attachments become text appended to the content, and
    /// images base64 strings in `images` (or their text fallback on a model that can't see).
    private static func plainMessage(_ msg: ChatMessage, chatFilename: String, imageInput: Bool) -> [String: Any] {
        guard msg.role == .user, let attachments = msg.attachments, !attachments.isEmpty else {
            return ["role": msg.role.rawValue, "content": msg.content]
        }
        var texts: [String] = msg.content.isEmpty ? [] : [msg.content]
        var images: [String] = []
        for attachment in attachments {
            switch attachment.kind {
            case .image:
                if imageInput {
                    if let data = EnvironmentManager.shared.loadAttachmentData(attachment, chatFilename: chatFilename) {
                        images.append(data.base64EncodedString())
                    }
                } else if let fallback = attachment.text, !fallback.isEmpty {
                    texts.append(fallback)
                }
            case .text, .document:
                if let text = attachment.text, !text.isEmpty,
                    let block = AttachmentRequestBuilder.block(for: attachment)
                {
                    texts.append(block)
                }
            }
        }
        var message: [String: Any] = ["role": "user", "content": texts.joined(separator: "\n\n")]
        if !images.isEmpty { message["images"] = images }
        return message
    }

    // MARK: - Stream event parsing

    /// One NDJSON line. Text and thinking are deltas; a tool call is complete and becomes a delta that
    /// already holds all its arguments (the transport emits the final call at the end of the stream);
    /// the last event brings the usage and the stop reason.
    func parseStreamChunk(_ data: Data, accumulator: ToolCallAccumulator) -> [StreamChunk] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        // An error after the stream began: the status stays 200 and the line is `{"error": "…"}`.
        if let error = json["error"] {
            return [.error(Self.errorMessage(error) ?? "Provider error")]
        }
        var chunks: [StreamChunk] = []
        if let message = json["message"] as? [String: Any] {
            if let thinking = message["thinking"] as? String, !thinking.isEmpty {
                chunks.append(.thinking(thinking))
            }
            if let content = message["content"] as? String, !content.isEmpty {
                chunks.append(.content(content))
            }
            for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                guard let function = call["function"] as? [String: Any],
                    let name = function["name"] as? String, !name.isEmpty
                else { continue }
                // The call's own `index` isn't reliable across events, so calls are numbered as they come.
                // Without an id the call gets the one the accumulator would invent, so the delta and the
                // final call are the same entry.
                let index = accumulator.count
                let id = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(index)"
                let arguments = Self.argumentsText(function["arguments"])
                accumulator.addDelta(index: index, id: id, name: name, argumentsDelta: arguments)
                chunks.append(.toolCallDelta(index: index, id: id, name: name, argumentsDelta: arguments))
            }
        }
        if JSONField.bool(json["done"]) == true {
            let hadToolCalls = !accumulator.isEmpty
            if let usage = Self.usage(json) { chunks.append(.usage(usage)) }
            // There is no `tool_calls` stop reason, so a turn that called tools says so here.
            let reason = json["done_reason"] as? String
            chunks.append(.finishReason(hadToolCalls ? "tool_calls" : (reason ?? "stop")))
        }
        return chunks
    }

    /// `prompt_eval_count` already includes the cached tokens (`prompt_eval_cached_count` is a part of it).
    static func usage(_ json: [String: Any]) -> TokenUsage? {
        guard let prompt = JSONField.int(json["prompt_eval_count"]),
            let completion = JSONField.int(json["eval_count"])
        else { return nil }
        let cached = min(JSONField.int(json["prompt_eval_cached_count"]) ?? 0, prompt)
        return TokenUsage(
            tokensUsed: prompt + completion,
            inputTokens: prompt - cached,
            outputTokens: completion,
            cachedInputTokens: cached,
            cacheCreationTokens: 0)
    }

    /// The arguments object as the compact JSON text the rest of the app stores.
    static func argumentsText(_ arguments: Any?) -> String {
        if let text = arguments as? String { return text }
        guard let object = arguments as? [String: Any],
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Error parsing

    func parseError(_ data: Data, statusCode: Int) -> LLMError {
        .parseOllama(data, statusCode: statusCode)
    }

    /// `{"error": "…"}`, or the nested `{"error": {"message": "…"}}` an OpenAI-style proxy in front would send.
    static func errorMessage(_ error: Any) -> String? {
        if let text = error as? String { return text }
        return (error as? [String: Any])?["message"] as? String
    }
}
