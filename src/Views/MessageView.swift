// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import Textual

struct MessageView: View {
    let message: ChatMessage
    @EnvironmentObject private var store: AppViewModel
    @State private var isHovering = false

    /// Drives the edit sheet.
    @State private var isEditing = false
    /// Drives the delete confirmation dialog.
    @State private var isConfirmingDelete = false

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
                HStack(spacing: 6) {
                    Text(roleLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // On hover, show the timestamp (and connection name for
                    // assistant messages) to the right of the participant name.
                    if isHovering {
                        Text(hoverDetail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .transition(.opacity)
                    }

                    Spacer(minLength: 4)

                    // Action buttons live in the top-right corner, opposite the
                    // speaker name and details. The container is always present
                    // (reserving layout space) but only visible while hovering,
                    // so the content below doesn't shift when the buttons appear.
                    HStack(spacing: 2) {
                        MessageActionButton(systemName: "doc.on.doc", help: "Copy") {
                            copyContent()
                        }
                        MessageActionButton(systemName: "pencil", help: "Edit") {
                            isEditing = true
                        }
                        MessageActionButton(systemName: "trash", help: "Delete", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
                }

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .sheet(isPresented: $isEditing) {
            EditMessageSheet(
                initialText: message.content,
                onCancel: { isEditing = false },
                onConfirm: { newText in
                    store.editMessage(messageID: message.id, to: newText)
                    isEditing = false
                }
            )
        }
        .sheet(isPresented: $isConfirmingDelete) {
            ConfirmActionSheet(
                title: "Delete this message?",
                message: "This action cannot be undone.",
                confirmLabel: "Delete",
                onCancel: { isConfirmingDelete = false },
                onConfirm: {
                    store.deleteMessage(messageID: message.id)
                    isConfirmingDelete = false
                }
            )
        }
    }

    /// Copies the original plain-text content (not the rendered markdown) to
    /// the system pasteboard.
    private func copyContent() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(message.content, forType: .string)
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

    /// Text shown on hover next to the participant name: the message timestamp,
    /// and for assistant messages the connection that produced the response.
    private var hoverDetail: String {
        var parts = [timestampText]
        if message.role == .assistant, let conn = message.connectionName, !conn.isEmpty {
            parts.append("via \(conn)")
        }
        return parts.joined(separator: " · ")
    }

    /// Formats the message timestamp for display (date + time), following the
    /// user's system locale and date/time preferences.
    private var timestampText: String {
        message.timestamp.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A compact, borderless icon button used for the per-message hover actions.
private struct MessageActionButton: View {
    let systemName: String
    let help: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.caption)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// A multiline plain-text editing modal for editing a message's content.
private struct EditMessageSheet: View {
    let initialText: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit message")
                .font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120, maxHeight: 240)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .focused($isFocused)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onConfirm(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            text = initialText
            isFocused = true
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
