// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import OpenAI
import SwiftAnthropic

/// A chunk received during streaming.
enum StreamChunk: Sendable {
    case thinking(String)
    case content(String)
    case error(String)
    /// A completed tool call accumulated from streamed deltas.
    case toolCall(ToolCall)
    /// The finish reason reported by the provider (e.g. "stop", "tool_calls",
    /// "tool_use"). Emitted once at the end of a stream.
    case finishReason(String)
}

/// Provides streaming chat completion for both OpenAI-compatible and Anthropic connections.
final class ChatService: @unchecked Sendable {

    static let shared = ChatService()

    private init() {}

    /// The outcome of a single streaming iteration. The tool-calling loop in
    /// `ChatEngine` inspects `toolCalls` and `finishReason` to decide whether
    /// to iterate again.
    struct StreamResult: Sendable {
        let content: String
        let toolCalls: [ToolCall]
        let finishReason: String?
    }

    /// Streams a chat completion, calling `onChunk` for each piece of content/thinking.
    /// - Parameters:
    ///   - connection: The connection to use.
    ///   - messages: The full conversation history (including system prompt if any).
    ///   - chatFilename: The chat's filename, used to resolve image attachments on disk.
    ///   - tools: Optional MCP tool definitions to expose to the model. When
    ///     non-empty, the model may emit tool calls instead of (or alongside)
    ///     text content.
    ///   - onChunk: Called for each streamed chunk.
    /// - Returns: The stream result (final text, accumulated tool calls, finish reason).
    @discardableResult
    func stream(
        connection: Connection,
        messages: [ChatMessage],
        chatFilename: String,
        tools: [ToolDefinition]? = nil,
        onChunk: @escaping @Sendable (StreamChunk) async -> Void
    ) async throws -> StreamResult {
        switch connection.provider {
        case .openai:
            return try await streamOpenAI(connection: connection, messages: messages, chatFilename: chatFilename, tools: tools, onChunk: onChunk)
        case .anthropic:
            return try await streamAnthropic(connection: connection, messages: messages, chatFilename: chatFilename, tools: tools, onChunk: onChunk)
        }
    }

    /// Fetches the list of available model IDs from an OpenAI-compatible
    /// provider. Not supported for Anthropic (the SwiftAnthropic package does
    /// not expose a models endpoint).
    func listModels(endpoint: String?, token: String?) async throws -> [String] {
        let configuration: OpenAI.Configuration
        if let endpoint = endpoint, let url = URL(string: endpoint) {
            let host = url.host ?? "api.openai.com"
            let port = url.port ?? (url.scheme == "http" ? 80 : 443)
            let scheme = url.scheme ?? "https"
            let basePath = url.path.isEmpty ? "/v1" : url.path
            configuration = OpenAI.Configuration(
                token: token,
                host: host,
                port: port,
                scheme: scheme,
                basePath: basePath,
                parsingOptions: .relaxed
            )
        } else {
            configuration = OpenAI.Configuration(
                token: token,
                parsingOptions: .relaxed
            )
        }

        let openAI = OpenAI(configuration: configuration)
        let result = try await openAI.models()
        return result.data.map { $0.id }.sorted()
    }

    /// Performs a non-streaming chat completion and returns the assistant's
    /// text. Used by the connection wizard's "say hi" test.
    func complete(connection: Connection, messages: [ChatMessage]) async throws -> String {
        switch connection.provider {
        case .openai:
            return try await completeOpenAI(connection: connection, messages: messages)
        case .anthropic:
            return try await completeAnthropic(connection: connection, messages: messages)
        }
    }

