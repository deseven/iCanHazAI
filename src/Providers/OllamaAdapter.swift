// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// An Ollama server through its native API, local or cloud. Unlike an
/// OpenAI-compatible endpoint, Ollama can say what each of its models does, so
/// nothing is looked up in LiteLLM:
///
/// - `GET /api/tags` lists the models; the request doubles as the key check.
/// - `POST /api/show` (one per model) gives the capabilities (`completion`,
///   `vision`, `thinking`), the thinking levels and the longest context.
///   Models that can't chat (embedding models) are left out.
/// - `GET /api/ps` gives the context a *loaded* model runs with.
///
/// The context shown is the one Ollama will really use, because the app doesn't
/// set `num_ctx` and so leaves the choice to the server: the model's Modelfile
/// `num_ctx`, else the loaded model's context, else Ollama's default (4k on
/// most machines), never more than the model supports. An empty list is taken at
/// its word, like for any custom provider.
struct OllamaAdapter: ProviderAdapter {
    let provider: Provider
    /// The server's address; `/api/...` is appended to it.
    var baseUrl: String

    /// What Ollama runs a model with when nothing says otherwise: its default
    /// for GPUs under 24 GiB (more memory gets a larger one).
    static let defaultContextWindow = 4096
    private static let showConcurrency = 6

    func fetchListing(apiKey: String, fetcher: HTTPFetching, metadata: ModelMetadataSource) async throws
        -> ProviderListing
    {
        let headers = apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
        let tagsUrl = try ProviderHTTP.endpoint(baseUrl, "/api/tags")
        let tags = try await ProviderHTTP.getJSON(tagsUrl, headers: headers, fetcher: fetcher)
        guard let items = tags["models"] as? [[String: Any]] else { throw ProviderError.badResponse }
        var seen = Set<String>()
        let names = items.compactMap { item -> String? in
            guard let name = (item["name"] as? String) ?? (item["model"] as? String), !name.isEmpty,
                seen.insert(name).inserted
            else { return nil }
            return name
        }
        let loaded = try await loadedContexts(headers: headers, fetcher: fetcher)
        let details = try await showAll(names, loaded: loaded, headers: headers, fetcher: fetcher)

        var models: [CatalogModel] = []
        var unknown = Set<ModelID>()
        var hidden = 0
        for name in names {
            let id = ModelID(provider: provider, name: name)
            switch details[name] {
            case .gone, .notChat, nil:
                hidden += 1
            case .failed:
                unknown.insert(id)
                models.append(
                    CatalogModel(
                        id: id, displayName: nil, capabilities: Self.fallbackCapabilities(loaded: loaded[name])))
            case .capabilities(let capabilities):
                models.append(CatalogModel(id: id, displayName: nil, capabilities: capabilities))
            }
        }
        models.sort { $0.id.name < $1.id.name }
        debugLog(
            "OllamaAdapter",
            "\(provider.displayName): \(tagsUrl.absoluteString) lists \(names.count) model(s)"
                + (hidden > 0 ? ", \(hidden) hidden as non-chat" : "")
                + (unknown.isEmpty ? "" : ", details unavailable for \(unknown.count)")
                + ", \(loaded.count) loaded")
        return ProviderListing(models: models, unknownCapabilities: unknown)
    }

    // MARK: - Requests

    private enum Shown: Sendable {
        case capabilities(ModelCapabilities)
        /// An embedding model or the like: it can't chat, so it isn't offered.
        case notChat
        /// The server no longer knows the model (removed since the listing).
        case gone
        /// The request failed for another reason, so the model is kept with what we can assume.
        case failed
    }

