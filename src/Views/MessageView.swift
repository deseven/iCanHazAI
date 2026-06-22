// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import Textual

struct MessageView: View {
    let message: ChatMessage
    @EnvironmentObject private var store: AppViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Role avatar
            Image(systemName: avatarIcon)
                .font(.title3)
                .foregroundStyle(avatarColor)
                .frame(width: 28, height: 28)
                .background(avatarColor.opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(roleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Thinking block (collapsible)
                if let thinking = message.thinking, !thinking.isEmpty {
                    ThinkingBlock(text: thinking)
                }

                // Content
                if !message.content.isEmpty {
                    StructuredText(markdown: message.content)
                        .textual.textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Error block with retry button
                if let error = message.error, !error.isEmpty {
                    ErrorBlock(text: error, isStreaming: store.isStreaming) {
                        store.retryLastMessage()
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private var avatarIcon: String {
        switch message.role {
        case .system: return "gearshape"
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        }
    }

    private var avatarColor: Color {
        switch message.role {
        case .system: return .gray
        case .user: return .blue
        case .assistant: return .purple
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .system: return "System"
        case .user: return "You"
        case .assistant: return "Assistant"
        }
    }
}

private struct ThinkingBlock: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The whole header (icon + label + chevron) is clickable to toggle.
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Label("Thinking", systemImage: "brain.head.profile")
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                    .padding(.top, 4)
            }
        }
    }
}

private struct ErrorBlock: View {
    let text: String
    let isStreaming: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color.red.opacity(0.12))
            .cornerRadius(6)

            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isStreaming)
        }
    }
}