    private func completeOpenAI(connection: Connection, messages: [ChatMessage]) async throws -> String {
        let configuration: OpenAI.Configuration
        if let endpoint = connection.endpoint, let url = URL(string: endpoint) {
            let host = url.host ?? "api.openai.com"
            let port = url.port ?? (url.scheme == "http" ? 80 : 443)
            let scheme = url.scheme ?? "https"
            let basePath = url.path.isEmpty ? "/v1" : url.path
            configuration = OpenAI.Configuration(
                token: connection.token,
                host: host,
                port: port,
                scheme: scheme,
                basePath: basePath,
                parsingOptions: .relaxed
            )
        } else {
            configuration = OpenAI.Configuration(
                token: connection.token,
                parsingOptions: .relaxed
            )
        }

        let openAI = OpenAI(configuration: configuration)

        let chatMessages: [ChatQuery.ChatCompletionMessageParam] = messages.compactMap { msg in
            ChatQuery.ChatCompletionMessageParam(role: roleFor(msg.role), content: msg.content)
        }

        let query = ChatQuery(
            messages: chatMessages,
            model: connection.model,
            maxCompletionTokens: connection.maxCompletionTokens,
            temperature: connection.temperature,
            topP: connection.topP
        )

        let result = try await openAI.chats(query: query, vendorParameters: connection.vendorParameters)
        return result.choices.first?.message.content ?? ""
    }

    private func completeAnthropic(connection: Connection, messages: [ChatMessage]) async throws -> String {
        let apiVersion = "2023-06-01"
        let basePath = connection.endpoint ?? "https://api.anthropic.com"
        let service = AnthropicServiceFactory.service(
            apiKey: connection.token ?? "",
            apiVersion: apiVersion,
            basePath: basePath,
            betaHeaders: nil
        )

        var systemText: String?
        var conversationMessages: [ChatMessage] = []
        for msg in messages {
            if msg.role == .system {
                systemText = msg.content
            } else {
                conversationMessages.append(msg)
            }
        }

        let anthropicMessages: [MessageParameter.Message] = conversationMessages.map { msg in
            let role: MessageParameter.Message.Role = msg.role == .user ? .user : .assistant
            return MessageParameter.Message(role: role, content: .text(msg.content))
        }

        let maxTokens = connection.maxTokens ?? 4096
        let parameters = MessageParameter(
            model: .other(connection.model),
            messages: anthropicMessages,
            maxTokens: maxTokens,
            system: systemText.map { .text($0) }
        )

        let response = try await service.createMessage(parameters)
        // Extract text from the first text content block.
        for content in response.content {
            if case .text(let text, _) = content {
                return text
            }
        }
        return ""
    }

    /// A box that lets `withTaskCancellationHandler.onCancel` reach both the
    /// vendor cancellable handle and the `AsyncThrowingStream` continuation,
    /// so it can cancel the HTTP request *and* finish the continuation
    /// synchronously — unblocking the `for try await` loop immediately.
    private final class StreamBox: @unchecked Sendable {
        var handle: (any CancellableRequest)?
        var continuation: AsyncThrowingStream<ChatStreamResult, Error>.Continuation?
        /// Guards against double-finishing the continuation (which is undefined
        /// behaviour and can crash or silently fail).
        var didFinish = false
    }

    // MARK: - OpenAI

