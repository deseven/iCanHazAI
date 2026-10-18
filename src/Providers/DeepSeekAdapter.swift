// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// DeepSeek's `/models` carries everything the picker needs, so no metadata
/// source is involved.
struct DeepSeekAdapter: ProviderAdapter {
    let provider = Provider.deepseek
    var baseUrl: String = Provider.deepseek.defaultBaseUrl

    func fetchListing(apiKey: String, fetcher: HTTPFetching, metadata: ModelMetadataSource) async throws
        -> ProviderListing
    {
        let url = try ProviderHTTP.endpoint(baseUrl, "/models")
        let json = try await ProviderHTTP.getJSON(
            url, headers: ["Authorization": "Bearer \(apiKey)"], fetcher: fetcher)
        guard let data = json["data"] as? [[String: Any]] else { throw ProviderError.badResponse }
        return ProviderListing(models: data.compactMap(Self.parse))
    }

    static func parse(_ model: [String: Any]) -> CatalogModel? {
        guard let name = model["id"] as? String, !name.isEmpty else { return nil }
        if let outputs = model["output_modalities"] as? [Any], !JSONField.strings(outputs).contains("text") {
            return nil
        }
        let effort = model["effort"] as? [String: Any]
        let levels = ReasoningLevels.sorted(JSONField.strings(effort?["supported_levels"]))
        return CatalogModel(
            id: ModelID(provider: .deepseek, name: name),
            displayName: model["name"] as? String,
            capabilities: ModelCapabilities(
                imageInput: JSONField.strings(model["input_modalities"]).contains("image"),
                contextWindow: JSONField.int(model["context_window"]) ?? ModelCapabilities.safeDefaults.contextWindow,
                maxOutputTokens: JSONField.int(model["max_output_tokens"]),
                reasoning: ReasoningCapability(
                    supported: !levels.isEmpty, levels: levels, defaultLevel: effort?["default_level"] as? String,
                    // `thinking.type = disabled` is always accepted.
                    canDisable: !levels.isEmpty)))
    }
}
