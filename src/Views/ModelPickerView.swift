// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A modal sheet for picking the model of the current chat. Single-select:
/// ↵ or a click picks the highlighted model. Typing `<provider>.` (or `:`)
/// narrows the list to one provider, by name or alias (`or.`, `oa.`, `an.`,
/// `ds.`); an OpenRouter prefix additionally searches OpenRouter beyond the
/// cached popular models. Built on
/// [`PickerDialog`](src/Views/PickerDialog.swift); the model in effect is
/// checkmarked and initially highlighted.
struct ModelPickerView: View {
    let models: [CatalogModel]
    let hasProviders: Bool
    let currentID: ModelID?
    var subtitle: String = "Pick the model used by this chat."
    /// OpenRouter server-side search.
    let search: (String) async throws -> [CatalogModel]
    let onCancel: () -> Void
    let onPick: (ModelID) -> Void

    @State private var queryText: String = ""
    @State private var serverResults: [CatalogModel] = []
    @State private var isSearching = false
    @State private var searchFailed = false

    private var query: ModelPickerQuery { ModelPickerQuery(queryText) }

    private var items: [CatalogModel] {
        query.merged(models, serverResults: query.openRouterSearchText == nil ? [] : serverResults)
    }

    private var initialSelection: CatalogModel? {
        items.first { $0.id == currentID } ?? items.first
    }

    var body: some View {
        PickerDialog<CatalogModel>(
            title: "Model",
            subtitle: searchFailed
                ? "OpenRouter search unavailable — showing cached models." : subtitle,
            searchText: $queryText,
            searchPlaceholder: "Search models, or type or. to search all of OpenRouter",
            items: items,
            pinnedHeader: nil,
            pinnedItems: [],
            emptyTitle: hasProviders ? "Loading models…" : "No providers",
            emptySubtitle: hasProviders ? nil : "Add one via Provider → New Provider…",
            width: 480,
            rowContent: { model, _ in
                AnyView(ModelRowContent(model: model, isCurrent: model.id == currentID))
            },
            onSelect: { onPick($0.id) },
            onCancel: onCancel,
            initialSelection: initialSelection,
            isLoading: isSearching
        )
        .task(id: query.openRouterSearchText) { await runSearch(query.openRouterSearchText) }
    }

    /// Debounced; a changed query cancels the previous task, so stale results
    /// never land.
    private func runSearch(_ text: String?) async {
        searchFailed = false
        guard let text else {
            serverResults = []
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let results = try await search(text)
            guard !Task.isCancelled else { return }
            serverResults = results
        } catch {
            guard !Task.isCancelled else { return }
            serverResults = []
            searchFailed = true
        }
        isSearching = false
    }
}

/// The model status block shared by the chat toolbar and Preferences: the
/// provider tag and a chip with the model name, or a red "No model" when none
/// is selected.
struct ModelStatusLabel: View {
    let provider: Provider?
    let label: String
    let hasModel: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
            if let provider { ProviderTag(provider: provider) }
            Text(label)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(hasModel ? Color.primary : Color.red)
    }
}

private struct ModelRowContent: View {
    let model: CatalogModel
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ProviderTag(provider: model.id.provider)
                    Text(model.id.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let name = model.displayName, name != model.id.name {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if model.capabilities.imageInput {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .help("Accepts images")
            }
            if model.capabilities.reasoning.supported {
                Image(systemName: "brain")
                    .foregroundStyle(.secondary)
                    .help("Supports reasoning")
            }
        }
    }
}
