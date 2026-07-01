// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A structured error returned by an LLM provider, with the response body
/// parsed into a human-readable message.
///
/// On non-2xx responses the transport drains the response body and hands it
/// to the provider strategy's error parser, which knows the provider's error
/// JSON shape. This gives the user the actual provider error message instead
/// of a bare status code.
struct LLMError: Error, LocalizedError, Sendable {
    /// HTTP status code from the failed response.
    let statusCode: Int
    /// The human-readable message parsed from the provider's error JSON, if any.
    let providerMessage: String?
    /// The provider's error type string (e.g. "invalid_request_error"), if any.
    let errorType: String?
    /// The raw response body, retained for debugging.
    let rawBody: String?
    /// The provider that produced this error.
    let provider: ConnectionProvider

    var errorDescription: String? {
        // Prefer the parsed provider message; fall back to the raw body; then
        // to a generic status-code description.
        if let message = providerMessage, !message.isEmpty {
            return "\(providerLabel) API error (\(statusCode)): \(message)"
        }
        if let body = rawBody, !body.isEmpty {
            return "\(providerLabel) API error (\(statusCode)): \(body)"
        }
        return "\(providerLabel) API error (\(statusCode))"
    }

    /// A friendly label for the provider, used in error messages.
    private var providerLabel: String {
        switch provider {
        case .openai:    return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    // MARK: - Parsing

    /// Parses an OpenAI-compatible error response body.
    ///
    /// Shape: `{"error":{"message":...,"type":...,"code":...}}`
    static func parseOpenAI(_ data: Data, statusCode: Int) -> LLMError {
        let rawBody = String(data: data, encoding: .utf8)
        var message: String?
        var type: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            message = error["message"] as? String
            type = error["type"] as? String
        }
        return LLMError(
            statusCode: statusCode,
            providerMessage: message,
            errorType: type,
            rawBody: rawBody,
            provider: .openai
        )
    }

    /// Parses an Anthropic error response body.
    ///
    /// Shape: `{"type":"error","error":{"type":...,"message":...}}`
    static func parseAnthropic(_ data: Data, statusCode: Int) -> LLMError {
        let rawBody = String(data: data, encoding: .utf8)
        var message: String?
        var type: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            message = error["message"] as? String
            type = error["type"] as? String
        }
        return LLMError(
            statusCode: statusCode,
            providerMessage: message,
            errorType: type,
            rawBody: rawBody,
            provider: .anthropic
        )
    }
}
