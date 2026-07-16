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

    /// The mode the role picker sheet operates in.
    enum RolePickerMode: Equatable {
        /// Creating a brand-new chat: picking a role creates the chat.
        case newChat
        /// Assigning a role to an existing chat whose role is missing. Carries
        /// the filename of the chat to update.
        case assignToExisting(filename: String)
    }

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
    @Published var prompts: [Prompt] = []
    @Published var connections: [Connection] = []
    @Published var mcps: [MCPServer] = []
    @Published var selectedChatID: String? {
        didSet {
            // Once the user opens a chat awaiting approval, the renderer shows
            // its Allow/Deny buttons directly — no need to keep blinking it.
            if let id = selectedChatID { blinkingChatIDs.remove(id) }
            // Chat-related sheets (role picker, workdir picker, pending
            // edit/delete/deny) only apply to the chat that was active when
            // they were opened. When the active chat changes they're no longer
            // applicable, so dismiss them. This also fixes a startup race where
            // a role-picker for a chat whose role failed to load could linger
            // over a freshly-opened Configurator chat (e.g. via "Fix with
            // Configurator" from the config-errors sheet).
            if Self.chatChanged(from: oldValue, to: selectedChatID) {
                showRolePicker = false
                showWorkdirPicker = false
                pendingEditMessageID = nil
                pendingDeleteMessageID = nil
                pendingDenyToolCallID = nil
            }
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
    /// Whether the role picker sheet is currently shown (for a new chat or to
    /// assign a role to an existing chat whose role is missing).
    @Published var showRolePicker: Bool = false
    /// The mode the role picker sheet is operating in: creating a brand-new
    /// chat, or assigning a role to an existing chat whose role is missing.
    @Published var rolePickerMode: RolePickerMode = .newChat
    /// Filenames for which the user dismissed the role-assignment picker, so
    /// it isn't immediately re-shown on the next state emit. Cleared when the
    /// chat is re-selected (so re-opening re-prompts) or when a role is
    /// assigned.
    @Published var dismissedRoleAssignmentFor: Set<String> = []
    /// Current configuration errors (mirrored from the engine). Drives the
    /// title-bar warning button and the errors sheet.
    @Published var configErrors: [ConfigError] = []
    /// Whether the configuration-errors sheet is currently shown.
    @Published var showConfigErrors: Bool = false
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
    /// User-managed list of working directories offered in the per-chat
    /// directory picker. Mirrored from `config.toml` `[general].working_directories`.
    @Published var workingDirectories: [String] = []
    /// Whether the working-directory picker sheet is currently shown.
    @Published var showWorkdirPicker: Bool = false

    // MARK: - Private

    private let engine = ChatEngine.shared
    private let config = ConfigManager.shared
    private var subscription: Task<Void, Never>?
    /// Weak reference to the active web view model, set when
    /// `ChatWebView.bind(store:)` is called. Used to push snapshots
    /// synchronously in `apply(.chatsChanged)` so the web view reflects
    /// tool-call state before the engine proceeds to execute the tool.
    weak var chatWebViewModel: ChatWebViewModel?

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
            let wd = await config.getWorkingDirectories()
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
            workingDirectories = wd
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
                    Task {
                        await engine.selectChat(filename: first)
                        // On startup auto-selection, present the role picker if
                        // the first chat's role is missing.
                        maybePresentRolePickerForSelectedChat()
                    }
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
            LoaderController.shared.markApplicationCompleted(.roles, loaded: roles.count)
            // A role may have been deleted on disk, leaving the selected chat's
            // role missing. Present the picker so the user can assign a new one
            // (unless they already dismissed it for this chat).
            maybePresentRolePickerForSelectedChat()
        case .promptsChanged(let prompts):
            self.prompts = prompts
            LoaderController.shared.markApplicationCompleted(.prompts, loaded: prompts.count)
        case .connectionsChanged(let connections):
            self.connections = connections
            refreshPreferences()
            // Clean-state flow: with no connections there's nothing to work
            // with, so always surface the creation wizard. Cancelling it (via
            // `closeAppOnCancel`) terminates the app.
            if connections.isEmpty {
                ConnectionWizardView.show(
                    closeAppOnCancel: true,
                    onFinish: { self.refreshAfterWizard() }
                )
            }
            LoaderController.shared.markApplicationCompleted(.connections, loaded: connections.count)
        case .mcpsChanged(let mcps):
            self.mcps = mcps
        case .mcpConfiguration(let state):
            LoaderController.shared.setMCPState(state)
        case .loaderActivity(let activity):
            LoaderController.shared.applicationStarted(activity.counts, refreshCounts: activity.refreshCounts)
        case .configChanged:
            refreshPreferences()
            LoaderController.shared.markApplicationCompleted(.configuration, loaded: 1)
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
        case .configErrorsChanged(let errors):
            configErrors = errors
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
    /// Forces the chat to the bottom so the follow-up assistant message stays
    /// in view as it streams in.
    func allowToolCall(callID: String) {
        chatWebViewModel?.scrollToBottom()
        Task { await engine.resolveToolCallApproval(callID: callID, approval: .allow) }
    }

    /// Denies a pending tool-call approval with an (optional) reason.
    /// Forces the chat to the bottom so the follow-up assistant message stays
    /// in view as it streams in.
    func denyToolCall(callID: String, reason: String) {
        chatWebViewModel?.scrollToBottom()
        Task { await engine.resolveToolCallApproval(callID: callID, approval: .deny(reason: reason)) }
    }

    // MARK: - Wizard completion

    /// Called after the connection wizard finishes. Refreshes preferences and
    /// automatically assigns the just-created connection as the default and
    /// utility connection when neither is set yet (first-connection flow):
    /// instead of prompting the user, we just use the connection they created.
    func refreshAfterWizard() {
        refreshPreferences()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await autoAssignConnectionRolesIfNeeded()
        }
    }

    /// When no default and/or utility connection is configured, assigns the
    /// most recently created connection to those roles automatically. This is
    /// the first-connection flow.
    private func autoAssignConnectionRolesIfNeeded() async {
        guard let conn = connections.last else { return }
        let dc = await config.getDefaultConnection()
        let uc = await config.getUtilityConnection()
        if dc == nil {
            await config.setDefaultConnection(conn.id)
        }
        if uc == nil {
            await config.setUtilityConnection(conn.id)
        }
        await MainActor.run { self.refreshPreferences() }
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

    /// The role assigned to the selected chat, if any (and if it still exists).
    var selectedRole: Role? {
        guard let roleName = selectedChatItem?.chat?.role else { return nil }
        return roles.first(where: { $0.name == roleName })
    }

    /// Whether the selected chat's assigned role exists. When false the message
    /// input and send button are disabled (the role was deleted or never set).
    var selectedChatHasValidRole: Bool {
        selectedRole != nil
    }

    /// Pure decision: whether a given chat record needs a role assigned via the
    /// picker. True when the chat has a role name set but that role no longer
    /// exists (deleted), or when the chat has no role at all. Extracted so it
    /// can be unit-tested without driving the full UI.
    nonisolated static func chatNeedsRoleAssignment(
        _ record: ChatRecord,
        availableRoles: [Role]
    ) -> Bool {
        let name = record.effectiveRoleName
        guard let name, !name.isEmpty else { return true }
        return !availableRoles.contains(where: { $0.name == name })
    }

    /// Pure decision: whether the active chat actually changed between two
    /// selection values. Used by the `selectedChatID` didSet to gate dismissal
    /// of chat-related sheets (role picker, workdir picker, pending
    /// edit/delete/deny). Extracted so it can be unit-tested without driving
    /// the full UI. Two `nil` values (e.g. the initial assignment on startup)
    /// are treated as "no change" so the sheets aren't needlessly reset.
    nonisolated static func chatChanged(from old: String?, to new: String?) -> Bool {
        old != new
    }

    /// Whether the currently selected chat needs a role assigned (its role is
    /// missing or doesn't exist among the loaded roles).
    var selectedChatNeedsRoleAssignment: Bool {
        guard let item = selectedChatItem else { return false }
        return Self.chatNeedsRoleAssignment(item, availableRoles: roles)
    }

    /// Presents the role picker to assign a role to the selected chat when its
    /// role is missing — unless the user already dismissed it for this chat, or
    /// the picker is already showing, or there are no roles to pick from.
    /// Called after chat selection changes and after roles are (re)loaded.
    func maybePresentRolePickerForSelectedChat() {
        guard !showRolePicker else { return }
        guard let id = selectedChatID else { return }
        guard !dismissedRoleAssignmentFor.contains(id) else { return }
        guard !roles.isEmpty else { return }
        guard selectedChatNeedsRoleAssignment else { return }
        rolePickerMode = .assignToExisting(filename: id)
        showRolePicker = true
    }

    /// Whether the selected chat has a resolvable connection: either the
    /// per-chat override or the role's connection references a valid connection.
    var selectedChatHasConnection: Bool {
        guard let chat = selectedChatItem?.chat, let role = selectedRole else { return false }
        for candidate in [chat.connection, role.connection] {
            if let id = candidate, !id.isEmpty, connections.contains(where: { $0.id == id }) {
                return true
            }
        }
        return false
    }

    /// The effective connection id for the selected chat (override when
    /// allowed, otherwise the role's connection). Nil when none resolves.
    var selectedChatConnectionID: String? {
        guard let chat = selectedChatItem?.chat, let role = selectedRole else { return nil }
        if role.connectionOverrideAllowed, let id = chat.connection,
           connections.contains(where: { $0.id == id }) {
            return id
        }
        if let id = role.connection, connections.contains(where: { $0.id == id }) {
            return id
        }
        return chat.connection
    }

    /// Whether the connection picker should be shown for the selected chat.
    var selectedChatConnectionPickerVisible: Bool {
        selectedRole?.connectionOverrideAllowed ?? false
    }

    /// The effective prompt name for the selected chat (override when allowed,
    /// otherwise the role's prompt).
    var selectedChatPromptName: String? {
        guard let chat = selectedChatItem?.chat, let role = selectedRole else { return nil }
        if role.promptOverrideAllowed, let override = chat.prompt {
            return override
        }
        return role.promptName
    }

    /// Whether the prompt picker should be shown for the selected chat.
    var selectedChatPromptPickerVisible: Bool {
        selectedRole?.promptOverrideAllowed ?? false
    }

    /// The effective working directory for the selected chat. The per-chat
    /// override is honored when the role allows overrides; otherwise the role's
    /// pre-set working directory is used. New chats are seeded with the role's
    /// working directory (see `ChatEngine.createNewChat`), so the per-chat value
    /// mirrors the role's when overrides aren't allowed.
    var selectedChatWorkingDirectory: String? {
        guard let chat = selectedChatItem?.chat, let role = selectedRole else { return nil }
        if role.workingDirectoryOverrideAllowed, let override = chat.workingDirectory, !override.isEmpty {
            return override
        }
        return role.workingDirectory
    }

    /// Whether the working-directory picker should be shown in the chat toolbar.
    ///
    /// The picker is shown when the role selects at least one workdir-capable
    /// bundled MCP (Filesystem, Code, or Shell) AND either:
    /// - the role pre-sets a working directory (the toolbar shows it; the user
    ///   can change it only when `working_directory_override_allowed` is true),
    ///   or
    /// - the role allows the user to pick a working directory
    ///   (`working_directory_override_allowed = true`), in which case the
    ///   toolbar shows "No directory" until the user picks one.
    ///
    /// When the role has no workdir-capable MCP, the directory is meaningless
    /// (nothing consumes it), so the picker is hidden regardless of the
    /// override flag.
    var selectedChatWorkdirPickerVisible: Bool {
        guard let role = selectedRole else { return false }
        guard role.hasWorkdirCapableMCP else { return false }
        if role.workingDirectory?.isEmpty == false { return true }
        return role.workingDirectoryOverrideAllowed
    }

    /// Whether the user is allowed to change the working directory for the
    /// selected chat (i.e. the picker button is enabled). True only when the
    /// role allows overrides. When false, the directory is fixed by the role.
    var selectedChatWorkdirPickerEnabled: Bool {
        selectedRole?.workingDirectoryOverrideAllowed ?? false
    }

    /// Whether the selected chat requires a working directory before the user
    /// can send a request. True when the role enables `directory_isolation` on
    /// at least one isolation-capable bundled MCP (Filesystem or Code) and no
    /// directory is currently set (neither the role's pre-set value nor a
    /// user-picked override). Drives the red "No directory" placeholder and the
    /// send gate.
    var selectedChatWorkdirRequired: Bool {
        guard let role = selectedRole, role.hasDirectoryIsolation else { return false }
        return selectedChatWorkingDirectory?.isEmpty ?? true
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
        guard let id = selectedChatConnectionID,
              let conn = connections.first(where: { $0.id == id }) else { return false }
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
        // Pin to the bottom regardless of where the user had scrolled, so the
        // outgoing message and the streaming reply stay in view.
        chatWebViewModel?.scrollToBottom()
        Task { await engine.sendMessage(filename: filename, text: text, pendingImages: pendingImages) }
    }

    func retryLastMessage() {
        guard let filename = selectedChatID else { return }
        // Pin to the bottom so the regenerated reply stays in view.
        chatWebViewModel?.scrollToBottom()
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

    /// Begins creating a new chat by presenting the role picker. The actual
    /// chat is created once the user picks a role.
    func createNewChat() {
        if let current = selectedChatID {
            previousChatID = current
        }
        if roles.isEmpty {
            // No roles available — create a chat with no role. The input will
            // be disabled until a role is assigned.
            Task {
                let filename = await engine.createNewChat(role: "")
                selectedChatID = filename
                await engine.selectChat(filename: filename)
                await engine.markViewed(filename: filename)
            }
            return
        }
        rolePickerMode = .newChat
        showRolePicker = true
    }

    /// Creates a new chat with the chosen role (called from the role picker).
    func createNewChat(role roleName: String) {
        showRolePicker = false
        Task {
            let filename = await engine.createNewChat(role: roleName)
            selectedChatID = filename
            await engine.selectChat(filename: filename)
            await engine.markViewed(filename: filename)
        }
    }

    /// Unified role-picker confirmation. Dispatches based on the current
    /// picker mode: creates a new chat (`.newChat`) or assigns the role to an
    /// existing chat whose role was missing (`.assignToExisting`).
    func rolePickerPicked(role roleName: String) {
        let mode = rolePickerMode
        showRolePicker = false
        switch mode {
        case .newChat:
            createNewChat(role: roleName)
        case .assignToExisting(let filename):
            // A role was assigned — clear any dismissal record so a future
            // role deletion re-prompts the picker.
            dismissedRoleAssignmentFor.remove(filename)
            setRole(roleName)
        }
    }

    /// Unified role-picker cancellation. For `.assignToExisting`, records the
    /// dismissal so the picker isn't immediately re-shown for this chat. The
    /// chat remains non-functional (input/send disabled) until a role is
    /// assigned. Re-selecting the chat clears the dismissal and re-prompts.
    func rolePickerCancelled() {
        switch rolePickerMode {
        case .assignToExisting(let filename):
            dismissedRoleAssignmentFor.insert(filename)
        case .newChat:
            break
        }
        showRolePicker = false
    }

    // MARK: - Configuration errors

    /// Builds the message sent to a Configurator chat for a set of errors: a
    /// header followed by a numbered list of one-line descriptions. Pure logic,
    /// so `nonisolated` to allow use from tests and any context.
    nonisolated static func configuratorMessage(for errors: [ConfigError]) -> String {
        var lines = ["Please investigate the following problems and propose solutions:"]
        for (i, error) in errors.enumerated() {
            lines.append("\(i + 1). \(error.configuratorLine)")
        }
        return lines.joined(separator: "\n")
    }

    /// Creates a new chat with the Configurator role and immediately sends it
    /// the current configuration errors as a numbered list, kicking off a
    /// Configurator request right away.
    func fixWithConfigurator() {
        let errors = configErrors
        showConfigErrors = false
        guard !errors.isEmpty else { return }
        let message = Self.configuratorMessage(for: errors)
        Task {
            let filename = await engine.createNewChat(role: ConfiguratorTools.configuratorRoleName)
            selectedChatID = filename
            await engine.selectChat(filename: filename)
            await engine.markViewed(filename: filename)
            chatWebViewModel?.scrollToBottom()
            await engine.sendMessage(filename: filename, text: message)
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

    /// Updates the per-chat prompt override for the selected chat.
    func setPrompt(_ promptName: String?) {
        guard let filename = selectedChatID else { return }
        Task { await engine.setPrompt(filename: filename, promptName: promptName) }
    }

    /// Updates the per-chat working-directory override for the selected chat.
    func setWorkingDirectory(_ path: String?) {
        guard let filename = selectedChatID else { return }
        Task { await engine.setWorkingDirectory(filename: filename, path: path) }
    }

    /// Adds a working directory to the user-managed list in the app config
    /// (deduped, preserving order). The directory picker offers these to the
    /// user when picking a per-chat working directory.
    func addWorkingDirectory(_ path: String) {
        let normalized = (path as NSString).standardizingPath
        guard !normalized.isEmpty else { return }
        guard !workingDirectories.contains(normalized) else { return }
        workingDirectories.append(normalized)
        let snapshot = workingDirectories
        Task { await config.setWorkingDirectories(snapshot) }
    }

    /// Removes a working directory from the user-managed list in the app config.
    func removeWorkingDirectory(_ path: String) {
        let normalized = (path as NSString).standardizingPath
        workingDirectories.removeAll { $0 == normalized }
        let snapshot = workingDirectories
        Task { await config.setWorkingDirectories(snapshot) }
    }

    /// Triggers a full MCP configuration pass ("File > Reload MCPs…"). Resets
    /// all configured MCPs and their tools cache, then re-connects and
    /// re-queries every server. The overlay is shown while in progress.
    func reloadMCPs() {
        Task { await engine.configureMCPs() }
    }

    /// Selects a chat, prunes other empty chats, and clears its unread marker.
    /// Re-selecting a chat clears any prior role-picker dismissal so the
    /// picker re-prompts if the chat's role is still missing.
    func selectChat(_ filename: String) {
        if !ctrlTabSessionActive, let current = selectedChatID, current != filename {
            previousChatID = current
        }
        // Clear the dismissal so re-opening a chat whose role is missing
        // re-prompts the role picker.
        dismissedRoleAssignmentFor.remove(filename)
        selectedChatID = filename
        Task {
            await engine.selectChat(filename: filename)
            await engine.markViewed(filename: filename)
            // After the chat is loaded, present the role picker if its role is
            // missing. Done after selectChat so the chat record is loaded and
            // `selectedChatNeedsRoleAssignment` reflects the real role state.
            maybePresentRolePickerForSelectedChat()
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
