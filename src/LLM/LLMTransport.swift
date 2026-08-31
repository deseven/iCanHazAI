// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The shared HTTP/SSE/cancellation/error infrastructure for all LLM
/// providers.
///
/// The transport is provider-agnostic: it builds a `URLRequest` via the
/// provider strategy's `buildRequestBody`, sends it with `URLSession`, and on
/// success parses the SSE stream (or the non-streaming body) back through the
/// strategy. On failure it drains the response body and hands it to the
/// strategy's error parser so the user sees the actual provider error message.
///
/// Every request attempt runs under a three-layer watchdog — no request can
/// hang indefinitely:
///
/// 1. `readTimeout` (default 30 s) — abort when **no data at all** arrives:
///    response headers, SSE lines, and keep-alive comments all count. The
///    clock starts before the connection is made, so offline networks,
///    blackholed connects, and unresponsive servers are caught too.
/// 2. `progressTimeout` (default 60 s) — abort when no **useful output**
///    arrives (content, thinking, tool-call deltas, finish reason, usage).
///    Keep-alives do not count. Catches providers that hold the connection
///    open while producing nothing (endless pings, wedged generation).
/// 3. `transportTimeout` (default 3600 s) — hard cap on the whole attempt
///    regardless of activity. Each retry attempt gets a fresh budget.
///
/// A connection value of `0` disables its layer; disabling all three removes
/// every application-level guard (the OS-level 24 h resource cap remains).
/// Non-streaming requests (connection wizard test, models listing) enforce
/// only the transport layer — a single-burst response has no meaningful
/// intermediate progress to measure; the OS idle timer covers their
/// silent-stall case as before.
///
/// Mechanics: the consumer work and the watchdog run as siblings in a task
/// group. A fired watchdog cancels the consumer, whose pending `URLSession`
/// read throws immediately, and its own typed error wins the race so the
/// caller sees `readTimeout`/`progressTimeout`/`transportTimeout` rather than
/// a generic cancellation. User-initiated stops propagate unchanged.
///
/// See the plan in [`plans/llm-transport-replacement.md`](plans/llm-transport-replacement.md)
/// for the original transport architecture.
enum LLMTransport {

    // MARK: - Timeout defaults

    /// Abort when no data at all arrives for this long.
    static let defaultReadTimeout: TimeInterval = 30
    /// Abort when no useful output arrives for this long.
    static let defaultProgressTimeout: TimeInterval = 60
    /// Hard cap on a single request attempt.
    static let defaultTransportTimeout: TimeInterval = 3600

    /// The shared URLSession. A dedicated configuration keeps LLM traffic
    /// isolated from the app's other URL activity (image scheme handler,
    /// MCP, etc.) and avoids contention on the shared session's queue.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Coarse OS-level idle failsafe. Streaming requests override it
        // per-request (sized to sit behind the read watchdog), so this only
        // bounds non-streaming requests and any path that forgets the
        // override.
        config.timeoutIntervalForRequest = 60
        // Backstop for the whole transfer. The per-attempt transportTimeout
        // watchdog is the real cap; this only bounds pathological
        // configurations where every application-level layer was disabled.
        config.timeoutIntervalForResource = 86400
        // Fail fast when offline instead of silently parking the request in
        // "waiting for connectivity" — that state ignores the request idle
        // timeout and used to hang for the full resource timeout.
        config.waitsForConnectivity = false
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
    /// not) using the provider strategy. The OS-level idle timer is pushed
    /// behind the application read watchdog: `readTimeout + 30 s` grace, or
    /// effectively off when the read layer is disabled.
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
        request.timeoutInterval = (TimeoutPolicy.resolve(connection).read ?? 86400) + 30
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

