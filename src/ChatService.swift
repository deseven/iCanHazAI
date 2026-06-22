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

        let stream = (openAI as OpenAIAsync).chatsStream(query: query, vendorParameters: connection.vendorParameters)
        for try await result in stream {
            // Allow the caller to cancel an in-flight stream between chunks.
            try Task.checkCancellation()
            for choice in result.choices {
                let delta = choice.delta
                if let content = delta.content {
                    fullContent += content
                    await onChunk(.content(content))
                }
                // Reasoning content from providers like DeepSeek/Grok/OpenRouter/Gemini.
                if let reasoning = delta.reasoning {
                    await onChunk(.thinking(reasoning))
                }
            }
        }

        return fullContent
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
