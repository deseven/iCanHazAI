// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A tiny Server-Sent Events line parser.
///
/// Reads lines from a `URLSession.AsyncBytes` stream and yields the `data:`
/// payloads as `Data`. Handles the `[DONE]` sentinel and ignores comments,
/// `event:`, `id:`, and `retry:` lines (we only consume `data:` payloads).
///
/// SSE frames are separated by blank lines. A single event may carry its
/// payload across multiple consecutive `data:` lines, which are joined with
/// `\n` per the spec. In practice both OpenAI and Anthropic emit one
/// `data:` line per event, so the joined form is rarely exercised.
enum SSEParser {

    /// The `[DONE]` sentinel used by OpenAI-compatible providers to signal the
    /// end of a stream. Anthropic does not emit it (the stream simply ends).
    static let doneSentinel = "[DONE]"

    /// Parses a single SSE line into a `Data` payload, or nil if the line is
    /// not a `data:` payload (e.g. a comment, `event:`, or blank line).
    ///
    /// - Parameter line: A raw line from `AsyncBytes.lines` (no trailing
    ///   newline).
    /// - Returns: The decoded payload, or nil. Returns an empty `Data` for the
    ///   `[DONE]` sentinel — callers should check `line == doneSentinel` or use
    ///   `parsePayload(_:)` instead.
    static func parseLine(_ line: String) -> Data? {
        // Comments and empty lines are ignored.
        guard !line.isEmpty, !line.hasPrefix(":") else { return nil }
        // We only consume `data:` fields.
        guard line.hasPrefix("data:") else { return nil }
        // Strip the `data:` prefix and a single optional leading space.
        var payload = String(line.dropFirst("data:".count))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        return payload.data(using: .utf8)
    }

    /// Parses a single SSE `data:` line into a payload string, returning nil
    /// for non-data lines and a sentinel for `[DONE]`.
    enum SSEPayload: Equatable {
        /// A JSON payload (the `data:` content, decoded to a string).
        case data(String)
        /// The `[DONE]` sentinel — the stream is finished.
        case done
    }

    static func parsePayload(_ line: String) -> SSEPayload? {
        guard !line.isEmpty, !line.hasPrefix(":") else { return nil }
        guard line.hasPrefix("data:") else { return nil }
        var payload = String(line.dropFirst("data:".count))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        if payload == doneSentinel { return .done }
        return .data(payload)
    }
}
