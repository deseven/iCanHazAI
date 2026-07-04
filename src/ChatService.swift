// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A chunk received during streaming.
enum StreamChunk: Sendable {
    case thinking(String)
    case content(String)
    case error(String)
    /// A completed tool call accumulated from streamed deltas.
    case toolCall(ToolCall)
    /// An incremental tool call update. Emitted as arguments stream in so the
    /// UI can show a tool call block populating live, before the call
    /// completes. `index` identifies which tool call (stable within a
    /// response). `id` and `name` are nil until the first delta carries them.
    /// `argumentsDelta` is a fragment of the argument JSON string.
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsDelta: String)
    /// The finish reason reported by the provider (e.g. "stop", "tool_calls",
    /// "tool_use"). Emitted once at the end of a stream.
    case finishReason(String)
    /// Token usage reported by the provider for this response. Emitted once
    /// at the end of a stream (OpenAI sends it in a final chunk with
    /// `stream_options.include_usage`; Anthropic sends it in `message_delta`).
    case usage(TokenUsage)
}

/// Token usage as reported by the provider. Stored on each assistant
/// message; the chat info panel shows the last assistant message's total.
struct TokenUsage: Sendable, Equatable, Codable {
    let inputTokens: Int
    let outputTokens: Int
    var totalTokens: Int { inputTokens + outputTokens }
}

/// A shared chunk coalescer used by both providers so they stream at the same
/// cadence. Providers (especially OpenAI-compatible ones) emit deltas as small
/// as a single token; without coalescing each delta becomes its own `onChunk`
/// call, which the engine turns into a full `chatsChanged` event. At hundreds
/// of events per second the main-actor queue backs up and the stop button
/// feels sluggish.
///
/// Text (content + thinking) is accumulated into buffers and only flushed to
/// `onChunk` when either a buffer reaches `minChars` or `interval` has elapsed
/// since the last flush. Tool-call argument deltas (`.toolCallDelta`) are
/// coalesced the same way, keyed by tool-call `index`, so a streaming argument
/// JSON (e.g. a large file patch) populates at the same cadence as text
/// instead of firing one UI event per token. Non-text chunks (completed tool
/// calls, finish reason, errors) are flushed immediately via `flush(force:)`
/// at the end of the stream.
///
/// Both providers use the same instance parameters (~40 ms / 10 chars) so the
/// two paths stream at the same cadence.
struct ChunkCoalescer {
    private let minChars: Int
    private let interval: Duration
    private let clock: ContinuousClock
    private var contentBuffer = ""
    private var thinkingBuffer = ""
    /// Per-tool-call argument buffer. Keyed by the stable `index` from the
    /// provider's stream. Each entry accumulates argument fragments until a
    /// flush; the first flush for an index also carries the `id`/`name`.
    private var toolCallBuffers: [Int: ToolCallBufferEntry] = [:]
    private var lastFlush: ContinuousClock.Instant

    private let onChunk: @Sendable (StreamChunk) async -> Void

    /// Mutable state for a single in-flight tool-call argument buffer.
    private struct ToolCallBufferEntry {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    init(
        minChars: Int = 10,
        interval: Duration = .milliseconds(40),
        clock: ContinuousClock = ContinuousClock(),
        onChunk: @escaping @Sendable (StreamChunk) async -> Void
    ) {
        self.minChars = minChars
        self.interval = interval
        self.clock = clock
        self.onChunk = onChunk
        self.lastFlush = clock.now
    }

    /// Accumulates a text/thinking/tool-call-delta fragment into the
    /// appropriate buffer and flushes if a buffer threshold or the time
    /// interval is met.
    mutating func add(_ chunk: StreamChunk) async {
        switch chunk {
        case .content(let text):
            contentBuffer += text
        case .thinking(let text):
            thinkingBuffer += text
        case .toolCallDelta(let index, let id, let name, let argsDelta):
            var entry = toolCallBuffers[index] ?? ToolCallBufferEntry()
            if let id, !id.isEmpty { entry.id = id }
            if let name, !name.isEmpty { entry.name = name }
            entry.arguments += argsDelta
            toolCallBuffers[index] = entry
        default:
            await flush(force: true)
            await onChunk(chunk)
            return
        }
        await flush(force: false)
    }

