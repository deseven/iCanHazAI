// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The model picker's search field, parsed. A leading provider prefix
/// restricts the list to that provider; the rest is searched with
/// [`SearchMatcher`](src/Utilities/SearchMatcher.swift). The prefix is the
/// provider name or its alias (`oa`, `an`, `ds`, `or`), in any case,
/// followed by `.` or `:` — `or.llama` and `openrouter:llama` are the same
/// query. A custom provider is found by its name. It only pre-filters; it
/// never takes part in the text search.
struct ModelPickerQuery: Equatable {
    let provider: Provider?
    let text: String

    /// `providers` are the ones a prefix may name; custom providers have to be included.
    init(_ raw: String, providers: [Provider] = Provider.allCases) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // The first separator decides: `gpt-5.2` or `claude-3.5` have a dot,
        // but what precedes it is not a provider, so they stay plain text.
        if let separator = trimmed.firstIndex(where: { $0 == ":" || $0 == "." }),
            let provider = Provider(searchPrefix: String(trimmed[..<separator]), among: providers)
        {
            self.provider = provider
            text = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        } else {
            provider = nil
            text = trimmed
        }
    }

    /// The models matching the query, best first. `pinnedID` (the default
    /// model) is moved to the top whenever it survives the filtering, so it
    /// never ranks below other matches.
    func filter(_ models: [CatalogModel], pinning pinnedID: ModelID? = nil) -> [CatalogModel] {
        let scoped = provider.map { p in models.filter { $0.id.provider == p } } ?? models
        var ranked = SearchMatcher.rank(scoped, query: text) { model in
            [model.id.description, model.displayName].compactMap { $0 }
        }
        if let pinnedID, let index = ranked.firstIndex(where: { $0.id == pinnedID }), index > 0 {
            ranked.insert(ranked.remove(at: index), at: 0)
        }
        return ranked
    }

}