    private func streamOpenAI(
        connection: Connection,
        messages: [ChatMessage],
        chatFilename: String,
        tools: [ToolDefinition]?,
        onChunk: @escaping @Sendable (StreamChunk) async -> Void
    ) async throws -> StreamResult {
        // Build configuration with optional endpoint override.
        let configuration: OpenAI.Configuration
        if let endpoint = connection.endpoint, let url = URL(string: endpoint) {
            let host = url.host ?? "api.openai.com"
            let port = url.port ?? (url.scheme == "http" ? 80 : 443)
            let scheme = url.scheme ?? "https"
            let basePath = url.path.isEmpty ? "/v1" : url.path
            configuration = OpenAI.Configuration(
                token: connection.token,
                host: host,
                port: port,
                scheme: scheme,
                basePath: basePath,
                parsingOptions: .relaxed
            )
        } else {
            configuration = OpenAI.Configuration(
                token: connection.token,
                parsingOptions: .relaxed
            )
        }

        let openAI = OpenAI(configuration: configuration)

        // Convert messages to OpenAI format. User messages with images become
        // multipart content (text + image_url parts); everything else stays a
        // plain string. Assistant messages carrying tool calls and tool-role
        // result messages are mapped to their OpenAI equivalents so the model
        // sees the full tool-calling history on re-request. Tool results are
        // stored as their own `tool`-role `ChatMessage` (the natural provider
        // shape), so no un-folding is needed — each message maps 1:1.
        let chatMessages: [ChatQuery.ChatCompletionMessageParam] = messages.compactMap { msg -> ChatQuery.ChatCompletionMessageParam? in
            if msg.role == .user, let images = msg.images, !images.isEmpty {
                return openAIMessage(for: msg, images: images, chatFilename: chatFilename)
            }
            // Assistant message with tool calls → assistant message carrying tool_calls.
            if msg.role == .assistant, let calls = msg.toolCalls, !calls.isEmpty {
                let toolCallParams = calls.map {
                    ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam(
                        id: $0.id,
                        function: .init(arguments: $0.arguments, name: $0.name)
                    )
                }
                let content: ChatQuery.ChatCompletionMessageParam.TextOrRefusalContent?
                if msg.content.isEmpty {
                    content = nil
                } else {
                    content = .textContent(msg.content)
                }
                return .assistant(.init(content: content, toolCalls: toolCallParams))
            }
            // Tool-result message → tool role message with tool_call_id.
            if msg.role == .tool, let results = msg.toolResults, !results.isEmpty {
                // OpenAI expects one tool message per tool_call_id. If a single
                // ChatMessage carries multiple results (unusual), we emit the
                // first; the loop normally creates one message per result.
                let r = results[0]
                return .tool(.init(content: .textContent(r.content), toolCallId: r.callID))
            }
            return ChatQuery.ChatCompletionMessageParam(role: roleFor(msg.role), content: msg.content)
        }

        // Parse reasoning effort from string.
        let reasoningEffort: ChatQuery.ReasoningEffort?
        if let effort = connection.reasoningEffort {
            switch effort {
            case "none": reasoningEffort = ChatQuery.ReasoningEffort.none
            case "minimal": reasoningEffort = .minimal
            case "low": reasoningEffort = .low
            case "medium": reasoningEffort = .medium
            case "high": reasoningEffort = .high
            default: reasoningEffort = .customValue(effort)
            }
        } else {
            reasoningEffort = nil
        }

        // Build tool definitions for the OpenAI Chat Completions `tools` field.
        // Each MCP tool is mapped to a function tool whose name is the
        // namespaced `mcp__{server}__{tool}` identifier.
        let toolParams: [ChatQuery.ChatCompletionToolParam]? = {
            guard let tools, !tools.isEmpty else { return nil }
            return tools.map { def in
                // Build the JSON schema parameter. The OpenAI `JSONSchema` is
                // an object dictionary; we decode the MCP schema string into
                // `[String: AnyJSONDocument]` and wrap as `.object`. The
                // closure is inlined into `parameters:` so its contextual type
                // (the OpenAI `JSONSchema?`) disambiguates the name collision
                // with SwiftAnthropic's `JSONSchema`.
                ChatQuery.ChatCompletionToolParam(
                    function: .init(
                        name: def.namespacedName,
                        description: def.description,
                        parameters: {
                            if let data = def.inputSchema.data(using: .utf8),
                               let object = try? JSONDecoder().decode([String: AnyJSONDocument].self, from: data) {
                                return .object(object)
                            }
                            return nil
                        }()
                    )
                )
            }
        }()

        let query = ChatQuery(
            messages: chatMessages,
            model: connection.model,
            reasoningEffort: reasoningEffort,
            frequencyPenalty: connection.frequencyPenalty,
            maxCompletionTokens: connection.maxCompletionTokens,
            presencePenalty: connection.presencePenalty,
            seed: connection.seed,
            temperature: connection.temperature,
            tools: toolParams,
            topP: connection.topP
        )

        var fullContent = ""
        // Accumulate streamed tool-call deltas keyed by their `index`. OpenAI
        // streams a tool call across multiple deltas: the first carries the id
        // and function name, subsequent ones carry argument JSON fragments.
        var toolCallAccumulator: [Int: (id: String, name: String, args: String)] = [:]
        var finishReason: String?

        // --- Chunk coalescing -------------------------------------------------
        // OpenAI-compatible providers (and many OpenRouter/Gemini proxies) emit
        // SSE deltas as small as a single token — often 1–4 characters. Each
        // delta would otherwise become its own `onChunk` call, which the engine
        // turns into a full `chatsChanged` event for the UI. At hundreds of
        // events per second the main actor's queue backs up for several
        // seconds, which is why the stop button felt unresponsive for OpenAI
        // but worked instantly for Anthropic (whose deltas are much larger).
        //
        // We accumulate content and reasoning text into buffers and only flush
        // to `onChunk` when either:
        //   • a buffer reaches `coalesceMinChars`, or
        //   • `coalesceInterval` has elapsed since the last flush.
        // This cuts the number of UI events by ~10–50× without introducing
        // noticeable latency (the interval is well below a frame).
        let coalesceMinChars = 10
        let coalesceInterval = Duration.milliseconds(40)
        let clock = ContinuousClock()
        var contentBuffer = ""
        var thinkingBuffer = ""
        var lastFlush = clock.now

        func flush(force: Bool) async {
            let now = clock.now
            let due = force || (now - lastFlush >= coalesceInterval)
            if !contentBuffer.isEmpty && (force || contentBuffer.count >= coalesceMinChars || due) {
                await onChunk(.content(contentBuffer))
                contentBuffer.removeAll(keepingCapacity: true)
            }
            if !thinkingBuffer.isEmpty && (force || thinkingBuffer.count >= coalesceMinChars || due) {
                await onChunk(.thinking(thinkingBuffer))
                thinkingBuffer.removeAll(keepingCapacity: true)
            }
            if due { lastFlush = now }
        }

        let box = StreamBox()
        return try await withTaskCancellationHandler {
            let stream = AsyncThrowingStream<ChatStreamResult, Error> { continuation in
                let cancellable = openAI.chatsStream(
                    query: query,
                    vendorParameters: connection.vendorParameters,
                    onResult: { result in
                        continuation.yield(with: result)
                    },
                    completion: { error in
                        guard !box.didFinish else {
                            return
                        }
                        box.didFinish = true
                        continuation.finish(throwing: error)
                    }
                )
                box.handle = cancellable
                box.continuation = continuation
                continuation.onTermination = { term in
                    // Always cancel the underlying URLSession.
                    cancellable.cancelRequest()
                    // If the stream was cancelled by the user, finish the
                    // continuation with CancellationError to unblock the
                    // `for try await` loop immediately. Only do this once.
                    if case .cancelled = term, !box.didFinish {
                        box.didFinish = true
                        continuation.finish(throwing: CancellationError())
                    }
                }
            }
            for try await result in stream {
                try Task.checkCancellation()
                for choice in result.choices {
                    let delta = choice.delta
                    if let content = delta.content {
                        fullContent += content
                        contentBuffer += content
                    }
                    // Reasoning content from providers like DeepSeek/Grok/OpenRouter/Gemini.
                    if let reasoning = delta.reasoning {
                        thinkingBuffer += reasoning
                    }
                    // Accumulate streamed tool-call deltas. OpenAI emits a
                    // tool call across multiple chunks: the first carries the
                    // id + function name, later ones carry argument JSON
                    // fragments. We key by `index` (stable within a response).
                    if let toolCallDeltas = delta.toolCalls {
                        for tc in toolCallDeltas {
                            var entry = toolCallAccumulator[tc.index] ?? (id: "", name: "", args: "")
                            if let id = tc.id, !id.isEmpty { entry.id = id }
                            if let fn = tc.function {
                                if let name = fn.name, !name.isEmpty { entry.name = name }
                                if let args = fn.arguments { entry.args += args }
                            }
                            toolCallAccumulator[tc.index] = entry
                        }
                    }
                    // Capture the finish reason (emitted on the final chunk).
                    if let reason = choice.finishReason {
                        finishReason = reason.rawValue
                    }
                }
                await flush(force: false)
            }
            // Drain any remaining buffered text before returning.
            await flush(force: true)
            // Materialize accumulated tool calls into ToolCall objects and
            // emit each as a chunk so the engine can render them live.
            var toolCalls: [ToolCall] = []
            for index in toolCallAccumulator.keys.sorted() {
                guard let entry = toolCallAccumulator[index] else { continue }
                let id = entry.id.isEmpty ? "call_\(index)" : entry.id
                let call = ToolCall(id: id, name: entry.name, arguments: entry.args)
                toolCalls.append(call)
                await onChunk(.toolCall(call))
            }
            if let reason = finishReason {
                await onChunk(.finishReason(reason))
            }
            return StreamResult(content: fullContent, toolCalls: toolCalls, finishReason: finishReason)
        } onCancel: {
            // Safety net: if onTermination hasn't fired yet, finish the
            // continuation here. onCancel fires synchronously when the Task
            // is cancelled, but onTermination typically fires first.
            box.handle?.cancelRequest()
            if !box.didFinish, let c = box.continuation {
                box.didFinish = true
                c.finish(throwing: CancellationError())
            }
        }
    }

