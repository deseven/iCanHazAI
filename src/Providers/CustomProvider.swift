// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The color of a custom provider's tag. These map to macOS system colors (see
/// `ProviderTag.swift`), which adapt to the light and dark appearance.
enum ProviderColor: String, CaseIterable, Sendable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, cyan, brown, gray

    static let `default` = ProviderColor.teal

    var displayName: String { rawValue.capitalized }
}

/// A user-defined OpenAI-compatible provider: one `[[custom_providers]]` entry
/// of `config.toml`. The API keys themselves live in the encrypted secret
/// store, like every provider's.
struct CustomProviderConfig: Codable, Equatable, Hashable, Sendable {
    /// Unique among all providers; it is also the provider part of model ids (`Name:model-id`).
    var name: String
    /// The API's base URL as the user wrote it (no `/v1` is added), `/models` and
    /// `/chat/completions` are appended to it.
    var endpoint: String
    /// A `ProviderColor` raw value. Nil or unknown falls back to the default.
    var color: String?
    /// The id of the active API key. Managed by the app.
    var key: String?

    static let maxNameLength = 30

    enum CodingKeys: String, CodingKey {
        case name, endpoint, color, key
    }

    init(name: String, endpoint: String, color: String? = nil, key: String? = nil) {
        self.name = name
        self.endpoint = endpoint
        self.color = color
        self.key = key
    }

    /// Every field is tolerated missing, so a hand-edited entry can't fail the
    /// decode of the whole config; `ProviderRegistry` drops unusable entries.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        key = try c.decodeIfPresent(String.self, forKey: .key)
    }

    var provider: Provider { .custom(name) }

    var providerColor: ProviderColor { color.flatMap(ProviderColor.init(rawValue:)) ?? .default }

    // MARK: - Validation

    enum NameProblem: Equatable {
        case empty
        case tooLong
        /// The model id is `Name:model-id`, split at the first colon.
        case containsColon
        case containsControlCharacters
        /// One of the built-in providers (in any case).
        case reserved
        case taken

        var message: String {
            switch self {
            case .empty: return "Enter a name."
            case .tooLong: return "Use at most \(CustomProviderConfig.maxNameLength) characters."
            case .containsColon: return "The name can't contain a colon."
            case .containsControlCharacters: return "The name can't contain line breaks or control characters."
            case .reserved: return "This is a built-in provider. Pick another name."
            case .taken: return "A custom provider with this name already exists."
            }
        }
    }

    /// Why `name` can't be used for a new custom provider, or nil when it can.
    /// `existing` are the names of the custom providers that already exist;
    /// uniqueness ignores case.
    static func problem(withName name: String, existing: [String]) -> NameProblem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count > maxNameLength { return .tooLong }
        if trimmed.contains(":") { return .containsColon }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .containsControlCharacters
        }
        if Provider.allCases.contains(where: { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame })
            || Provider.allCases.contains(where: { $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame })
        {
            return .reserved
        }
        if existing.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { return .taken }
        return nil
    }

    /// The endpoint without surrounding whitespace and trailing slashes, or nil
    /// when it isn't an http(s) URL with a host.
    static func normalizedEndpoint(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        return text
    }
}
