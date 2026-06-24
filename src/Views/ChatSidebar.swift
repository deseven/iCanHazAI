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
            // Header with new chat button
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

            // Chat list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.chatItems) { item in
                        ChatRow(
                            item: item,
                            isSelected: item.id == store.selectedChatID,
                            isUnread: item.hasUnreadActivity,
                            isStreaming: item.isStreaming
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.selectChat(item.id)
                        }
                        // Right-click / control-click context menu.
                        .contextMenu {
                            Button("Rename") {
                                renamingFilename = item.id
                                renameText = item.chat.title ?? ""
                            }
                            Button("Delete", role: .destructive) {
                                deletingFilename = item.id
                            }
                        }
                        if item.id != store.chatItems.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .background(.regularMaterial)
        // Rename sheet
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
        // Delete confirmation
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { deletingFilename != nil },
                set: { if !$0 { deletingFilename = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let filename = deletingFilename {
                    store.deleteChat(filename)
                }
                deletingFilename = nil
            }
            Button("Cancel", role: .cancel) {
                deletingFilename = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }
}

/// Wrapper to make a filename identifiable for use with `.sheet(item:)`.
private struct ChatRenameTarget: Identifiable {
    let filename: String
    var id: String { filename }
    init(_ filename: String) { self.filename = filename }
}

private struct ChatRow: View {
    let item: ChatRecord
    let isSelected: Bool
    var isUnread: Bool = false
    var isStreaming: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                Text(item.filename)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }

    /// Derives a display title from the user-defined title, or the first user
    /// message, or "New chat" for empty chats.
    private var displayTitle: String {
        if let title = item.chat.title, !title.isEmpty {
            return title
        }
        if let firstUser = item.chat.messages.first(where: { $0.role == .user }) {
            return String(firstUser.content.prefix(40))
        }
        return "New chat"
    }
}

