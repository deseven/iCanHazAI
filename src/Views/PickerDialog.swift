// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A reusable modal picker dialog used by the role picker, working-directory
/// picker, and future pickers. Renders a header, a scrollable list of items
/// with an optional pinned bottom section (e.g. built-in roles, the role's
/// default working directory), and a footer with keyboard hints + Cancel.
///
/// Keyboard navigation: ↑/↓ moves the selection across both the scrollable and
/// pinned items, ↵ selects. Hover updates the selection without scrolling.
/// Each row's height is measured at runtime so the scroll area fits an exact
/// number of rows before a scrollbar appears.
///
/// Callers provide a `rowContent` builder for the row's inner content (icon,
/// title, subtitle, trailing actions); this view applies padding, the
/// selection highlight, hover, and tap handling.
struct PickerDialog<Item: Identifiable & Hashable>: View {
    let title: String
    let subtitle: String?
    /// Scrollable items shown in the main list.
    let items: [Item]
    /// Header label for the pinned section; nil when there are no pinned items.
    let pinnedHeader: String?
    /// Items pinned at the bottom, always visible (mirrors built-in roles).
    let pinnedItems: [Item]
    let emptyTitle: String
    let emptySubtitle: String?
    /// Number of rows that fit in the scroll area before a scrollbar appears.
    let visibleRowCount: Int
    /// Fallback per-row height until real measurements arrive.
    let estimatedRowHeight: CGFloat
    let width: CGFloat
    /// Builds the inner content of a row (without padding/highlight). The
    /// `isSelected` flag is provided for rows that want to react to selection
    /// beyond the standard highlight.
    let rowContent: (Item, Bool) -> AnyView
    let onSelect: (Item) -> Void
    let onCancel: () -> Void
    let initialSelection: Item?

    /// Currently highlighted item (driven by both keyboard and hover).
    @State private var selection: Item?
    /// True when the latest `selection` change came from keyboard navigation
    /// (or initial appear) rather than hover. Only keyboard-driven changes
    /// scroll the list, so moving the mouse over rows no longer recenters it.
    @State private var isKeyboardSelection: Bool = false
    @State private var rowHeights: [Int: CGFloat] = [:]
    @FocusState private var focused: Bool

    /// Combined ordered list used for keyboard navigation.
    private var allItems: [Item] { items + pinnedItems }

    private func rowHeight(at index: Int) -> CGFloat {
        rowHeights[index] ?? estimatedRowHeight
    }

    /// Scroll area height: the measured height of the first `visibleRowCount`
    /// rows (or all rows when there are fewer), so a scrollbar only appears
    /// once there are more than `visibleRowCount` scrollable items.
    private var listHeight: CGFloat {
        let count = items.count
        guard count > 0 else { return 0 }
        let divider: CGFloat = 1
        if count <= visibleRowCount {
            let total = (0..<count).reduce(CGFloat(0)) { $0 + rowHeight(at: $1) }
            return total + divider * CGFloat(max(count - 1, 0))
        }
        let firstN = (0..<visibleRowCount).reduce(CGFloat(0)) { $0 + rowHeight(at: $1) }
        return firstN + divider * CGFloat(visibleRowCount - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            if allItems.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(emptyTitle)
                        .foregroundStyle(.secondary)
                    if let emptySubtitle {
                        Text(emptySubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: estimatedRowHeight * CGFloat(visibleRowCount))
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        if !items.isEmpty {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                        rowContainer(item, isSelected: selection == item)
                                            .measureRowHeight(at: index)
                                        if item.id != items.last?.id {
                                            Divider()
                                        }
                                    }
                                }
                            }
                            .frame(height: listHeight)
                            .onPreferenceChange(IndexedRowHeightKey.self) { rowHeights = $0 }
                        }

                        if !pinnedItems.isEmpty {
                            VStack(spacing: 0) {
                                if let pinnedHeader {
                                    PickerSectionHeader(title: pinnedHeader)
                                }
                                LazyVStack(spacing: 0) {
                                    ForEach(pinnedItems) { item in
                                        rowContainer(item, isSelected: selection == item)
                                    }
                                }
                            }
                            .background(Color.secondary.opacity(0.05))
                        }
                    }
                    .onChange(of: selection) { _, newItem in
                        guard let newItem, isKeyboardSelection else { return }
                        isKeyboardSelection = false
                        proxy.scrollTo(newItem.id, anchor: .center)
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
        .frame(width: width)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { pickCurrent(); return .handled }
        .onAppear {
            isKeyboardSelection = true
            selection = initialSelection
            focused = true
        }
    }

    @ViewBuilder
    private func rowContainer(_ item: Item, isSelected: Bool) -> some View {
        rowContent(item, isSelected)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { selection = item }
            }
            .onTapGesture { onSelect(item) }
            .id(item.id)
    }

    /// Moves the keyboard selection by `delta` positions, clamped to the list.
    private func moveSelection(by delta: Int) {
        guard !allItems.isEmpty else { return }
        let current = selection.flatMap { allItems.firstIndex(of: $0) } ?? 0
        let newIndex = min(max(current + delta, 0), allItems.count - 1)
        isKeyboardSelection = true
        selection = allItems[newIndex]
    }

    /// Selects the currently highlighted item (falling back to the first when
    /// the selection no longer exists in the list, e.g. after a removal).
    private func pickCurrent() {
        let all = allItems
        if let sel = selection, all.contains(sel) {
            onSelect(sel)
        } else if let first = all.first {
            onSelect(first)
        }
    }
}
