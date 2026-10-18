// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct AnthropicAdapter: ProviderAdapter {
    let provider = Provider.anthropic
    var baseUrl: String = Provider.anthropic.defaultBaseUrl

    private static let effortLevels = ["low", "medium", "high", "xhigh", "max"]
    private static let maxPages = 20

    func fetchListing(apiKey: String, fetcher: HTTPFetching, metadata: ModelMetadataSource) async throws
        -> ProviderListing
    {
        let headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        var models: [CatalogModel] = []
        var afterId: String?
        for _ in 0..<Self.maxPages {
            var query = [URLQueryItem(name: "limit", value: "1000")]
            if let afterId { query.append(URLQueryItem(name: "after_id", value: afterId)) }
            let url = try ProviderHTTP.endpoint(baseUrl, "/models", query: query)
            let json = try await ProviderHTTP.getJSON(url, headers: headers, fetcher: fetcher)
            guard let data = json["data"] as? [[String: Any]] else { throw ProviderError.badResponse }
            models += data.compactMap(Self.parse)
            guard JSONField.bool(json["has_more"]) == true, let last = json["last_id"] as? String else { break }
            afterId = last
        }
        return ProviderListing(models: models)
    }

    static func parse(_ model: [String: Any]) -> CatalogModel? {
        guard let name = model["id"] as? String, !name.isEmpty else { return nil }
        if (model["lifecycle"] as? String) == "retired" { return nil }
        let capabilities = model["capabilities"] as? [String: Any] ?? [:]
        let effort = capabilities["effort"] as? [String: Any] ?? [:]
        let thinking = capabilities["thinking"] as? [String: Any] ?? [:]
        let levels = effortLevels.filter { level in
            (effort[level] as? [String: Any]).flatMap { JSONField.bool($0["supported"]) } == true
        }
        let reasoningSupported =
            JSONField.bool(effort["supported"]) == true || JSONField.bool(thinking["supported"]) == true
        let imageInput =
            (capabilities["image_input"] as? [String: Any]).flatMap { JSONField.bool($0["supported"]) } == true
        return CatalogModel(
            id: ModelID(provider: .anthropic, name: name),
            displayName: model["display_name"] as? String,
            capabilities: ModelCapabilities(
                imageInput: imageInput,
                contextWindow: JSONField.int(model["max_input_tokens"]) ?? ModelCapabilities.safeDefaults.contextWindow,
                maxOutputTokens: JSONField.int(model["max_tokens"]),
                reasoning: ReasoningCapability(supported: reasoningSupported, levels: levels, defaultLevel: nil)))
    }
}