    /// Streams a chat completion with automatic retry and the three-layer
    /// watchdog. Retries are invisible to the caller — the first successful
    /// (or final failing) attempt is surfaced. Retries are skipped once any
    /// output reached the caller (a second attempt would concatenate a
    /// duplicate response onto the partial one) and for permanent failures
    /// (offline / DNS errors, HTTP 4xx, total-budget timeout).
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
        let output = OutputTracker()

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
                    onChunk: { chunk in
                        output.record(chunk)
                        await onChunk(chunk)
                    }
                )
            } catch is CancellationError {
                // User-initiated cancellation — never retry.
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                // A stop during the connect phase surfaces as URLError.cancelled
                // from URLSession; normalize so callers see CancellationError.
                throw CancellationError()
            } catch {
                if output.hasEmittedOutput || !isRetryable(error) {
                    throw error
                }
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

    /// Performs a single streaming attempt under the watchdog. Called by
    /// `stream()`; exposed separately so retries can be attempted without the
    /// caller knowing.
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
        let state = WatchdogState(policy: TimeoutPolicy.resolve(connection))
        let accumulator = ToolCallAccumulator()
        let resultBox = ResultBox<ChatService.StreamResult>()

        try await raceWatchdog(state) {
            let (bytes, response): (URLSession.AsyncBytes, URLResponse)
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch {
                DebugLogger.recordLastRequest(
                    requestDump(
                        request: request, response: nil, receivedBody: Data(),
                        transportError: watchdogNote(state, "\(error)")))
                throw error
            }
            // Response headers arrived — that is data for the read layer.
            state.touchData()

            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let body = try await drainBytes(bytes) { state.touchData() }
                DebugLogger.recordLastRequest(requestDump(request: request, response: http, receivedBody: body))
                debugLog(
                    "LLM", "HTTP \(http.statusCode) error body:\n\(String(data: body, encoding: .utf8) ?? "<non-utf8>")"
                )
                throw provider.parseError(body, statusCode: http.statusCode)
            }

            var fullContent = ""
            var finishReason: String?
            var usage: TokenUsage?
            var streamError: String?
            // Raw SSE lines of this stream, kept for the debug dump on error.
            var rawDump: [String] = []

            do {
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    state.touchData()

                    rawDump.append(line)
                    guard let payload = SSEParser.parsePayload(line) else { continue }
                    if case .done = payload { break }
                    guard case .data(let jsonString) = payload,
                        let data = jsonString.data(using: .utf8)
                    else { continue }
                    let chunks = provider.parseStreamChunk(data, accumulator: accumulator)
                    for chunk in chunks {
                        if isUsefulOutput(chunk) {
                            state.touchProgress()
                        }
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

                let result = ChatService.StreamResult(
                    content: fullContent,
                    toolCalls: toolCalls,
                    finishReason: finishReason,
                    usage: usage,
                    error: streamError
                )
                // Stash the result first, then tell the watchdog the attempt
                // completed cleanly so it exits instead of firing a timeout
                // that races the result.
                resultBox.set(result)
                state.finish()
            } catch {
                // Stream aborted (cancellation, connection drop, watchdog fire):
                // dump everything received so far so last_request.log reflects
                // this request rather than a stale one.
                DebugLogger.recordLastRequest(
                    requestDump(
                        request: request,
                        response: response,
                        receivedBody: Data(rawDump.joined(separator: "\n").utf8),
                        transportError: watchdogNote(state, "\(error)")))
                throw error
            }
        }

        guard let result = resultBox.get() else {
            throw LLMTransportError.watchdogRace
        }
        return result
    }

    // MARK: - Non-streaming

    /// Performs a non-streaming chat completion and returns the assistant's
    /// text. Used by the connection wizard's "say hi" test. Only the
    /// transport-timeout layer applies: the response arrives as a single
    /// burst, so there is no intermediate progress to measure. The OS idle
    /// timer (sized from the connection's read timeout by `buildRequest`)
    /// covers the silent-stall case.
    static func complete(connection: Connection, messages: [ChatMessage]) async throws -> String {
        let provider = provider(for: connection)
        let request = try buildRequest(
            connection: connection,
            messages: messages,
            chatFilename: "",
            tools: nil,
            stream: false
        )
        let state = WatchdogState(
            policy: TimeoutPolicy(read: nil, progress: nil, transport: TimeoutPolicy.resolve(connection).transport))
        let box = ResultBox<(Data, URLResponse)>()
        let finalRequest = request

        try await raceWatchdog(state) {
            do {
                box.set(try await session.data(for: finalRequest))
            } catch {
                DebugLogger.recordLastRequest(
                    requestDump(request: finalRequest, response: nil, receivedBody: Data(), transportError: "\(error)"))
                throw error
            }
        }
        guard let (data, response) = box.get() else {
            throw LLMTransportError.watchdogRace
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            DebugLogger.recordLastRequest(requestDump(request: finalRequest, response: http, receivedBody: data))
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
            DebugLogger.recordLastRequest(requestDump(request: finalRequest, response: http, receivedBody: data))
            debugLog("LLM", "HTTP 200 error body:\n\(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
            throw provider.parseError(data, statusCode: http.statusCode)
        }

        DebugLogger.recordLastRequest(requestDump(request: finalRequest, response: response, receivedBody: data))
        return provider.parseCompleteResponse(data)
    }

    // MARK: - Models listing

    /// Fetches the list of available models from a provider's `/models`
    /// endpoint. `headers` is threaded through so a credentials check / model
    /// fetch in the wizard matches what the saved connection will send —
    /// otherwise the wizard could fail while the saved config works, for
    /// exactly the header-gated gateway that motivated custom headers.
    /// Enforces the transport-timeout layer only (see `complete`).
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
        let synthetic = Connection(
            provider: provider,
            name: "_models",
            baseUrl: baseUrl,
            apiKey: apiKey,
            model: "",
            imageInput: false,
            requestParameters: nil,
            headers: headers
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in strategy.buildHeaders(connection: synthetic) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let state = WatchdogState(
            policy: TimeoutPolicy(read: nil, progress: nil, transport: TimeoutPolicy.resolve(synthetic).transport))
        let box = ResultBox<(Data, URLResponse)>()
        let finalRequest = request

        try await raceWatchdog(state) {
            do {
                box.set(try await session.data(for: finalRequest))
            } catch {
                DebugLogger.recordLastRequest(
                    requestDump(request: finalRequest, response: nil, receivedBody: Data(), transportError: "\(error)"))
                throw error
            }
        }
        guard let (data, response) = box.get() else {
            throw LLMTransportError.watchdogRace
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            DebugLogger.recordLastRequest(requestDump(request: finalRequest, response: http, receivedBody: data))
            throw strategy.parseError(data, statusCode: http.statusCode)
        }

        DebugLogger.recordLastRequest(requestDump(request: finalRequest, response: response, receivedBody: data))
        return strategy.parseModelsResponse(data)
    }

    // MARK: - Watchdog race

    /// Runs `consumer` racing a watchdog task. The watchdog exits once the
    /// consumer finishes (or when every layer is disabled) and throws a
    /// timeout error when a deadline genuinely expires — cancelling the
    /// consumer, whose pending `URLSession` read then throws immediately.
    /// The consumer hands its outcome back through a `ResultBox` captured by
    /// the caller, keeping non-`Sendable` response objects out of the
    /// task-group boundary.
    private static func raceWatchdog(
        _ state: WatchdogState,
        consumer: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await state.runWatchdog()
                return false
            }
            group.addTask {
                try await consumer()
                return true
            }

            var consumerFinished = false
            var failure: Error?
            do {
                for try await finished in group {
                    if finished {
                        consumerFinished = true
                        group.cancelAll()
                    }
                }
            } catch {
                failure = error
            }
            if consumerFinished, failure == nil { return }
            if let failure { throw failure }
            throw LLMTransportError.watchdogRace
        }
    }

    // MARK: - Classification helpers

    /// Whether a chunk carries output the user would see. Drives both the
    /// progress-timeout layer (keep-alives don't refresh it) and the
    /// retry gate (output was emitted → don't retry).
    fileprivate static func isUsefulOutput(_ chunk: StreamChunk) -> Bool {
        switch chunk {
        case .content(let text): return !text.isEmpty
        case .thinking(let text): return !text.isEmpty
        case .toolCallDelta, .toolCall, .finishReason, .usage, .error: return true
        }
    }

    /// Whether a failed attempt is worth retrying. Offline-class failures and
    /// permanent HTTP 4xx errors surface immediately; the total-budget
    /// timeout is also final (a retry would burn another full budget on the
    /// same pathological request). Read/progress stalls are retried —
    /// transient stalls are the classic retry case.
    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case is CancellationError:
            return false
        case let urlError as URLError:
            switch urlError.code {
            case .cancelled,
                .notConnectedToInternet,
                .internationalRoamingOff,
                .dataNotAllowed,
                .dnsLookupFailed,
                .cannotFindHost:
                return false
            default:
                return true
            }
        case let llmError as LLMError:
            return !(400..<500).contains(llmError.statusCode)
        case let transportError as LLMTransportError:
            if case .transportTimeout = transportError { return false }
            return true
        default:
            return true
        }
    }

    /// Annotates a transport-error dump with the watchdog layer that fired,
    /// so `last_request.log` shows the real cause when the watchdog's
    /// cancellation surfaces inside the consumer as a generic cancellation
    /// error.
    private static func watchdogNote(_ state: WatchdogState, _ underlying: String) -> String {
        if let kind = state.firedKind() {
            return "watchdog fired (\(kind.label)); consumer error: \(underlying)"
        }
        return underlying
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
    /// full error body on non-2xx responses before parsing it. `onData` is
    /// called per received byte so the read-timeout layer tracks a slow
    /// error body like any other data.
    private static func drainBytes(
        _ bytes: URLSession.AsyncBytes,
        onData: @escaping @Sendable () -> Void
    ) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            onData()
        }
        return body
    }
}

