// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// OpenAI's `/models` returns bare ids (embeddings, tts, image and sora models
/// included), so the chat-capable subset and the capabilities come from LiteLLM.
struct OpenAIAdapter: ProviderAdapter {
    let provider = Provider.openai
    var baseUrl: String = Provider.openai.defaultBaseUrl
    var now: @Sendable () -> Date = { Date() }

    struct ListedModel: Equatable {
        var id: String
        var shutdownDate: String?
    }

    func fetchListing(apiKey: String, fetcher: HTTPFetching, metadata: ModelMetadataSource) async throws
        -> ProviderListing
    {
        async let entries = Self.loadEntries(metadata)
        let url = try ProviderHTTP.endpoint(baseUrl, "/models")
        let json = try await ProviderHTTP.getJSON(
            url, headers: ["Authorization": "Bearer \(apiKey)"], fetcher: fetcher)
        guard let data = json["data"] as? [[String: Any]] else { throw ProviderError.badResponse }
        let listed = data.compactMap { item -> ListedModel? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return ListedModel(id: id, shutdownDate: item["shutdown_date"] as? String)
        }
        let known = try await entries
        return ProviderListing(
            models: Self.select(listed, entries: known, now: now()), capabilitiesUnknown: known == nil)
    }

    /// A LiteLLM failure must not fail the refresh: the caller falls back to
    /// name heuristics and keeps whatever capabilities it already has.
    private static func loadEntries(_ metadata: ModelMetadataSource) async throws -> [String: LiteLLMEntry]? {
        do {
            return try await metadata.openAIEntries()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            debugLog("OpenAIAdapter", "⚠️ LiteLLM metadata unavailable: \(error)")
            return nil
        }
    }

    private static let hiddenNameParts = [
        "audio", "realtime", "transcribe", "tts", "search", "deep-research", "computer-use", "instruct", "image",
        "sora", "embedding", "moderation",
    ]

    static func select(_ listed: [ListedModel], entries: [String: LiteLLMEntry]?, now: Date) -> [CatalogModel] {
        var survivors: [String: CatalogModel] = [:]
        for model in listed {
            if let shutdown = model.shutdownDate, isPast(shutdown, now: now) { continue }
            if isHiddenByName(model.id) { continue }
            if let entries {
                if let entry = entries[model.id] ?? entries["chatgpt/\(model.id)"] {
                    guard entry.supportsChatCompletions else { continue }
                    survivors[model.id] = catalogModel(model.id, entry: entry)
                    continue
                }
            }
            guard looksLikeChatModel(model.id) else { continue }
            survivors[model.id] = CatalogModel(
                id: ModelID(provider: .openai, name: model.id), displayName: nil, capabilities: .safeDefaults)
        }
        return survivors.values
            .filter { !isSnapshot($0.id.name, shadowedBy: survivors) }
            .sorted { $0.id.name < $1.id.name }
    }

    private static func catalogModel(_ id: String, entry: LiteLLMEntry) -> CatalogModel {
        CatalogModel(
            id: ModelID(provider: .openai, name: id),
            displayName: nil,
            capabilities: ModelCapabilities(
                imageInput: entry.supportsVision,
                contextWindow: entry.maxInputTokens ?? ModelCapabilities.safeDefaults.contextWindow,
                maxOutputTokens: entry.maxOutputTokens,
                reasoning: ReasoningCapability(
                    supported: entry.supportsReasoning, levels: entry.reasoningLevels, defaultLevel: nil)))
    }

    private static func isHiddenByName(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return lowered.hasPrefix("ft:") || hiddenNameParts.contains { lowered.contains($0) }
    }

    private static func looksLikeChatModel(_ id: String) -> Bool {
        id.range(of: #"^(gpt-|o\d|chatgpt-)"#, options: .regularExpression) != nil
    }

    /// `X-YYYY-MM-DD` is hidden when the alias `X` survived too.
    private static func isSnapshot(_ id: String, shadowedBy survivors: [String: CatalogModel]) -> Bool {
        guard let range = id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) else { return false }
        return survivors[String(id[..<range.lowerBound])] != nil
    }

    private static func isPast(_ shutdown: String, now: Date) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: String(shutdown.prefix(10))) else { return false }
        return date < now
    }
}
