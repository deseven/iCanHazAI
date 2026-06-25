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
    /// Whether the left sidebar (chat list) is currently shown.
    @Published var chatListSidebarVisible: Bool = true
    /// Whether the right-hand chat info sidebar is currently shown.
    @Published var chatInfoSidebarVisible: Bool = false
    /// Message id pending an edit action (set by the web view bridge; consumed
    /// by ChatView's edit sheet).
    @Published var pendingEditMessageID: UUID?
    /// Message id pending a delete action (set by the web view bridge;
    /// consumed by ChatView's delete confirmation sheet).
    @Published var pendingDeleteMessageID: UUID?

    // MARK: - Preferences state (cached from ConfigManager)

    /// Cached preferences values, kept in sync with ConfigManager.
    @Published var preferencesDefaultConnection: String? = nil
    @Published var preferencesDefaultRole: String? = "Assistant"
    @Published var preferencesUtilityConnection: String? = nil
    @Published var preferencesMermaidEnabled: Bool = false
    @Published var preferencesKatexEnabled: Bool = false
    @Published var preferencesChatRendererDebugEnabled: Bool = false

    // MARK: - Private

    private let engine = ChatEngine.shared
    private let config = ConfigManager.shared
    private var subscription: Task<Void, Never>?
    /// Whether we've already performed the initial "no connections" check.
    /// Prevents the wizard from popping up again after the user dismisses it.
    private var didCheckInitialConnections = false

    // MARK: - Ctrl+Tab chat switching state

    /// The chat that was selected before the current one, used for quick
    /// single-press Ctrl+Tab toggle.
    private var previousChatID: String?
    /// Whether we are currently in a Ctrl+Tab session (Ctrl is held).
    private var ctrlTabSessionActive = false
    /// The chat that was selected when the Ctrl+Tab session started.
    private var ctrlTabOriginID: String?
    /// Current index into `chatItems` during a Ctrl+Tab cycle.
    private var ctrlTabCurrentIndex: Int = 0
    /// Local event monitor token for intercepting Ctrl+Tab.
    private var keyMonitor: Any?

    // MARK: - Init

    init() {
        AppViewModel.shared = self
        startListening()
        loadPreferences()
        setupKeyboardMonitor()
    }

    deinit {
        subscription?.cancel()
        // The local event monitor is torn down by the system when the app
        // terminates, since AppViewModel is a singleton.
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
            let ls = await config.getChatListSidebarVisible()
            let rs = await config.getChatInfoSidebarVisible()
            let me = await config.getMermaidEnabled()
            let ke = await config.getKatexEnabled()
            let cd = await config.getChatRendererDebugEnabled()
            preferencesDefaultConnection = dc
            preferencesDefaultRole = dr
            preferencesUtilityConnection = uc
            preferencesMermaidEnabled = me
            preferencesKatexEnabled = ke
            preferencesChatRendererDebugEnabled = cd
            if let ls { chatListSidebarVisible = ls }
            if let rs { chatInfoSidebarVisible = rs }
        }
    }

    /// Persists the current sidebar visibility states to config.
    func saveSidebarState() {
        let listVisible = chatListSidebarVisible
        let infoVisible = chatInfoSidebarVisible
        Task {
            await config.setChatListSidebarVisible(listVisible)
            await config.setChatInfoSidebarVisible(infoVisible)
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

    var bindingMermaidEnabled: Binding<Bool> {
        Binding(
            get: { self.preferencesMermaidEnabled },
            set: { newValue in
                self.preferencesMermaidEnabled = newValue
                Task { await self.config.setMermaidEnabled(newValue) }
            }
        )
    }

    var bindingKatexEnabled: Binding<Bool> {
        Binding(
            get: { self.preferencesKatexEnabled },
            set: { newValue in
                self.preferencesKatexEnabled = newValue
                Task { await self.config.setKatexEnabled(newValue) }
            }
        )
    }

    var bindingChatRendererDebugEnabled: Binding<Bool> {
        Binding(
            get: { self.preferencesChatRendererDebugEnabled },
            set: { newValue in
                self.preferencesChatRendererDebugEnabled = newValue
                Task { await self.config.setChatRendererDebugEnabled(newValue) }
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
        if let current = selectedChatID {
            previousChatID = current
        }
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
        // Track the previous chat for Ctrl+Tab quick-switch, but not during
        // a Ctrl+Tab cycling session (to avoid overwriting the origin).
        if !ctrlTabSessionActive, let current = selectedChatID, current != filename {
            previousChatID = current
        }
        selectedChatID = filename
        Task {
            await engine.selectChat(filename: filename)
            await engine.markViewed(filename: filename)
        }
    }

    // MARK: - Keyboard shortcuts

    /// Installs a local event monitor that intercepts Ctrl+Tab for chat
    /// switching and Ctrl release to end the switch session.
    private func setupKeyboardMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return event }
            // Only handle events destined for the main window.
            guard let window = event.window,
                  window == NSApplication.shared.mainWindow else {
                return event
            }
            switch event.type {
            case .keyDown:
                if event.keyCode == 48, // Tab key
                   event.modifierFlags.contains(.control),
                   !event.modifierFlags.contains(.command) {
                    self.handleCtrlTab()
                    return nil // Swallow the event
                }
            case .flagsChanged:
                // Detect when Ctrl is released to end the session.
                if self.ctrlTabSessionActive,
                   !event.modifierFlags.contains(.control) {
                    self.endCtrlTabSession()
                }
            default:
                break
            }
            return event
        }
    }

    /// Handles a single Ctrl+Tab key press.
    private func handleCtrlTab() {
        let items = chatItems
        guard !items.isEmpty else { return }

        if !ctrlTabSessionActive {
            // Start a new Ctrl+Tab session.
            ctrlTabSessionActive = true
            ctrlTabOriginID = selectedChatID

            // First press: go to the previous chat if available, otherwise
            // go to the next chat in the list.
            if let prev = previousChatID,
               let idx = items.firstIndex(where: { $0.id == prev }) {
                ctrlTabCurrentIndex = idx
            } else if let current = selectedChatID,
                      let idx = items.firstIndex(where: { $0.id == current }) {
                ctrlTabCurrentIndex = (idx + 1) % items.count
            } else {
                ctrlTabCurrentIndex = 0
            }
        } else {
            // Continuing the session: cycle to the next chat.
            ctrlTabCurrentIndex = (ctrlTabCurrentIndex + 1) % items.count
        }

        let targetID = items[ctrlTabCurrentIndex].id
        selectedChatID = targetID
        Task {
            await engine.selectChat(filename: targetID)
            await engine.markViewed(filename: targetID)
        }
    }

    /// Ends the Ctrl+Tab session, finalising the switch.
    private func endCtrlTabSession() {
        ctrlTabSessionActive = false
        // Update previousChatID so the next single Ctrl+Tab toggles back.
        if let origin = ctrlTabOriginID, let current = selectedChatID, origin != current {
            previousChatID = origin
        }
        ctrlTabOriginID = nil
    }
}
