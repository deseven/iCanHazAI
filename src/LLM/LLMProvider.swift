// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A provider strategy that knows how to build request bodies and parse
/// responses for a specific LLM provider (OpenAI-compatible or Anthropic).
///
/// The transport layer ([`LLMTransport`](src/LLM/LLMTransport.swift)) is
/// provider-agnostic: it handles HTTP, SSE, cancellation, and error-body
/// reading. The strategy only supplies the parts that differ between
/// providers — request body shape, SSE event shape, and error JSON shape.
///
/// Strategies are stateless value types. Per-stream tool-call accumulation
/// state lives in a [`ToolCallAccumulator`](src/LLM/LLMProvider.swift) owned
/// by the transport and passed into [`parseStreamChunk(_:accumulator:)`](src/LLM/LLMProvider.swift).
protocol LLMProvider: Sendable {
    /// The wire format this strategy implements.
    var wire: LLMWire { get }
    /// The path appended to the base URL for chat completions
    /// (e.g. `/chat/completions` or `/messages`).
    var chatPath: String { get }

    /// Builds the HTTP headers for a request to this provider.
    /// Includes `Content-Type` and the provider-specific auth headers.
    func buildHeaders(model: ResolvedModel) -> [String: String]

    /// Builds the JSON request body for a chat completion (streaming or not).
    /// Returns a dictionary suitable for `JSONSerialization`.
    func buildRequestBody(
        model: ResolvedModel,
        messages: [ChatMessage],
        chatFilename: String,
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> [String: Any]

    /// Parses a single SSE `data:` payload (already decoded from the wire)
    /// into zero or more [`StreamChunk`](src/Chat/ChatService.swift) values, and
    /// feeds tool-call deltas into the shared `accumulator`.
    ///
    /// The transport calls this once per SSE event. Content/thinking/finish
    /// chunks are returned directly; tool-call deltas are both recorded in
    /// the accumulator (for the final `.toolCall` emit at stream end) and
    /// returned as `.toolCallDelta` chunks (for live UI updates).
    func parseStreamChunk(_ data: Data, accumulator: ToolCallAccumulator) -> [StreamChunk]

    /// Parses an error response body into a structured [`LLMError`](src/LLM/LLMError.swift).
    func parseError(_ data: Data, statusCode: Int) -> LLMError
}

// MARK: - Streaming accumulator

/// Mutable accumulator for streamed tool-call deltas, shared across the
/// `parseStreamChunk` calls of a single stream. Both providers use the same
/// shape: keyed by index, capturing id + name (first delta) and accumulating
/// argument fragments. The transport owns one instance per stream and passes
/// it to the strategy's chunk parser.
///
/// Thread-safe via an internal lock so the value-type strategies can call it
/// from any context.
final class ToolCallAccumulator: @unchecked Sendable {
    private struct Entry {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }
    private var entries: [Int: Entry] = [:]
    private var inputTokens: Int = 0
    private var cachedInputTokens: Int = 0
    private var cacheCreationTokens: Int = 0
    private let lock = NSLock()

    /// Records a delta for the given index. `id`/`name` are applied when
    /// non-empty (first delta carries them); `argumentsDelta` is appended.
    func addDelta(index: Int, id: String?, name: String?, argumentsDelta: String?) {
        lock.lock()
        defer { lock.unlock() }
        var entry = entries[index] ?? Entry()
        if let id, !id.isEmpty { entry.id = id }
        if let name, !name.isEmpty { entry.name = name }
        if let args = argumentsDelta, !args.isEmpty { entry.arguments += args }
        entries[index] = entry
    }

    /// Stashes the input token count for later combination with the output
    /// count (Anthropic splits usage across two events).
    func setInputTokens(_ count: Int, cached: Int = 0, creation: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        inputTokens = count
        cachedInputTokens = cached
        cacheCreationTokens = creation
    }

    /// Returns the stashed input token counts.
    func getInputTokens() -> (input: Int, cached: Int, creation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (inputTokens, cachedInputTokens, cacheCreationTokens)
    }

    /// Whether no tool-call deltas were recorded (the stream produced no tool
    /// calls at all).
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    /// Materialize the accumulated tool calls into [`ToolCall`](src/MCP/MCPModels.swift)
    /// objects, ordered by index. Missing ids are synthesised as `call_{index}`.
    func materialize() -> [ToolCall] {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.sorted().map { index in
            let e = entries[index]!
            let id = e.id.isEmpty ? "call_\(index)" : e.id
            return ToolCall(id: id, name: e.name, arguments: e.arguments)
        }
    }
}