// MARK: - Timeout policy

/// The three timeout layers resolved for a single request. `nil` means the
/// layer is disabled; resolution maps a connection's `nil` to the layer
/// default and `≤ 0` to disabled.
struct TimeoutPolicy: Sendable {
    let read: TimeInterval?
    let progress: TimeInterval?
    let transport: TimeInterval?

    static func resolve(_ connection: Connection) -> TimeoutPolicy {
        TimeoutPolicy(
            read: layer(connection.readTimeout, LLMTransport.defaultReadTimeout),
            progress: layer(connection.progressTimeout, LLMTransport.defaultProgressTimeout),
            transport: layer(connection.transportTimeout, LLMTransport.defaultTransportTimeout))
    }

    private static func layer(_ value: Double?, _ fallback: TimeInterval) -> TimeInterval? {
        guard let value else { return fallback }
        return value > 0 ? value : nil
    }
}

// MARK: - Watchdog state

/// Shared progress state between a request's consumer work and its watchdog
/// task. The consumer refreshes `lastDataAt` / `lastProgressAt` as bytes and
/// useful chunks arrive; the watchdog wakes at each nearest deadline and
/// re-evaluates — fresh timestamps push the deadline out, a genuinely stale
/// one fires and cancels the consumer.
private final class WatchdogState: @unchecked Sendable {
    /// Which timeout layer fired.
    enum Kind: Sendable {
        case read
        case progress
        case transport

