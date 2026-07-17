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
    /// True when the latest `selection` change came from keyboard navigation
    /// (or initial appear) rather than hover. Only keyboard-driven changes
    /// scroll the list, so moving the mouse over rows no longer recenters it.
    @State private var isKeyboardSelection: Bool = false
    @State private var rowHeights: [Int: CGFloat] = [:]
    @FocusState private var focused: Bool

    /// User-defined roles shown in the main scrollable list.
    private var userRoles: [Role] { store.roles.filter { !$0.isBuiltin } }
    /// Built-in roles pinned to the bottom, always visible.
    private var builtinRoles: [Role] { store.roles.filter { $0.isBuiltin } }
    /// Combined ordered list used for keyboard navigation.
    private var allRoles: [Role] { userRoles + builtinRoles }
    /// The default role name from the app config, if any.
    private var defaultRoleName: String? { store.preferencesDefaultRole }

    /// Number of user-defined roles that fit in the scroll area before a
    /// scrollbar appears. Rows have variable heights (descriptions wrap), so
    /// each row's height is measured at runtime and summed.
    private let visibleRowCount = 5
    /// Fallback per-row height until real measurements arrive, so the list has
    /// a non-zero size on first render (rows must render to be measured).
    private let estimatedRowHeight: CGFloat = 50

    private func rowHeight(at index: Int) -> CGFloat {
        rowHeights[index] ?? estimatedRowHeight
    }

    /// Scroll area height: the measured height of the first `visibleRowCount`
    /// rows (or all rows when there are fewer), so a scrollbar only appears
    /// once there are more than `visibleRowCount` user roles.
    private var listHeight: CGFloat {
        let count = userRoles.count
        guard count > 0 else { return 0 }
        let divider: CGFloat = 1
        if count <= visibleRowCount {
            let total = (0..<count).reduce(CGFloat(0)) { $0 + rowHeight(at: $1) }
            return total + divider * CGFloat(max(count - 1, 0))
        }
        let firstN = (0..<visibleRowCount).reduce(CGFloat(0)) { $0 + rowHeight(at: $1) }
        return firstN + divider * CGFloat(visibleRowCount - 1)
    }

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
                .frame(maxWidth: .infinity, minHeight: estimatedRowHeight * CGFloat(visibleRowCount))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(userRoles.enumerated()), id: \.element.id) { index, role in
                                roleRow(role)
                                    .measureRowHeight(at: index)
                                    .id(role.name)
                                if role.id != userRoles.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(height: listHeight)
                    .onPreferenceChange(IndexedRowHeightKey.self) { rowHeights = $0 }

                    // Built-in roles pinned at the bottom, always visible.
                    VStack(spacing: 0) {
                        PickerSectionHeader(title: "Built-in")
                        LazyVStack(spacing: 0) {
                            ForEach(builtinRoles) { role in
                                roleRow(role)
                                    .id(role.name)
                            }
                        }
                    }
                    .background(Color.secondary.opacity(0.05))
                    .onChange(of: selection) { _, newName in
                        guard let newName, isKeyboardSelection else { return }
                        isKeyboardSelection = false
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
        .frame(width: 380)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { pickCurrent(); return .handled }
        .onAppear {
            isKeyboardSelection = true
            if let dr = defaultRoleName, allRoles.contains(where: { $0.name == dr }) {
                selection = dr
            } else {
                selection = allRoles.first?.name
            }
            focused = true
        }
    }

    @ViewBuilder
    private func roleRow(_ role: Role) -> some View {
        RolePickerRow(
            role: role,
            isDefault: role.name == defaultRoleName,
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
        isKeyboardSelection = true
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
    var isSelected: Bool = false

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
