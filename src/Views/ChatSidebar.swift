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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.headline)
                    .padding(.leading, 12)
                Spacer()
                Button(action: { store.createNewChat() }) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 4)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
                .help("New chat")
            }
            .frame(height: 36)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    let sections = ChatSidebar.dateSections(for: store.chatSummaries)
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        PickerSectionHeader(title: section.title)
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            let role = item.roleName.flatMap { name in
                                store.roles.first(where: { $0.name == name })
                            }
                            ChatRow(
                                item: item,
                                roleIcon: role?.icon ?? Role.defaultIcon,
                                roleAccent: role?.accentColor ?? .accentColor,
                                isSelected: item.id == store.selectedChatID,
                                isUnread: item.hasUnreadActivity && item.id != store.selectedChatID,
                                isStreaming: item.isStreaming,
                                isBlinking: store.blinkingChatIDs.contains(item.id)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.selectChat(item.id)
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
                            if index != section.items.indices.last {
                                Divider()
                            }
                        }
                    }
                }
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

    /// Opens the chat JSON file in Finder, selecting it.
    private func revealInFinder(filename: String) {
        let url = EnvironmentManager.shared.chatsURL.appendingPathComponent(filename)
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

    @State private var blink: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let roleName = item.roleName, !roleName.isEmpty {
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