    private func roleFor(_ role: MessageRole) -> ChatQuery.ChatCompletionMessageParam.Role {
        switch role {
        case .system: return .system
        case .user: return .user
        case .assistant: return .assistant
        case .tool: return .tool
        }
    }

    // MARK: - Image content builders

    /// Builds an OpenAI user message with multipart content (text + image_url
    /// parts) for a message that carries images. Images are base64-encoded
    /// data URLs.
    private func openAIMessage(
        for msg: ChatMessage,
        images: [ImageAttachment],
        chatFilename: String
    ) -> ChatQuery.ChatCompletionMessageParam {
        typealias UserMsg = ChatQuery.ChatCompletionMessageParam.UserMessageParam
        var parts: [UserMsg.Content.ContentPart] = []
        // Text first (if any), then images.
        if !msg.content.isEmpty {
            parts.append(.text(.init(text: msg.content)))
        }
        for img in images {
            guard let data = EnvironmentManager.shared.loadImageData(img, chatFilename: chatFilename) else { continue }
            let url = "data:\(img.mimeType);base64,\(data.base64EncodedString())"
            let imageURL = ChatQuery.ChatCompletionMessageParam.ContentPartImageParam.ImageURL(url: url, detail: .auto)
            parts.append(.image(.init(imageUrl: imageURL)))
        }
        let content = UserMsg.Content.contentParts(parts)
        return .user(.init(content: content))
    }

