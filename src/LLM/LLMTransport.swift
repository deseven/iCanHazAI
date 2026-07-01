// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The shared HTTP/SSE/cancellation/error infrastructure for all LLM
/// providers.
///
/// The transport is provider-agnostic: it builds a `URLRequest` via the
/// provider strategy's [`buildRequestBody`](src/LLM/LLMProvider.swift), sends
/// it with `URLSession`, and on success parses the SSE stream (or the
/// non-streaming body) back through the strategy. On failure it drains the
/// response body and hands it to the strategy's error parser so the user
/// sees the actual provider error message.
///
/// Cancellation: `URLSession.bytes(for:)` respects `Task.cancel()`
/// natively, so cancelling the consuming `Task` propagates to the
/// underlying URLSession request without any manual wiring.
///
/// See the plan in [`plans/llm-transport-replacement.md`](plans/llm-transport-replacement.md)
/// for the full architecture.
enum LLMTransport {

    /// The shared URLSession. A dedicated configuration keeps LLM traffic
    /// isolated from the app's other URL activity (image scheme handler,
    /// MCP, etc.) and avoids contention on the shared session's queue.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // `timeoutIntervalForRequest` is the max idle time between received
        // bytes — it resets on every chunk, so a streaming response that
        // keeps producing tokens never hits it.
        config.timeoutIntervalForRequest = 30
        // `timeoutIntervalForResource` caps the total transfer time for the
        // entire stream.
        config.timeoutIntervalForResource = 1200
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    // MARK: - Provider resolution

    /// Returns the strategy for a given connection's provider.
    static func provider(for connection: Connection) -> any LLMProvider {
        switch connection.provider {
        case .openai:    return OpenAIProvider()
        case .anthropic: return AnthropicProvider()
        }
    }

    /// Resolves the effective base URL for a connection, falling back to the
    /// provider's default when the connection doesn't specify one.
    static func resolveBaseUrl(connection: Connection, provider: any LLMProvider) -> String {
        if let baseUrl = connection.baseUrl, !baseUrl.isEmpty {
            return baseUrl
        }
        return provider.defaultBaseUrl
    }

    // MARK: - Request building

