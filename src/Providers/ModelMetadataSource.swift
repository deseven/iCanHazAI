// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The slice of a LiteLLM entry the OpenAI and custom provider adapters need.
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

    /// `defaultContextWindow` stands in when the entry has no input token limit.
    func capabilities(defaultContextWindow: Int) -> ModelCapabilities {
        ModelCapabilities(
            imageInput: supportsVision,
            contextWindow: maxInputTokens ?? defaultContextWindow,
            maxOutputTokens: maxOutputTokens,
            reasoning: ReasoningCapability(supported: supportsReasoning, levels: reasoningLevels, defaultLevel: nil))
    }
}

protocol ModelMetadataSource: Sendable {
    /// LiteLLM entries for OpenAI models, keyed by the LiteLLM model key.
    func openAIEntries() async throws -> [String: LiteLLMEntry]

    /// The LiteLLM entries whose key is exactly one of `names`, whichever
    /// provider they belong to. Names LiteLLM doesn't know are left out.
    func entries(named names: Set<String>) async throws -> [String: LiteLLMEntry]
}

/// Reads LiteLLM's public model list. The file is ~2.9 MB, so only the entries
/// asked for are kept and the rest is dropped immediately.
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

    func entries(named names: Set<String>) async throws -> [String: LiteLLMEntry] {
        let data = try await ProviderHTTP.get(url, headers: [:], fetcher: fetcher)
        return try Self.parseEntries(from: data, named: names)
    }

    /// Only the OpenAI and ChatGPT entries.
    static func parseOpenAIEntries(from data: Data) throws -> [String: LiteLLMEntry] {
        let root = try parseRoot(data)
        var entries: [String: LiteLLMEntry] = [:]
        for (key, value) in root {
            guard let raw = value as? [String: Any],
                let owner = raw["litellm_provider"] as? String,
                owner == "openai" || owner == "chatgpt"
            else { continue }
            entries[key] = entry(from: raw, owner: owner)
        }
        return entries
    }

    static func parseEntries(from data: Data, named names: Set<String>) throws -> [String: LiteLLMEntry] {
        let root = try parseRoot(data)
        var entries: [String: LiteLLMEntry] = [:]
        for name in names {
            // `sample_spec` documents the format and isn't a model.
            guard name != "sample_spec", let raw = root[name] as? [String: Any],
                let owner = raw["litellm_provider"] as? String
            else { continue }
            entries[name] = entry(from: raw, owner: owner)
        }
        return entries
    }

    private static func parseRoot(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse
        }
        return root
    }

    private static func entry(from raw: [String: Any], owner: String) -> LiteLLMEntry {
        let supportsReasoning = JSONField.bool(raw["supports_reasoning"]) == true
        return LiteLLMEntry(
            litellmProvider: owner,
            mode: raw["mode"] as? String,
            supportedEndpoints: (raw["supported_endpoints"] as? [Any]).map(JSONField.strings),
            supportsVision: JSONField.bool(raw["supports_vision"]) == true,
            maxInputTokens: JSONField.int(raw["max_input_tokens"]),
            maxOutputTokens: JSONField.int(raw["max_output_tokens"]),
            supportsReasoning: supportsReasoning,
            reasoningLevels: supportsReasoning ? reasoningLevels(raw) : [])
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
