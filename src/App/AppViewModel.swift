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
        /// Creating a temporary chat: never saved to disk, never listed, and
        /// destroyed as soon as another chat is selected or created.
        case newTemporaryChat
        /// Assigning a role to an existing chat whose role is missing. Carries
        /// the filename of the chat to update.
        case assignToExisting(filename: String)
    }

    /// The sidebar's chat list display mode.
    enum ChatListMode: String, Equatable, CaseIterable {
        /// Plain list of all chats (default).
        case all
        /// Filter chats by role.
        case role
        /// Filter chats by working directory.
        case directory
    }

    /// Shared reference set by the app on launch so that auxiliary windows
    /// (e.g. Preferences) can reach the view model without walking the
    /// responder chain.
    @MainActor static weak var shared: AppViewModel?

    // MARK: - Published state (mirrored from the engine)

    @Published var chatItems: [ChatRecord] = []
    /// Whether the main window is currently open (it persists hidden after being closed).
    @Published var mainWindowVisible = false
    /// An export or print is being prepared; the Chat menu items are disabled meanwhile.
    @Published var chatExportRunning = false
    /// Cheap, message-free projection of `chatItems` for the sidebar. The
    /// sidebar observes this instead of `chatItems` so a busy chat's per-token
    /// emits don't force it to re-diff full message arrays for every chat.
    /// Derived in `apply(.chatsChanged)` from `chatItems`.
    @Published var chatSummaries: [ChatSummary] = []
    @Published var roles: [Role] = []
    @Published var prompts: [Prompt] = []

    @Published var providers: [ConfiguredProvider] = []
    @Published var models: [CatalogModel] = []
    @Published var mcps: [MCPServer] = []
    @Published var selectedChatID: String? {
        didSet {
            // Once the user opens a chat awaiting approval, the list shows
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
                showMCPPicker = false
                showModelPicker = false
                workdirPickPending = false
                pendingEditMessageID = nil
                pendingDeleteMessageID = nil
                pendingDenyToolCallID = nil
            }
        }
    }
    /// Filename of an archived chat explicitly opened from the archived-chats
    /// picker for viewing without unarchiving: it stays hidden from the
    /// sidebar (like a temporary chat) but the selection survives the
    /// `.chatsChanged` fallback logic. Cleared when another chat is selected
    /// or when the chat is restored or deleted.
    private var archivedPreviewID: String?
    @Published var errorMessage: String?
    /// Whether the currently selected chat is scrolled to the bottom. Updated
    /// by `ChatView`; used to suppress the unread marker when the user is
    /// already looking at the latest content.
    @Published var selectedChatAtBottom: Bool = true
    /// Whether the right-hand chat info sidebar is currently shown.
    @Published var chatInfoSidebarVisible: Bool = false
    /// Width of the chat list sidebar. Drag-resizable via the split view
    /// divider (clamped to `SidebarSizing.chatListRange`, never collapsible).
    @Published var chatListSidebarWidth: CGFloat = SidebarSizing.defaultChatListWidth
    /// Width of the chat info sidebar. Drag-resizable, never collapsible
    /// (it's shown/hidden wholesale instead).
    @Published var chatInfoSidebarWidth: CGFloat = SidebarSizing.defaultChatInfoWidth
    /// The sheet currently shown over the main window — never more than one.
    /// Presenting another replaces it; see `presentSheet(_:)`. The `show…`
    /// and `pending…` properties below are views onto this value.
    @Published var activeSheet: MainSheet? {
        didSet {
            // Pickers that were held back while an app-level sheet was
            // showing (e.g. the model picker once the wizard added the first
            // provider) get their turn when it closes. Deferred so a sheet
            // closed as part of a larger state change sees the final state.
            guard activeSheet == nil, oldValue?.isAppLevel == true else { return }
            Task { @MainActor [weak self] in
                guard let self, self.activeSheet == nil else { return }
                self.maybePresentRolePickerForSelectedChat()
                self.maybePresentModelPickerForSelectedChat()
            }
        }
    }
    /// Message id pending an edit action (set by the chat list; shown as the
    /// edit sheet).
    var pendingEditMessageID: UUID? {
        get { if case .editMessage(let id) = activeSheet { return id } else { return nil } }
        set {
            if let newValue {
                presentSheet(.editMessage(newValue))
            } else if case .editMessage = activeSheet {
                activeSheet = nil
            }
        }
    }
    /// Message id pending a delete action (set by the chat list; shown as the
    /// delete confirmation sheet).
    var pendingDeleteMessageID: UUID? {
        get { if case .deleteMessage(let id) = activeSheet { return id } else { return nil } }
        set {
            if let newValue {
                presentSheet(.deleteMessage(newValue))
            } else if case .deleteMessage = activeSheet {
                activeSheet = nil
            }
        }
    }
    /// Tool-call id pending a deny-reason sheet (set by the chat list when the
    /// user presses Deny).
    var pendingDenyToolCallID: String? {
        get { if case .denyToolCall(let id) = activeSheet { return id } else { return nil } }
        set {
            if let newValue {
                presentSheet(.denyToolCall(callID: newValue))
            } else if case .denyToolCall = activeSheet {
                activeSheet = nil
            }
        }
    }
    /// Filenames of chats awaiting tool-call approval that aren't currently
    /// selected. Each blinks in the sidebar to draw the user's attention.
    @Published var blinkingChatIDs: Set<String> = []
    /// Whether the role picker sheet is currently shown (for a new chat or to
    /// assign a role to an existing chat whose role is missing).
    var showRolePicker: Bool {
        get { activeSheet == .rolePicker }
        set { setSheet(.rolePicker, shown: newValue) }
    }
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
    var showConfigErrors: Bool {
        get { activeSheet == .configErrors }
        set { setSheet(.configErrors, shown: newValue) }
    }
    /// Active dock-bounce request id (if any), cancelled when the window
    /// becomes active or all approvals are resolved.
    private var attentionRequestID: Int? = nil
    /// Runtime-only per-chat input drafts (unsent text + pending images),
    /// written by `ChatView` on chat switch and restored on return.
    var inputDrafts = InputDraftStore()
    /// Observer token for `didBecomeActive` (to cancel the dock bounce).
    private var didBecomeActiveObserver: NSObjectProtocol?

    // MARK: - Preferences state (cached from ConfigManager)

    /// Cached preferences values, kept in sync with ConfigManager.
    @Published var preferencesDefaultRole: String? = "Assistant"
    /// `provider:model-id` strings; nil means "No model".
    @Published var preferencesDefaultModel: String?
    @Published var preferencesUtilityModel: String?

    @Published var preferencesInterfaceScale: Double = ChatFeaturesConfig.defaultInterfaceScale
    @Published var preferencesAppDebugEnabled: Bool = false

    @Published var preferencesExpandToolUse: Bool = false
    @Published var preferencesWebSearchProvider: String = "none"
    @Published var preferencesWebSearchToken: String = ""
    @Published var preferencesLinkupRenderJS: Bool = false
    @Published var preferencesTavilyAdvancedExtraction: Bool = false
    /// User-managed list of working directories offered in the per-chat
    /// directory picker. Mirrored from `config.toml` `[general].working_directories`.
    @Published var workingDirectories: [String] = []
    /// Whether the working-directory picker sheet is currently shown.
    var showWorkdirPicker: Bool {
        get { activeSheet == .workdirPicker }
        set { setSheet(.workdirPicker, shown: newValue) }
    }
    /// Whether the MCP picker sheet is currently shown.
    var showMCPPicker: Bool {
        get { activeSheet == .mcpPicker }
        set { setSheet(.mcpPicker, shown: newValue) }
    }
    /// Whether the model picker sheet is currently shown.
    var showModelPicker: Bool {
        get { activeSheet == .modelPicker }
        set { setSheet(.modelPicker, shown: newValue) }
    }
    /// A new chat's role needs a working directory: the workdir picker opens
    /// once the model picker was picked or dismissed, never stacked on it.
    private var workdirPickPending = false
    /// Filenames for which the user dismissed the model picker, so it isn't
    /// immediately re-shown on the next state emit. Cleared when the chat is
    /// re-selected or a model is picked.
    @Published var dismissedModelPickerFor: Set<String> = []
    /// Monotonic counter bumped on every MCP configuration state change, so
    /// views displaying live MCP tool lists know when to refetch.
    @Published var mcpConfigurationVersion: Int = 0

    // MARK: - Chat list mode state

    /// Current sidebar display mode (all / role / directory). Persisted to
    /// `[chat_list].mode` in the app config.
    @Published var chatListMode: ChatListMode = .all {
        didSet { saveChatListState() }
    }
    /// Role selected in "By Role" mode. Persisted to `[chat_list].role`.
    @Published var chatListRole: String? = nil {
        didSet { saveChatListState() }
    }
    /// Directory selected in "By Directory" mode. Persisted to
    /// `[chat_list].directory`. Defaults to "~" (user home).
    @Published var chatListDirectory: String? = nil {
        didSet { saveChatListState() }
    }
    /// Whether the sidebar's role picker (for "By Role" mode) is shown.
    var showSidebarRolePicker: Bool {
        get { activeSheet == .sidebarRolePicker }
        set { setSheet(.sidebarRolePicker, shown: newValue) }
    }
    /// Whether the sidebar's directory picker (for "By Directory" mode) is
    /// shown.
    var showSidebarDirectoryPicker: Bool {
        get { activeSheet == .sidebarDirectoryPicker }
        set { setSheet(.sidebarDirectoryPicker, shown: newValue) }
    }

    // MARK: - Sheets

    /// Shows `sheet` over the main window, replacing the sheet that is showing
    /// (only one at a time). The one exception is a blocking sheet — the
    /// no-provider wizard — which nothing else may displace.
    func presentSheet(_ sheet: MainSheet) {
        guard activeSheet != sheet else { return }
        if let current = activeSheet, current.isBlocking, !sheet.isBlocking { return }
        activeSheet = sheet
    }

    /// Closes `sheet` if it is the one showing; a no-op when another sheet has
    /// since replaced it.
    func dismissSheet(_ sheet: MainSheet) {
        if activeSheet == sheet { activeSheet = nil }
    }

    /// Closes the showing sheet, unless it's blocking.
    func dismissActiveSheet() {
        if activeSheet?.isBlocking == false { activeSheet = nil }
    }

    private func setSheet(_ sheet: MainSheet, shown: Bool) {
        if shown { presentSheet(sheet) } else { dismissSheet(sheet) }
    }

    /// Brings the main window forward (creating it if needed) and shows `sheet`
    /// in it. This is how the menu items open Preferences and the wizards.
    func presentSheetInMainWindow(_ sheet: MainSheet) {
        MainWindowController.shared.reveal()
        presentSheet(sheet)
    }

    /// Suppresses `saveChatListState` during initial load so restoring values
    /// from config doesn't trigger redundant writes.
    private var isLoadingChatListState = false

    // MARK: - Private

    private let engine = ChatEngine.shared
    private let config = ConfigManager.shared
    private var subscription: Task<Void, Never>?
    /// Weak reference to the active chat list controller, set when
    /// `ChatListController.bind(store:)` is called. Used to push snapshots
    /// synchronously in `apply(.chatsChanged)` so the list reflects
    /// tool-call state before the engine proceeds to execute the tool.
    weak var chatListController: ChatListController?

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
            let dr = await config.getDefaultRole()
            let dm = await config.getDefaultModel()
            let um = await config.getUtilityModel()
            let wd = await config.getWorkingDirectories()
            let rs = await config.getChatInfoSidebarVisible()
            let lw = await config.getChatListSidebarWidth()
            let iw = await config.getChatInfoSidebarWidth()

            let scale = await config.getInterfaceScale()
            let ad = await config.getAppDebugEnabled()

            let eu = await config.getExpandToolUse()
            let ws = await config.getWebSearchConfig()
            let clm = await config.getChatListConfig()
            preferencesDefaultRole = dr
            preferencesDefaultModel = dm
            preferencesUtilityModel = um
            workingDirectories = wd

            preferencesInterfaceScale = scale
            preferencesAppDebugEnabled = ad

            preferencesExpandToolUse = eu
            preferencesWebSearchProvider = ws.provider ?? "none"
            preferencesWebSearchToken = ws.token ?? ""
            preferencesLinkupRenderJS = ws.linkupRenderJS ?? false
            preferencesTavilyAdvancedExtraction = ws.tavilyAdvancedExtraction ?? false
            // Restore chat list mode and filter selections, falling back to
            // defaults when the stored role/directory no longer exists.
            isLoadingChatListState = true
            chatListMode = ChatListMode(rawValue: clm.mode ?? "all") ?? .all
            chatListRole =
                clm.role.flatMap { name in
                    roles.contains(where: { $0.name == name }) ? name : nil
                } ?? preferencesDefaultRole
            chatListDirectory = clm.directory ?? Self.homeDirectoryPath
            isLoadingChatListState = false
            // If the mode is "role" and the default role isn't available,
            // trigger the sidebar role picker so the user picks one.
            if chatListMode == .role, !roles.isEmpty,
                !roles.contains(where: { $0.name == chatListRole })
            {
                showSidebarRolePicker = true
            }
            DebugLogger.setEnabled(ad)
            if let rs { chatInfoSidebarVisible = rs }
            // Clamp restored widths into the allowed ranges so a hand-edited
            // config can't squeeze a sidebar out of existence.
            if let lw {
                chatListSidebarWidth = min(
                    max(CGFloat(lw), SidebarSizing.chatListRange.lowerBound), SidebarSizing.chatListRange.upperBound)
            }
            if let iw {
                chatInfoSidebarWidth = min(
                    max(CGFloat(iw), SidebarSizing.chatInfoRange.lowerBound), SidebarSizing.chatInfoRange.upperBound)
            }
        }
    }

    /// Persists the sidebar states (info sidebar visibility, both sidebar
    /// widths) to config.
    func saveSidebarState() {
        let infoVisible = chatInfoSidebarVisible
        let listWidth = Double(chatListSidebarWidth)
        let infoWidth = Double(chatInfoSidebarWidth)
        Task {
            await config.setSidebarState(
                chatInfoVisible: infoVisible, chatListWidth: listWidth, chatInfoWidth: infoWidth)
        }
    }

    /// Reloads preferences (call after changes to roles/config).
    func refreshPreferences() {
        loadPreferences()
    }

    // MARK: - Chat list mode persistence

    /// The user's home directory path, used as the default directory filter.
    nonisolated static let homeDirectoryPath: String = {
        (NSHomeDirectory() as NSString).standardizingPath
    }()

    /// Persists the current chat list mode and filter selections to config.
    /// Called on every change to `chatListMode`, `chatListRole`, or
    /// `chatListDirectory`. Even when the mode is "all", the last role and
    /// directory selections are saved so switching back restores them.
    private func saveChatListState() {
        guard !isLoadingChatListState else { return }
        let mode = chatListMode.rawValue
        let role = chatListRole
        let directory = chatListDirectory
        Task {
            await config.setChatListConfig(
                ChatListConfig(
                    mode: mode,
                    role: role,
                    directory: directory
                ))
        }
    }

    // MARK: - Chat list filtering

    /// The chats visible in the sidebar after applying the current mode filter.
    /// In "all" mode this is every non-archived, non-temporary chat. In "role"
    /// mode only chats matching `chatListRole` are shown. In "directory" mode
    /// only chats whose working directory matches `chatListDirectory` are shown.
    /// The active chat is NOT forced into the list — it stays selected and
    /// viewable even when filtered out.
    var visibleChatSummaries: [ChatSummary] {
        switch chatListMode {
        case .all:
            return chatSummaries
        case .role:
            let targetRole = chatListRole ?? ""
            return chatSummaries.filter { $0.roleName == targetRole }
        case .directory:
            return chatSummaries.filter {
                Self.chatMatchesDirectory($0, directory: chatListDirectory ?? Self.homeDirectoryPath)
            }
        }
    }

    /// Archived chats filtered by the current mode, for the archive picker.
    var visibleArchivedSummaries: [ChatSummary] {
        let archived =
            chatItems
            .filter { $0.isArchived && !$0.isTemporary }
            .map(ChatSummary.init)
            .sorted { $0.sortKey > $1.sortKey }
        switch chatListMode {
        case .all:
            return archived
        case .role:
            let targetRole = chatListRole ?? ""
            return archived.filter { $0.roleName == targetRole }
        case .directory:
            return archived.filter {
                Self.chatMatchesDirectory($0, directory: chatListDirectory ?? Self.homeDirectoryPath)
            }
        }
    }

    /// Whether a chat's working directory matches the filter directory.
    /// Home directory (`~`) matches chats with no working directory set.
    /// `nonisolated` so it can be unit-tested without the main actor.
    nonisolated static func chatMatchesDirectory(_ chat: ChatSummary, directory: String) -> Bool {
        let normalized = Self.normalizeDirectoryForComparison(directory)
        let chatDir = chat.workingDirectory
        if chatDir == nil || chatDir?.isEmpty == true {
            // Chats with no directory match the home filter.
            return normalized == Self.homeDirectoryPath
        }
        return Self.normalizeDirectoryForComparison(chatDir!) == normalized
    }

    /// Normalizes a directory path for comparison: SSH specs are kept
    /// verbatim; local paths are tilde-expanded and standardized.
    nonisolated static func normalizeDirectoryForComparison(_ path: String) -> String {
        if SSHSpec.isSSH(path) { return path.trimmingCharacters(in: .whitespaces) }
        return (path as NSString).standardizingPath
    }

    /// Truncates a role name for display in the sidebar mode bar: shows the
    /// first part of the name with "..." appended when it's too long.
    nonisolated static func truncateRoleName(_ name: String, maxLen: Int = 12) -> String {
        guard name.count > maxLen else { return name }
        return String(name.prefix(maxLen - 3)) + "..."
    }

    /// Truncates a directory path for display in the sidebar mode bar.
    /// SSH specs show as "host.../last" when too long; local paths show as
    /// ".../last" when too long.
    nonisolated static func truncateDirectoryPath(_ path: String, maxLen: Int = 20) -> String {
        guard path.count > maxLen else { return path }
        if SSHSpec.isSSH(path) {
            // Try to show "host.../lastPathComponent"
            if let slash = path.lastIndex(of: "/") {
                let host = path[..<slash]
                let last = path[path.index(after: slash)...]
                let hostStr = String(host)
                let lastStr = String(last)
                if lastStr.count + 4 <= maxLen && !hostStr.isEmpty {
                    return String(hostStr.prefix(1)) + "..." + "/" + lastStr
                }
            }
            return String(path.prefix(maxLen - 3)) + "..."
        }
        // Local path: show ".../last few components" via middle truncation.
        let nsPath = path as NSString
        let last = nsPath.lastPathComponent
        if last.count + 4 <= maxLen {
            return "..." + String(path.suffix(maxLen - 3))
        }
        return String(path.prefix(maxLen - 3)) + "..."
    }

    /// The display label for the current directory filter, abbreviated with
    /// `~` for the home directory.
    var chatListDirectoryDisplay: String {
        let dir = chatListDirectory ?? Self.homeDirectoryPath
        if dir == Self.homeDirectoryPath {
            return "~"
        }
        return SSHSpec.isSSH(dir) ? dir : (dir as NSString).abbreviatingWithTildeInPath
    }

    /// The currently selected role object for "By Role" mode, if it exists.
    var chatListSelectedRole: Role? {
        guard let name = chatListRole else { return nil }
        return roles.first(where: { $0.name == name })
    }

    // MARK: - Chat list mode actions

    /// Switches the sidebar to a new display mode. No-op when the mode is
    /// already active (acts like tabs — pressing the active button does nothing).
    func setChatListMode(_ mode: ChatListMode) {
        guard chatListMode != mode else { return }
        chatListMode = mode
        if mode == .role, !roles.isEmpty,
            !roles.contains(where: { $0.name == chatListRole })
        {
            showSidebarRolePicker = true
        }
        if mode == .directory, chatListDirectory == nil || chatListDirectory?.isEmpty == true {
            chatListDirectory = Self.homeDirectoryPath
        }
    }

    /// Called when a role is picked from the sidebar's role picker.
    func sidebarRolePickerPicked(role roleName: String) {
        chatListRole = roleName
        showSidebarRolePicker = false
    }

    /// Called when the sidebar's role picker is cancelled.
    func sidebarRolePickerCancelled() {
        showSidebarRolePicker = false
        // If no valid role is selected, fall back to "all" mode.
        if !roles.contains(where: { $0.name == chatListRole }) {
            chatListMode = .all
        }
    }

    /// Called when a directory is picked from the sidebar's directory picker.
    func sidebarDirectoryPickerPicked(_ path: String) {
        chatListDirectory = path
        showSidebarDirectoryPicker = false
    }

    /// Called when the sidebar's directory picker is cancelled.
    func sidebarDirectoryPickerCancelled() {
        showSidebarDirectoryPicker = false
    }

    /// Roles available for the sidebar's "By Directory" mode picker — only
    /// roles that have disk access (bind to a directory) are offered, since
    /// the directory is pre-picked and we skip the workdir picker.
    var rolesWithDiskAccess: [Role] {
        roles.filter { $0.bindsToDirectory }
    }

    // MARK: - Chat creation (mode-aware)

    /// Begins creating a new chat, mode-aware. In "role" mode the picked role
    /// is used directly (no role picker). In "directory" mode only roles with
    /// disk access are offered and the picked directory is pre-set (no workdir
    /// picker). In "all" mode the standard flow applies.
    func createNewChat() {
        if let current = selectedChatID {
            previousChatID = current
        }
        if roles.isEmpty {
            Task {
                let filename = await engine.createNewChat(role: "")
                selectedChatID = filename
                await engine.selectChat(filename: filename)
                await engine.markViewed(filename: filename)
            }
            return
        }
        switch chatListMode {
        case .role:
            // Role is already picked — create directly.
            if let roleName = chatListRole, roles.contains(where: { $0.name == roleName }) {
                createNewChat(role: roleName)
            } else {
                // No valid role — fall back to the picker.
                rolePickerMode = .newChat
                showRolePicker = true
            }
        case .directory:
            // Offer only roles with disk access; the directory is pre-set.
            rolePickerMode = .newChat
            showRolePicker = true
        case .all:
            rolePickerMode = .newChat
            showRolePicker = true
        }
    }

    /// Begins creating a temporary chat, mode-aware (same logic as
    /// `createNewChat` but for temporary chats).
    func createNewTemporaryChat() {
        if let current = selectedChatID {
            previousChatID = current
        }
        if roles.isEmpty {
            Task {
                let filename = await engine.createNewChat(role: "", temporary: true)
                selectedChatID = filename
                await engine.selectChat(filename: filename)
                await engine.markViewed(filename: filename)
            }
            return
        }
        switch chatListMode {
        case .role:
            if let roleName = chatListRole, roles.contains(where: { $0.name == roleName }) {
                createNewTemporaryChat(role: roleName)
            } else {
                rolePickerMode = .newTemporaryChat
                showRolePicker = true
            }
        case .directory:
            rolePickerMode = .newTemporaryChat
            showRolePicker = true
        case .all:
            rolePickerMode = .newTemporaryChat
            showRolePicker = true
        }
    }

    /// Creates a new chat with the chosen role (called from the role picker).
    /// Mode-aware: in "role" mode the role is already picked so this isn't
    /// called. In "directory" mode the picked directory is pre-set and the
    /// workdir picker is skipped. In "all" mode the standard flow applies.
    func createNewChat(role roleName: String) {
        showRolePicker = false
        let needsWorkdir: Bool
        let overrideWorkdir: String?
        switch chatListMode {
        case .directory:
            overrideWorkdir = chatListDirectory
            // Skip workdir picker — the directory is pre-set from the mode.
            needsWorkdir = false
        case .role, .all:
            overrideWorkdir = nil
            needsWorkdir = roleNeedsWorkdirPick(roleName)
        }
        Task {
            let filename = await engine.createNewChat(role: roleName, workingDirectory: overrideWorkdir)
            selectedChatID = filename
            await engine.selectChat(filename: filename)
            await engine.markViewed(filename: filename)
            let hasModel = await engine.chatModel(filename: filename) != nil
            presentModelPickerForNewChat(needsWorkdir: needsWorkdir, hasModel: hasModel)
        }
    }

    /// Creates a temporary chat with the chosen role (called from the role
    /// picker in "New Temporary Chat" mode). Same mode-aware logic as
    /// `createNewChat(role:)`.
    func createNewTemporaryChat(role roleName: String) {
        showRolePicker = false
        let needsWorkdir: Bool
        let overrideWorkdir: String?
        switch chatListMode {
        case .directory:
            overrideWorkdir = chatListDirectory
            needsWorkdir = false
        case .role, .all:
            overrideWorkdir = nil
            needsWorkdir = roleNeedsWorkdirPick(roleName)
        }
        Task {
            let filename = await engine.createNewChat(
                role: roleName, temporary: true, workingDirectory: overrideWorkdir)
            selectedChatID = filename
            await engine.selectChat(filename: filename)
            await engine.markViewed(filename: filename)
            let hasModel = await engine.chatModel(filename: filename) != nil
            presentModelPickerForNewChat(needsWorkdir: needsWorkdir, hasModel: hasModel)
        }
    }

    /// True when a role requires the user to pick a working directory: it has
    /// directory-relevant tools (Filesystem/Code) and doesn't pre-set a
    /// directory. Used to auto-present the workdir picker after a role is picked.
    private func roleNeedsWorkdirPick(_ roleName: String) -> Bool {
        guard let role = roles.first(where: { $0.name == roleName }) else { return false }
        return Self.roleNeedsWorkdirPick(role)
    }

    /// Pure decision logic (testable without an app instance).
    nonisolated static func roleNeedsWorkdirPick(_ role: Role) -> Bool {
        guard role.hasDirectoryRelevantTools else { return false }
        return role.workingDirectory?.isEmpty ?? true
    }

    // MARK: - Preference models

    func preferencesModel(for setting: ModelSetting) -> String? {
        switch setting {
        case .defaultModel: return preferencesDefaultModel
        case .utilityModel: return preferencesUtilityModel
        }
    }

    func preferencesModelID(for setting: ModelSetting) -> ModelID? {
        preferencesModel(for: setting).flatMap { ModelID(parsing: $0) }
    }

    /// What a model status block shows: the display name when the model is in
    /// the catalog, else the raw id; "No model" when unset.
    func modelLabel(for raw: String?) -> String {
        guard let raw else { return "No model" }
        guard let id = ModelID(parsing: raw) else { return raw }
        return models.first { $0.id == id }?.displayName ?? raw
    }

    /// Hides Preferences and shows the model picker for a general model setting.
    func pickSettingsModel(_ setting: ModelSetting) {
        presentSheet(.settingsModelPicker(setting))
    }

    /// Stores the picked model (nil clears it) and returns to Preferences.
    func settingsModelPicked(_ setting: ModelSetting, _ id: ModelID?) {
        let value = id?.description
        switch setting {
        case .defaultModel:
            preferencesDefaultModel = value
            Task { await config.setDefaultModel(value) }
        case .utilityModel:
            preferencesUtilityModel = value
            Task { await config.setUtilityModel(value) }
        }
        if let id { Task { await engine.markModelUsed(id) } }
        presentSheet(.preferences)
    }

    // MARK: - Preference bindings (two-way, write-through to ConfigManager)

    var bindingDefaultRole: Binding<String?> {
        Binding(
            get: { self.preferencesDefaultRole },
            set: { newValue in
                self.preferencesDefaultRole = newValue
                Task { await self.config.setDefaultRole(newValue) }
            }
        )
    }

    var bindingInterfaceScale: Binding<Double> {
        Binding(
            get: { self.preferencesInterfaceScale },
            set: { newValue in
                let normalized = ChatFeaturesConfig.normalizedInterfaceScale(newValue)
                self.preferencesInterfaceScale = normalized
                Task { await self.config.setInterfaceScale(normalized) }
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

    var bindingExpandToolUse: Binding<Bool> {
        Binding(
            get: { self.preferencesExpandToolUse },
            set: { newValue in
                self.preferencesExpandToolUse = newValue
                Task { await self.config.setExpandToolUse(newValue) }
            }
        )
    }

    var bindingWebSearchProvider: Binding<String> {
        Binding(
            get: { self.preferencesWebSearchProvider },
            set: { newValue in
                self.preferencesWebSearchProvider = newValue
                Task { await self.config.setWebSearchProvider(newValue) }
            }
        )
    }

    var bindingWebSearchToken: Binding<String> {
        Binding(
            get: { self.preferencesWebSearchToken },
            set: { newValue in
                self.preferencesWebSearchToken = newValue
                Task { await self.config.setWebSearchToken(newValue) }
            }
        )
    }

    var bindingLinkupRenderJS: Binding<Bool> {
        Binding(
            get: { self.preferencesLinkupRenderJS },
            set: { newValue in
                self.preferencesLinkupRenderJS = newValue
                Task { await self.config.setLinkupRenderJS(newValue) }
            }
        )
    }

    var bindingTavilyAdvancedExtraction: Binding<Bool> {
        Binding(
            get: { self.preferencesTavilyAdvancedExtraction },
            set: { newValue in
                self.preferencesTavilyAdvancedExtraction = newValue
                Task { await self.config.setTavilyAdvancedExtraction(newValue) }
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
            // Content-gated publishing. During streaming the engine emits a
            // coalesced chatsChanged on every token flush, but the only thing
            // that changed is the selected chat's message text — which the
            // chat list already receives via `pushSnapshot()` below (not through
            // SwiftUI). Reassigning `chatItems`/`chatSummaries` unconditionally
            // here gave every subscriber a brand-new array identity each token,
            // invalidating the ENTIRE view tree (the observed main-thread
            // AttributeGraph storm). So only touch the @Published arrays when
            // a UI-relevant value actually changed:
            //  - `chatSummaries` is message-free (title/flags/sortKey) and
            //    Hashable, so a token flush yields an EQUAL array → skipped.
            //  - `chatItems` is updated only when a record's non-content
            //    fields changed (flags, selection, titles, metadata); pure
            //    text/thinking appends are not, since SwiftUI never reads
            //    message content directly.
            let newSummaries =
                records
                .filter { !$0.isArchived && !$0.isTemporary }
                .map(ChatSummary.init)
            if newSummaries != chatSummaries {
                chatSummaries = newSummaries
            }
            if Self.recordsUIRelevantChanged(from: chatItems, to: records) {
                chatItems = records
                maybePresentModelPickerForSelectedChat()
            }
            // Drafts of destroyed temporary chats are dead weight (their
            // filenames are never reused) — drop them.
            inputDrafts.removeStaleTemporaryDrafts(validFilenames: Set(records.map(\.id)))
            // During startup, report the chat-cache sync (total vs already
            // cached vs re-decoded) to the loader's chats row.
            if LoaderController.shared.mode == .startup,
                let stats = ChatStore.shared.lastStartupSyncStats()
            {
                LoaderController.shared.markChatsCompleted(
                    total: stats.totalFiles, freshCached: stats.freshCached, failed: stats.failed)
            }
            // Treat an archived (or deleted) selected chat as "no selection"
            // so the UI falls back to the first visible chat — except an
            // archived chat explicitly opened from the archived-chats picker,
            // which stays selected while remaining hidden from the sidebar.
            let selectedStillVisible =
                selectedChatID.flatMap { id in
                    records.first(where: { $0.id == id })
                }.map { Self.isSelectedChatVisible($0, archivedPreviewID: archivedPreviewID) } ?? false
            if selectedStillVisible, let selected = selectedChatID {
                // Keep selection — if the chat is not loaded, load it so the
                // UI can display its messages. This handles the initial
                // auto-selection on startup (where chats start unloaded).
                if records.first(where: { $0.id == selected })?.chat == nil {
                    Task { await engine.ensureChatLoaded(filename: selected) }
                }
            } else {
                archivedPreviewID = nil
                // The selected chat vanished (deleted/archived) or none was
                // selected yet (startup). Fall back to the first non-archived
                // chat and route through `selectChat` so the engine's
                // `selectedFilename` stays in sync with `selectedChatID` —
                // otherwise the engine can't tell this chat is being viewed
                // and would release it.
                selectedChatID = records.first(where: { !$0.isArchived && !$0.isTemporary })?.id
                if let first = selectedChatID {
                    Task {
                        await engine.selectChat(filename: first)
                        // On startup auto-selection, present the role picker if
                        // the first chat's role is missing, else the model picker.
                        maybePresentRolePickerForSelectedChat()
                        maybePresentModelPickerForSelectedChat()
                    }
                }
            }
            // Suppress the unread marker if the user is already viewing the
            // selected chat scrolled to the bottom.
            if selectedChatAtBottom,
                let selected = selectedChatID,
                let item = records.first(where: { $0.id == selected }),
                item.hasUnreadActivity,
                !item.isStreaming
            {
                Task { await engine.markViewed(filename: selected) }
            }
            // Push the snapshot synchronously in the same main-actor turn so
            // the list reflects tool-call state before the engine resumes
            // to execute the tool. Pass the fresh records: `chatItems` is
            // content-gated above, so during streaming it lags the engine —
            // the list must render from the live snapshot, not the stale
            // published array.
            chatListController?.pushSnapshot(records: records)
        case .rolesChanged(let roles):
            self.roles = roles
            refreshPreferences()
            LoaderController.shared.markApplicationCompleted(.roles, loaded: roles.count)
            // A role may have been deleted on disk, leaving the selected chat's
            // role missing. Present the picker so the user can assign a new one
            // (unless they already dismissed it for this chat).
            maybePresentRolePickerForSelectedChat()
            maybePresentModelPickerForSelectedChat()
        case .promptsChanged(let prompts):
            self.prompts = prompts
            LoaderController.shared.markApplicationCompleted(.prompts, loaded: prompts.count)
        case .providersChanged(let providers):
            self.providers = providers
            LoaderController.shared.markProvidersCompleted(providers)
            // Clean-state flow: with no providers there's nothing to chat
            // with, so always surface the wizard (over whatever sheet is
            // showing). Cancelling it (via `closeAppOnCancel`) terminates the
            // app. Repeated events are no-ops. The sheet is shown once the
            // main window exists, so it never competes with the loader.
            if providers.isEmpty {
                presentSheet(.providerWizard(closeAppOnCancel: true))
            }
            maybePresentModelPickerForSelectedChat()
        case .modelsChanged(let models):
            self.models = models
        case .mcpsChanged(let mcps):
            self.mcps = mcps
        case .mcpConfiguration(let state):
            LoaderController.shared.setMCPState(state)
            // Bump so views showing live MCP tool lists (chat info sidebar)
            // refetch once a configuration pass changes the discovered tools.
            mcpConfigurationVersion += 1
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
            } else {
                // Bring the pending tool block (with its Allow/Deny buttons,
                // always at the bottom) into view.
                chatListController?.scrollToBottom()
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

    /// Resolves a pending tool-call approval. Called from the chat list
    /// when the user presses Allow (and from the deny sheet on confirm).
    /// Forces the chat to the bottom so the follow-up assistant message stays
    /// in view as it streams in.
    func allowToolCall(callID: String) {
        chatListController?.scrollToBottom()
        Task { await engine.resolveToolCallApproval(callID: callID, approval: .allow) }
    }

    /// Resolves a pending tool-call approval and remembers the tool as
    /// auto-approved for this chat ("Allow for this chat" button).
    func allowToolCallForChat(callID: String) {
        chatListController?.scrollToBottom()
        Task { await engine.allowToolCallForChat(callID: callID) }
    }

    /// Denies a pending tool-call approval with an (optional) reason.
    /// Forces the chat to the bottom so the follow-up assistant message stays
    /// in view as it streams in.
    func denyToolCall(callID: String, reason: String) {
        chatListController?.scrollToBottom()
        Task { await engine.resolveToolCallApproval(callID: callID, approval: .deny(reason: reason)) }
    }

    /// The tool call of the selected chat that awaits approval, if any. Calls
    /// are approved one at a time, so there is at most one. Nil while the deny
    /// sheet is up, which keeps the hotkeys from firing behind it.
    var pendingApprovalCallID: String? {
        guard pendingDenyToolCallID == nil, let chat = selectedChatItem?.chat else { return nil }
        return chat.activeMessages.last(where: { $0.role == .assistant })?
            .toolCalls?.first(where: \.pendingApproval)?.id
    }

    /// Menu/hotkey entry points: act on the selected chat's pending approval.
    func allowPendingToolCall() {
        if let id = pendingApprovalCallID { allowToolCall(callID: id) }
    }

    func allowPendingToolCallForChat() {
        if let id = pendingApprovalCallID { allowToolCallForChat(callID: id) }
    }

    func denyPendingToolCall() {
        if let id = pendingApprovalCallID { pendingDenyToolCallID = id }
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

    /// Whether the Chat menu's export/print items are available: the main window
    /// is open and the selected chat has messages and isn't streaming.
    var canExportCurrentChat: Bool {
        guard mainWindowVisible, !chatExportRunning, let item = selectedChatItem, !item.isStreaming,
            let chat = item.chat
        else { return false }
        return !chat.messages.isEmpty
    }

    /// Whether a "stop after current iteration" request is pending for the
    /// selected chat: the current model response and its tool calls finish,
    /// then the stream stops without another model request.
    var stopAfterIterationPending: Bool {
        selectedChatItem?.stopAfterIteration ?? false
    }

    /// Messages queued in the selected chat while it streams.
    var selectedChatQueuedMessages: [QueuedMessage] {
        selectedChatItem?.queuedMessages ?? []
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
        guard activeSheet == nil else { return }
        guard let id = selectedChatID else { return }
        guard !dismissedRoleAssignmentFor.contains(id) else { return }
        guard !roles.isEmpty else { return }
        guard selectedChatNeedsRoleAssignment else { return }
        rolePickerMode = .assignToExisting(filename: id)
        showRolePicker = true
    }

    /// The model identity string of the selected chat, if any.
    var selectedChatModelID: ModelID? {
        selectedChatItem?.chat?.model.flatMap { ModelID(parsing: $0) }
    }

    /// The catalog entry of the selected chat's model, when it's in the cache.
    var selectedChatModel: CatalogModel? {
        guard let id = selectedChatModelID else { return nil }
        return models.first { $0.id == id }
    }

    /// Whether the selected chat has a model. Validity was enforced when the
    /// chat was loaded (an unusable model is reset to nil).
    var selectedChatHasModel: Bool {
        selectedChatItem?.chat?.model != nil
    }

    /// Pure decision: whether the model picker should be presented for a chat
    /// that has no model. Extracted so the picker state machine is testable
    /// without driving the UI.
    nonisolated static func shouldPresentModelPicker(
        chat: Chat?, hasProviders: Bool, roleValid: Bool, anotherPickerShowing: Bool, dismissed: Bool
    ) -> Bool {
        guard let chat, chat.model == nil else { return false }
        return hasProviders && roleValid && !anotherPickerShowing && !dismissed
    }

    /// Presents the model picker for the selected chat when it has no model —
    /// unless the user already dismissed it for this chat, another picker is
    /// showing, no provider is configured, or the role is missing (the role
    /// picker comes first). Called after chat selection changes and after
    /// roles, providers or chats change.
    func maybePresentModelPickerForSelectedChat() {
        guard let id = selectedChatID else { return }
        let show = Self.shouldPresentModelPicker(
            chat: selectedChatItem?.chat,
            hasProviders: !providers.isEmpty,
            roleValid: selectedChatHasValidRole,
            anotherPickerShowing: activeSheet != nil,
            dismissed: dismissedModelPickerFor.contains(id))
        if show { showModelPicker = true }
    }

    /// Opens the model picker for a just-created chat, unless a default or
    /// role-preferred model was already preselected. A role that needs a
    /// working directory gets its picker once the model picker is done.
    private func presentModelPickerForNewChat(needsWorkdir: Bool, hasModel: Bool) {
        guard !providers.isEmpty, !hasModel else {
            if needsWorkdir { showWorkdirPicker = true }
            return
        }
        workdirPickPending = needsWorkdir
        showModelPicker = true
    }

    private func continuePendingWorkdirPick() {
        guard workdirPickPending else { return }
        workdirPickPending = false
        showWorkdirPicker = true
    }

    /// A model was chosen in the picker.
    func modelPickerPicked(_ id: ModelID) {
        showModelPicker = false
        if let filename = selectedChatID { dismissedModelPickerFor.insert(filename) }
        setModel(id.description)
        continuePendingWorkdirPick()
    }

    /// The picker was dismissed. The chat stays without a model (sending is
    /// disabled) until the user picks one from the toolbar.
    func modelPickerCancelled() {
        showModelPicker = false
        if let filename = selectedChatID { dismissedModelPickerFor.insert(filename) }
        continuePendingWorkdirPick()
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

    /// The effective working directory for the selected chat: the per-chat
    /// value (seeded from the role at creation or picked by the user —
    /// permanent either way), falling back to the role's working directory.
    var selectedChatWorkingDirectory: String? {
        guard let chat = selectedChatItem?.chat else { return nil }
        if let dir = chat.workingDirectory, !dir.isEmpty { return dir }
        return selectedRole?.workingDirectory
    }

    /// Whether the working-directory control should be shown in the chat
    /// toolbar. Shown when the role pre-sets a working directory (display
    /// only — the value is permanent) or when the role selects
    /// directory-relevant tools (Filesystem/Code) so a directory must be
    /// picked. Hidden otherwise: with no directory-relevant tools nothing
    /// requires a directory (Shell alone defaults to the user's home).
    var selectedChatWorkdirPickerVisible: Bool {
        guard let role = selectedRole else { return false }
        return Self.workdirPickerVisible(role: role)
    }

    /// Pure decision logic behind `selectedChatWorkdirPickerVisible`
    /// (testable without an app instance). A role pre-set to the home
    /// directory hides the control: home is the default directory and it
    /// can't be changed, so there's nothing to show.
    nonisolated static func workdirPickerVisible(role: Role) -> Bool {
        if let dir = role.workingDirectory, !dir.isEmpty {
            return !isHomeWorkdir(dir)
        }
        return role.hasDirectoryRelevantTools
    }

    /// Whether the chat info sidebar shows the working-directory section:
    /// the role selects at least one workdir-capable tool group (Filesystem,
    /// Code, or Shell), so the chat has a directory worth reporting.
    var selectedChatWorkdirInfoVisible: Bool {
        selectedRole?.hasWorkdirCapableMCP ?? false
    }

    /// Whether the given working directory is the user's home. SSH specs are
    /// never considered home: a remote spec is always informative.
    nonisolated static func isHomeWorkdir(_ path: String) -> Bool {
        guard !SSHSpec.isSSH(path) else { return false }
        let expanded = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        return expanded == (NSHomeDirectory() as NSString).standardizingPath
    }

    /// Whether the user can pick a working directory for the selected chat
    /// (i.e. the control opens the picker). True only while the chat has no
    /// directory yet and the role doesn't pre-set one. The pick is permanent,
    /// like the role itself: once a directory is set, a different one
    /// requires a new chat (a mid-chat swap would confuse the model).
    var selectedChatWorkdirPickerEnabled: Bool {
        guard let role = selectedRole else { return false }
        return Self.workdirPickerEnabled(role: role, chatWorkingDirectory: selectedChatItem?.chat?.workingDirectory)
    }

    /// Pure decision logic behind `selectedChatWorkdirPickerEnabled`
    /// (testable without an app instance).
    nonisolated static func workdirPickerEnabled(role: Role, chatWorkingDirectory: String?) -> Bool {
        guard role.hasDirectoryRelevantTools else { return false }
        guard role.workingDirectory?.isEmpty ?? true else { return false }
        return chatWorkingDirectory?.isEmpty ?? true
    }

    /// Whether the selected chat requires a working directory before the user
    /// can send a request. True when the role selects directory-relevant tools
    /// (Filesystem/Code) and no directory is set (neither the role's pre-set
    /// value nor a user pick). Drives the red "No directory" placeholder and
    /// the send gate.
    var selectedChatWorkdirRequired: Bool {
        guard let role = selectedRole, role.hasDirectoryRelevantTools else { return false }
        return selectedChatWorkingDirectory?.isEmpty ?? true
    }

    /// Whether the selected chat's working directory is directory-isolated:
    /// the role enables `directory_isolation` and a directory is actually
    /// set (picked or pre-set). Drives the ISOLATED tag in the chat info
    /// sidebar and the toolbar folder icon.
    var selectedChatWorkdirIsolated: Bool {
        guard let role = selectedRole, role.hasDirectoryIsolation else { return false }
        return selectedChatWorkingDirectory?.isEmpty == false
    }

    /// The toolbar icon for the workdir control: a question-marked folder
    /// while no directory is picked yet, a circled folder for an isolated
    /// directory, a plain folder otherwise.
    nonisolated static func workdirIcon(directory: String?, isolated: Bool) -> String {
        guard let directory, !directory.isEmpty else { return "questionmark.folder" }
        return isolated ? "folder.circle" : "folder"
    }

    /// Names of the custom MCP servers active for the selected chat: the
    /// chat's own selection (seeded from the role), falling back to the role's
    /// entries for chats that predate the per-chat selection. Names whose
    /// server config no longer exists are dropped, order is preserved.
    var selectedChatMCPNames: [String] {
        guard let chat = selectedChatItem?.chat, let role = selectedRole else { return [] }
        let existing = Set(mcps.map(\.name))
        let selected = chat.mcps ?? (role.config.mcps ?? []).map(\.mcp)
        var seen: Set<String> = []
        return selected.filter { existing.contains($0) && seen.insert($0).inserted }
    }

    /// Whether the MCP control should be shown in the chat toolbar. Hidden
    /// entirely when no custom MCP servers are configured. When the role
    /// doesn't allow MCP overrides, it's only shown to display the active
    /// selection — hidden again when that selection is empty.
    var selectedChatMCPControlVisible: Bool {
        guard !mcps.isEmpty else { return false }
        guard selectedRole != nil else { return false }
        if selectedChatMCPPickerEnabled { return true }
        return !selectedChatMCPNames.isEmpty
    }

    /// Whether the user is allowed to change the MCP selection for the
    /// selected chat (i.e. the toolbar control opens the picker). True only
    /// when the role allows MCP overrides.
    var selectedChatMCPPickerEnabled: Bool {
        selectedRole?.mcpsOverrideAllowed ?? false
    }

    /// Whether the last message in the selected chat is from the user. Used to
    /// allow pressing send with empty input to trigger an assistant reply on
    /// that last user message (e.g. after the agent's answer was removed).
    var selectedChatLastMessageIsFromUser: Bool {
        guard let item = selectedChatItem else { return false }
        return item.chat?.activeMessages.last?.role == .user
    }

    /// Whether attachments are enabled for the selected chat: the role's
    /// `with_attachments` feature flag. Off when the role has no `[features]`
    /// table or omits the key — the paperclip, drag-and-drop, and clipboard
    /// paste paths are all gated on this.
    var selectedChatSupportsAttachments: Bool {
        Self.supportsAttachments(role: selectedRole)
    }

    /// Pure decision logic behind `selectedChatSupportsAttachments`
    /// (testable without an app instance).
    nonisolated static func supportsAttachments(role: Role?) -> Bool {
        role?.hasAttachments ?? false
    }

    /// Whether response regeneration is enabled for the selected chat: the
    /// role's `with_response_regen` feature flag. Off when the role has no
    /// `[features]` table or omits the key — the per-message Regen button is
    /// gated on this.
    var selectedChatSupportsResponseRegen: Bool {
        Self.supportsResponseRegen(role: selectedRole)
    }

    /// Pure decision logic behind `selectedChatSupportsResponseRegen`
    /// (testable without an app instance).
    nonisolated static func supportsResponseRegen(role: Role?) -> Bool {
        role?.hasResponseRegen ?? false
    }

    /// Whether chat trees (non-destructive regen/edit branching) are enabled
    /// for the selected chat: the role's `with_chat_trees` feature flag.
    /// Drives the tree overview toolbar button visibility.
    var selectedChatSupportsChatTrees: Bool {
        Self.supportsChatTrees(role: selectedRole)
    }

    /// Pure decision logic behind `selectedChatSupportsChatTrees`
    /// (testable without an app instance).
    nonisolated static func supportsChatTrees(role: Role?) -> Bool {
        role?.hasChatTrees ?? false
    }

    /// Cumulative token usage for the currently selected chat, summed
    /// across all assistant responses. Nil until the first response
    /// with usage completes.
    var selectedChatTokenUsage: TokenUsage? {
        selectedChatItem?.tokenUsage
    }

    /// Whether two `records` snapshots differ in any field SwiftUI actually
    /// reads. Used to gate `chatItems` publishing (see `apply(.chatsChanged)`):
    /// during streaming the only per-token change is the selected chat's
    /// message *text* (`content`/`thinking`), which SwiftUI never reads — it
    /// renders through the native chat list via `pushSnapshot()`. Everything else a view
    /// can observe (flags, selection metadata, title, message structure, tool
    /// calls, errors, token usage) is compared here; if none changed, the
    /// @Published array is left untouched so subscribers aren't invalidated.
    nonisolated static func recordsUIRelevantChanged(from old: [ChatRecord], to new: [ChatRecord]) -> Bool {
        guard old.count == new.count else { return true }
        for (a, b) in zip(old, new) {
            if a.filename != b.filename { return true }
            // Record-level scalars.
            if a.isStreaming != b.isStreaming
                || a.stopAfterIteration != b.stopAfterIteration
                || a.queuedMessages != b.queuedMessages
                || a.hasUnreadActivity != b.hasUnreadActivity
                || a.lastError != b.lastError
                || a.cachedName != b.cachedName
                || a.cachedRole != b.cachedRole
                || a.cachedArchive != b.cachedArchive
                || a.cachedWorkingDirectory != b.cachedWorkingDirectory
                || a.cachedLastActivity != b.cachedLastActivity
                || a.isTemporary != b.isTemporary
            {
                return true
            }
            // Loaded-chat structure. We compare everything EXCEPT the message
            // text bodies (content/thinking), which stream in per token and
            // are only consumed by the chat list.
            if chatsUIRelevantChanged(a.chat, b.chat) { return true }
        }
        return false
    }

    /// Structural comparison of two loaded chats, ignoring the streaming text
    /// bodies (`content`/`thinking`). Nil-vs-loaded and any structural or
    /// metadata difference counts as changed.
    private nonisolated static func chatsUIRelevantChanged(_ a: Chat?, _ b: Chat?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (nil, .some), (.some, nil): return true
        case (let x?, let y?):
            if x.role != y.role
                || x.title != y.title
                || x.model != y.model
                || x.prompt != y.prompt
                || x.workingDirectory != y.workingDirectory
                || x.mcps != y.mcps
                || x.archive != y.archive
                || x.autoAllow != y.autoAllow
                || x.autoDeny != y.autoDeny
                || x.outputRendering != y.outputRendering
            {
                return true
            }
            return messagesUIRelevantChanged(x.messages, y.messages)
        }
    }

    /// Structural comparison of message trees, ignoring `content`/`thinking`.
    private nonisolated static func messagesUIRelevantChanged(_ a: [ChatMessage], _ b: [ChatMessage]) -> Bool {
        guard a.count == b.count else { return true }
        for (m, n) in zip(a, b) {
            if m.id != n.id
                || m.role != n.role
                || m.error != n.error
                || m.timestamp != n.timestamp
                || m.model != n.model
                || m.attachments != n.attachments
                || m.toolCalls != n.toolCalls
                || m.toolResults != n.toolResults
                || m.tokenUsage != n.tokenUsage
                || m.activeBranch != n.activeBranch
            {
                return true
            }
            switch (m.branches, n.branches) {
            case (nil, nil): break
            case (nil, .some), (.some, nil): return true
            case (let mb?, let nb?):
                guard mb.count == nb.count else { return true }
                for (ba, bb) in zip(mb, nb) where messagesUIRelevantChanged(ba, bb) { return true }
            }
        }
        return false
    }

    // MARK: - Actions (forwarders to the engine)

    func sendMessage(_ text: String, pendingAttachments: [PendingAttachment] = []) {
        guard let filename = selectedChatID else { return }
        // Pin to the bottom regardless of where the user had scrolled, so the
        // outgoing message and the streaming reply stay in view.
        chatListController?.scrollToBottom()
        Task { await engine.sendMessage(filename: filename, text: text, pendingAttachments: pendingAttachments) }
    }

    /// Queues a message for the selected (streaming) chat; it is sent when the
    /// current answer ends.
    func queueMessage(_ text: String, pendingAttachments: [PendingAttachment] = []) {
        guard let filename = selectedChatID else { return }
        Task { await engine.queueMessage(filename: filename, text: text, pendingAttachments: pendingAttachments) }
    }

    /// Stops the selected chat's stream and sends the queue plus this message now.
    func sendMessageImmediately(_ text: String, pendingAttachments: [PendingAttachment] = []) {
        guard let filename = selectedChatID else { return }
        chatListController?.scrollToBottom()
        let extra = QueuedMessage(text: text, attachments: pendingAttachments)
        Task { await engine.sendQueuedMessagesNow(filename: filename, extra: extra) }
    }

    /// Stops the selected chat's stream and sends the queued messages now.
    func sendQueuedMessagesNow() {
        guard let filename = selectedChatID else { return }
        chatListController?.scrollToBottom()
        Task { await engine.sendQueuedMessagesNow(filename: filename) }
    }

    func clearQueuedMessages() {
        guard let filename = selectedChatID else { return }
        Task { await engine.clearQueuedMessages(filename: filename) }
    }

    func retryLastMessage() {
        guard let filename = selectedChatID else { return }
        // Pin to the bottom so the regenerated reply stays in view.
        chatListController?.scrollToBottom()
        Task { await engine.retryLastMessage(filename: filename) }
    }

    /// Regenerates the assistant response at `assistantMessageID` for the
    /// selected chat. Pins to the bottom so the new reply stays in view.
    func regenerateMessage(assistantMessageID: UUID) {
        guard let filename = selectedChatID else { return }
        chatListController?.scrollToBottom()
        Task { await engine.regenerate(filename: filename, assistantMessageID: assistantMessageID) }
    }

    /// Switches the active branch at the message's fork point. Resolves the
    /// target sibling from `direction` (-1 for ◀, +1 for ▶) and calls the
    /// engine's `setActiveBranch`. No-op when the message has no siblings.
    func switchBranch(messageID: String, direction: Int) {
        guard let filename = selectedChatID,
            let messageUUID = UUID(uuidString: messageID)
        else { return }
        Task {
            if let siblingID = await engine.siblingForSwitch(
                filename: filename, messageID: messageUUID, direction: direction),
                let parentID = await engine.record(for: filename)?.chat?.parent(of: messageUUID)?.id
            {
                await engine.setActiveBranch(filename: filename, parentID: parentID, childID: siblingID)
            }
        }
    }

    /// Whether the tree overview mode is currently open for the selected chat.
    @Published var treeOverviewOpen: Bool = false

    /// Toggles the tree overview mode for the selected chat. When opening,
    /// shows the tree overview; when closing,
    /// hides it. No-op while streaming (the overview blocks
    /// interactions anyway).
    func toggleTreeOverview() {
        if treeOverviewOpen {
            closeTreeOverview()
        } else {
            openTreeOverview()
        }
    }

    /// Opens the tree overview mode for the selected chat.
    func openTreeOverview() {
        guard let item = selectedChatItem, item.chat != nil else { return }
        treeOverviewOpen = true
        chatListController?.enterTreeOverview()
    }

    /// Closes the tree overview mode.
    func closeTreeOverview() {
        treeOverviewOpen = false
        chatListController?.exitTreeOverview()
    }

    /// Jumps to a message from the tree overview: resolves the path to the
    /// node, calls `setActiveBranch` for each fork on the way (no-op when
    /// already on-path), closes the overview, pushes the snapshot, then
    /// scrolls to the target message.
    func gotoMessage(messageID: String) {
        guard let filename = selectedChatID,
            let targetUUID = UUID(uuidString: messageID)
        else { return }
        let wasOpen = treeOverviewOpen
        treeOverviewOpen = false
        Task {
            // Point the active path at the target message: every fork on the
            // way switches to the branch containing it.
            await engine.activatePath(filename: filename, messageID: targetUUID)
            // Close the overview (if it was open) and push the snapshot.
            if wasOpen {
                chatListController?.exitTreeOverview()
            }
            // The scroll is queued behind the snapshot, so it lands once the
            // list shows the new active path.
            pushSnapshotAfterBranchSwitch()
            chatListController?.scrollToMessage(messageID)
        }
    }

    /// Pushes a fresh snapshot after a branch switch triggered from the
    /// overview, so the list reflects the new active path before the
    /// scroll-to-message lands.
    private func pushSnapshotAfterBranchSwitch() {
        chatListController?.pushSnapshot()
    }

    func stopStreaming() {
        guard let filename = selectedChatID else { return }
        Task { await engine.stopStreaming(filename: filename) }
    }

    func stopStreamingAfterIteration() {
        guard let filename = selectedChatID else { return }
        Task { await engine.stopStreamingAfterIteration(filename: filename) }
    }

    /// Opens the in-chat search bar (Cmd-F). No-op when no chat is selected.
    /// Asks the chat list to show its search form.
    func startSearchInChat() {
        guard selectedChatItem != nil else { return }
        chatListController?.startSearch()
    }

    /// Find Next (1) / Find Previous (-1) in the chat.
    func findInChat(direction: Int) {
        guard selectedChatItem != nil else { return }
        chatListController?.stepSearch(direction)
    }

    /// Bumped to hand keyboard focus back to the message input.
    @Published var chatInputFocusRequest = 0

    func focusChatInput() {
        chatInputFocusRequest &+= 1
    }

    /// Incremented to ask the chat sidebar to focus its filter field
    /// (Option-Cmd-F). A counter rather than a bool so repeated invocations
    /// each fire `.onChange`.
    @Published var chatListFilterFocusRequest = 0

    /// Focuses the chat list filter field in the sidebar (the sidebar can't
    /// be collapsed, so it's always there to receive the request).
    func focusChatListFilter() {
        chatListFilterFocusRequest += 1
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

    /// Unified role-picker confirmation. Dispatches based on the current
    /// picker mode: creates a new chat (`.newChat`) or assigns the role to an
    /// existing chat whose role was missing (`.assignToExisting`).
    func rolePickerPicked(role roleName: String) {
        let mode = rolePickerMode
        showRolePicker = false
        switch mode {
        case .newChat:
            // `createNewChat(role:)` auto-presents the workdir picker when the
            // role requires a user-picked directory.
            createNewChat(role: roleName)
        case .newTemporaryChat:
            createNewTemporaryChat(role: roleName)
        case .assignToExisting(let filename):
            // A role was assigned — clear any dismissal record so a future
            // role deletion re-prompts the picker.
            dismissedRoleAssignmentFor.remove(filename)
            setRole(roleName)
            if roleNeedsWorkdirPick(roleName) {
                // Don't auto-prompt if this chat already has a working directory.
                let hasWorkdir =
                    chatItems
                    .first(where: { $0.id == filename })?.chat?.workingDirectory?.isEmpty == false
                if !hasWorkdir { showWorkdirPicker = true }
            }
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
        case .newChat, .newTemporaryChat:
            break
        }
        showRolePicker = false
    }

    // MARK: - Configuration errors

    /// Builds the message sent to a Configurator chat for a set of errors: a
    /// header followed by a numbered list of one-line descriptions. Pure logic,
    /// so `nonisolated` to allow use from tests and any context.
    /// Whether the selected chat record may keep the UI selection: visible
    /// chats always; archived chats only when explicitly opened for preview
    /// from the archived-chats picker. `nonisolated` for testability.
    nonisolated static func isSelectedChatVisible(_ record: ChatRecord, archivedPreviewID: String?) -> Bool {
        !record.isArchived || record.filename == archivedPreviewID
    }

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
            chatListController?.scrollToBottom()
            await engine.sendMessage(filename: filename, text: message)
        }
    }

    func deleteChat(_ filename: String) {
        if archivedPreviewID == filename { archivedPreviewID = nil }
        inputDrafts.remove(for: filename)
        Task { await engine.deleteChat(filename: filename) }
    }

    /// Deletes every archived chat (the archived-chats picker's "Delete All"
    /// action). Deletions run sequentially through the engine.
    func deleteAllArchivedChats() {
        let filenames = visibleArchivedSummaries.map(\.filename)
        for filename in filenames { inputDrafts.remove(for: filename) }
        if let preview = archivedPreviewID, filenames.contains(preview) { archivedPreviewID = nil }
        Task { for filename in filenames { await engine.deleteChat(filename: filename) } }
    }

    /// Opens an archived chat in the chat view without unarchiving it: it
    /// stays hidden from the sidebar, like a temporary chat.
    func openArchivedChat(_ filename: String) {
        archivedPreviewID = filename
        selectChat(filename)
    }

    func renameChat(_ filename: String, to newTitle: String) {
        Task { await engine.renameChat(filename: filename, to: newTitle) }
    }

    /// Archives a chat (hides it from the chat list) or unarchives it.
    func setChatArchived(_ filename: String, archived: Bool) {
        // Archiving the previewed chat ends its preview (it becomes hidden);
        // restoring makes the preview flag moot — the chat is visible anyway.
        if archivedPreviewID == filename { archivedPreviewID = nil }
        Task { await engine.setChatArchived(filename: filename, archived: archived) }
    }

    /// OpenRouter server-side search for the model picker.
    func searchModels(_ text: String, provider: Provider) async throws -> [CatalogModel] {
        try await engine.searchModels(text, provider: provider)
    }

    func setModel(_ modelID: String) {
        guard let filename = selectedChatID else { return }
        Task { await engine.setModel(filename: filename, modelID: modelID) }
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

    /// Updates the per-chat custom MCP selection for the selected chat.
    func setChatMCPs(_ names: [String]) {
        guard let filename = selectedChatID else { return }
        Task { await engine.setChatMCPs(filename: filename, names: names) }
    }

    /// The tools available to the selected chat (built-in groups + external
    /// MCP servers), for the chat info sidebar. Nil when no chat is selected.
    func chatToolSnapshot() async -> ChatToolSnapshot? {
        guard let filename = selectedChatID else { return nil }
        return await engine.toolSnapshot(filename: filename)
    }

    /// Toggles the per-chat auto-approval state of a tool for the selected
    /// chat, relative to the role's defaults (persisted by the engine).
    func toggleChatToolAutoApproval(toolName: String) {
        guard let filename = selectedChatID else { return }
        Task { await engine.toggleToolAutoApproval(filename: filename, toolName: toolName) }
    }

    /// Maximum number of recently used working directories kept in the app
    /// config; older entries fall off the end automatically.
    nonisolated static let workingDirectoryRecentLimit = 30

    /// Normalizes a working directory for storage: SSH specs (`host:/path`)
    /// are kept verbatim (standardization would mangle them), local paths are
    /// standardized (resolving `~` and symlinks).
    nonisolated static func normalizeWorkingDirectory(_ path: String) -> String {
        SSHSpec.isSSH(path)
            ? path.trimmingCharacters(in: .whitespaces)
            : (path as NSString).standardizingPath
    }

    /// Pure MRU-list update behind `recordWorkingDirectory`: moves
    /// `normalized` to the front (deduped), capping the list at `limit`.
    nonisolated static func recentDirectories(
        inserting normalized: String, into list: [String], limit: Int = workingDirectoryRecentLimit
    ) -> [String] {
        var result = list.filter { $0 != normalized }
        result.insert(normalized, at: 0)
        if result.count > limit { result = Array(result.prefix(limit)) }
        return result
    }

    /// Records a working directory as recently used: moves it to the front of
    /// the MRU list (deduped), capping the list at `workingDirectoryRecentLimit`
    /// entries. Persisted to the app config; the directory picker offers these
    /// when picking a per-chat working directory.
    func recordWorkingDirectory(_ path: String) {
        let normalized = Self.normalizeWorkingDirectory(path)
        guard !normalized.isEmpty else { return }
        workingDirectories = Self.recentDirectories(inserting: normalized, into: workingDirectories)
        let snapshot = workingDirectories
        Task { await config.setWorkingDirectories(snapshot) }
    }

    /// Removes a working directory from the recent list in the app config.
    func removeWorkingDirectory(_ path: String) {
        let normalized = Self.normalizeWorkingDirectory(path)
        workingDirectories.removeAll { $0 == normalized }
        let snapshot = workingDirectories
        Task { await config.setWorkingDirectories(snapshot) }
    }

    /// Re-reads the given entities from disk (the "Reload …" menu items) —
    /// a manual fallback for files edited outside the app, since the data
    /// directory is not watched.
    func reloadFromDisk(_ change: ConfigChange) {
        Task { await engine.applyConfigChange(change) }
    }

    /// Re-fetches the model lists of every configured provider ("Provider > Refresh Models…").
    func refreshModels() {
        Task { await engine.refreshModels() }
    }

    /// Triggers a full MCP configuration pass ("MCP > Reinitialize MCP Servers…"). Resets
    /// all configured MCPs and their tools cache, then re-connects and
    /// re-queries every server. The overlay is shown while in progress.
    func reloadMCPs() {
        Task { await engine.configureMCPs() }
    }

    /// Selects a chat, prunes other empty chats, and clears its unread marker.
    /// Re-selecting a chat clears any prior role-picker dismissal so the
    /// picker re-prompts if the chat's role is still missing.
    func selectChat(_ filename: String) {
        // Selecting any chat other than the previewed archived one ends the
        // archived preview (see `openArchivedChat`).
        if archivedPreviewID != filename { archivedPreviewID = nil }
        if !ctrlTabSessionActive, let current = selectedChatID, current != filename {
            previousChatID = current
        }
        // Clear the dismissal so re-opening a chat whose role is missing
        // re-prompts the role picker.
        dismissedRoleAssignmentFor.remove(filename)
        dismissedModelPickerFor.remove(filename)
        selectedChatID = filename
        Task {
            await engine.selectChat(filename: filename)
            await engine.markViewed(filename: filename)
            // After the chat is loaded, present the role picker if its role is
            // missing. Done after selectChat so the chat record is loaded and
            // `selectedChatNeedsRoleAssignment` reflects the real role state.
            maybePresentRolePickerForSelectedChat()
            maybePresentModelPickerForSelectedChat()
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
                window == NSApplication.shared.mainWindow
            else {
                return event
            }
            switch event.type {
            case .keyDown:
                if event.keyCode == 48,  // Tab key
                    event.modifierFlags.contains(.control),
                    !event.modifierFlags.contains(.command)
                {
                    self.handleCtrlTab()
                    return nil  // Swallow the event
                }
            case .flagsChanged:
                if self.ctrlTabSessionActive,
                    !event.modifierFlags.contains(.control)
                {
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
        // Archived chats are hidden from the sidebar, so skip them when
        // cycling through chats.
        let items = chatItems.filter { !$0.isArchived }
        guard !items.isEmpty else { return }

        if !ctrlTabSessionActive {
            ctrlTabSessionActive = true
            ctrlTabOriginID = selectedChatID

            if let prev = previousChatID,
                let idx = items.firstIndex(where: { $0.id == prev })
            {
                ctrlTabCurrentIndex = idx
            } else if let current = selectedChatID,
                let idx = items.firstIndex(where: { $0.id == current })
            {
                ctrlTabCurrentIndex = (idx + 1) % items.count
            } else {
                ctrlTabCurrentIndex = 0
            }
        } else {
            ctrlTabCurrentIndex = (ctrlTabCurrentIndex + 1) % items.count
        }

        let targetID = items[ctrlTabCurrentIndex].id
        archivedPreviewID = nil
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