    /// Flushes any buffered text/tool-call deltas. Call with `force: true` at
    /// stream end.
    mutating func flush(force: Bool) async {
        let now = clock.now
        let due = force || (now - lastFlush >= interval)
        if !contentBuffer.isEmpty && (force || contentBuffer.count >= minChars || due) {
            await onChunk(.content(contentBuffer))
            contentBuffer.removeAll(keepingCapacity: true)
        }
        if !thinkingBuffer.isEmpty && (force || thinkingBuffer.count >= minChars || due) {
            await onChunk(.thinking(thinkingBuffer))
            thinkingBuffer.removeAll(keepingCapacity: true)
        }
        // Flush tool-call argument buffers. Only emit when there are arguments
        // to send (the initial id/name-only delta is held until the first
        // argument fragment arrives, then flushed together). After flushing,
        // the entry is cleared; subsequent deltas recreate it carrying only
        // argument fragments — the engine already has the id/name.
        for (index, entry) in toolCallBuffers {
            let shouldEmit = force || due || entry.arguments.count >= minChars
            if shouldEmit && !entry.arguments.isEmpty {
                await onChunk(.toolCallDelta(
                    index: index,
                    id: entry.id,
                    name: entry.name,
                    argumentsDelta: entry.arguments
                ))
                toolCallBuffers.removeValue(forKey: index)
            }
        }
        if due { lastFlush = now }
    }
}

/// Provides streaming chat completion for both OpenAI-compatible and Anthropic
/// connections. This is a thin facade over [`LLMTransport`](src/LLM/LLMTransport.swift):
/// it wraps the transport's raw chunk stream in a [`ChunkCoalescer`](src/ChatService.swift)
/// and adds request lifecycle logging. All request building, SSE parsing,
/// cancellation, and error handling live in the transport + provider
/// strategies.
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
        let usage: TokenUsage?
    }

    /// Streams a chat completion, calling `onChunk` for each piece of
    /// content/thinking/tool-call-delta. Chunks are coalesced before reaching
    /// `onChunk` to keep the UI cadence sane.
    /// - Parameters:
    ///   - connection: The connection to use.
    ///   - messages: The full conversation history (including system prompt if any).
    ///   - chatFilename: The chat's filename, used to resolve image attachments on disk.
    ///   - tools: Optional MCP tool definitions to expose to the model. When
    ///     non-empty, the model may emit tool calls instead of (or alongside)
    ///     text content.
    ///   - onChunk: Called for each coalesced chunk.
    /// - Returns: The stream result (final text, accumulated tool calls, finish reason).
    @discardableResult
    func stream(
        connection: Connection,
        messages: [ChatMessage],
        chatFilename: String,
        tools: [ToolDefinition]? = nil,
        onChunk: @escaping @Sendable (StreamChunk) async -> Void
    ) async throws -> StreamResult {
        let toolCount = tools?.count ?? 0
        debugLog("LLM", "request start — provider=\(connection.provider.rawValue), model=\(connection.model), messages=\(messages.count), tools=\(toolCount), chat=\(chatFilename)")
        let started = Date()

        let box = CoalescerBox(onChunk: onChunk)
        let result: StreamResult
        do {
            result = try await LLMTransport.stream(
                connection: connection,
                messages: messages,
                chatFilename: chatFilename,
                tools: tools,
                onChunk: { chunk in await box.add(chunk) }
            )
            // Drain any remaining buffered text/tool-call deltas.
            await box.flush(force: true)
        } catch is CancellationError {
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            debugLog("LLM", "request cancelled — elapsed=\(elapsed)s, chat=\(chatFilename)")
            throw CancellationError()
        } catch let error as LLMError {
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            debugLog("LLM", "request failed — status=\(error.statusCode), body=\(error.rawBody ?? "nil"), elapsed=\(elapsed)s, chat=\(chatFilename)")
            throw error
        } catch {
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            debugLog("LLM", "request failed — \(error.localizedDescription), elapsed=\(elapsed)s, chat=\(chatFilename)")
            throw error
        }

        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        debugLog("LLM", "request finish — finishReason=\(result.finishReason ?? "nil"), contentSize=\(result.content.count), toolCalls=\(result.toolCalls.count), elapsed=\(elapsed)s, chat=\(chatFilename)")
        return result
    }

    /// Fetches the list of available models from a provider's `/models`
    /// endpoint. Anthropic reports per-model capabilities (e.g.
    /// `image_input`); OpenAI-compatible endpoints return ids only.
    func listModels(provider: ConnectionProvider, baseUrl: String?, apiKey: String?) async throws -> [ModelInfo] {
        try await LLMTransport.listModels(provider: provider, baseUrl: baseUrl, apiKey: apiKey)
    }

    /// Performs a non-streaming chat completion and returns the assistant's
    /// text. Used by the connection wizard's "say hi" test.
    func complete(connection: Connection, messages: [ChatMessage]) async throws -> String {
        try await LLMTransport.complete(connection: connection, messages: messages)
    }
}

/// A sendable wrapper around the mutable `ChunkCoalescer` so it can be captured
/// in the transport's `@Sendable` onChunk closure.
private final class CoalescerBox: @unchecked Sendable {
    private var coalescer: ChunkCoalescer
    init(onChunk: @escaping @Sendable (StreamChunk) async -> Void) {
        self.coalescer = ChunkCoalescer(onChunk: onChunk)
    }
    func add(_ chunk: StreamChunk) async {
        await coalescer.add(chunk)
    }
    func flush(force: Bool) async {
        await coalescer.flush(force: force)
    }
}
