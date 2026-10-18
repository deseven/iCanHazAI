// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct ReasoningCapability: Codable, Hashable, Sendable {
    var supported: Bool
    /// Ordered low to high, e.g. `["low", "medium", "high", "xhigh"]`.
    var levels: [String]
    var defaultLevel: String?

    static let unsupported = ReasoningCapability(supported: false, levels: [], defaultLevel: nil)
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
