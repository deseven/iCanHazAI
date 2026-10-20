// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Who serves a model. The four built-in providers are fixed; `.custom` is a
/// user-defined OpenAI-compatible endpoint whose unique name is its identity
/// (the `Name` of `Name:model-id`). A custom provider's endpoint and color
/// aren't part of the value — they live in `CustomProviderConfig`.
enum Provider: Hashable, Comparable, Sendable, CaseIterable, RawRepresentable, Codable {
    case openai, anthropic, deepseek, openrouter
    case custom(String)

    /// The built-in providers, in display order. Custom ones are dynamic and not listed.
    static let allCases: [Provider] = [.openai, .anthropic, .deepseek, .openrouter]

    /// The built-in provider's lowercase id, or the custom provider's name. Any
    /// other non-empty string is taken as a custom provider's name, so
    /// whether it exists is for the registry to say.
    var rawValue: String {
        switch self {
        case .openai: return "openai"
        case .anthropic: return "anthropic"
        case .deepseek: return "deepseek"
        case .openrouter: return "openrouter"
        case .custom(let name): return name
        }
    }

    init?(rawValue: String) {
        if let builtIn = Provider.allCases.first(where: { $0.rawValue == rawValue }) {
            self = builtIn
        } else if rawValue.isEmpty {
            return nil
        } else {
            self = .custom(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let provider = Provider(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Empty provider name"))
        }
        self = provider
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// Built-ins first, in `allCases` order, then custom providers by name.
    static func < (lhs: Provider, rhs: Provider) -> Bool {
        switch (Provider.allCases.firstIndex(of: lhs), Provider.allCases.firstIndex(of: rhs)) {
        case (let left?, let right?): return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return lhs.rawValue.localizedCaseInsensitiveCompare(rhs.rawValue) == .orderedAscending
        }
    }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .deepseek: return "DeepSeek"
        case .openrouter: return "OpenRouter"
        case .custom(let name): return name
        }
    }

    /// The short name accepted by the model picker search (`or.llama`). A
    /// custom provider's is its lowercased name.
    var alias: String {
        switch self {
        case .openai: return "oa"
        case .anthropic: return "an"
        case .deepseek: return "ds"
        case .openrouter: return "or"
        case .custom(let name): return name.lowercased()
        }
    }

    /// A provider written the way the picker accepts it: the full name or the
    /// alias, in any case. Only `providers` are considered; custom ones have
    /// to be passed in.
    init?(searchPrefix: String, among providers: [Provider] = Provider.allCases) {
        let lowered = searchPrefix.lowercased()
        guard let match = providers.first(where: { $0.rawValue.lowercased() == lowered || $0.alias == lowered })
        else { return nil }
        self = match
    }

    /// One line shown in the provider wizard.
    var summary: String {
        switch self {
        case .openai: return "GPT and o-series models"
        case .anthropic: return "Claude models"
        case .deepseek: return "DeepSeek models"
        case .openrouter: return "One key for hundreds of models from many vendors"
        case .custom: return "Any OpenAI-compatible API, such as Ollama, LM Studio or vLLM"
        }
    }

    /// Empty for a custom provider, whose endpoint comes from its `CustomProviderConfig`.
    var defaultBaseUrl: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .deepseek: return "https://api.deepseek.com"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        }
    }
}
