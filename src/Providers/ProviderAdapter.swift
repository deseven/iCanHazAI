// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What a listing request produced.
struct ProviderListing: Sendable {
    var models: [CatalogModel]
    /// The count to show to the user when it differs from `models.count`
    /// (OpenRouter lists a top slice of a much larger catalog).
    var totalCount: Int?
    /// The capability source was unreachable, so `models` carry safe defaults
    /// that must not overwrite capabilities we already know.
    var capabilitiesUnknown: Bool = false

    var modelCount: Int { totalCount ?? models.count }
}

struct ValidationResult: Sendable {
    let modelCount: Int
    let seed: [CatalogModel]
    /// Mirrors `ProviderListing.capabilitiesUnknown` for the seed.
    var capabilitiesUnknown: Bool = false
}

protocol ProviderAdapter: Sendable {
    var provider: Provider { get }
    /// Validates the key and returns what the wizard needs.
    func validate(apiKey: String, fetcher: HTTPFetching, metadata: ModelMetadataSource) async throws
        -> ValidationResult
    /// The listing used by refreshes.
    func fetchListing(apiKey: String, fetcher: HTTPFetching, metadata: ModelMetadataSource) async throws
        -> ProviderListing
}

extension ProviderAdapter {
    func validate(apiKey: String, fetcher: HTTPFetching, metadata: ModelMetadataSource) async throws
        -> ValidationResult
    {
        let listing = try await fetchListing(apiKey: apiKey, fetcher: fetcher, metadata: metadata)
        return ValidationResult(
            modelCount: listing.modelCount, seed: listing.models, capabilitiesUnknown: listing.capabilitiesUnknown)
    }
}

enum ProviderAdapters {
    static func make(_ provider: Provider, baseUrl: String? = nil) -> ProviderAdapter {
        let base = baseUrl ?? provider.defaultBaseUrl
        switch provider {
        case .openai: return OpenAIAdapter(baseUrl: base)
        case .anthropic: return AnthropicAdapter(baseUrl: base)
        case .deepseek: return DeepSeekAdapter(baseUrl: base)
        case .openrouter: return OpenRouterAdapter(baseUrl: base)
        }
    }
}

/// Small JSON helpers shared by the adapters.
enum JSONField {
    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
