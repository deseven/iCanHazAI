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
}

/// Provides streaming chat completion for both OpenAI-compatible and Anthropic connections.
final class ChatService: @unchecked Sendable {

    static let shared = ChatService()

    private init() {}

    /// Streams a chat completion, calling `onChunk` for each piece of content/thinking.
    /// - Parameters:
    ///   - connection: The connection to use.
    ///   - messages: The full conversation history (including system prompt if any).
    ///   - onChunk: Called for each streamed chunk.
    /// - Returns: The final assistant message text.
    @discardableResult
    func stream(
        connection: Connection,
        messages: [ChatMessage],
        onChunk: @escaping @Sendable (StreamChunk) async -> Void
    ) async throws -> String {
        switch connection.provider {
        case .openai:
            return try await streamOpenAI(connection: connection, messages: messages, onChunk: onChunk)
        case .anthropic:
            return try await streamAnthropic(connection: connection, messages: messages, onChunk: onChunk)
        }
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
        onChunk: @escaping @Sendable (StreamChunk) async -> Void
    ) async throws -> String {
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

        // Convert messages to OpenAI format.
        let chatMessages: [ChatQuery.ChatCompletionMessageParam] = messages.compactMap { msg in
            ChatQuery.ChatCompletionMessageParam(role: roleFor(msg.role), content: msg.content)
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

        let query = ChatQuery(
            messages: chatMessages,
            model: connection.model,
            reasoningEffort: reasoningEffort,
            frequencyPenalty: connection.frequencyPenalty,
            maxCompletionTokens: connection.maxCompletionTokens,
            presencePenalty: connection.presencePenalty,
            seed: connection.seed,
            temperature: connection.temperature,
            topP: connection.topP
        )

        var fullContent = ""

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
                }
                await flush(force: false)
            }
            // Drain any remaining buffered text before returning.
            await flush(force: true)
            return fullContent
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
        }
    }

    // MARK: - Anthropic

    private func streamAnthropic(
        connection: Connection,
        messages: [ChatMessage],
        onChunk: @escaping @Sendable (StreamChunk) async -> Void
    ) async throws -> String {
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

        let anthropicMessages: [MessageParameter.Message] = conversationMessages.map { msg in
            let role: MessageParameter.Message.Role = msg.role == .user ? .user : .assistant
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

        let parameters = MessageParameter(
            model: .other(connection.model),
            messages: anthropicMessages,
            maxTokens: maxTokens,
            system: systemText.map { .text($0) },
            stopSequences: connection.stopSequences,
            temperature: connection.temperature,
            topK: connection.topK,
            topP: connection.topP,
            thinking: thinking
        )

        var fullContent = ""

        let stream = try await service.streamMessage(parameters)
        for try await event in stream {
            // Allow the caller to cancel an in-flight stream between chunks.
            try Task.checkCancellation()
            if event.type == "content_block_delta" {
                if let delta = event.delta {
                    if delta.type == "thinking_delta", let thinking = delta.thinking {
                        await onChunk(.thinking(thinking))
                    } else if let text = delta.text {
                        fullContent += text
                        await onChunk(.content(text))
                    }
                }
            }
        }

        return fullContent
    }
}
