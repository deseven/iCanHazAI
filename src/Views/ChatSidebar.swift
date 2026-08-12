// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct ChatSidebar: View {
    @EnvironmentObject var store: AppViewModel

    /// Filename pending a rename action (drives the rename sheet).
    @State private var renamingFilename: String?
    @State private var renameText: String = ""

    /// Filename pending a delete confirmation (drives the confirmation dialog).
    @State private var deletingFilename: String?

    /// Whether the archived-chats picker sheet is currently shown.
    @State private var showArchivedPicker = false

    /// Whether the option key is currently held — swaps the new-chat button
    /// to its "temporary chat" variant (dashed circle).
    @State private var optionHeld = false
    /// Local monitor tracking option-key presses for the button icon swap.
    @State private var modifierMonitor: Any?

    /// Filter text for the chat list (fuzzy on titles, exact substring on
    /// filenames). Empty means the full sectioned list is shown.
    @State private var filterText = ""
    /// Highlighted chat while filtering — driven by ↑/↓ in the filter field,
    /// confirmed with ↵. Nil when the filter is empty.
    @State private var filterSelection: ChatSummary?
    /// Set by keyboard navigation so the list scrolls to keep the highlight
    /// visible (mirrors `PickerDialog`'s `isKeyboardSelection`).
    @State private var filterKeyboardScroll = false
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.headline)
                    .padding(.leading, 12)
                Spacer()
                // Zero-spacing group so the two buttons read as a unit stuck
                // to the sidebar's trailing edge.
                HStack(spacing: 0) {
                    Button(action: { showArchivedPicker = true }) {
                        Image(systemName: "archivebox.circle")
                            .font(.system(size: 20))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
                    .help("Archived chats")
                    Button(action: {
                        if NSEvent.modifierFlags.contains(.option) {
                            store.createNewTemporaryChat()
                        } else {
                            store.createNewChat()
                        }
                    }) {
                        Image(systemName: optionHeld ? "plus.circle.dashed" : "plus.circle")
                            .font(.system(size: 20))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
                    .help("New chat (hold ⌥ for a temporary chat)")
                }
                .padding(.trailing, 4)
            }
            .frame(height: 36)
            .onAppear {
                modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    optionHeld = event.modifierFlags.contains(.option)
                    return event
                }
            }
            .onDisappear {
                if let monitor = modifierMonitor {
                    NSEvent.removeMonitor(monitor)
                    modifierMonitor = nil
                }
            }

            Divider()

           // Filter field: fuzzy-matches chat titles and exactly matches
           // (case-insensitive substring) filenames; contents are never
           // touched, so filtering stays instant. ↑/↓ move the highlight,
           // ↵ opens the highlighted chat, Esc clears the filter. Sits below
           // the divider so it reads as part of the list, not the header.
            // Mode bar: three tab-like buttons for All / By Role / By Directory,
            // with an optional role/directory picker control following them.
            HStack(spacing: 4) {
                modeButton(.all, icon: "list.bullet.circle", help: "All chats")
                modeButton(.role, icon: "theatermasks.circle", help: "By Role")
                modeButton(.directory, icon: "folder.circle", help: "By Directory")
                if store.chatListMode == .role {
                    RoleFilterTag()
                        .onTapGesture { store.showSidebarRolePicker = true }
                } else if store.chatListMode == .directory {
                    DirectoryFilterTag()
                        .onTapGesture { store.showSidebarDirectoryPicker = true }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Filter by name or filename", text: $filterText)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape]) { handleFilterKeyPress($0) }
                    // Fallback for ↵ if the field editor gets it first.
                    .onSubmit(confirmFilterSelection)
                if !filterText.isEmpty {
                    Button(action: clearFilter) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isFiltering {
                            // Filtered: a flat ranked list, no date sections.
                            ForEach(filteredChats) { item in
                                chatRow(for: item)
                                    .id(item.id)
                                if item.id != filteredChats.last?.id {
                                    Divider()
                                }
                            }
                        } else {
                           // A single flat ForEach, NOT nested ForEach(sections) {
                           // ForEach(items) }: with nesting, a chat moving between
                           // sections (e.g. "Today" -> "Yesterday" at day rollover)
                           // jumps between two different ForEach containers, and
                           // LazyVStack reuses the cached row view with its stale
                           // selection highlight. Flat entries with stable ids turn
                           // the move into a plain reorder, which diffs correctly.
                            ForEach(ChatSidebar.sidebarEntries(for: store.visibleChatSummaries)) { entry in
                               switch entry {
                                case .header(let title):
                                    PickerSectionHeader(title: title)
                                case .row(let item, let showsDivider):
                                    chatRow(for: item)
                                    if showsDivider {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
                .onChange(of: filterSelection) { _, newSelection in
                    guard filterKeyboardScroll, let newSelection else { return }
                    filterKeyboardScroll = false
                    proxy.scrollTo(newSelection.id, anchor: .center)
                }
            }
            .onChange(of: filterText) { _, _ in
                filterSelection = filteredChats.first
            }
            // "Filter Chat List…" (⌥⌘F) in the Edit menu.
            .onChange(of: store.chatListFilterFocusRequest) { _, _ in
                filterFocused = true
            }
        }
        .background(.regularMaterial)
        .sheet(item: Binding(
            get: { renamingFilename.map(ChatRenameTarget.init) },
            set: { newValue in renamingFilename = newValue?.filename }
        )) { target in
            RenameChatSheet(
                initialText: renameText,
                onCancel: { renamingFilename = nil },
                onConfirm: { newTitle in
                    store.renameChat(target.filename, to: newTitle)
                    renamingFilename = nil
                }
            )
        }
        .sheet(isPresented: $showArchivedPicker) {
            ArchivedChatsPickerView(onCancel: { showArchivedPicker = false })
        }
        .sheet(item: Binding(
            get: { deletingFilename.map(ChatDeleteTarget.init) },
            set: { newValue in deletingFilename = newValue?.filename }
        )) { target in
            ConfirmActionSheet(
                title: "Delete this chat?",
                message: "This action cannot be undone.",
                confirmLabel: "Delete",
                onCancel: { deletingFilename = nil },
                onConfirm: {
                    store.deleteChat(target.filename)
                    deletingFilename = nil
                }
            )
        }
    }

    // MARK: - Filtering

    private var isFiltering: Bool { !filterText.isEmpty }

    /// The chat list filtered by `filterText` (identity when the filter is
   /// empty).
   private var filteredChats: [ChatSummary] {
        ChatSidebar.filterChats(store.visibleChatSummaries, query: filterText)
   }

    /// Filters the chat list: fuzzy matching on the display title plus exact
    /// (case-insensitive substring) matching on the filename. Chat contents
    /// are never inspected, so this is instant even for large histories.
    /// Fuzzy title matches come first (best match first); filename matches
    /// the fuzzy pass missed follow in list order. `nonisolated` so it can be
    /// unit-tested without the main actor.
    nonisolated static func filterChats(_ summaries: [ChatSummary], query: String) -> [ChatSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return summaries }
        let byTitle = FuzzySearch.rank(summaries, query: q) { [$0.displayTitle] }
        let matched = Set(byTitle.map(\.id))
        let byFilename = summaries.filter {
            !matched.contains($0.id) && $0.filename.range(of: q, options: .caseInsensitive) != nil
        }
        return byTitle + byFilename
    }

    /// Handles ↑/↓/↵/Esc while the filter field is focused.
    private func handleFilterKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            moveFilterSelection(by: -1)
        case .downArrow:
            moveFilterSelection(by: 1)
        case .return:
            confirmFilterSelection()
        case .escape:
            clearFilter()
        default:
            return .ignored
        }
        return .handled
    }

    /// Moves the filter highlight by `delta` positions, clamped to the list.
    private func moveFilterSelection(by delta: Int) {
        let items = filteredChats
        guard !items.isEmpty else { return }
        let current = filterSelection.flatMap { sel in items.firstIndex(where: { $0.id == sel.id }) }
            ?? (delta > 0 ? -1 : 0)
        let newIndex = min(max(current + delta, 0), items.count - 1)
        filterKeyboardScroll = true
        filterSelection = items[newIndex]
    }

    /// ↵ action: opens the highlighted chat (falling back to the first match).
    private func confirmFilterSelection() {
        let items = filteredChats
        guard let target = filterSelection.flatMap({ sel in items.first(where: { $0.id == sel.id }) })
            ?? items.first else { return }
        openChat(target.id)
    }

    /// Opens a chat from the list (tap or ↵): selects it, then clears the
    /// filter and drops field focus so the message input takes over.
    private func openChat(_ filename: String) {
        store.selectChat(filename)
        clearFilter()
    }

    /// Clears the filter text and unfocuses the filter field.
    private func clearFilter() {
        filterText = ""
        filterSelection = nil
        filterFocused = false
    }

    @ViewBuilder
   private func chatRow(for item: ChatSummary) -> some View {
       let role = item.roleName.flatMap { name in
           store.roles.first(where: { $0.name == name })
       }
       ChatRow(
           item: item,
           roleIcon: role?.icon ?? Role.defaultIcon,
           roleAccent: role?.accentColor ?? .accentColor,
           isSelected: isFiltering ? item.id == filterSelection?.id : item.id == store.selectedChatID,
           isUnread: item.hasUnreadActivity && item.id != store.selectedChatID,
           isStreaming: item.isStreaming,
            isBlinking: store.blinkingChatIDs.contains(item.id),
            hidesRoleBadge: store.chatListMode == .role
       )
        .contentShape(Rectangle())
        .onTapGesture {
            openChat(item.id)
        }
        .contextMenu {
            Button("Rename") {
                renamingFilename = item.id
                renameText = store.chatItems.first(where: { $0.id == item.id })?.chat?.title ?? store.chatItems.first(where: { $0.id == item.id })?.cachedName ?? ""
            }
            Button("Archive") {
                store.setChatArchived(item.id, archived: true)
            }
            Button("Delete", role: .destructive) {
                deletingFilename = item.id
            }
            Divider()
            Button("Reveal in Finder") {
                revealInFinder(filename: item.id)
            }
        }
    }

    /// Opens the chat JSON file in Finder, selecting it.
    private func revealInFinder(filename: String) {
       let url = EnvironmentManager.shared.chatsURL.appendingPathComponent(filename)
       NSWorkspace.shared.activateFileViewerSelecting([url])
   }

    // MARK: - Mode bar

    @ViewBuilder
    private func modeButton(_ mode: AppViewModel.ChatListMode, icon: String, help: String) -> some View {
        let isActive = store.chatListMode == mode
        Button(action: { store.setChatListMode(mode) }) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: - Date sectioning

    /// A titled group of chats sharing a calendar day. The sidebar renders one
    /// [`PickerSectionHeader`](src/Views/PickerSectionHeader.swift) per section.
    struct ChatSection: Identifiable {
        let title: String
        let items: [ChatSummary]
        var id: String { title }
    }

    /// Groups chats into day-based sections, preserving the descending
    /// last-activity order within each section. Section titles are "Today",
    /// "Yesterday", then the full date in "Thu 16 Jul 2026" format. Chats
    /// whose sort key is older than the start of the current year are still
    /// grouped by day; the calendar is the user's local time zone (matching
    /// how the chat filename timestamp is generated).
    /// `nonisolated` so it can be unit-tested without the main actor.
    nonisolated static func dateSections(for summaries: [ChatSummary]) -> [ChatSection] {
        guard !summaries.isEmpty else { return [] }
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE d MMM yyyy"

        var buckets: [(start: Date, title: String, items: [ChatSummary])] = []
        var bucketIndex: [Date: Int] = [:]

        for item in summaries {
            let dayStart = calendar.startOfDay(for: item.sortKey)
            let title: String
            if dayStart >= startOfToday {
                title = "Today"
            } else if dayStart >= startOfYesterday {
                title = "Yesterday"
            } else {
                title = dateFormatter.string(from: dayStart)
            }
            if let idx = bucketIndex[dayStart] {
                buckets[idx].items.append(item)
            } else {
                bucketIndex[dayStart] = buckets.count
                buckets.append((dayStart, title, [item]))
            }
        }
        // Sort sections by day descending (most recent first) and the items
        // within each section by sortKey descending. The input is normally
        // pre-sorted, but loading a chat swaps its sortKey from the cached
        // last-activity to the live last-message timestamp; sorting here keeps
        // the section order stable regardless.
        buckets.sort { $0.start > $1.start }
        for i in buckets.indices {
            buckets[i].items.sort { $0.sortKey > $1.sortKey }
        }
        return buckets.map { ChatSection(title: $0.title, items: $0.items) }
    }

    /// One element of the sidebar's flattened list: either a section header
    /// or a chat row. `showsDivider` marks rows that are not the last in
    /// their section, so a separator follows them.
    enum SidebarEntry: Identifiable {
        case header(String)
        case row(ChatSummary, showsDivider: Bool)

        var id: String {
            switch self {
            case .header(let title): return "section:\(title)"
            case .row(let item, _): return item.id
            }
        }
    }

    /// Flattens the day-based sections into a single list of headers and
    /// rows for the sidebar's single-level `ForEach` (see the comment in
    /// `body` for why nesting is avoided). `nonisolated` so it can be
    /// unit-tested without the main actor.
    nonisolated static func sidebarEntries(for summaries: [ChatSummary]) -> [SidebarEntry] {
        dateSections(for: summaries).flatMap { section -> [SidebarEntry] in
            [.header(section.title)] + section.items.enumerated().map { index, item in
                .row(item, showsDivider: index != section.items.indices.last)
            }
        }
    }
}

/// Wrapper to make a filename identifiable for use with `.sheet(item:)`.
private struct ChatRenameTarget: Identifiable {
    let filename: String
    var id: String { filename }
    init(_ filename: String) { self.filename = filename }
}

/// Wrapper to make a filename identifiable for use with `.sheet(item:)`.
private struct ChatDeleteTarget: Identifiable {
    let filename: String
    var id: String { filename }
    init(_ filename: String) { self.filename = filename }
}

private struct ChatRow: View {
    let item: ChatSummary
    /// SF Symbol for the chat's role (resolved from `store.roles`), with a
    /// generic fallback. Only shown when `item.roleName` is non-empty.
    var roleIcon: String = Role.defaultIcon
    /// Accent color for the chat's role badge (resolved from `store.roles`),
    /// falling back to the macOS accent color.
    var roleAccent: Color = .accentColor
    let isSelected: Bool
    var isUnread: Bool = false
    var isStreaming: Bool = false
    /// Pulses the row to flag a tool call awaiting approval in this chat.
   var isBlinking: Bool = false

    /// When true, the role badge is hidden (used in "By Role" mode where the
    /// role is already picked and showing it on every row is redundant).
    var hidesRoleBadge: Bool = false

   @State private var blink: Bool = false

   var body: some View {
       HStack {
           VStack(alignment: .leading, spacing: 2) {
               Text(item.displayTitle)
                   .font(.callout)
                   .lineLimit(1)
               HStack(spacing: 5) {
                    if !hidesRoleBadge, let roleName = item.roleName, !roleName.isEmpty {
                       RoleBadge(name: roleName, icon: roleIcon, accent: roleAccent)
                   }
                    Text(item.filename)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isStreaming {
                ProgressView()
                    .controlSize(.small)
                    .help("Streaming")
            } else if isUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .help("New activity")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.3), value: blink)
        // Drive the pulse with a task scoped to `isBlinking`: when it flips
        // false the task is cancelled and `blink` resets, so the pulsing stops
        // immediately (unlike `repeatForever`, which lingers).
        .task(id: isBlinking) {
            guard isBlinking else { blink = false; return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                if Task.isCancelled { break }
                blink.toggle()
            }
        }
    }

    /// Selected rows keep their solid selection tint; otherwise, while
    /// blinking, pulse an accent-tinted background to draw attention.
    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.15) }
        if isBlinking { return blink ? Color.accentColor.opacity(0.22) : Color.clear }
        return Color.clear
    }
}

