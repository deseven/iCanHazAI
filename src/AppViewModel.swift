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

    /// Shared reference set by the app on launch so that auxiliary windows
    /// (e.g. Preferences) can reach the view model without walking the
    /// responder chain.
    @MainActor static weak var shared: AppViewModel?

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

    // MARK: - Preferences state (cached from ConfigManager)

    /// Cached preferences values, kept in sync with ConfigManager.
    @Published var preferencesDefaultConnection: String? = nil
    @Published var preferencesDefaultRole: String? = "Assistant"
    @Published var preferencesUtilityConnection: String? = nil

    // MARK: - Private

    private let engine = ChatEngine.shared
    private let config = ConfigManager.shared
    private var subscription: Task<Void, Never>?
    /// Whether we've already performed the initial "no connections" check.
    /// Prevents the wizard from popping up again after the user dismisses it.
    private var didCheckInitialConnections = false

    // MARK: - Init

    init() {
        AppViewModel.shared = self
        startListening()
        loadPreferences()
    }

    deinit {
        subscription?.cancel()
    }

    // MARK: - Preferences sync

    /// Loads current preferences from the config manager into the cached
    /// `@Published` properties.
    private func loadPreferences() {
        Task {
            await config.load()
            let dc = await config.getDefaultConnection()
            let dr = await config.getDefaultRole()
            let uc = await config.getUtilityConnection()
            preferencesDefaultConnection = dc
            preferencesDefaultRole = dr
            preferencesUtilityConnection = uc
        }
    }

    /// Reloads preferences (call after FSEvents changes to connections/roles).
    func refreshPreferences() {
        loadPreferences()
    }

    // MARK: - Preference bindings (two-way, write-through to ConfigManager)

    var bindingDefaultConnection: Binding<String?> {
        Binding(
            get: { self.preferencesDefaultConnection },
            set: { newValue in
                self.preferencesDefaultConnection = newValue
                Task { await self.config.setDefaultConnection(newValue) }
            }
        )
    }

    var bindingDefaultRole: Binding<String?> {
        Binding(
            get: { self.preferencesDefaultRole },
            set: { newValue in
                self.preferencesDefaultRole = newValue
                Task { await self.config.setDefaultRole(newValue) }
            }
        )
    }

    var bindingUtilityConnection: Binding<String?> {
        Binding(
            get: { self.preferencesUtilityConnection },
            set: { newValue in
                self.preferencesUtilityConnection = newValue
                Task { await self.config.setUtilityConnection(newValue) }
            }
        )
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
            refreshPreferences()
        case .connectionsChanged(let connections):
            self.connections = connections
            refreshPreferences()
            // On the first connections snapshot, if there are no connections
            // at all, automatically open the New Connection wizard.
            if !didCheckInitialConnections {
                didCheckInitialConnections = true
                if connections.isEmpty {
                    ConnectionWizardView.show(onFinish: { self.refreshAfterWizard() })
                }
            }
        case .error(let message):
            errorMessage = message
        }
    }

    // MARK: - Wizard completion

    /// Called after the connection wizard finishes. Refreshes preferences and,
    /// if the app has no default/utility connection set, asks the user whether
    /// to use the just-created connection for those roles.
    func refreshAfterWizard() {
        refreshPreferences()
        Task {
            // Give the engine a moment to pick up the new connection file via
            // FSEvents before reading the config.
            try? await Task.sleep(for: .milliseconds(300))
            await promptForDefaultIfNeeded()
            await promptForUtilityIfNeeded()
        }
    }

    /// If no default connection is configured, asks the user whether to set
    /// the most recently created connection as the default.
    private func promptForDefaultIfNeeded() async {
        let dc = await config.getDefaultConnection()
        guard dc == nil else { return }
        guard let conn = connections.last else { return }
        await MainActor.run {
            self.askToSetConnection(
                title: "Set Default Connection?",
                message: "No default connection is set. Use “\(conn.displayName)” as the default connection for new chats?",
                connectionID: conn.id,
                setter: { self.setDefaultConnection($0) }
            )
        }
    }

    /// If no utility connection is configured, asks the user whether to set
    /// the most recently created connection as the utility connection.
    private func promptForUtilityIfNeeded() async {
        let uc = await config.getUtilityConnection()
        guard uc == nil else { return }
        guard let conn = connections.last else { return }
        await MainActor.run {
            self.askToSetConnection(
                title: "Set Utility Connection?",
                message: "No utility connection is set. Use “\(conn.displayName)” for utility tasks such as chat name generation?",
                connectionID: conn.id,
                setter: { self.setUtilityConnection($0) }
            )
        }
    }

    /// Presents a yes/no alert asking whether to assign a connection to a role.
    private func askToSetConnection(
        title: String,
        message: String,
        connectionID: String,
        setter: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Set as Default")
        alert.addButton(withTitle: "Not Now")
        // Repurpose the first button title per caller context.
        alert.buttons.first?.title = "Use This Connection"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            setter(connectionID)
        }
    }

    private func setDefaultConnection(_ id: String) {
        preferencesDefaultConnection = id
        Task { await config.setDefaultConnection(id) }
    }

    private func setUtilityConnection(_ id: String) {
        preferencesUtilityConnection = id
        Task { await config.setUtilityConnection(id) }
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
