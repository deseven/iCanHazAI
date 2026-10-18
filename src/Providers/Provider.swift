// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum Provider: String, CaseIterable, Codable, Sendable {
    case openai, anthropic, deepseek, openrouter

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .deepseek: return "DeepSeek"
        case .openrouter: return "OpenRouter"
        }
    }

    /// The short name accepted by the model picker search (`or.llama`).
    var alias: String {
        switch self {
        case .openai: return "oa"
        case .anthropic: return "an"
        case .deepseek: return "ds"
        case .openrouter: return "or"
        }
    }

    /// A provider written the way the picker accepts it: the full name or the
    /// alias, in any case.
    init?(searchPrefix: String) {
        let lowered = searchPrefix.lowercased()
        guard let match = Provider.allCases.first(where: { $0.rawValue == lowered || $0.alias == lowered }) else {
            return nil
        }
        self = match
    }

    /// One line shown in the provider wizard.
    var summary: String {
        switch self {
        case .openai: return "GPT and o-series models"
        case .anthropic: return "Claude models"
        case .deepseek: return "DeepSeek models"
        case .openrouter: return "One key for hundreds of models from many vendors"
        }
    }

    var defaultBaseUrl: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .deepseek: return "https://api.deepseek.com"
        case .openrouter: return "https://openrouter.ai/api/v1"
        }
    }
}