        var label: String {
            switch self {
            case .read: return "readTimeout"
            case .progress: return "progressTimeout"
            case .transport: return "transportTimeout"
            }
        }
    }

    private let lock = NSLock()
    private let policy: TimeoutPolicy
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var lastDataAt: ContinuousClock.Instant
    private var lastProgressAt: ContinuousClock.Instant
    private var finished = false
    private var fired: Kind?

    init(policy: TimeoutPolicy) {
        self.policy = policy
        let now = clock.now
        self.startedAt = now
        self.lastDataAt = now
        self.lastProgressAt = now
    }

    /// Records that raw data (headers, bytes, SSE lines) arrived.
    func touchData() {
        lock.lock()
        lastDataAt = clock.now
        lock.unlock()
    }

    /// Records that useful output (content, thinking, tool calls, ...) arrived.
    func touchProgress() {
        lock.lock()
        lastProgressAt = clock.now
        lock.unlock()
    }

    /// Marks the attempt complete so the watchdog exits without firing.
    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    /// The layer that fired, if any. Used to annotate error dumps.
    func firedKind() -> Kind? {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    /// The earliest unmet deadline across the enabled layers, or nil when the
    /// attempt finished or every layer is disabled.
    func nearestDeadline() -> (kind: Kind, deadline: ContinuousClock.Instant)? {
        lock.lock()
        defer { lock.unlock() }
        if finished { return nil }
        var best: (kind: Kind, deadline: ContinuousClock.Instant)?
        if let t = policy.transport {
            let d = startedAt.advanced(by: .seconds(t))
            if best == nil || d < best!.deadline { best = (.transport, d) }
        }
        if let r = policy.read {
            let d = lastDataAt.advanced(by: .seconds(r))
            if best == nil || d < best!.deadline { best = (.read, d) }
        }
        if let p = policy.progress {
            let d = lastProgressAt.advanced(by: .seconds(p))
            if best == nil || d < best!.deadline { best = (.progress, d) }
        }
        return best
    }

    /// Records the fired layer.
    func markFired(_ kind: Kind) {
        lock.lock()
        fired = kind
        lock.unlock()
    }

    /// The error thrown when `kind` fires.
    func error(for kind: Kind) -> Error {
        switch kind {
        case .read: return LLMTransportError.readTimeout(policy.read ?? 0)
        case .progress: return LLMTransportError.progressTimeout(policy.progress ?? 0)
        case .transport: return LLMTransportError.transportTimeout(policy.transport ?? 0)
        }
    }

    /// The watchdog loop: sleep until the nearest deadline, re-evaluate, and
    /// throw when one genuinely expires. Waking to fresh timestamps re-arms
    /// the sleep — no signaling needed. Task cancellation ends the loop.
    func runWatchdog() async throws {
        while !Task.isCancelled {
            guard let (kind, deadline) = nearestDeadline() else { return }
            let remaining = clock.now.duration(to: deadline)
            if remaining <= .zero {
                markFired(kind)
                throw error(for: kind)
            }
            try? await Task.sleep(for: remaining)
        }
    }
}

// MARK: - Result box

/// A lock-protected one-shot result slot. Lets the watchdog-race consumer
/// hand its outcome to the caller without requiring the payload to be
/// `Sendable` (the box is `@unchecked`); the payload is written once and
/// never mutated afterwards.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Output tracker

/// Tracks whether any output-carrying chunk reached the caller during a
/// streaming attempt. Retries are suppressed once output was emitted — a
/// second attempt would concatenate a duplicate response onto the partial one.
private final class OutputTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var emitted = false

