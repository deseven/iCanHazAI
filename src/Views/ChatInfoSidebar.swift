// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The right info panel. Shown inline next to ChatView when chatInfoSidebarVisible
/// is true. Styled to match the left ChatSidebar: a headline header bar, a
/// divider, and a .regularMaterial background.
struct ChatInfoSidebar: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat Info")
                    .font(.headline)
                    .padding(.leading, 12)
                Spacer()
            }
            .frame(height: 36)

            Divider()

            if let item = store.selectedChatItem {
                Form {
                    Section("Chat") {
                        InfoCell(label: "Name", value: displayName(for: item))
                    }
                    Section("Timestamps") {
                        InfoCell(label: "Created", value: formatted(createdDate(for: item)))
                        InfoCell(label: "Updated", value: formatted(updatedDate(for: item)))
                    }
                    Section("Usage") {
                        LabeledContent("Tokens", value: "\(item.tokenCount)")
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
                Text("No chat selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .background(.regularMaterial)
    }

    // MARK: - Helpers

    private func displayName(for item: ChatRecord) -> String {
        if let title = item.chat.title, !title.isEmpty {
            return title
        }
        if let firstUser = item.chat.messages.first(where: { $0.role == .user }) {
            let trimmed = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(60))
            }
        }
        return "New chat"
    }

    private func createdDate(for item: ChatRecord) -> Date {
        item.chat.messages.first?.timestamp ?? item.createdAt
    }

    private func updatedDate(for item: ChatRecord) -> Date {
        item.chat.messages.last?.timestamp ?? item.createdAt
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A stacked label+value cell: label on the first line, value (possibly multiline)
/// below it. Never breaks the layout regardless of value length.
private struct InfoCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}
