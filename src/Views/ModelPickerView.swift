// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A modal sheet for picking the model of the current chat. Single-select:
/// ↵ or a click picks the highlighted model. Typing `<provider>.` (or `:`)
/// narrows the list to one provider, by name or alias (`or.`, `oa.`, `an.`,
/// `ds.`); the rest is a case-insensitive search over the cached catalog. Built on
/// [`PickerDialog`](src/Views/PickerDialog.swift); the model in effect is
/// checkmarked. The default model from Preferences is pinned to the top
/// (unless filtered out) and initially highlighted, so ↵ right after opening
/// picks it; without one, the model in effect is highlighted instead.
struct ModelPickerView: View {
    let models: [CatalogModel]
    let hasProviders: Bool
    let currentID: ModelID?
    let defaultID: ModelID?
    var subtitle: String = "Pick the model used by this chat."
    let onCancel: () -> Void
    let onPick: (ModelID) -> Void

    @State private var queryText: String = ""

    var body: some View {
        let items = ModelPickerQuery(queryText).filter(models, pinning: defaultID)
        let initialSelection =
            items.first { $0.id == defaultID } ?? items.first { $0.id == currentID } ?? items.first
        return PickerDialog<CatalogModel>(
            title: "Model",
            subtitle: subtitle,
            searchText: $queryText,
            searchPlaceholder: "Search models, or narrow by provider with or. oa. an. ds.",
            items: items,
            pinnedHeader: nil,
            pinnedItems: [],
            emptyTitle: hasProviders ? "Loading models…" : "No providers",
            emptySubtitle: hasProviders ? nil : "Add one via Provider → New Provider…",
            width: 480,
            rowContent: { model, _ in
                AnyView(
                    ModelRowContent(
                        model: model, isCurrent: model.id == currentID, isDefault: model.id == defaultID))
            },
            onSelect: { onPick($0.id) },
            onCancel: onCancel,
            initialSelection: initialSelection
        )
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
    let isDefault: Bool

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
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

    /// The second line: `Default | {name} | {context size}`, where the default
    /// marker (default model only) and the human-readable name (when it
    /// differs from the ID) are optional.
    private var subtitle: String {
        var parts: [String] = []
        if isDefault { parts.append("Default") }
        if let name = model.displayName, name != model.id.name { parts.append(name) }
        parts.append(ModelCapabilities.compactCount(model.capabilities.contextWindow))
        return parts.joined(separator: " | ")
    }
}
