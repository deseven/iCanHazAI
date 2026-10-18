// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct ReasoningCapability: Codable, Hashable, Sendable {
    var supported: Bool
    /// Ordered low to high, e.g. `["low", "medium", "high", "xhigh"]`. May
    /// contain `"none"` (the provider's own spelling of "off").
    var levels: [String]
    var defaultLevel: String?
    /// Reasoning can be switched off. Also implied by `"none"` in `levels`.
    var canDisable: Bool = false
    /// Anthropic models that only accept `thinking.type = enabled` with a
    /// token budget instead of adaptive thinking.
    var budgetOnly: Bool = false

    static let unsupported = ReasoningCapability(supported: false, levels: [], defaultLevel: nil)
}

/// A reasoning setting as stored in a chat. `off` and `on` are the two
/// non-effort values; everything else is a provider effort level.
enum ReasoningSetting {
    static let off = "off"
    static let on = "on"

    /// How a setting reads in the toolbar and its menu.
    static func title(_ setting: String) -> String {
        switch setting {
        case "xhigh": return "Extra high"
        default: return setting.prefix(1).uppercased() + setting.dropFirst()
        }
    }
}

extension ReasoningCapability {
    /// Effort levels without the provider's "none".
    var effortLevels: [String] { levels.filter { $0 != "none" } }

    var canTurnOff: Bool { supported && (canDisable || levels.contains("none")) }

    /// What the toolbar menu offers, in display order: `off` (when allowed),
    /// then the effort levels low to high. A model with no levels is a plain
    /// on/off switch. Empty when there is nothing to choose.
    var options: [String] {
        guard supported else { return [] }
        var result: [String] = []
        if canTurnOff { result.append(ReasoningSetting.off) }
        let efforts = effortLevels
        if efforts.isEmpty {
            if canTurnOff { result.append(ReasoningSetting.on) }
        } else {
            result += efforts
        }
        return result.count > 1 ? result : []
    }

    /// Whether the model has a reasoning control worth showing.
    var isConfigurable: Bool { !options.isEmpty }

    /// Reasoning is preferred over off. Uses the provider's own default level
    /// when it is one of the offered effort levels; otherwise picks the middle
    /// of the effort levels, rounding up (low/medium/high gives medium, five
    /// levels give the third).
    var defaultOption: String? {
        guard isConfigurable else { return nil }
        let efforts = effortLevels
        if efforts.isEmpty { return ReasoningSetting.on }
        if let defaultLevel, efforts.contains(defaultLevel) { return defaultLevel }
        return efforts[efforts.count / 2]
    }

    /// The setting for fast, throwaway requests: off when possible, otherwise
    /// the lowest effort level. Nil leaves the provider default alone.
    var fastOption: String? {
        guard supported else { return nil }
        if canTurnOff { return ReasoningSetting.off }
        return effortLevels.first
    }

    /// A stored setting resolved against this model: the setting itself when
    /// the model offers it, otherwise the default. Nil when the model has no
    /// reasoning control.
    func effectiveOption(for stored: String?) -> String? {
        guard isConfigurable else { return nil }
        if let stored, options.contains(stored) { return stored }
        return defaultOption
    }
}

struct ModelCapabilities: Codable, Hashable, Sendable {
    var imageInput: Bool
    /// Input and output tokens together: the number a usage meter divides by.
    var contextWindow: Int
    var maxOutputTokens: Int?
    var reasoning: ReasoningCapability

    /// Used for anything a provider doesn't tell us.
    static let safeDefaults = ModelCapabilities(
        imageInput: false,
        contextWindow: 1_000_000,
        maxOutputTokens: nil,
        reasoning: .unsupported
    )
}

struct CatalogModel: Identifiable, Hashable, Sendable {
    let id: ModelID
    var displayName: String?
    var capabilities: ModelCapabilities
}
