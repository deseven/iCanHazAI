// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A modal sheet for picking which custom MCP servers are active for the
/// current chat. Multi-select: clicking a row or pressing space toggles it,
/// ↵ (or the default "Apply" button) commits the selection, Esc (or "Cancel")
/// discards it. Built on [`PickerDialog`](src/Views/PickerDialog.swift)'s
/// multi-select mode; the working selection lives here and is only committed
/// on apply.
struct MCPPickerView: View {
    /// All configured custom MCP servers (already sorted by name).
    let servers: [MCPServer]
    /// Names active when the picker was opened.
    let initiallySelected: Set<String>
    let onCancel: () -> Void
    /// Called with the applied selection, in server-list order.
    let onApply: ([String]) -> Void

    /// The working selection; only committed on apply.
    @State private var checked: Set<String> = []

    var body: some View {
        PickerDialog<MCPServer>(
            title: "MCP servers",
            subtitle: "Pick which MCP servers are active for this chat.",
            items: servers,
            pinnedHeader: nil,
            pinnedItems: [],
            emptyTitle: "No MCP servers",
            emptySubtitle: nil,
            visibleRowCount: 6,
            estimatedRowHeight: 50,
            width: 420,
            rowContent: { server, _ in
                AnyView(MCPRowContent(server: server, isChecked: checked.contains(server.name)))
            },
            onSelect: { _ in },
            onCancel: onCancel,
            initialSelection: servers.first,
            multiSelect: PickerDialog<MCPServer>.MultiSelect(
                onToggle: { server in
                    if checked.contains(server.name) {
                        checked.remove(server.name)
                    } else {
                        checked.insert(server.name)
                    }
                },
                onApply: {
                    onApply(servers.map(\.name).filter { checked.contains($0) })
                }
            )
        )
        .onAppear { checked = initiallySelected }
    }
}

/// Inner content of an MCP picker row: a checkmark reflecting the working
/// selection, the server name, and its transport summary.
private struct MCPRowContent: View {
    let server: MCPServer
    let isChecked: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        switch server.transport {
        case .stdio:
            return "stdio · \(server.command ?? "")"
        case .http:
            return "http · \(server.endpoint ?? "")"
        }
    }
}
