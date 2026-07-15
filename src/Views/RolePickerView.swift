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
/// Keyboard navigation: ↑/↓ moves the selection, ↵ starts a chat with the
/// selected role. The role marked as default in the app config is tagged with
/// a star and is the initial selection, so pressing ↵ immediately after the
/// picker appears starts a chat with the default role.
struct RolePickerView: View {
    @EnvironmentObject var store: AppViewModel
    /// The mode the picker operates in: creating a new chat or assigning a
    /// role to an existing chat whose role is missing.
    let mode: AppViewModel.RolePickerMode
    let onCancel: () -> Void
    let onPick: (String) -> Void

    /// Currently highlighted role (driven by both keyboard and hover).
    @State private var selection: String?
    @FocusState private var focused: Bool

    /// User-defined roles shown in the main scrollable list.
    private var userRoles: [Role] { store.roles.filter { !$0.isBuiltin } }
    /// Built-in roles pinned to the bottom, always visible.
    private var builtinRoles: [Role] { store.roles.filter { $0.isBuiltin } }
    /// Combined ordered list used for keyboard navigation.
    private var allRoles: [Role] { userRoles + builtinRoles }
    /// The default role name from the app config, if any.
    private var defaultRoleName: String? { store.preferencesDefaultRole }

    /// Header title reflecting the picker's mode.
    private var headerTitle: String {
        switch mode {
        case .newChat: return "New Chat"
        case .assignToExisting: return "This chat is missing a role"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                if case .assignToExisting = mode {
                    Text("Pick a role to make this chat functional. You can't send messages until a role is assigned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(userRoles) { role in
                                roleRow(role, isBuiltin: false)
                                    .id(role.name)
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
                            roleRow(role, isBuiltin: true)
                                .id(role.name)
                        }
                    }
                    .onChange(of: selection) { _, newName in
                        guard let newName else { return }
                        proxy.scrollTo(newName, anchor: .center)
                    }
                }
            }

            Divider()

            HStack {
                Text("↑↓ navigate · ↵ select")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 380, height: 460)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { pickCurrent(); return .handled }
        .onAppear {
            if let dr = defaultRoleName, allRoles.contains(where: { $0.name == dr }) {
                selection = dr
            } else {
                selection = allRoles.first?.name
            }
            focused = true
        }
    }

    @ViewBuilder
    private func roleRow(_ role: Role, isBuiltin: Bool) -> some View {
        RolePickerRow(
            role: role,
            isDefault: role.name == defaultRoleName,
            isBuiltin: isBuiltin,
            isSelected: selection == role.name
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { selection = role.name }
        }
        .onTapGesture { onPick(role.name) }
    }

    /// Moves the keyboard selection by `delta` positions, clamped to the list.
    private func moveSelection(by delta: Int) {
        guard !allRoles.isEmpty else { return }
        let current = allRoles.firstIndex(where: { $0.name == selection }) ?? 0
        let newIndex = min(max(current + delta, 0), allRoles.count - 1)
        selection = allRoles[newIndex].name
    }

    /// Starts a chat with the currently selected role (falling back to the
    /// first role if none is selected).
    private func pickCurrent() {
        if let name = selection {
            onPick(name)
        } else if let first = allRoles.first {
            onPick(first.name)
        }
    }
}

private struct RolePickerRow: View {
    let role: Role
    var isDefault: Bool = false
    var isBuiltin: Bool = false
    var isSelected: Bool = false

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
                    if isDefault {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
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
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}
