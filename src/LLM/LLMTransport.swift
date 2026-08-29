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
        // keeps producing tokens never hits it. Raised to 60 s so it acts as a
        // coarse failsafe rather than the primary watchdog (the per-request
        // `readTimeout` is the stricter, content-aware guard).
        config.timeoutIntervalForRequest = 60
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
        case .openai: return OpenAIProvider()
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

    /// Streams a chat completion with automatic retry and a per-request
    /// read-timeout. Retries are invisible to the caller — the first
    /// successful (or final failing) attempt is surfaced.
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
        let maxRetries = max(0, connection.numRetries ?? 1)
        var lastError: Error?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delay = pow(2.0, Double(attempt - 1))
                debugLog("LLM", "retry \(attempt)/\(maxRetries) after \(delay)s — \(connection.id)")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                return try await streamOnce(
                    connection: connection,
                    messages: messages,
                    chatFilename: chatFilename,
                    tools: tools,
                    onChunk: onChunk
                )
            } catch is CancellationError {
                // User-initiated cancellation — never retry.
                throw CancellationError()
            } catch {
                lastError = error
                debugLog(
                    "LLM", "stream attempt \(attempt + 1)/\(maxRetries + 1) failed — \(error.localizedDescription)")
            }
        }

        // `streamOnce` already wrote `last_request.log` for the final attempt.
        if let error = lastError {
            throw error
        }
        // Should be unreachable, but satisfies the compiler.
        throw LLMTransportError.invalidUrl("unknown")
    }

    /// Performs a single streaming attempt. Called by `stream()`; exposed
    /// separately so retries can be attempted without the caller knowing.
    private static func streamOnce(
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

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            DebugLogger.recordLastRequest(
                requestDump(request: request, response: nil, receivedBody: Data(), transportError: "\(error)"))
            throw error
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = try await drainBytes(bytes)
            DebugLogger.recordLastRequest(requestDump(request: request, response: http, receivedBody: body))
            debugLog(
                "LLM", "HTTP \(http.statusCode) error body:\n\(String(data: body, encoding: .utf8) ?? "<non-utf8>")")
            throw provider.parseError(body, statusCode: http.statusCode)
        }

        let readTimeout = connection.readTimeout ?? 30
        let effectiveTimeout = readTimeout > 0 ? readTimeout : nil

        var fullContent = ""
        var finishReason: String?
        var usage: TokenUsage?
        var streamError: String?
        // Raw SSE lines of this stream, kept for the debug dump on error.
        var rawDump: [String] = []
        let accumulator = ToolCallAccumulator()

        // Watchdog that aborts the stream if no useful output arrives within
        // `readTimeout` seconds from the start of the stream. Bare SSE
        // keep-alive lines do NOT reset it — only actual content / thinking /
        // tool-call-delta / finish-reason / usage chunks count as useful.
        let timeoutSeconds: TimeInterval? = effectiveTimeout
        let timeoutTask: Task<Void, Never>?
        let timedOut: @Sendable () -> Bool
        if let seconds = timeoutSeconds {
            let box = TimeoutBox()
            timedOut = { box.isTimedOut }
            timeoutTask = Task { [box] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                box.setTimedOut()
            }
        } else {
            timedOut = { false }
            timeoutTask = nil
        }

        let streamResult: ChatService.StreamResult
        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()

                // Check timeout before processing the line we just received.
                // If the provider sent a keep-alive after a long silence, the
                // timeout may already have fired while `next()` was blocked.
                if timedOut() {
                    throw LLMTransportError.readTimeout(timeoutSeconds!)
                }

                rawDump.append(line)
                guard let payload = SSEParser.parsePayload(line) else { continue }
                if case .done = payload { break }
                guard case .data(let jsonString) = payload,
                    let data = jsonString.data(using: .utf8)
                else { continue }
                let chunks = provider.parseStreamChunk(data, accumulator: accumulator)
                for chunk in chunks {
                    switch chunk {
                    case .content(let text):
                        fullContent += text
                    case .finishReason(let reason):
                        finishReason = reason
                    case .usage(let u):
                        usage = u
                    case .error(let message):
                        streamError = message
                    default:
                        break
                    }
                    await onChunk(chunk)
                }
            }

            // Debug: dump the entire raw response when the stream ended in an
            // error OR produced no usable output (empty content, no tool calls).
            if streamError != nil
                || (fullContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && accumulator.isEmpty)
            {
                debugLog("LLM", "raw stream dump (\(rawDump.count) lines):\n" + rawDump.joined(separator: "\n"))
            }

            DebugLogger.recordLastRequest(
                requestDump(
                    request: request,
                    response: response,
                    receivedBody: Data(rawDump.joined(separator: "\n").utf8)))

            let toolCalls = accumulator.materialize()
            for call in toolCalls {
                await onChunk(.toolCall(call))
            }
            if let reason = finishReason {
                await onChunk(.finishReason(reason))
            }
            if let usage {
                await onChunk(.usage(usage))
            }

            streamResult = ChatService.StreamResult(
                content: fullContent,
                toolCalls: toolCalls,
                finishReason: finishReason,
                usage: usage,
                error: streamError
            )
        } catch {
            // Cancel the watchdog so it doesn't fire after we've left the scope.
            timeoutTask?.cancel()
            // Stream aborted (cancellation, connection drop, read timeout, ...):
            // dump everything received so far so last_request.log reflects this
            // request rather than a stale one.
            DebugLogger.recordLastRequest(
                requestDump(
                    request: request,
                    response: response,
                    receivedBody: Data(rawDump.joined(separator: "\n").utf8),
                    transportError: "\(error)"))
            throw error
        }

        timeoutTask?.cancel()
        return streamResult
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

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            DebugLogger.recordLastRequest(
                requestDump(request: request, response: nil, receivedBody: Data(), transportError: "\(error)"))
            throw error
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            DebugLogger.recordLastRequest(requestDump(request: request, response: http, receivedBody: data))
            debugLog(
                "LLM", "HTTP \(http.statusCode) error body:\n\(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
            throw provider.parseError(data, statusCode: http.statusCode)
        }

        // Some OpenAI-compatible gateways return HTTP 200 with an
        // `{"error": {...}}` body instead of a non-2xx status. Surface it.
        if let http = response as? HTTPURLResponse,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["error"] != nil
        {
            DebugLogger.recordLastRequest(requestDump(request: request, response: http, receivedBody: data))
            debugLog("LLM", "HTTP 200 error body:\n\(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
            throw provider.parseError(data, statusCode: http.statusCode)
        }

        DebugLogger.recordLastRequest(requestDump(request: request, response: response, receivedBody: data))
        return provider.parseCompleteResponse(data)
    }

    // MARK: - Models listing

    /// Fetches the list of available models from a provider's `/models`
    /// endpoint. `headers` is threaded through so a credentials check / model
    /// fetch in the wizard matches what the saved connection will send —
    /// otherwise the wizard could fail while the saved config works, for
    /// exactly the header-gated gateway that motivated custom headers.
    static func listModels(
        provider: ConnectionProvider,
        baseUrl: String?,
        apiKey: String?,
        headers: [String: String]? = nil
    ) async throws -> [ModelInfo] {
        let strategy: any LLMProvider
        switch provider {
        case .openai: strategy = OpenAIProvider()
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
        for (key, value) in strategy.buildHeaders(
            connection: Connection(
                provider: provider,
                name: "_models",
                baseUrl: baseUrl,
                apiKey: apiKey,
                model: "",
                imageInput: false,
                requestParameters: nil,
                headers: headers
            ))
        {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            DebugLogger.recordLastRequest(
                requestDump(request: request, response: nil, receivedBody: Data(), transportError: "\(error)"))
            throw error
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            DebugLogger.recordLastRequest(requestDump(request: request, response: http, receivedBody: data))
            throw strategy.parseError(data, statusCode: http.statusCode)
        }

        DebugLogger.recordLastRequest(requestDump(request: request, response: response, receivedBody: data))
        return strategy.parseModelsResponse(data)
    }

    // MARK: - Last request capture

    /// Builds a complete, human-readable dump of an HTTP exchange for
    /// `last_request.log` (written by
    /// [`DebugLogger.recordLastRequest(_:)`](src/Utilities/DebugLogger.swift) when
    /// app debug logging is enabled): method, URL, every request header, the
    /// request body, response status and headers, and the raw received body.
    /// When the transport itself failed (`transportError`), no response was
    /// received and the error is dumped instead.
    static func requestDump(
        request: URLRequest,
        response: URLResponse?,
        receivedBody: Data,
        transportError: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("=== Request ===")
        lines.append("\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<no url>")")
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            for key in headers.keys.sorted() {
                lines.append("\(key): \(headers[key] ?? "")")
            }
        }
        if let body = request.httpBody, !body.isEmpty {
            lines.append("")
            lines.append("=== Request body ===")
            lines.append(String(data: body, encoding: .utf8) ?? "<non-utf8 body, \(body.count) bytes>")
        }
        if let transportError {
            lines.append("")
            lines.append("=== Transport error ===")
            lines.append(transportError)
            return lines.joined(separator: "\n") + "\n"
        }
        lines.append("")
        lines.append("=== Response ===")
        if let http = response as? HTTPURLResponse {
            lines.append("HTTP \(http.statusCode)")
            for (key, value) in http.allHeaderFields {
                lines.append("\(key): \(value)")
            }
        } else if let response {
            lines.append(String(describing: response))
        } else {
            lines.append("<no response>")
        }
        lines.append("")
        lines.append("=== Response body ===")
        if receivedBody.isEmpty {
            lines.append("<empty>")
        } else {
            lines.append(String(data: receivedBody, encoding: .utf8) ?? "<non-utf8 body, \(receivedBody.count) bytes>")
        }
        return lines.joined(separator: "\n") + "\n"
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

// MARK: - Timeout box

/// A thread-safe box used by the read-timeout watchdog in `LLMTransport`.
/// The timer sleeps for `readTimeout` seconds and flips the flag; the stream
/// loop checks the flag before every line-read and throws
/// `LLMTransportError.readTimeout` when it is set.
private final class TimeoutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _isTimedOut = false

    var isTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isTimedOut
    }

    func setTimedOut() {
        lock.lock()
        _isTimedOut = true
        lock.unlock()
    }
}

// MARK: - Errors

enum LLMTransportError: Error, LocalizedError {
    case invalidUrl(String)
    case modelsEndpointUnavailable(ConnectionProvider)
    case readTimeout(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .invalidUrl(let url):
            return "Invalid URL: \(url)"
        case .modelsEndpointUnavailable(let provider):
            return "\(provider.rawValue) does not expose a models listing endpoint."
        case .readTimeout(let seconds):
            return "No data received for \(Int(seconds))s — the stream timed out."
        }
    }
}
