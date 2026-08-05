// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import AppKit

/// A reusable modal picker dialog used by the role picker, working-directory
/// picker, MCP picker, and future pickers. Renders a header, a search field
/// (focused on appear), a scrollable list of items with an optional pinned
/// bottom section (e.g. built-in roles, the role's default working
/// directory), and a footer with keyboard hints + Cancel.
///
/// The sheet has a fixed size (80% of the parent window's height) with its
/// top edge anchored 15% below the parent window's top; the item list
/// scrolls within. The fixed content size means SwiftUI sizes the sheet
/// window exactly once and we never resize it — two authorities resizing
/// the same window previously caused an infinite setFrame/layout cycle
/// pegging the main thread (a full app hang while typing in the workdir
/// picker). The window is only ever moved into place (sheets normally
/// attach right under the toolbar — moving keeps it modal while allowing
/// the floating position). See `positionSheet()` and `PickerLayout`.
///
/// Filtering is owned by the caller: the dialog exposes `searchText` as a
/// binding and renders whatever `items`/`pinnedItems` it is given. Whenever
/// the search text changes the highlight resets to the first item.
///
/// Keyboard navigation: ↑/↓ moves the selection across both the scrollable and
/// pinned items, ↵ selects. Implemented with standard SwiftUI key handling
/// scoped to the dialog's view hierarchy (`.onKeyPress` on the search field
/// and the dialog container, `.onSubmit` as a fallback for ↵) — no event
/// monitors, so key interception can never leak into the underlying window
/// after the sheet closes. Hover updates the selection without scrolling —
/// but hover is suspended once the keyboard takes over and only re-enabled
/// by actual mouse movement, because scrolling or re-laying out the list
/// under a stationary cursor fires hover events that would fight the
/// keyboard highlight.
///
/// Callers provide a `rowContent` builder for the row's inner content (icon,
/// title, subtitle, trailing actions); this view applies padding, the
/// selection highlight, hover, and tap handling.
///
/// Multi-select mode (`multiSelect` non-nil, used by the MCP picker): tap or
/// ⇧↵ toggles the highlighted item instead of picking it (space now types
/// into the search field), ↵ applies the selection (the footer gains a
/// default "Apply" button before "Cancel"), and Esc still cancels. The toggle
/// state itself is owned by the caller.
struct PickerDialog<Item: Identifiable & Hashable>: View {
    /// Multi-select behavior. When set, the dialog toggles items instead of
    /// picking one: `onToggle` fires on tap/⇧↵, `onApply` on ↵/Apply.
    struct MultiSelect {
        let onToggle: (Item) -> Void
        let onApply: () -> Void
    }

    let title: String
    let subtitle: String?
    /// Current search text; the caller filters `items`/`pinnedItems` from it.
    @Binding var searchText: String
    /// Placeholder for the search field.
    var searchPlaceholder: String = "Search"
    /// Scrollable items shown in the main list.
    let items: [Item]
    /// Header label for the pinned section; nil when there are no pinned items.
    let pinnedHeader: String?
    /// Items pinned at the bottom, always visible (mirrors built-in roles).
    let pinnedItems: [Item]
    let emptyTitle: String
    let emptySubtitle: String?
    let width: CGFloat
    /// Builds the inner content of a row (without padding/highlight). The
    /// `isSelected` flag is provided for rows that want to react to selection
    /// beyond the standard highlight.
    let rowContent: (Item, Bool) -> AnyView
    let onSelect: (Item) -> Void
    let onCancel: () -> Void
    let initialSelection: Item?
    /// When non-nil, the dialog runs in multi-select mode (see `MultiSelect`).
    var multiSelect: MultiSelect? = nil