    /// `/api/ps`, best effort: it only improves the context shown. A failure other than a cancellation is
    /// not worth failing the listing for.
    private func loadedContexts(headers: [String: String], fetcher: HTTPFetching) async throws -> [String: Int] {
        let url = try ProviderHTTP.endpoint(baseUrl, "/api/ps")
        do {
            let json = try await ProviderHTTP.getJSON(url, headers: headers, fetcher: fetcher)
            var result: [String: Int] = [:]
            for item in json["models"] as? [[String: Any]] ?? [] {
                if let name = (item["name"] as? String) ?? (item["model"] as? String),
                    let context = JSONField.int(item["context_length"]), context > 0
                {
                    result[name] = context
                }
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            debugLog("OllamaAdapter", "⚠️ /api/ps unavailable: \(error)")
            return [:]
        }
    }

    /// `/api/show` for every model, a few at a time.
    private func showAll(
        _ names: [String], loaded: [String: Int], headers: [String: String], fetcher: HTTPFetching
    ) async throws -> [String: Shown] {
        guard !names.isEmpty else { return [:] }
        let url = try ProviderHTTP.endpoint(baseUrl, "/api/show")
        var results: [String: Shown] = [:]
        try await withThrowingTaskGroup(of: (String, Shown).self) { group in
            var next = 0
            func addNext() {
                guard next < names.count else { return }
                let name = names[next]
                next += 1
                group.addTask {
                    do {
                        let json = try await ProviderHTTP.postJSON(
                            url, body: ["model": name], headers: headers, fetcher: fetcher)
                        guard let capabilities = Self.capabilities(show: json, loadedContext: loaded[name]) else {
                            return (name, .notChat)
                        }
                        return (name, .capabilities(capabilities))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch ProviderError.http(let status, _) where status == 404 {
                        return (name, .gone)
                    } catch ProviderError.invalidKey {
                        throw ProviderError.invalidKey
                    } catch {
                        debugLog("OllamaAdapter", "⚠️ /api/show failed for \(name): \(error)")
                        return (name, .failed)
                    }
                }
            }
            for _ in 0..<Self.showConcurrency { addNext() }
            while let (name, shown) = try await group.next() {
                results[name] = shown
                addNext()
            }
        }
        return results
    }

    // MARK: - Capabilities

    /// The capabilities in an `/api/show` answer, or nil for a model that can't chat. `loadedContext` is
    /// the context of the model as `/api/ps` reports it, when it is loaded.
    static func capabilities(show: [String: Any], loadedContext: Int?) -> ModelCapabilities? {
        let listed = JSONField.strings(show["capabilities"])
        // Servers that predate `capabilities` don't send it: the model is taken for a plain chat model.
        if !listed.isEmpty, !listed.contains("completion") { return nil }
        return ModelCapabilities(
            imageInput: listed.contains("vision"),
            contextWindow: contextWindow(show: show, loadedContext: loadedContext),
            maxOutputTokens: nil,
            reasoning: reasoning(show: show, listed: listed))
    }

    /// What a model we know nothing about is assumed to do.
    static func fallbackCapabilities(loaded: Int?) -> ModelCapabilities {
        ModelCapabilities(
            imageInput: false, contextWindow: loaded ?? defaultContextWindow, maxOutputTokens: nil,
            reasoning: .unsupported)
    }

    /// `thinking.values` holds booleans for an on/off control and strings for named levels; `[false]` alone
    /// is a model that doesn't think. A model that says it can think but not how is an on/off switch.
    static func reasoning(show: [String: Any], listed: [String]) -> ReasoningCapability {
        guard let thinking = show["thinking"] as? [String: Any], let values = thinking["values"] as? [Any] else {
            return listed.contains("thinking")
                ? ReasoningCapability(supported: true, levels: [], defaultLevel: nil, canDisable: true)
                : .unsupported
        }
        let levels = ReasoningLevels.sorted(values.compactMap { $0 as? String })
        let canDisable = values.contains { JSONField.bool($0) == false }
        let canThink = !levels.isEmpty || values.contains { JSONField.bool($0) == true }
        guard canThink else { return .unsupported }
        return ReasoningCapability(
            supported: true, levels: levels, defaultLevel: thinking["default"] as? String, canDisable: canDisable)
    }

    /// The Modelfile's `num_ctx` wins, then the loaded model's context, then Ollama's default; none can
    /// exceed what the model supports.
    static func contextWindow(show: [String: Any], loadedContext: Int?) -> Int {
        let supported = trainedContext(show["model_info"] as? [String: Any])
        let effective = modelfileContext(show["parameters"] as? String) ?? loadedContext ?? defaultContextWindow
        return supported.map { min(effective, $0) } ?? effective
    }

    /// `model_info` keys are `<architecture>.<field>`.
    static func trainedContext(_ info: [String: Any]?) -> Int? {
        guard let info else { return nil }
        if let architecture = info["general.architecture"] as? String,
            let value = JSONField.int(info["\(architecture).context_length"]), value > 0
        {
            return value
        }
        return info.compactMap { key, value in key.hasSuffix(".context_length") ? JSONField.int(value) : nil }
            .filter { $0 > 0 }.min()
    }

    /// `parameters` is the Modelfile's settings as text, one `name value` per line.
    static func modelfileContext(_ parameters: String?) -> Int? {
        guard let parameters else { return nil }
        for line in parameters.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "num_ctx", let value = Int(parts[1]), value > 0 { return value }
        }
        return nil
    }
}