    /// Builds an Anthropic message with multipart content (text + image parts)
    /// for a message that carries images. Images are base64-encoded sources.
    private func anthropicMessage(
        for msg: ChatMessage,
        images: [ImageAttachment],
        role: MessageParameter.Message.Role,
        chatFilename: String
    ) -> MessageParameter.Message {
        var objects: [MessageParameter.Message.Content.ContentObject] = []
        if !msg.content.isEmpty {
            objects.append(.text(msg.content))
        }
        for img in images {
            guard let data = EnvironmentManager.shared.loadImageData(img, chatFilename: chatFilename) else { continue }
            let mediaType: MessageParameter.Message.Content.ImageSource.MediaType = img.isLossless ? .png : .jpeg
            let source = MessageParameter.Message.Content.ImageSource(
                type: .base64,
                mediaType: mediaType,
                data: data.base64EncodedString()
            )
            objects.append(.image(source))
        }
        return MessageParameter.Message(role: role, content: .list(objects))
    }

    // MARK: - Anthropic

    private func streamAnthropic(
        connection: Connection,
        messages: [ChatMessage],
        chatFilename: String,
        tools: [ToolDefinition]?,
        onChunk: @escaping @Sendable (StreamChunk) async -> Void
    ) async throws -> StreamResult {
        let apiVersion = "2023-06-01"

        let basePath = connection.endpoint ?? "https://api.anthropic.com"
        let service = AnthropicServiceFactory.service(
            apiKey: connection.token ?? "",
            apiVersion: apiVersion,
            basePath: basePath,
            betaHeaders: nil
        )

        // Separate system prompt from conversation messages.
        var systemText: String?
        var conversationMessages: [ChatMessage] = []
        for msg in messages {
            if msg.role == .system {
                systemText = msg.content
            } else {
                conversationMessages.append(msg)
            }
        }

        // Convert messages to Anthropic format. Tool-result messages (role
        // `.tool`) are folded into a `user` message as `tool_result` content
        // blocks, per the Anthropic API: tool results must be sent as `user`
        // messages containing `tool_result` blocks. Assistant messages
        // carrying tool calls become `assistant` messages with `tool_use`
        // content blocks. Tool results are stored as their own `tool`-role
        // `ChatMessage` (the natural provider shape), so no un-folding is
        // needed — each message maps 1:1.
        let anthropicMessages: [MessageParameter.Message] = conversationMessages.map { msg -> MessageParameter.Message in
            let role: MessageParameter.Message.Role = msg.role == .user || msg.role == .tool ? .user : .assistant
            if let images = msg.images, !images.isEmpty {
                return anthropicMessage(for: msg, images: images, role: role, chatFilename: chatFilename)
            }
            // Assistant message with tool calls → list with text + tool_use blocks.
            if msg.role == .assistant, let calls = msg.toolCalls, !calls.isEmpty {
                var objects: [MessageParameter.Message.Content.ContentObject] = []
                if !msg.content.isEmpty {
                    objects.append(.text(msg.content))
                }
                for call in calls {
                    let input = anthropicToolInput(from: call.arguments)
                    objects.append(.toolUse(call.id, call.name, input))
                }
                return MessageParameter.Message(role: .assistant, content: .list(objects))
            }
            // Tool-result message → user message with tool_result block(s).
            if msg.role == .tool, let results = msg.toolResults, !results.isEmpty {
                var objects: [MessageParameter.Message.Content.ContentObject] = []
                for r in results {
                    objects.append(.toolResult(r.callID, [.text(r.content)], r.isError ? false : nil, nil))
                }
                return MessageParameter.Message(role: .user, content: .list(objects))
            }
            return MessageParameter.Message(role: role, content: .text(msg.content))
        }

        let maxTokens = connection.maxTokens ?? 4096

        // Build thinking parameter if enabled.
        let thinking: MessageParameter.Thinking?
        if connection.thinkingEnabled == true {
            thinking = MessageParameter.Thinking(budgetTokens: connection.thinkingBudget ?? 16000)
        } else {
            thinking = nil
        }

        // Build Anthropic tool definitions from MCP tools.
        let anthropicTools: [MessageParameter.Tool]? = {
            guard let tools, !tools.isEmpty else { return nil }
            return tools.map { def in
                .function(
                    name: def.namespacedName,
                    description: def.description,
                    inputSchema: anthropicJSONSchema(for: def.inputSchema)
                )
            }
        }()

        let parameters = MessageParameter(
            model: .other(connection.model),
            messages: anthropicMessages,
            maxTokens: maxTokens,
            system: systemText.map { .text($0) },
            stopSequences: connection.stopSequences,
            temperature: connection.temperature,
            topK: connection.topK,
            topP: connection.topP,
            tools: anthropicTools,
            thinking: thinking
        )

        var fullContent = ""
        var finishReason: String?
        // Anthropic streams a tool_use block across events: `content_block_start`
        // carries the id + name, then `content_block_delta` events carry
        // `partialJson` fragments for the input. We accumulate per block index.
        var toolBlockAccumulator: [Int: (id: String, name: String, args: String)] = [:]

        let stream = try await service.streamMessage(parameters)
        for try await event in stream {
            // Allow the caller to cancel an in-flight stream between chunks.
            try Task.checkCancellation()
            switch event.type {
            case "content_block_start":
                // A new content block is starting. If it's a tool_use block,
                // capture its id + name keyed by index.
                if let block = event.contentBlock, block.type == "tool_use",
                   let index = event.index,
                   let id = block.id, let name = block.name {
                    toolBlockAccumulator[index] = (id: id, name: name, args: "")
                }
            case "content_block_delta":
                if let delta = event.delta {
                    if delta.type == "thinking_delta", let thinking = delta.thinking {
                        await onChunk(.thinking(thinking))
                    } else if delta.type == "input_json_delta", let partial = delta.partialJson {
                        // Accumulate tool-use input JSON fragments.
                        if let index = event.index, toolBlockAccumulator[index] != nil {
                            toolBlockAccumulator[index]!.args += partial
                        }
                    } else if let text = delta.text {
                        fullContent += text
                        await onChunk(.content(text))
                    }
                }
            case "message_delta":
                // The stop_reason arrives in the message_delta event.
                if let reason = event.delta?.stopReason {
                    finishReason = reason
                }
            default:
                break
            }
        }

        // Materialize accumulated tool-use blocks into ToolCall objects.
        var toolCalls: [ToolCall] = []
        for index in toolBlockAccumulator.keys.sorted() {
            guard let entry = toolBlockAccumulator[index] else { continue }
            let call = ToolCall(id: entry.id, name: entry.name, arguments: entry.args)
            toolCalls.append(call)
            await onChunk(.toolCall(call))
        }
        if let reason = finishReason {
            await onChunk(.finishReason(reason))
        }
        return StreamResult(content: fullContent, toolCalls: toolCalls, finishReason: finishReason)
    }

