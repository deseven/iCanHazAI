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
    /// The provider this strategy implements.
    var provider: ConnectionProvider { get }
    /// The default base URL used when a connection doesn't specify one.
    var defaultBaseUrl: String { get }
    /// The path appended to the base URL for chat completions
    /// (e.g. `/v1/chat/completions` or `/v1/messages`).
    var chatPath: String { get }
    /// The path appended to the base URL for the models listing endpoint,
    /// or nil if the provider doesn't expose one.
    var modelsPath: String? { get }

    /// Builds the HTTP headers for a request to this provider.
    /// Includes `Content-Type` and the provider-specific auth headers.
    func buildHeaders(connection: Connection) -> [String: String]

    /// Builds the JSON request body for a chat completion (streaming or not).
    /// Returns a dictionary suitable for `JSONSerialization`.
    func buildRequestBody(
        connection: Connection,
        messages: [ChatMessage],
        chatFilename: String,
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> [String: Any]

    /// Parses a single SSE `data:` payload (already decoded from the wire)
    /// into zero or more [`StreamChunk`](src/ChatService.swift) values, and
    /// feeds tool-call deltas into the shared `accumulator`.
    ///
    /// The transport calls this once per SSE event. Content/thinking/finish
    /// chunks are returned directly; tool-call deltas are both recorded in
    /// the accumulator (for the final `.toolCall` emit at stream end) and
    /// returned as `.toolCallDelta` chunks (for live UI updates).
    func parseStreamChunk(_ data: Data, accumulator: ToolCallAccumulator) -> [StreamChunk]

    /// Parses a non-streaming completion response body into the assistant's
    /// text content.
    func parseCompleteResponse(_ data: Data) -> String

    /// Parses an error response body into a structured [`LLMError`](src/LLM/LLMError.swift).
    func parseError(_ data: Data, statusCode: Int) -> LLMError

    /// Parses a `/models` listing response body into [`ModelInfo`](src/LLM/LLMProvider.swift)
    /// entries. Each entry carries the model id and, where the provider reports
    /// it, whether the model accepts image input. Both OpenAI-compatible and
    /// Anthropic endpoints expose `/v1/models`; Anthropic additionally reports
    /// per-model capabilities (e.g. `image_input`), which the connection wizard
    /// uses to auto-set the `imageInput` flag.
    func parseModelsResponse(_ data: Data) -> [ModelInfo]
}

/// A model entry returned by a provider's `/models` endpoint.
struct ModelInfo: Sendable, Equatable {
    /// The model identifier (e.g. "gpt-5", "claude-opus-4-6").
    let id: String
    /// Whether the provider reports this model as accepting image input.
    /// Nil when the provider doesn't report image-input capability (e.g.
    /// OpenAI-compatible endpoints that only return ids).
    let imageInput: Bool?
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
    private let lock = NSLock()

    /// Records a delta for the given index. `id`/`name` are applied when
    /// non-empty (first delta carries them); `argumentsDelta` is appended.
    func addDelta(index: Int, id: String?, name: String?, argumentsDelta: String?) {
        lock.lock(); defer { lock.unlock() }
        var entry = entries[index] ?? Entry()
        if let id, !id.isEmpty { entry.id = id }
        if let name, !name.isEmpty { entry.name = name }
        if let args = argumentsDelta, !args.isEmpty { entry.arguments += args }
        entries[index] = entry
    }

    /// Materialize the accumulated tool calls into [`ToolCall`](src/MCPModels.swift)
    /// objects, ordered by index. Missing ids are synthesised as `call_{index}`.
    func materialize() -> [ToolCall] {
        lock.lock(); defer { lock.unlock() }
        return entries.keys.sorted().map { index in
            let e = entries[index]!
            let id = e.id.isEmpty ? "call_\(index)" : e.id
            return ToolCall(id: id, name: e.name, arguments: e.arguments)
        }
    }
}
