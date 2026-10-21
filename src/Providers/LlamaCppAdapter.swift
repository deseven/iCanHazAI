// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A `llama-server` from llama.cpp. Chatting goes through its OpenAI-style
/// `/v1/chat/completions` (that route *is* its chat API), but what the server
/// says about itself is richer than a bare model list, so nothing is looked up
/// in LiteLLM:
///
/// - `GET /v1/models` lists the models. A single-model server has one, with
///   `meta.n_ctx` (the context of one slot) and `architecture` (`image` input);
///   a router lists every model it can load with a `status`, and `meta` only
///   for the loaded ones.
/// - `GET /props` (`?model=` for a router) adds what the chat template supports,
///   which decides whether reasoning can be controlled.
///
/// A model whose details the server can't give right now (still loading, or an
/// unloaded router model) keeps what the catalog already knows about it; one
/// never seen before gets the context size and reasoning of a plain model.
struct LlamaCppAdapter: ProviderAdapter {
    let provider: Provider
    /// The server's address; `/v1/...` and `/props` are appended to it.
    var baseUrl: String

    /// Used while the server doesn't say: llama-server's own default is the model's training context.
    static let defaultContextWindow = 128_000
    private static let propsConcurrency = 4

    func fetchListing(apiKey: String, fetcher: HTTPFetching, metadata: ModelMetadataSource) async throws
        -> ProviderListing
    {
        let headers = apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
        let url = try ProviderHTTP.endpoint(baseUrl, "/v1/models")
        let json = try await ProviderHTTP.getJSON(url, headers: headers, fetcher: fetcher)
        guard let data = json["data"] as? [[String: Any]] else { throw ProviderError.badResponse }

        var seen = Set<String>()
        let items = data.filter { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return false }
            return seen.insert(id).inserted
        }
        let isRouter = items.contains { $0["status"] is [String: Any] }
        let props = try await loadProps(for: items, isRouter: isRouter, headers: headers, fetcher: fetcher)

        var models: [CatalogModel] = []
        var unknown = Set<ModelID>()
        var hidden = 0
        for item in items {
            guard let name = item["id"] as? String else { continue }
            let id = ModelID(provider: provider, name: name)
            guard Self.canChat(item) else {
                hidden += 1
                continue
            }
            let capabilities = Self.capabilities(item: item, props: props[name])
            if capabilities.known == false { unknown.insert(id) }
            models.append(CatalogModel(id: id, displayName: nil, capabilities: capabilities.value))
        }
        models.sort { $0.id.name < $1.id.name }
        debugLog(
            "LlamaCppAdapter",
            "\(provider.displayName): \(url.absoluteString) lists \(items.count) model(s)"
                + (isRouter ? " (router)" : "") + (hidden > 0 ? ", \(hidden) hidden as non-chat" : "")
                + (unknown.isEmpty ? "" : ", details unavailable for \(unknown.count)")
                + ", \(props.count) with /props")
        return ProviderListing(models: models, unknownCapabilities: unknown)
    }

    // MARK: - /props

    /// `/props` is best effort: the listing already worked, and without it a model just has no reasoning
    /// control. A single-model server has one; a router is asked per loaded model.
    private func loadProps(
        for items: [[String: Any]], isRouter: Bool, headers: [String: String], fetcher: HTTPFetching
    ) async throws -> [String: Props] {
        if !isRouter {
            guard let name = items.first?["id"] as? String else { return [:] }
            let url = try ProviderHTTP.endpoint(baseUrl, "/props")
            guard let props = try await fetchProps(url, name: name, headers: headers, fetcher: fetcher) else {
                return [:]
            }
            return [name: props]
        }
        let loaded = items.compactMap { item -> String? in
            guard (item["status"] as? [String: Any])?["value"] as? String == "loaded" else { return nil }
            return item["id"] as? String
        }
        var result: [String: Props] = [:]
        try await withThrowingTaskGroup(of: (String, Props?).self) { group in
            var next = 0
            func addNext() {
                guard next < loaded.count else { return }
                let name = loaded[next]
                next += 1
                group.addTask {
                    let url = try ProviderHTTP.endpoint(
                        baseUrl, "/props", query: [URLQueryItem(name: "model", value: name)])
                    return (name, try await fetchProps(url, name: name, headers: headers, fetcher: fetcher))
                }
            }
            for _ in 0..<Self.propsConcurrency { addNext() }
            while let (name, props) = try await group.next() {
                if let props { result[name] = props }
                addNext()
            }
        }
        return result
    }

    private func fetchProps(_ url: URL, name: String, headers: [String: String], fetcher: HTTPFetching) async throws
        -> Props?
    {
        do {
            let json = try await ProviderHTTP.getJSON(url, headers: headers, fetcher: fetcher)
            return Props(json)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            debugLog("LlamaCppAdapter", "⚠️ /props unavailable for \(name): \(error)")
            return nil
        }
    }

    /// The slice of `/props` the app reads. A plain value so it can cross task boundaries.
    struct Props: Sendable, Equatable {
        var contextWindow: Int?
        var imageInput: Bool?
        var reasoning: ReasoningCapability

        init(_ json: [String: Any]) {
            let settings = json["default_generation_settings"] as? [String: Any]
            contextWindow = JSONField.int(settings?["n_ctx"]).flatMap { $0 > 0 ? $0 : nil }
            imageInput = JSONField.bool((json["modalities"] as? [String: Any])?["vision"])
            reasoning = LlamaCppAdapter.reasoning(
                templateCaps: json["chat_template_caps"] as? [String: Any],
                template: json["chat_template"] as? String)
        }
    }

    // MARK: - Capabilities

    /// A model that can't produce text (a speech or decision-only one) can't chat. Older servers send no
    /// `architecture`, and then the model is taken for a text model.
    static func canChat(_ item: [String: Any]) -> Bool {
        guard let outputs = (item["architecture"] as? [String: Any])?["output_modalities"] as? [Any] else {
            return true
        }
        return outputs.isEmpty || outputs.contains { ($0 as? String) == "text" }
    }

    /// The capabilities of a listed model; `known` is false when its context couldn't be read this time.
    static func capabilities(item: [String: Any], props: Props?) -> (value: ModelCapabilities, known: Bool) {
        let meta = item["meta"] as? [String: Any]
        let inputs = ((item["architecture"] as? [String: Any])?["input_modalities"] as? [Any])?
            .compactMap { $0 as? String }
        // `architecture` is computed from the model files, so it holds for unloaded models too.
        let image = inputs.map { $0.contains("image") } ?? props?.imageInput ?? false
        let context = JSONField.int(meta?["n_ctx"]).flatMap { $0 > 0 ? $0 : nil } ?? props?.contextWindow
        let value = ModelCapabilities(
            imageInput: image,
            contextWindow: context ?? defaultContextWindow,
            maxOutputTokens: nil,
            reasoning: props?.reasoning ?? .unsupported)
        return (value, context != nil && props != nil)
    }

    /// What the chat template allows. `/props` has no flag for turning thinking off, but a template that can
    /// reads `enable_thinking`; one that takes an effort level has `supports_reasoning_effort`.
    static func reasoning(templateCaps: [String: Any]?, template: String?) -> ReasoningCapability {
        let effort = JSONField.bool(templateCaps?["supports_reasoning_effort"]) == true
        let switchable = template?.contains("enable_thinking") == true
        guard effort || switchable else { return .unsupported }
        return ReasoningCapability(
            supported: true, levels: effort ? ["low", "medium", "high"] : [], defaultLevel: nil,
            canDisable: switchable)
    }
}
