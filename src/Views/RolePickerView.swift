// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A modal sheet shown when creating a new chat, asking the user to pick a
/// role. Lists every available role (filename without `.toml`) with its
/// description as a subtitle, styled like the chat sidebar list.
///
/// Built-in roles (served from the app bundle, e.g. the `iCHAI Configurator`)
/// are pinned to the bottom in their own section, separated by a divider, so
/// they're always visible and distinct from user-defined roles.
struct RolePickerView: View {
    @EnvironmentObject var store: AppViewModel
    let onCancel: () -> Void
    let onPick: (String) -> Void

    @State private var hovered: String?

    /// User-defined roles shown in the main scrollable list.
    private var userRoles: [Role] { store.roles.filter { !$0.isBuiltin } }
    /// Built-in roles pinned to the bottom, always visible.
    private var builtinRoles: [Role] { store.roles.filter { $0.isBuiltin } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Chat")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            if store.roles.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No roles available")
                        .foregroundStyle(.secondary)
                    Text("Add a role TOML to ~/iCanHazAI/roles/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(userRoles) { role in
                            RolePickerRow(
                                role: role,
                                isHovered: hovered == role.name
                            )
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                hovered = hovering ? role.name : nil
                            }
                            .onTapGesture {
                                onPick(role.name)
                            }
                            if role.id != userRoles.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                Divider()

                // Built-in roles pinned at the bottom, always visible.
                LazyVStack(spacing: 0) {
                    ForEach(builtinRoles) { role in
                        RolePickerRow(
                            role: role,
                            isHovered: hovered == role.name,
                            isBuiltin: true
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hovered = hovering ? role.name : nil
                        }
                        .onTapGesture {
                            onPick(role.name)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 380, height: 460)
    }
}

private struct RolePickerRow: View {
    let role: Role
    let isHovered: Bool
    var isBuiltin: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: role.icon)
                .font(.title3)
                .foregroundStyle(role.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(role.name)
                        .font(.callout)
                        .lineLimit(1)
                    if isBuiltin {
                        Text("Built-in")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(role.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}