/// A compact capsule badge showing a chat's role, with a theatermasks glyph.
/// Sits in the chat row's subtitle line so each chat is identifiable by its
/// role at a glance.
private struct RoleBadge: View {
    let name: String
    let icon: String
    let accent: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(name)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(accent.opacity(0.12), in: Capsule())
        .foregroundStyle(accent)
        .lineLimit(1)
        .fixedSize()
        .help("Role: \(name)")
    }
}

/// A capsule tag showing the currently selected role in "By Role" mode,
/// styled like the role badges in chat rows. Tapping opens the role picker.
private struct RoleFilterTag: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        let role = store.chatListSelectedRole
        let name = store.chatListRole ?? "None"
        let truncated = AppViewModel.truncateRoleName(name)
        HStack(spacing: 3) {
            Image(systemName: role?.icon ?? Role.defaultIcon)
                .font(.system(size: 9, weight: .semibold))
            Text(truncated)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background((role?.accentColor ?? .accentColor).opacity(0.15), in: Capsule())
        .foregroundStyle(role?.accentColor ?? .accentColor)
        .lineLimit(1)
        .help("Filtering by role: \(name). Click to change.")
    }
}

/// A capsule tag showing the currently selected directory in "By Directory"
/// mode. Tapping opens the directory picker.
private struct DirectoryFilterTag: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        let display = store.chatListDirectoryDisplay
        let truncated = AppViewModel.truncateDirectoryPath(display)
        HStack(spacing: 3) {
            Image(systemName: SSHSpec.isSSH(store.chatListDirectory ?? "") ? "network" : "folder")
                .font(.system(size: 9, weight: .semibold))
            Text(truncated)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help("Filtering by directory: \(display). Click to change.")
    }
}
