// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The model picker's search field, parsed. A leading `<provider>:` (any case)
/// restricts the list to that provider; the rest is fuzzy-matched.
struct ModelPickerQuery: Equatable {
    let provider: Provider?
    let text: String

    /// Minimum characters after `openrouter:` before the server is asked.
    static let minServerSearchLength = 2

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.firstIndex(of: ":"),
            let provider = Provider(rawValue: trimmed[..<colon].lowercased())
        {
            self.provider = provider
            text = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else {
            provider = nil
            text = trimmed
        }
    }

    /// The text to send to OpenRouter's server-side search, or nil when the
    /// query isn't an `openrouter:<text>` of sufficient length.
    var openRouterSearchText: String? {
        guard provider == .openrouter, text.count >= Self.minServerSearchLength else { return nil }
        return text
    }

    func filter(_ models: [CatalogModel]) -> [CatalogModel] {
        let scoped = provider.map { p in models.filter { $0.id.provider == p } } ?? models
        guard !text.isEmpty else { return scoped }
        return FuzzySearch.rank(scoped, query: text) { model in
            [model.id.description, model.displayName].compactMap { $0 }
        }
    }

    /// Cached matches followed by server results that aren't already listed.
    func merged(_ models: [CatalogModel], serverResults: [CatalogModel]) -> [CatalogModel] {
        var result = filter(models)
        var seen = Set(result.map(\.id))
        for model in serverResults where seen.insert(model.id).inserted { result.append(model) }
        return result
    }
}
