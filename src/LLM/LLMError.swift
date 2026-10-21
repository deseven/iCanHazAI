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
    /// The wire format of the response that produced this error.
    let wire: LLMWire
    /// The provider that answered (e.g. "DeepSeek"); several providers share a
    /// wire. Falls back to the wire's name when unknown.
    var providerName: String?

    var errorDescription: String? {
        if let message = providerMessage, !message.isEmpty {
            return "\(providerLabel) API error (\(statusCode)): \(message)"
        }
        if let body = rawBody, !body.isEmpty {
            return "\(providerLabel) API error (\(statusCode)): \(body)"
        }
        return "\(providerLabel) API error (\(statusCode))"
    }

    private var providerLabel: String {
        if let providerName { return providerName }
        switch wire {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .ollama: return "Ollama"
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
            let error = json["error"] as? [String: Any]
        {
            message = error["message"] as? String
            type = error["type"] as? String
            // llama.cpp says how far over the limit a prompt is, next to the error.
            if type == "exceed_context_size_error", let prompt = JSONField.int(json["n_prompt_tokens"]),
                let context = JSONField.int(json["n_ctx"])
            {
                message =
                    "\(message ?? "The prompt doesn't fit the context") (the prompt has \(prompt) tokens, the context holds \(context))"
            }
        }
        return LLMError(
            statusCode: statusCode,
            providerMessage: message,
            errorType: type,
            rawBody: rawBody,
            wire: .openai
        )
    }

    /// Parses an Ollama error response body.
    ///
    /// Shape: `{"error":"..."}`
    static func parseOllama(_ data: Data, statusCode: Int) -> LLMError {
        let rawBody = String(data: data, encoding: .utf8)
        var message: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"]
        {
            if let text = error as? String {
                message = text
            } else if let nested = error as? [String: Any] {
                message = nested["message"] as? String
            }
        }
        return LLMError(
            statusCode: statusCode,
            providerMessage: message,
            errorType: nil,
            rawBody: rawBody,
            wire: .ollama
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
            let error = json["error"] as? [String: Any]
        {
            message = error["message"] as? String
            type = error["type"] as? String
        }
        return LLMError(
            statusCode: statusCode,
            providerMessage: message,
            errorType: type,
            rawBody: rawBody,
            wire: .anthropic
        )
    }
}