    /// Currently highlighted item (driven by both keyboard and hover).
    @State private var selection: Item?
    /// True when the latest `selection` change came from keyboard navigation
    /// (or initial appear) rather than hover. Only keyboard-driven changes
    /// scroll the list, so moving the mouse over rows no longer recenters it.
    @State private var isKeyboardSelection: Bool = false
    /// Whether hover may move the selection. Suspended by keyboard
    /// navigation (and search-driven selection resets); re-enabled by actual
    /// mouse movement over the dialog — scroll/layout-induced hover events
    /// under a stationary cursor would otherwise steal the highlight.
    @State private var hoverEnabled: Bool = true
    @FocusState private var searchFocused: Bool
    /// The sheet window hosting the dialog (resolved after appear).
    @State private var sheetWindow: NSWindow?
    /// Parent window height; determines the dialog height.
    @State private var parentWindowHeight: CGFloat = 720
    /// Observers re-positioning the sheet when the parent window or the
    /// sheet itself moves or resizes.
    @State private var windowObservers: [NSObjectProtocol] = []

    /// Combined ordered list used for keyboard navigation.
    private var allItems: [Item] { items + pinnedItems }

    var body: some View {
        VStack(spacing: 0) {
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

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(searchPlaceholder, text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onKeyPress(keys: [.upArrow, .downArrow, .return]) { handleKeyPress($0) }
                        // Fallback for ↵ if the field editor gets it first.
                        .onSubmit(confirmCurrent)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                Divider()
            }

            if allItems.isEmpty {
                VStack(spacing: 8) {
                    Text(searchText.isEmpty ? emptyTitle : "No matches")
                        .foregroundStyle(.secondary)
                    if searchText.isEmpty, let emptySubtitle {
                        Text(emptySubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        if !items.isEmpty {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
                                        rowContainer(item, isSelected: selection == item)
                                        if item.id != items.last?.id {
                                            Divider()
                                        }
                                    }
                                }
                            }
                        } else {
                            Spacer(minLength: 0)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .onChange(of: selection) { _, newItem in
                        guard let newItem, isKeyboardSelection else { return }
                        isKeyboardSelection = false
                        proxy.scrollTo(newItem.id, anchor: .center)
                    }
                }
            }

            VStack(spacing: 0) {
                Divider()

                HStack {
                    Text(multiSelect != nil ? "↑↓ navigate · ⇧↵ toggle · ↵ apply" : "↑↓ navigate · ↵ select")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let multiSelect {
                        Button("Apply", action: multiSelect.onApply)
                            .keyboardShortcut(.defaultAction)
                    }
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
        }
        .frame(width: width, height: PickerLayout.dialogHeight(windowHeight: parentWindowHeight))
        // Catches ↑/↓/↵ when the search field doesn't hold focus (e.g. a row
        // button took it); handled presses stop propagating, so keys focused
        // in the search field never reach here twice.
        .onKeyPress(keys: [.upArrow, .downArrow, .return]) { handleKeyPress($0) }
        // Re-enables hover selection on actual mouse movement (scrolling the
        // list under a stationary cursor must not steal the highlight).
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active = phase { hoverEnabled = true }
        }
        .background(WindowAccessor { window in
            if sheetWindow !== window {
                sheetWindow = window
                updateParentHeight()
                positionSheet()
            }
        })
        .onChange(of: searchText) { _, _ in
            isKeyboardSelection = true
            hoverEnabled = false
            selection = allItems.first
        }
        .onAppear {
            isKeyboardSelection = true
            selection = initialSelection
            updateParentHeight()
            installWindowObservers()
            // Defer so the sheet has finished laying out before taking focus.
            DispatchQueue.main.async { searchFocused = true }
            // Position now (async so the sheet window exists) and again once
            // the slide-in animation has finished.
            DispatchQueue.main.async { positionSheet() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { positionSheet() }
        }
        .onDisappear {
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            windowObservers = []
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
                if hovering, hoverEnabled { selection = item }
            }
            .onTapGesture {
                if let multiSelect { multiSelect.onToggle(item) } else { onSelect(item) }
            }
            .id(item.id)
    }

    /// Reads the parent window's height (determines the dialog height).
    private func updateParentHeight() {
        let sheet = sheetWindow ?? NSApp.keyWindow
        guard let parent = sheet?.sheetParent ?? NSApp.mainWindow else { return }
        let height = parent.frame.height
        if height > 0 { parentWindowHeight = height }
    }

    /// Positions the sheet window: top edge anchored 15% below the parent
    /// window's top, horizontally centered. Called on appear, when the
    /// parent window moves or resizes, and when the sheet itself resizes
    /// (SwiftUI resizes around the window origin, so size changes would
    /// otherwise drift the anchored top edge).
    ///
    /// Sizing is deliberately NOT done here — see the type header. Moving
    /// the window doesn't relayout its content, so this is safe to call
    /// from any notification.
    private func positionSheet() {
        guard let sheet = sheetWindow ?? NSApp.keyWindow,
              let parent = sheet.sheetParent else { return }
        let origin = PickerLayout.sheetOrigin(parentFrame: parent.frame, sheetSize: sheet.frame.size)
        let target = NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
        // Sub-point tolerance: AppKit may hold the window at a pixel-rounded
        // position slightly off the computed anchor.
        guard abs(target.x - sheet.frame.minX) >= 0.75 || abs(target.y - sheet.frame.minY) >= 0.75 else { return }
        sheet.setFrameOrigin(target)
    }

    /// Re-positions the sheet when the parent window moves or resizes (the
    /// anchor is relative to the parent's frame, and the dialog height
    /// depends on the parent's height) and when the sheet itself resizes
    /// (size changes drift the anchored top edge).
    private func installWindowObservers() {
        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        windowObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let sheet = sheetWindow ?? NSApp.keyWindow
                guard let window = note.object as? NSWindow else { return }
                if window === sheet {
                    positionSheet()
                } else if window === sheet?.sheetParent {
                    updateParentHeight()
                    positionSheet()
                }
            }
        }
    }

