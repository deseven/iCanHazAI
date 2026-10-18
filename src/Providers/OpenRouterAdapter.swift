// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// OpenRouter's public `/models` has hundreds of entries, so listings are the
/// top 50 by popularity and everything else is found through server-side search.
struct OpenRouterAdapter: ProviderAdapter {
    let provider = Provider.openrouter
    var baseUrl: String = Provider.openrouter.defaultBaseUrl

    static let listingLimit = 50

    func fetchListing(apiKey: String, fetcher: HTTPFetching, metadata: ModelMetadataSource) async throws
        -> ProviderListing
    {
        try await fetchModels(query: nil, fetcher: fetcher)
    }

    func validate(apiKey: String, fetcher: HTTPFetching, metadata: ModelMetadataSource) async throws
        -> ValidationResult
    {
        // `/models` is public, so only `/key` can tell whether the key works.
        async let keyCheck: Void = checkKey(apiKey, fetcher: fetcher)
        async let count = fetchModels(query: nil, limit: 1, fetcher: fetcher)
        async let seed = fetchModels(query: nil, fetcher: fetcher)
        try await keyCheck
        let total = try await count.totalCount
        let listing = try await seed
        return ValidationResult(modelCount: total ?? listing.models.count, seed: listing.models)
    }

    /// Text-output models matching `query` (`q`, not `search`: that one is silently ignored).
    func search(_ query: String, fetcher: HTTPFetching) async throws -> [CatalogModel] {
        try await fetchModels(query: query, fetcher: fetcher).models
    }

    /// Nil when the lookup succeeded but OpenRouter no longer has the model.
    func lookup(_ name: String, fetcher: HTTPFetching) async throws -> CatalogModel? {
        // The query also matches variants such as `:batch`, hence the exact match.
        try await fetchModels(query: name, fetcher: fetcher).models.first { $0.id.name == name }
    }

    private func checkKey(_ apiKey: String, fetcher: HTTPFetching) async throws {
        let url = try ProviderHTTP.endpoint(baseUrl, "/key")
        _ = try await ProviderHTTP.get(url, headers: ["Authorization": "Bearer \(apiKey)"], fetcher: fetcher)
    }

    private func fetchModels(query: String?, limit: Int = Self.listingLimit, fetcher: HTTPFetching) async throws
        -> ProviderListing
    {
        var items = [
            URLQueryItem(name: "output_modalities", value: "text"),
            URLQueryItem(name: "sort", value: "most-popular"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        let url = try ProviderHTTP.endpoint(baseUrl, "/models", query: items)
        let json = try await ProviderHTTP.getJSON(url, headers: [:], fetcher: fetcher)
        guard let data = json["data"] as? [[String: Any]] else { throw ProviderError.badResponse }
        return ProviderListing(models: data.compactMap(Self.parse), totalCount: JSONField.int(json["total_count"]))
    }

    static func parse(_ model: [String: Any]) -> CatalogModel? {
        guard let name = model["id"] as? String, !name.isEmpty else { return nil }
        let architecture = model["architecture"] as? [String: Any]
        let topProvider = model["top_provider"] as? [String: Any]
        return CatalogModel(
            id: ModelID(provider: .openrouter, name: name),
            displayName: model["name"] as? String,
            capabilities: ModelCapabilities(
                imageInput: JSONField.strings(architecture?["input_modalities"]).contains("image"),
                contextWindow: JSONField.int(model["context_length"]) ?? ModelCapabilities.safeDefaults.contextWindow,
                maxOutputTokens: JSONField.int(topProvider?["max_completion_tokens"]),
                reasoning: reasoning(model)))
    }

    private static func reasoning(_ model: [String: Any]) -> ReasoningCapability {
        if let reasoning = model["reasoning"] as? [String: Any] {
            if JSONField.bool(reasoning["supported"]) == false { return .unsupported }
            return ReasoningCapability(
                supported: true,
                levels: ReasoningLevels.sorted(JSONField.strings(reasoning["supported_efforts"])),
                defaultLevel: reasoning["default_effort"] as? String)
        }
        if JSONField.strings(model["supported_parameters"]).contains("reasoning") {
            return ReasoningCapability(supported: true, levels: [], defaultLevel: nil)
        }
        return .unsupported
    }
}
