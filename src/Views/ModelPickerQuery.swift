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

    /// The models matching the query, best first, except that the ones that
    /// survive the filtering are lifted to the top regardless of their rank:
    /// `pinnedID` (the default model) first, then the `favorites` sorted by
    /// name, then the rest.
    func filter(
        _ models: [CatalogModel], pinning pinnedID: ModelID? = nil, favorites: Set<ModelID> = []
    ) -> [CatalogModel] {
        let scoped = provider.map { p in models.filter { $0.id.provider == p } } ?? models
        let ranked = SearchMatcher.rank(scoped, query: text) { model in
            [model.id.description, model.displayName].compactMap { $0 }
        }
        guard pinnedID != nil || !favorites.isEmpty else { return ranked }
        var pinned: [CatalogModel] = []
        var starred: [CatalogModel] = []
        var rest: [CatalogModel] = []
        for model in ranked {
            if model.id == pinnedID {
                pinned.append(model)
            } else if favorites.contains(model.id) {
                starred.append(model)
            } else {
                rest.append(model)
            }
        }
        starred.sort { lhs, rhs in
            let order = lhs.id.name.localizedStandardCompare(rhs.id.name)
            return order == .orderedSame ? lhs.id.provider < rhs.id.provider : order == .orderedAscending
        }
        return pinned + starred + rest
    }

}