    /// Handles ↑/↓/↵ for the search field and the dialog container. ⇧↵
    /// toggles in multi-select mode; plain ↵ picks (or applies).
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            moveSelection(by: -1)
        case .downArrow:
            moveSelection(by: 1)
        case .return:
            if press.modifiers.contains(.shift), multiSelect != nil {
                toggleCurrent()
            } else {
                confirmCurrent()
            }
        default:
            return .ignored
        }
        return .handled
    }

    /// ↵ action: applies the selection in multi-select mode, picks the
    /// highlighted item otherwise.
    private func confirmCurrent() {
        if let multiSelect {
            multiSelect.onApply()
        } else {
            pickCurrent()
        }
    }

    /// Moves the keyboard selection by `delta` positions, clamped to the list.
    private func moveSelection(by delta: Int) {
        guard !allItems.isEmpty else { return }
        let current = selection.flatMap { allItems.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        let newIndex = min(max(current + delta, 0), allItems.count - 1)
        isKeyboardSelection = true
        hoverEnabled = false
        selection = allItems[newIndex]
    }

    /// Toggles the currently highlighted item in multi-select mode (falling
    /// back to the first when the highlight no longer exists in the list).
    /// No-op in single-select mode.
    private func toggleCurrent() {
        guard let multiSelect else { return }
        let all = allItems
        if let sel = selection, all.contains(sel) {
            multiSelect.onToggle(sel)
        } else if let first = all.first {
            multiSelect.onToggle(first)
        }
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

/// Pure layout math for `PickerDialog`, extracted for testability.
enum PickerLayout {
    /// Fraction of the parent window's height from its top where the sheet's
    /// top edge is anchored.
    static let topInsetFraction: CGFloat = 0.15
    /// Fixed fraction of the parent window's height the dialog occupies.
    static let heightFraction: CGFloat = 0.80

    /// The dialog's fixed height: a fixed fraction of the parent window's.
    static func dialogHeight(windowHeight: CGFloat) -> CGFloat {
        windowHeight * heightFraction
    }

    /// Sheet origin anchoring the sheet's top edge `topInsetFraction` of the
    /// parent window's height below the window's top, centered horizontally.
    static func sheetOrigin(parentFrame: NSRect, sheetSize: NSSize) -> NSPoint {
        NSPoint(
            x: parentFrame.midX - sheetSize.width / 2,
            y: parentFrame.maxY - parentFrame.height * topInsetFraction - sheetSize.height
        )
    }
}

/// Reports the window hosting the view it's attached to. SwiftUI has no
/// direct window accessor, so this bridges through a dummy NSView.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