    var hasEmittedOutput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return emitted
    }

    func record(_ chunk: StreamChunk) {
        if LLMTransport.isUsefulOutput(chunk) {
            lock.lock()
            emitted = true
            lock.unlock()
        }
    }
}

// MARK: - Errors

enum LLMTransportError: Error, LocalizedError {
    case invalidUrl(String)
    case modelsEndpointUnavailable(ConnectionProvider)
    /// No data at all arrived within the read-timeout window.
    case readTimeout(TimeInterval)
    /// Data (keep-alives) kept arriving but no useful output did.
    case progressTimeout(TimeInterval)
    /// The whole attempt exceeded its total budget.
    case transportTimeout(TimeInterval)
    /// Unreachable: the watchdog race ended without a consumer outcome.
    case watchdogRace

    var errorDescription: String? {
        switch self {
        case .invalidUrl(let url):
            return "Invalid URL: \(url)"
        case .modelsEndpointUnavailable(let provider):
            return "\(provider.rawValue) does not expose a models listing endpoint."
        case .readTimeout(let seconds):
            return "No data received for \(Int(seconds))s — the connection stalled or the provider is unreachable."
        case .progressTimeout(let seconds):
            return
                "No usable output for \(Int(seconds))s — the provider kept the connection alive but stopped producing content."
        case .transportTimeout(let seconds):
            return "The request exceeded its total \(Int(seconds))s budget and was aborted."
        case .watchdogRace:
            return "Internal error: request watchdog race ended without an outcome."
        }
    }
}
