// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The model picker's search field, parsed. A leading provider prefix
/// restricts the list to that provider; the rest is fuzzy-matched. The prefix
/// is the provider name or its alias (`oa`, `an`, `ds`, `or`), in any case,
/// followed by `.` or `:` — `or.llama` and `openrouter:llama` are the same
/// query. It only pre-filters; it never takes part in the fuzzy match.
struct ModelPickerQuery: Equatable {
    let provider: Provider?
    let text: String

    /// Minimum characters after the OpenRouter prefix before the server is asked.
    static let minServerSearchLength = 2

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // The first separator decides: `gpt-5.2` or `claude-3.5` have a dot,
        // but what precedes it is not a provider, so they stay plain text.
        if let separator = trimmed.firstIndex(where: { $0 == ":" || $0 == "." }),
            let provider = Provider(searchPrefix: String(trimmed[..<separator]))
        {
            self.provider = provider
            text = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        } else {
            provider = nil
            text = trimmed
        }
    }

    /// The text to send to OpenRouter's server-side search, or nil when the
    /// query isn't an OpenRouter-scoped search of sufficient length.
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
