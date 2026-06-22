// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct ChatSidebar: View {
    @EnvironmentObject var store: AppViewModel

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
                        if item.id != store.chatItems.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .background(.regularMaterial)
    }
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

    /// Derives a display title from the first user message, if any.
    private var displayTitle: String {
        if let firstUser = item.chat.messages.first(where: { $0.role == .user }) {
            return String(firstUser.content.prefix(40))
        }
        return "New chat"
    }
}
