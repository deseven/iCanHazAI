// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct ChatView: View {
    @EnvironmentObject var store: AppViewModel
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Custom header bar with pickers — lives inside ChatView so it
            // naturally shrinks when the inspector panel is open.
            ChatHeaderBar {
                store.chatInfoSidebarVisible.toggle()
            }

            Divider()

            // Chat content: rendered by the persistent web view.
            ChatWebView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Input
            HStack(spacing: 8) {
                TextEditor(text: $inputText)
                    .font(.body)
                    .frame(minHeight: 36, maxHeight: 100)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .focused($isInputFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            // Let the default newline happen
                            return .ignored
                        }
                        send()
                        return .handled
                    }

                Button(action: handleSendOrStop) {
                    Image(systemName: store.isStreaming ? "stop.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(sendDisabled)
                .help(store.isStreaming ? "Stop" : "Send")
            }
            .padding(12)
        }
        .onAppear {
            isInputFocused = true
        }
        .onChange(of: store.selectedChatID) { _, _ in
            inputText = ""
            isInputFocused = true
        }
        // Edit sheet — driven by the web view bridge setting
        // `pendingEditMessageID`.
        .sheet(item: Binding(
            get: { store.pendingEditMessageID.map { PendingID(id: $0) } },
            set: { if $0 == nil { store.pendingEditMessageID = nil } }
        )) { pending in
            if let item = store.selectedChatItem,
               let msg = item.chat.messages.first(where: { $0.id == pending.id }) {
                EditMessageSheet(
                    initialText: msg.content,
                    onCancel: { store.pendingEditMessageID = nil },
                    onConfirm: { newText in
                        store.editMessage(messageID: pending.id, to: newText)
                        store.pendingEditMessageID = nil
                    }
                )
            }
        }
        // Delete confirmation — driven by the web view bridge setting
        // `pendingDeleteMessageID`.
        .sheet(item: Binding(
            get: { store.pendingDeleteMessageID.map { PendingID(id: $0) } },
            set: { if $0 == nil { store.pendingDeleteMessageID = nil } }
        )) { pending in
            ConfirmActionSheet(
                title: "Delete this message?",
                message: "This action cannot be undone.",
                confirmLabel: "Delete",
                onCancel: { store.pendingDeleteMessageID = nil },
                onConfirm: {
                    store.deleteMessage(messageID: pending.id)
                    store.pendingDeleteMessageID = nil
                }
            )
        }
    }

    /// Whether the send/stop button should be disabled.
    private var sendDisabled: Bool {
        if store.isStreaming { return false }
        // Disallow sending when there's no usable connection selected.
        if !store.selectedChatHasConnection { return true }
        return inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A header bar that sits at the top of the chat content area (below the
    /// window titlebar). By living inside the content, it naturally shifts left
    /// when the inspector panel opens — unlike toolbar items which span the full
    /// titlebar width regardless of the inspector.
    private struct ChatHeaderBar: View {
        @EnvironmentObject var store: AppViewModel
        let onToggleInfo: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                Picker("Connection", selection: Binding(
                    get: { store.selectedChatItem?.chat.connection ?? "" },
                    set: { store.setConnection($0) }
                )) {
                    Text("No connection").tag("")
                    ForEach(store.connections) { connection in
                        Text(connection.displayName).tag(connection.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220)

                Picker("Role", selection: Binding(
                    get: { store.selectedChatItem?.chat.role ?? "" },
                    set: { store.setRole($0) }
                )) {
                    Text("No role").tag("")
                    ForEach(store.roles) { role in
                        HStack {
                            Text(role.name)
                            if role.isDefault {
                                Image(systemName: "checkmark.seal")
                            }
                        }
                        .tag(role.name)
                    }
                }
                .labelsHidden()
                .frame(width: 180)

                Spacer()

                Button(action: onToggleInfo) {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(store.chatInfoSidebarVisible ? "Hide chat info" : "Show chat info")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
    }

    /// Routes the button press to either stop (while streaming) or send.
    private func handleSendOrStop() {
        if store.isStreaming {
            store.stopStreaming()
            return
        }
        send()
    }

    private func send() {
        // Disallow sending when no connection is selected instead of silently dropping.
        guard store.selectedChatHasConnection else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.isStreaming else { return }
        inputText = ""
        store.sendMessage(text)
    }
}

/// A wrapper that makes a `UUID` `Identifiable` so it can drive `.sheet(item:)`.
private struct PendingID: Identifiable {
    let id: UUID
}