    // MARK: - Tool schema / input helpers

    /// Maps a raw JSON Schema string (from an MCP tool) into the SwiftAnthropic
    /// `JSONSchema` type. The Anthropic schema struct is a fixed shape that
    /// only models a subset of JSON Schema; rather than fully walk the schema
    /// tree, we decode the top-level `type`/`properties`/`required` and best-
    /// effort map property types. If parsing fails we fall back to a permissive
    /// object schema so the tool is still exposed.
    private func anthropicJSONSchema(for schemaString: String) -> SwiftAnthropic.JSONSchema? {
        guard let data = schemaString.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SwiftAnthropic.JSONSchema(type: .object, properties: [:], required: nil)
        }
        let typeString = (raw["type"] as? String) ?? "object"
        let jsonType = SwiftAnthropic.JSONSchema.JSONType(rawValue: typeString) ?? .object
        let required = raw["required"] as? [String]
        var properties: [String: SwiftAnthropic.JSONSchema.Property] = [:]
        if let props = raw["properties"] as? [String: Any] {
            for (key, value) in props {
                if let propDict = value as? [String: Any] {
                    let propType = (propDict["type"] as? String) ?? "string"
                    properties[key] = SwiftAnthropic.JSONSchema.Property(
                        type: SwiftAnthropic.JSONSchema.JSONType(rawValue: propType) ?? .string,
                        description: propDict["description"] as? String
                    )
                } else {
                    properties[key] = SwiftAnthropic.JSONSchema.Property(type: .string)
                }
            }
        }
        return SwiftAnthropic.JSONSchema(type: jsonType, properties: properties, required: required)
    }

    /// Parses a raw JSON arguments string into the `Input` dictionary shape
    /// expected by the SwiftAnthropic `toolUse` content object. If parsing
    /// fails, an empty dictionary is returned so the tool call still serializes.
    private func anthropicToolInput(from arguments: String) -> MessageResponse.Content.Input {
        guard let data = arguments.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var input: MessageResponse.Content.Input = [:]
        for (key, value) in raw {
            input[key] = anthropicDynamicContent(from: value)
        }
        return input
    }

    /// Recursively converts a JSON-serialized value into the SwiftAnthropic
    /// `DynamicContent` enum.
    private func anthropicDynamicContent(from value: Any) -> MessageResponse.Content.DynamicContent {
        if let v = value as? String { return .string(v) }
        if let v = value as? Int { return .integer(v) }
        if let v = value as? Double { return .double(v) }
        if let v = value as? Bool { return .bool(v) }
        if let v = value as? [Any] { return .array(v.map { anthropicDynamicContent(from: $0) }) }
        if let v = value as? [String: Any] {
            var dict: MessageResponse.Content.Input = [:]
            for (k, val) in v { dict[k] = anthropicDynamicContent(from: val) }
            return .dictionary(dict)
        }
        return .null
    }
}
