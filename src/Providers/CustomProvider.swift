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

/// The API a custom provider speaks (`type` of a `[[custom_providers]]` entry).
enum CustomProviderType: String, CaseIterable, Sendable {
    /// Any server that implements the OpenAI Chat Completions API.
    case openai
    /// Ollama's own API (`/api/chat`, `/api/tags`, `/api/show`), not its OpenAI layer.
    case ollama
    /// llama.cpp's `llama-server`: the OpenAI chat route it implements natively, plus its `/props`.
    case llamacpp

    var displayName: String {
        switch self {
        case .openai: return "OpenAI-compatible"
        case .ollama: return "Ollama"
        case .llamacpp: return "llama.cpp"
        }
    }

    /// One line for the radio button in the wizard.
    var summary: String {
        switch self {
        case .openai:
            return "Any server that implements the OpenAI API, such as LM Studio, vLLM, LiteLLM or a gateway"
        case .ollama:
            return
                "Ollama's own API: reads each model's real capabilities, reasoning levels and context, with local and cloud models"
        case .llamacpp:
            return "llama-server from llama.cpp: reads the loaded model's context size, vision and reasoning support"
        }
    }

    /// The API root is the server's address (`http://host:port`) rather than a
    /// base URL that includes a version path: the app adds `/api` or `/v1` itself.
    var usesServerRoot: Bool { self != .openai }

    /// Added to the endpoint to get the base URL the chat path is appended to.
    var chatBasePath: String {
        switch self {
        case .openai: return ""
        case .ollama: return "/api"
        case .llamacpp: return "/v1"
        }
    }

    var endpointPlaceholder: String {
        switch self {
        case .openai: return "e.g. http://localhost:1234/v1"
        case .ollama: return "e.g. http://localhost:11434"
        case .llamacpp: return "e.g. http://127.0.0.1:9931"
        }
    }

    var endpointHint: String {
        switch self {
        case .openai:
            return
                "The API's base URL. /models and /chat/completions are added to it as is, so include /v1 if the provider needs it."
        case .ollama:
            return
                "The address of the Ollama server, without /api or /v1: the app adds the paths itself. Use https://ollama.com for Ollama's cloud (it needs an API key)."
        case .llamacpp:
            return
                "The address of llama-server, without /v1: the app adds the paths itself (/v1/chat/completions, /v1/models and /props)."
        }
    }

    /// The path suffixes a user may paste along with the address of a server-root API.
    fileprivate var strippedSuffixes: [String] {
        switch self {
        case .openai: return []
        case .ollama: return ["/api", "/v1"]
        case .llamacpp: return ["/v1"]
        }
    }
}

/// A user-defined provider: one `[[custom_providers]]` entry of `config.toml`.
/// The API keys themselves live in the encrypted secret store, like every
/// provider's.
struct CustomProviderConfig: Codable, Equatable, Hashable, Sendable {
    /// Unique among all providers; it is also the provider part of model ids (`Name:model-id`).
    var name: String
    /// What the endpoint speaks. Missing or unknown in the file reads as `openai`.
    var type: CustomProviderType
    /// For `openai` the API's base URL as the user wrote it (no `/v1` is added),
    /// `/models` and `/chat/completions` are appended to it. For `ollama` and
    /// `llamacpp` the server's address; the paths are added by the app.
    var endpoint: String
    /// A `ProviderColor` raw value. Nil or unknown falls back to the default.
    var color: String?
    /// The id of the active API key. Managed by the app.
    var key: String?

    static let maxNameLength = 30

    enum CodingKeys: String, CodingKey {
        case name, type, endpoint, color, key
    }

    init(
        name: String, type: CustomProviderType = .openai, endpoint: String, color: String? = nil, key: String? = nil
    ) {
        self.name = name
        self.type = type
        self.endpoint = endpoint
        self.color = color
        self.key = key
    }

    /// Every field is tolerated missing, so a hand-edited entry can't fail the
    /// decode of the whole config; `ProviderRegistry` drops unusable entries.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let rawType = try c.decodeIfPresent(String.self, forKey: .type)
        type = rawType.flatMap(CustomProviderType.init(rawValue:)) ?? .openai
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        key = try c.decodeIfPresent(String.self, forKey: .key)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(type.rawValue, forKey: .type)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(key, forKey: .key)
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
    /// when it isn't an http(s) URL with a host. For a server-root type a
    /// trailing `/v1` (or, for Ollama, `/api`) is dropped too, since the app adds
    /// those paths itself and people paste the OpenAI-style URL out of habit.
    static func normalizedEndpoint(_ raw: String, type: CustomProviderType = .openai) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        var stripped = true
        while stripped {
            stripped = false
            for suffix in type.strippedSuffixes where text.lowercased().hasSuffix(suffix) {
                // Only a whole path segment: `http://host/api` loses `/api`, `http://hostapi` has none.
                let rest = String(text.dropLast(suffix.count))
                guard URLComponents(string: rest)?.host?.isEmpty == false else { continue }
                text = rest
                while text.hasSuffix("/") { text.removeLast() }
                stripped = true
            }
        }
        return text
    }
}
