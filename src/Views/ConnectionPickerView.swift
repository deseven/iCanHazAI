// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A modal sheet for picking the connection (model) of the current chat.
/// Single-select: ↵ or a click picks the highlighted connection. The list is
/// fuzzy-filtered by the search field over the connection name and model.
/// Built on [`PickerDialog`](src/Views/PickerDialog.swift); the connection in
/// effect is checkmarked and initially highlighted.
struct ConnectionPickerView: View {
    let connections: [Connection]
    /// Id of the connection in effect when the picker was opened.
    let currentID: String?
    let onCancel: () -> Void
    let onPick: (Connection) -> Void

    @State private var query: String = ""

    private var filteredConnections: [Connection] {
        FuzzySearch.rank(connections, query: query) { [$0.name, $0.model] }
    }

    private var initialSelection: Connection? {
        filteredConnections.first { $0.id == currentID } ?? filteredConnections.first
    }

    var body: some View {
        PickerDialog<Connection>(
            title: "Model",
            subtitle: "Pick the connection used by this chat.",
            searchText: $query,
            searchPlaceholder: "Search models",
            items: filteredConnections,
            pinnedHeader: nil,
            pinnedItems: [],
            emptyTitle: "No connections",
            emptySubtitle: "Add a connection under ~/iCanHazAI/connections/",
            width: 420,
            rowContent: { connection, _ in
                AnyView(ConnectionRowContent(connection: connection, isCurrent: connection.id == currentID))
            },
            onSelect: onPick,
            onCancel: onCancel,
            initialSelection: initialSelection
        )
    }
}

/// Inner content of a connection picker row: a checkmark for the connection
/// in effect, its name, and the model identifier with the provider.
private struct ConnectionRowContent: View {
    let connection: Connection
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName)
                    .font(.callout)
                    .lineLimit(1)
                Text("\(connection.provider.rawValue) · \(connection.model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }
}
