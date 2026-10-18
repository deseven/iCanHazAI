// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A model reference written as `provider:name`.
struct ModelID: Hashable, Codable, Sendable, CustomStringConvertible {
    let provider: Provider
    let name: String

    init(provider: Provider, name: String) {
        self.provider = provider
        self.name = name
    }

    /// Splits on the first colon only, because model names may contain colons
    /// themselves (OpenRouter's `:free`, `:batch`). The provider part is
    /// case-sensitive and must be the lowercase raw value. Returns nil for an
    /// unknown provider or an empty name.
    init?(parsing string: String) {
        guard let colon = string.firstIndex(of: ":"),
            let provider = Provider(rawValue: String(string[..<colon]))
        else { return nil }
        let name = String(string[string.index(after: colon)...])
        guard !name.isEmpty else { return nil }
        self.init(provider: provider, name: name)
    }

    var description: String { "\(provider.rawValue):\(name)" }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = ModelID(parsing: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid model id \"\(raw)\""))
        }
        self = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
