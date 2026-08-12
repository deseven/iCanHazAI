// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A modal sheet listing archived chats, shown from the sidebar's archive
/// button. Chats can be fuzzy-searched by title and filename, opened for
/// viewing without unarchiving (they stay hidden from the sidebar, like
/// temporary chats), restored to the chat list, or deleted — individually
/// or all at once via the footer's "Delete All" (both deletions ask for
/// confirmation).
///
/// Layout and keyboard navigation are shared with other pickers via
/// [`PickerDialog`](src/Views/PickerDialog.swift:47).
struct ArchivedChatsPickerView: View {
    @EnvironmentObject var store: AppViewModel
    let onCancel: () -> Void

    @State private var query: String = ""
    /// Chat pending an individual delete confirmation.
    @State private var deletingChat: ChatSummary?
    /// Whether the "delete all archived chats" confirmation is shown.
    @State private var confirmingDeleteAll = false

    /// All archived chats, unfiltered — drives the Delete All button so it
    /// stays available (and correctly counted) while a search query hides
    /// part of the list.
    private var allArchived: [ChatSummary] {
        FuzzySearch.rank(store.visibleArchivedSummaries, query: "") { [$0.displayTitle, $0.filename] }
    }
    private var items: [ChatSummary] {
        FuzzySearch.rank(store.visibleArchivedSummaries, query: query) { [$0.displayTitle, $0.filename] }
    }

    /// Projects archived chats into summaries sorted by last activity
    /// (newest first), fuzzy-filtered by display title and filename.
    /// `nonisolated` so it can be unit-tested without the main actor.
    nonisolated static func filter(_ records: [ChatRecord], query: String) -> [ChatSummary] {
        let archived =
            records
            .filter { $0.isArchived && !$0.isTemporary }
            .map(ChatSummary.init)
            .sorted { $0.sortKey > $1.sortKey }
        return FuzzySearch.rank(archived, query: query) { [$0.displayTitle, $0.filename] }
    }

    private var footerExtra: (() -> AnyView)? {
        guard !allArchived.isEmpty else { return nil }
        return {
            AnyView(Button("Delete All", role: .destructive) { confirmingDeleteAll = true })
        }
    }

    var body: some View {
        PickerDialog<ChatSummary>(
            title: "Archived Chats",
            subtitle: "Open a chat to view it without unarchiving, or restore it to the chat list.",
            searchText: $query,
            searchPlaceholder: "Search by name or filename",
            items: items,
            pinnedHeader: nil,
            pinnedItems: [],
            emptyTitle: "No archived chats",
            emptySubtitle: "Archive chats from their context menu in the chat list",
            width: 420,
            rowContent: { item, _ in
                let role = item.roleName.flatMap { name in store.roles.first(where: { $0.name == name }) }
                return AnyView(
                    ArchivedChatRowContent(
                        item: item,
                        role: role,
                        onRestore: { store.setChatArchived(item.id, archived: false) },
                        onDelete: { deletingChat = item }
                    ))
            },
            onSelect: { item in
                store.openArchivedChat(item.id)
                onCancel()
            },
            onCancel: onCancel,
            initialSelection: nil,
            footerExtra: footerExtra
        )
        .sheet(item: $deletingChat) { item in
            ConfirmActionSheet(
                title: "Delete this chat?",
                message: "This action cannot be undone.",
                confirmLabel: "Delete",
                onCancel: { deletingChat = nil },
                onConfirm: {
                    store.deleteChat(item.id)
                    deletingChat = nil
                }
            )
        }
        .sheet(isPresented: $confirmingDeleteAll) {
            ConfirmActionSheet(
                title: "Delete all archived chats?",
                message: "\(allArchived.count) chat(s) will be permanently deleted. This action cannot be undone.",
                confirmLabel: "Delete All",
                onCancel: { confirmingDeleteAll = false },
                onConfirm: {
                    store.deleteAllArchivedChats()
                    confirmingDeleteAll = false
                }
            )
        }
    }
}

/// Inner content of an archived-chat picker row: role icon, title, filename,
/// and restore/delete actions. Padding and the selection highlight are
/// applied by [`PickerDialog`](src/Views/PickerDialog.swift:47).
private struct ArchivedChatRowContent: View {
    let item: ChatSummary
    let role: Role?
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: role?.icon ?? Role.defaultIcon)
                .font(.title3)
                .foregroundStyle(role?.accentColor ?? Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                Text(item.filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onRestore) {
                Image(systemName: "arrow.up.bin")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Restore to the chat list")
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.title3)
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.borderless)
            .help("Delete chat")
        }
    }
}
