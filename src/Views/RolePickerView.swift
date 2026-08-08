// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A modal sheet shown when creating a new chat or assigning a role to an
/// existing chat whose role is missing, asking the user to pick a role. Lists
/// every available role (filename without `.toml`) with its description as a
/// subtitle, styled like the chat sidebar list.
///
/// Built-in roles (served from the app bundle, e.g. the `Configurator`)
/// are pinned to the bottom in their own section, separated by a divider, so
/// they're always visible and distinct from user-defined roles.
///
/// The role marked as default in the app config is tagged with a star and is
/// the initial selection, so pressing ↵ immediately after the picker appears
/// starts a chat with the default role. Layout and keyboard navigation are
/// shared with other pickers via [`PickerDialog`](src/Views/PickerDialog.swift:14).
struct RolePickerView: View {
    @EnvironmentObject var store: AppViewModel
    /// The mode the picker operates in: creating a new chat or assigning a
    /// role to an existing chat whose role is missing.
    let mode: AppViewModel.RolePickerMode
    let onCancel: () -> Void
    let onPick: (String) -> Void

    @State private var query: String = ""

    private var userRoles: [Role] {
        FuzzySearch.rank(store.roles.filter { !$0.isBuiltin }, query: query) { [$0.name, $0.description] }
    }
    private var builtinRoles: [Role] {
        FuzzySearch.rank(store.roles.filter { $0.isBuiltin }, query: query) { [$0.name, $0.description] }
    }
    private var defaultRoleName: String? { store.preferencesDefaultRole }

    private var headerTitle: String {
        switch mode {
        case .newChat: return "New Chat"
        case .newTemporaryChat: return "New Temporary Chat"
        case .assignToExisting: return "This chat is missing a role"
        }
    }

    private var headerSubtitle: String? {
        switch mode {
        case .assignToExisting:
            return "Pick a role to make this chat functional. You can't send messages until a role is assigned."
        case .newTemporaryChat:
            return "This chat is never saved and is destroyed when you switch away from it."
        case .newChat:
            return nil
        }
    }

    private var initialSelection: Role? {
        if let dr = defaultRoleName, userRoles.contains(where: { $0.name == dr }) || builtinRoles.contains(where: { $0.name == dr }) {
            return (userRoles + builtinRoles).first { $0.name == dr }
        }
        return (userRoles + builtinRoles).first
    }

    var body: some View {
        PickerDialog<Role>(
            title: headerTitle,
            subtitle: headerSubtitle,
            searchText: $query,
            searchPlaceholder: "Search roles",
            items: userRoles,
            pinnedHeader: builtinRoles.isEmpty ? nil : "Built-in",
            pinnedItems: builtinRoles,
            emptyTitle: "No roles available",
            emptySubtitle: "Add a role TOML to ~/iCanHazAI/roles/",
            width: 380,
            rowContent: { role, _ in
                AnyView(RolePickerRowContent(role: role, isDefault: role.name == defaultRoleName))
            },
            onSelect: { onPick($0.name) },
            onCancel: onCancel,
            initialSelection: initialSelection
        )
    }
}

/// Inner content of a role picker row: icon, name (with a star when it's the
/// default role), and a description. Padding and the selection
/// highlight are applied by [`PickerDialog`](src/Views/PickerDialog.swift:14).
private struct RolePickerRowContent: View {
    let role: Role
    let isDefault: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: role.icon)
                .font(.title3)
                .foregroundStyle(role.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(role.name)
                        .font(.callout)
                        .lineLimit(1)
                    if isDefault {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(role.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
