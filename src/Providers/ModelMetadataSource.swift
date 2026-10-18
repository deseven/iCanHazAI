// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The slice of a LiteLLM entry the OpenAI adapter needs.
struct LiteLLMEntry: Sendable, Equatable {
    var litellmProvider: String
    var mode: String?
    /// Nil when the entry has no `supported_endpoints` key at all.
    var supportedEndpoints: [String]?
    var supportsVision: Bool
    var maxInputTokens: Int?
    var maxOutputTokens: Int?
    var supportsReasoning: Bool
    /// Empty unless the entry supports reasoning.
    var reasoningLevels: [String]

    /// Whether the model can be used through `/chat/completions`.
    var supportsChatCompletions: Bool {
        guard mode == "chat" || mode == "responses" else { return false }
        if let supportedEndpoints { return supportedEndpoints.contains("/v1/chat/completions") }
        return mode == "chat"
    }
}

protocol ModelMetadataSource: Sendable {
    /// LiteLLM entries for OpenAI models, keyed by the LiteLLM model key.
    func openAIEntries() async throws -> [String: LiteLLMEntry]
}

/// Reads LiteLLM's public model list. The file is ~2.9 MB, so only the OpenAI
/// and ChatGPT entries are kept and the rest is dropped immediately.
struct LiteLLMMetadataSource: ModelMetadataSource {
    static let defaultUrl = URL(
        string:
            "https://raw.githubusercontent.com/BerriAI/litellm/refs/heads/main/model_prices_and_context_window.json")!

    let fetcher: HTTPFetching
    var url: URL = Self.defaultUrl

    func openAIEntries() async throws -> [String: LiteLLMEntry] {
        let data = try await ProviderHTTP.get(url, headers: [:], fetcher: fetcher)
        return try Self.parseOpenAIEntries(from: data)
    }

    static func parseOpenAIEntries(from data: Data) throws -> [String: LiteLLMEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse
        }
        var entries: [String: LiteLLMEntry] = [:]
        for (key, value) in root {
            guard let raw = value as? [String: Any],
                let owner = raw["litellm_provider"] as? String,
                owner == "openai" || owner == "chatgpt"
            else { continue }
            let supportsReasoning = JSONField.bool(raw["supports_reasoning"]) == true
            entries[key] = LiteLLMEntry(
                litellmProvider: owner,
                mode: raw["mode"] as? String,
                supportedEndpoints: (raw["supported_endpoints"] as? [Any]).map(JSONField.strings),
                supportsVision: JSONField.bool(raw["supports_vision"]) == true,
                maxInputTokens: JSONField.int(raw["max_input_tokens"]),
                maxOutputTokens: JSONField.int(raw["max_output_tokens"]),
                supportsReasoning: supportsReasoning,
                reasoningLevels: supportsReasoning ? reasoningLevels(raw) : [])
        }
        return entries
    }

    /// `reasoning_effort_levels` wins when present. Otherwise low/medium/high
    /// plus whichever extra levels the entry flags.
    private static func reasoningLevels(_ raw: [String: Any]) -> [String] {
        let listed = JSONField.strings(raw["reasoning_effort_levels"])
        if !listed.isEmpty { return ReasoningLevels.sorted(listed) }
        var levels = ["low", "medium", "high"]
        for extra in ["none", "minimal", "xhigh", "max"]
        where JSONField.bool(raw["supports_\(extra)_reasoning_effort"]) == true {
            levels.append(extra)
        }
        return ReasoningLevels.sorted(levels)
    }
}