    /// Builds a fully-formed `URLRequest` for a chat completion (streaming or
    /// not) using the provider strategy.
    static func buildRequest(
        connection: Connection,
        messages: [ChatMessage],
        chatFilename: String,
        tools: [ToolDefinition]?,
        stream: Bool
    ) throws -> URLRequest {
        let provider = provider(for: connection)
        let baseUrl = resolveBaseUrl(connection: connection, provider: provider)
        guard let url = URL(string: baseUrl + provider.chatPath) else {
            throw LLMTransportError.invalidUrl(baseUrl + provider.chatPath)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in provider.buildHeaders(connection: connection) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let body = provider.buildRequestBody(
            connection: connection,
            messages: messages,
            chatFilename: chatFilename,
            tools: tools,
            stream: stream
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Streaming

    /// Streams a chat completion, calling `onChunk` for each piece of
    /// content/thinking/tool-call-delta as it arrives from the SSE stream.
    ///
    /// At stream end the accumulated tool calls are materialized and emitted
    /// as `.toolCall` chunks, followed by the `.finishReason` chunk (if any).
    ///
    /// - Parameters:
    ///   - connection: The connection to use.
    ///   - messages: The full conversation history (including system prompt if any).
    ///   - chatFilename: The chat's filename, used to resolve image attachments on disk.
    ///   - tools: Optional MCP tool definitions to expose to the model.
    ///   - onChunk: Called for each streamed chunk (coalesced by the caller).
    /// - Returns: The stream result (final text, accumulated tool calls, finish reason).
    @discardableResult
    static func stream(
        connection: Connection,
        messages: [ChatMessage],
        chatFilename: String,
        tools: [ToolDefinition]?,
        onChunk: @escaping @Sendable (StreamChunk) async -> Void
    ) async throws -> ChatService.StreamResult {
        let provider = provider(for: connection)
        let request = try buildRequest(
            connection: connection,
            messages: messages,
            chatFilename: chatFilename,
            tools: tools,
            stream: true
        )

        let (bytes, response) = try await session.bytes(for: request)

        // Check the HTTP status before consuming the stream. On error, drain
        // the body and parse it via the provider's error shape.
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = try await drainBytes(bytes)
            throw provider.parseError(body, statusCode: http.statusCode)
        }

        var fullContent = ""
        var finishReason: String?
        let accumulator = ToolCallAccumulator()

        // Iterate over SSE lines. `bytes.lines` yields one line at a time
        // (no trailing newline), which is exactly what the SSE parser wants.
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let payload = SSEParser.parsePayload(line) else { continue }
            if case .done = payload { break }
            guard case .data(let jsonString) = payload,
                  let data = jsonString.data(using: .utf8) else { continue }
            let chunks = provider.parseStreamChunk(data, accumulator: accumulator)
            for chunk in chunks {
                switch chunk {
                case .content(let text):
                    fullContent += text
                case .finishReason(let reason):
                    finishReason = reason
                default:
                    break
                }
                await onChunk(chunk)
            }
        }

        // Materialize accumulated tool calls and emit each as a final chunk.
        let toolCalls = accumulator.materialize()
        for call in toolCalls {
            await onChunk(.toolCall(call))
        }
        if let reason = finishReason {
            await onChunk(.finishReason(reason))
        }

        return ChatService.StreamResult(
            content: fullContent,
            toolCalls: toolCalls,
            finishReason: finishReason
        )
    }

    // MARK: - Non-streaming

    /// Performs a non-streaming chat completion and returns the assistant's
    /// text. Used by the connection wizard's "say hi" test.
    static func complete(connection: Connection, messages: [ChatMessage]) async throws -> String {
        let provider = provider(for: connection)
        let request = try buildRequest(
            connection: connection,
            messages: messages,
            chatFilename: "",
            tools: nil,
            stream: false
        )

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw provider.parseError(data, statusCode: http.statusCode)
        }

        return provider.parseCompleteResponse(data)
    }

    // MARK: - Models listing

    /// Fetches the list of available models from a provider's `/models`
    /// endpoint.
    static func listModels(
        provider: ConnectionProvider,
        baseUrl: String?,
        apiKey: String?
    ) async throws -> [ModelInfo] {
        let strategy: any LLMProvider
        switch provider {
        case .openai:    strategy = OpenAIProvider()
        case .anthropic: strategy = AnthropicProvider()
        }
        guard let path = strategy.modelsPath else {
            throw LLMTransportError.modelsEndpointUnavailable(provider)
        }
        let base = (baseUrl?.isEmpty == false ? baseUrl! : strategy.defaultBaseUrl)
        guard let url = URL(string: base + path) else {
            throw LLMTransportError.invalidUrl(base + path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in strategy.buildHeaders(connection: Connection(
            provider: provider,
            name: "_models",
            baseUrl: baseUrl,
            apiKey: apiKey,
            model: "",
            imageInput: false,
            requestParameters: nil
        )) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw strategy.parseError(data, statusCode: http.statusCode)
        }

        return strategy.parseModelsResponse(data)
    }

    // MARK: - Helpers

    /// Drains an `AsyncBytes` stream into a `Data` buffer. Used to read the
    /// full error body on non-2xx responses before parsing it.
    private static func drainBytes(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
        }
        return body
    }
}

// MARK: - Errors

enum LLMTransportError: Error, LocalizedError {
    case invalidUrl(String)
    case modelsEndpointUnavailable(ConnectionProvider)

    var errorDescription: String? {
        switch self {
        case .invalidUrl(let url):
            return "Invalid URL: \(url)"
        case .modelsEndpointUnavailable(let provider):
            return "\(provider.rawValue) does not expose a models listing endpoint."
        }
    }
}
