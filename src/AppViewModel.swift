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
    /// Cheap, message-free projection of `chatItems` for the sidebar. The
    /// sidebar observes this instead of `chatItems` so a busy chat's per-token
    /// emits don't force it to re-diff full message arrays for every chat.
    /// Derived in `apply(.chatsChanged)` from `chatItems`.
    @Published var chatSummaries: [ChatSummary] = []
    @Published var roles: [Role] = []
    @Published var connections: [Connection] = []
    @Published var mcps: [MCPServer] = []
    /// Live MCP configuration status, mirrored from the engine. Drives the
    /// configuration overlay. The overlay observes this and adds a 1-second
    /// display delay after configuration completes.
    @Published var mcpConfiguration: MCPConfigurationState = .empty
    @Published var selectedChatID: String? {
        didSet {
            // Once the user opens a chat awaiting approval, the renderer shows
            // its Allow/Deny buttons directly — no need to keep blinking it.
            if let id = selectedChatID { blinkingChatIDs.remove(id) }
        }
    }
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
    /// Tool-call id pending a deny-reason sheet (set by the web view bridge
    /// when the user presses Deny; consumed by ChatView's deny sheet).
    @Published var pendingDenyToolCallID: String?
    /// Filenames of chats awaiting tool-call approval that aren't currently
    /// selected. Each blinks in the sidebar to draw the user's attention.
    @Published var blinkingChatIDs: Set<String> = []
    /// Active dock-bounce request id (if any), cancelled when the window
    /// becomes active or all approvals are resolved.
    private var attentionRequestID: Int? = nil
    /// Observer token for `didBecomeActive` (to cancel the dock bounce).
    private var didBecomeActiveObserver: NSObjectProtocol?

    // MARK: - Preferences state (cached from ConfigManager)

    /// Cached preferences values, kept in sync with ConfigManager.
    @Published var preferencesDefaultConnection: String? = nil
    @Published var preferencesDefaultRole: String? = "Assistant"
    @Published var preferencesUtilityConnection: String? = nil
    @Published var preferencesMermaidEnabled: Bool = false
    @Published var preferencesKatexEnabled: Bool = false
    @Published var preferencesAppDebugEnabled: Bool = false
    @Published var preferencesChatRendererDebugEnabled: Bool = false
    @Published var preferencesExpandThinking: Bool = false
    @Published var preferencesExpandToolUse: Bool = false

    // MARK: - Private

    private let engine = ChatEngine.shared
    private let config = ConfigManager.shared
    private var subscription: Task<Void, Never>?
    /// Weak reference to the active web view model, set when
    /// `ChatWebView.bind(store:)` is called. Used to push snapshots
    /// synchronously in `apply(.chatsChanged)` so the web view reflects
    /// tool-call state before the engine proceeds to execute the tool.
    weak var chatWebViewModel: ChatWebViewModel?
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
        // Cancel any dock bounce once the user activates the app/window.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelAttention() }
        }
    }

    deinit {
        subscription?.cancel()
        // `deinit` is nonisolated; the view model is `@MainActor`, so reach the
        // observer token from the main actor to remove it safely.
        MainActor.assumeIsolated {
            if let obs = didBecomeActiveObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }
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
            let ad = await config.getAppDebugEnabled()
            let cd = await config.getChatRendererDebugEnabled()
            let et = await config.getExpandThinking()
            let eu = await config.getExpandToolUse()
            preferencesDefaultConnection = dc
            preferencesDefaultRole = dr
            preferencesUtilityConnection = uc
            preferencesMermaidEnabled = me
            preferencesKatexEnabled = ke
            preferencesAppDebugEnabled = ad
            preferencesChatRendererDebugEnabled = cd
            preferencesExpandThinking = et
            preferencesExpandToolUse = eu
            DebugLogger.setEnabled(ad)
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

    var bindingAppDebugEnabled: Binding<Bool> {
        Binding(
            get: { self.preferencesAppDebugEnabled },
            set: { newValue in
                self.preferencesAppDebugEnabled = newValue
                DebugLogger.setEnabled(newValue)
                Task { await self.config.setAppDebugEnabled(newValue) }
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

    var bindingExpandThinking: Binding<Bool> {
        Binding(
            get: { self.preferencesExpandThinking },
            set: { newValue in
                self.preferencesExpandThinking = newValue
                Task { await self.config.setExpandThinking(newValue) }
            }
        )
    }

    var bindingExpandToolUse: Binding<Bool> {
        Binding(
            get: { self.preferencesExpandToolUse },
            set: { newValue in
                self.preferencesExpandToolUse = newValue
                Task { await self.config.setExpandToolUse(newValue) }
            }
        )
    }

    // MARK: - Listening

    private func startListening() {
        subscription = Task { [weak self] in
            guard let self else { return }
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
            chatSummaries = records.map(ChatSummary.init)
            if let selected = selectedChatID, records.contains(where: { $0.id == selected }) {
                // Keep selection — if the chat is not loaded, load it so the
                // UI can display its messages. This handles the initial
                // auto-selection on startup (where chats start unloaded).
                if records.first(where: { $0.id == selected })?.chat == nil {
                    Task { await engine.ensureChatLoaded(filename: selected) }
                }
            } else {
                // The selected chat vanished (deleted) or none was selected
                // yet (startup). Fall back to the first chat and route through
                // `selectChat` so the engine's `selectedFilename` stays in sync
                // with `selectedChatID` — otherwise the engine can't tell this
                // chat is being viewed and would release it.
                selectedChatID = records.first?.id
                if let first = selectedChatID {
                    Task { await engine.selectChat(filename: first) }
                }
            }
            // Suppress the unread marker if the user is already viewing the
            // selected chat scrolled to the bottom.
            if selectedChatAtBottom,
               let selected = selectedChatID,
               let item = records.first(where: { $0.id == selected }),
               item.hasUnreadActivity,
               !item.isStreaming {
                Task { await engine.markViewed(filename: selected) }
            }
            // Push the snapshot synchronously in the same main-actor turn so
            // the web view reflects tool-call state before the engine resumes
            // to execute the tool.
            chatWebViewModel?.pushSnapshot()
        case .rolesChanged(let roles):
            self.roles = roles
            refreshPreferences()
        case .connectionsChanged(let connections):
            self.connections = connections
            refreshPreferences()
            if !didCheckInitialConnections {
                didCheckInitialConnections = true
                if connections.isEmpty {
                    ConnectionWizardView.show(onFinish: { self.refreshAfterWizard() })
                }
            }
        case .mcpsChanged(let mcps):
            self.mcps = mcps
        case .mcpConfiguration(let state):
            mcpConfiguration = state
        case .configChanged:
            refreshPreferences()
        case .toolApprovalRequested(let filename, _):
            // Blink the chat in the sidebar if the user isn't already viewing
            // it (otherwise the renderer shows the Allow/Deny buttons).
            if filename != selectedChatID {
                blinkingChatIDs.insert(filename)
            }
            requestAttentionIfNeeded()
        case .toolApprovalResolved(let filename, _):
            blinkingChatIDs.remove(filename)
            if blinkingChatIDs.isEmpty {
                cancelAttention()
            }
        case .error(let message):
            errorMessage = message
        }
    }

    // MARK: - Tool-call approval attention

    /// Bounces the dock icon if the window doesn't exist or isn't key/front,
    /// so the user notices a tool call awaiting approval. `.criticalRequest`
    /// repeats until cancelled (on app activation or once resolved).
    private func requestAttentionIfNeeded() {
        let mainWindow = NSApp.mainWindow
        let windowKey = mainWindow?.isKeyWindow ?? false
        let needsAttention = !NSApp.isActive || mainWindow == nil || !windowKey
        guard needsAttention, attentionRequestID == nil else { return }
        attentionRequestID = NSApp.requestUserAttention(.criticalRequest)
    }

    private func cancelAttention() {
        if let id = attentionRequestID {
            NSApp.cancelUserAttentionRequest(id)
            attentionRequestID = nil
        }
    }

    /// Resolves a pending tool-call approval. Called from the web view bridge
    /// when the user presses Allow (and from the deny sheet on confirm).
    func allowToolCall(callID: String) {
        Task { await engine.resolveToolCallApproval(callID: callID, approval: .allow) }
    }

    /// Denies a pending tool-call approval with an (optional) reason.
    func denyToolCall(callID: String, reason: String) {
        Task { await engine.resolveToolCallApproval(callID: callID, approval: .deny(reason: reason)) }
    }

    // MARK: - Wizard completion

    /// Called after the connection wizard finishes. Refreshes preferences and,
    /// if the app has no default/utility connection set, asks the user whether
    /// to use the just-created connection for those roles.
    func refreshAfterWizard() {
        refreshPreferences()
        Task {
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
              let connectionID = item.chat?.connection,
              !connectionID.isEmpty,
              connections.contains(where: { $0.id == connectionID }) else { return false }
        return true
    }

    /// Whether the last message in the selected chat is from the user. Used to
    /// allow pressing send with empty input to trigger an assistant reply on
    /// that last user message (e.g. after the agent's answer was removed).
    var selectedChatLastMessageIsFromUser: Bool {
        guard let item = selectedChatItem else { return false }
        return item.chat?.messages.last?.role == .user
    }

    /// Whether the selected chat's connection supports image input. Used to
    /// gate the attach button and drag-and-drop in the input area.
    var selectedChatSupportsImageInput: Bool {
        guard let item = selectedChatItem,
              let connectionID = item.chat?.connection,
              let conn = connections.first(where: { $0.id == connectionID }) else { return false }
        return conn.imageInput
    }

    /// Token usage for the currently selected chat, as reported by the
    /// provider on the last assistant response. Nil until the first
    /// response with usage completes.
    var selectedChatTokenCount: Int? {
        selectedChatItem?.tokenCount
    }

    // MARK: - Actions (forwarders to the engine)

    func sendMessage(_ text: String, pendingImages: [PendingImageAttachment] = []) {
        guard let filename = selectedChatID else { return }
        Task { await engine.sendMessage(filename: filename, text: text, pendingImages: pendingImages) }
    }

    func retryLastMessage() {
        guard let filename = selectedChatID else { return }
        Task { await engine.retryLastMessage(filename: filename) }
    }

    func stopStreaming() {
        guard let filename = selectedChatID else { return }
        Task { await engine.stopStreaming(filename: filename) }
    }

    /// Opens the in-chat search bar (Cmd-F). No-op when no chat is selected.
    /// Focuses the web view and asks the renderer to show its search form.
    func startSearchInChat() {
        guard selectedChatItem != nil else { return }
        chatWebViewModel?.startSearch()
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
            // Route through `selectChat` so the engine's `selectedFilename`
            // tracks the new chat (and the previously-viewed chat is released).
            await engine.selectChat(filename: filename)
            await engine.markViewed(filename: filename)
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

    /// Updates the set of active MCP servers for the selected chat.
    func setActiveMCPs(_ names: [String]?) {
        guard let filename = selectedChatID else { return }
        Task { await engine.setActiveMCPs(filename: filename, names: names) }
    }

    /// Triggers a full MCP configuration pass ("File > Reload MCPs…"). Resets
    /// all configured MCPs and their tools cache, then re-connects and
    /// re-queries every server. The overlay is shown while in progress.
    func reloadMCPs() {
        Task { await engine.configureMCPs() }
    }

    /// Selects a chat, prunes other empty chats, and clears its unread marker.
    func selectChat(_ filename: String) {
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
            ctrlTabSessionActive = true
            ctrlTabOriginID = selectedChatID

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
        if let origin = ctrlTabOriginID, let current = selectedChatID, origin != current {
            previousChatID = origin
        }
        ctrlTabOriginID = nil
    }
}
