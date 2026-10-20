// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

extension ModelCapabilities {
    /// For custom-provider models LiteLLM knows nothing about.
    static let customProviderDefaults = ModelCapabilities(
        imageInput: false, contextWindow: 128_000, maxOutputTokens: nil, reasoning: .unsupported)
}

/// Any OpenAI-compatible endpoint. The standard `/models` route only returns
/// bare ids, so capabilities come from LiteLLM, looked up by the full model
/// name; a model LiteLLM doesn't have gets `ModelCapabilities.customProviderDefaults`.
/// Reaching `/models` is all it takes for the endpoint to count as working, and
/// an empty list is taken at its word (the catalog doesn't treat it as a glitch).
/// A body without a `data` array, on the other hand, is a bad response.
struct CustomProviderAdapter: ProviderAdapter {
    let provider: Provider
    /// Used as written: `/models` and `/chat/completions` are appended to it.
    var baseUrl: String

    /// LiteLLM modes of models that can't take a chat request. The listing
    /// stays open to anything else, since a gateway may serve what LiteLLM
    /// files under another mode.
    private static let nonChatModes: Set<String> = [
        "embedding", "image_generation", "image_edit", "audio_transcription", "audio_speech", "moderation",
        "rerank", "ocr", "video_generation", "vector_store", "search",
    ]

    func fetchListing(apiKey: String, fetcher: HTTPFetching, metadata: ModelMetadataSource) async throws
        -> ProviderListing
    {
        let url = try ProviderHTTP.endpoint(baseUrl, "/models")
        // An endpoint that needs no key is given none, rather than an empty bearer.
        let headers = apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
        let json = try await ProviderHTTP.getJSON(url, headers: headers, fetcher: fetcher)
        guard let data = json["data"] as? [[String: Any]] else { throw ProviderError.badResponse }
        var seen = Set<String>()
        let names = data.compactMap { item -> String? in
            guard let id = item["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
        let entries = try await Self.loadEntries(metadata, names: seen)
        let models = names.compactMap { model($0, entries: entries) }.sorted { $0.id.name < $1.id.name }
        // One line per listing (launch, daily refresh, manual refresh): enough to
        // tell a wrong endpoint from an empty server or an over-eager filter.
        let hidden = names.count - models.count
        let known = entries.map { "\($0.count) known to LiteLLM" } ?? "LiteLLM unavailable"
        debugLog(
            "CustomProviderAdapter",
            "\(provider.displayName): \(url.absoluteString) lists \(names.count) model(s)"
                + (hidden > 0 ? ", \(hidden) hidden as non-chat" : "") + ", \(known)")
        return ProviderListing(models: models, capabilitiesUnknown: entries == nil)
    }

    /// A LiteLLM failure must not fail the listing: the endpoint answered, so
    /// the models are usable. The caller keeps whatever capabilities it already has.
    private static func loadEntries(_ metadata: ModelMetadataSource, names: Set<String>) async throws
        -> [String: LiteLLMEntry]?
    {
        guard !names.isEmpty else { return [:] }
        do {
            return try await metadata.entries(named: names)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            debugLog("CustomProviderAdapter", "⚠️ LiteLLM metadata unavailable: \(error)")
            return nil
        }
    }

    private func model(_ name: String, entries: [String: LiteLLMEntry]?) -> CatalogModel? {
        var capabilities = ModelCapabilities.customProviderDefaults
        if let entry = entries?[name] {
            if let mode = entry.mode, Self.nonChatModes.contains(mode) { return nil }
            capabilities = entry.capabilities(defaultContextWindow: capabilities.contextWindow)
        }
        return CatalogModel(id: ModelID(provider: provider, name: name), displayName: nil, capabilities: capabilities)
    }
}
