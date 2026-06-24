// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SwiftUI

/// The UI bridge. A thin `@MainActor ObservableObject` that subscribes to
/// `ChatEngine` events, mirrors state into `@Published` properties, and
/// forwards user actions to the engine. It owns no business logic.
///
/// Because the engine is a singleton actor, closing a window (and thus
/// deallocating this view model) does not cancel in-flight streams.
@MainActor
final class AppViewModel: ObservableObject {

    // MARK: - Published state (mirrored from the engine)

    @Published var chatItems: [ChatRecord] = []
    @Published var roles: [Role] = []
    @Published var connections: [Connection] = []
    @Published var selectedChatID: String?
    @Published var errorMessage: String?
    /// Whether the currently selected chat is scrolled to the bottom. Updated
    /// by `ChatView`; used to suppress the unread marker when the user is
    /// already looking at the latest content.
    @Published var selectedChatAtBottom: Bool = true
    /// Whether the right-hand chat info sidebar is currently shown.
    @Published var chatInfoSidebarVisible: Bool = false

    // MARK: - Private

    private let engine = ChatEngine.shared
    private var subscription: Task<Void, Never>?

    // MARK: - Init

    init() {
        startListening()
    }

    deinit {
        subscription?.cancel()
    }

    // MARK: - Listening

    private func startListening() {
        subscription = Task { [weak self] in
            guard let self else { return }
            // Ensure the engine is started before subscribing so the initial
            // snapshot reflects loaded data rather than an empty state.
            await self.engine.start()
            let stream = await self.engine.subscribe()
            for await event in stream {
                guard !Task.isCancelled else { return }
                self.apply(event)
            }
        }
    }

    private func apply(_ event: EngineEvent) {
        switch event {
        case .chatsChanged(let records):
            chatItems = records
            // Preserve selection if still present, otherwise pick the first.
            if let selected = selectedChatID, records.contains(where: { $0.id == selected }) {
                // keep selection
            } else {
                selectedChatID = records.first?.id
            }
            // If the user is viewing the selected chat and is scrolled to the
            // bottom, suppress the unread marker — they've already seen the
            // latest content (e.g. a stream that just finished).
            if selectedChatAtBottom,
               let selected = selectedChatID,
               let item = records.first(where: { $0.id == selected }),
               item.hasUnreadActivity,
               !item.isStreaming {
                Task { await engine.markViewed(filename: selected) }
            }
        case .rolesChanged(let roles):
            self.roles = roles
        case .connectionsChanged(let connections):
            self.connections = connections
        case .error(let message):
            errorMessage = message
        }
    }

    // MARK: - Derived helpers

    /// Returns the currently selected chat record, if any.
    var selectedChatItem: ChatRecord? {
        chatItems.first(where: { $0.id == selectedChatID })
    }

    /// Whether the selected chat currently has an active streaming request.
    var isStreaming: Bool {
        selectedChatItem?.isStreaming ?? false
    }

    /// Whether the selected chat has a valid connection chosen.
    var selectedChatHasConnection: Bool {
        guard let item = selectedChatItem,
              let connectionID = item.chat.connection,
              !connectionID.isEmpty,
              connections.contains(where: { $0.id == connectionID }) else { return false }
        return true
    }

    /// Approximate token count for the currently selected chat, updated live
    /// as content streams in.
    var selectedChatTokenCount: Int {
        selectedChatItem?.tokenCount ?? 0
    }

    // MARK: - Actions (forwarders to the engine)

    func sendMessage(_ text: String) {
        guard let filename = selectedChatID else { return }
        Task { await engine.sendMessage(filename: filename, text: text) }
    }

    func retryLastMessage() {
        guard let filename = selectedChatID else { return }
        Task { await engine.retryLastMessage(filename: filename) }
    }

    func stopStreaming() {
        guard let filename = selectedChatID else { return }
        Task { await engine.stopStreaming(filename: filename) }
    }

    /// Edits a message's plain-text content in the selected chat.
    func editMessage(messageID: UUID, to newText: String) {
        guard let filename = selectedChatID else { return }
        Task { await engine.editMessage(filename: filename, messageID: messageID, newText: newText) }
    }

    /// Deletes a single message from the selected chat's message tree.
    func deleteMessage(messageID: UUID) {
        guard let filename = selectedChatID else { return }
        Task { await engine.deleteMessage(filename: filename, messageID: messageID) }
    }

    func createNewChat() {
        Task {
            let filename = await engine.createNewChat()
            selectedChatID = filename
        }
    }

    func deleteChat(_ filename: String) {
        Task { await engine.deleteChat(filename: filename) }
    }

    func renameChat(_ filename: String, to newTitle: String) {
        Task { await engine.renameChat(filename: filename, to: newTitle) }
    }

    func setConnection(_ connectionID: String) {
        guard let filename = selectedChatID else { return }
        Task { await engine.setConnection(filename: filename, connectionID: connectionID) }
    }

    func setRole(_ roleName: String) {
        guard let filename = selectedChatID else { return }
        Task { await engine.setRole(filename: filename, roleName: roleName) }
    }

    /// Selects a chat, prunes other empty chats, and clears its unread marker.
    func selectChat(_ filename: String) {
        selectedChatID = filename
        Task {
            await engine.selectChat(filename: filename)
            await engine.markViewed(filename: filename)
        }
    }
}
