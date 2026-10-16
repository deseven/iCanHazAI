// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The chat area: a persistent `ChatListView` fed by `ChatListController`.
/// The list is kept alive across chat switches (held by the controller), so
/// switching chats is just a new snapshot.
struct NativeChatView: View {
    @EnvironmentObject var store: AppViewModel
    @StateObject private var controller = ChatListController()

    var body: some View {
        ZStack {
            NativeChatRepresentable(controller: controller)
                .onAppear { controller.bind(store: store) }
                .onDisappear { controller.unbind() }
                .onChange(of: store.selectedChatID) { _, newID in
                    debugLog("Chat", "selection changed → \(newID ?? "nil")")
                    if store.treeOverviewOpen { store.closeTreeOverview() }
                    if newID == nil { controller.unload() }
                    controller.pushSnapshot()
                }
                .onChange(of: store.isStreaming) { _, _ in controller.pushSnapshot() }
                .onChange(of: store.selectedRole) { _, _ in controller.pushSnapshot() }
                .onChange(of: store.preferencesExpandThinking) { _, _ in controller.updatePreferences() }
                .onChange(of: store.preferencesExpandToolUse) { _, _ in controller.updatePreferences() }
                .onChange(of: store.preferencesInterfaceScale) { _, _ in controller.updatePreferences() }

            // The selected chat is still being read from disk or rendered: the
            // list would show the previous chat (or a half-built one) until
            // its snapshot has been applied.
            if let id = store.selectedChatID, store.selectedChatItem?.chat == nil || controller.shownChatID != id {
                Color(nsColor: .windowBackgroundColor)
                ProgressView()
                    .controlSize(.large)
            }

            if let content = controller.treeOverview {
                TreeOverviewView(
                    content: content,
                    roleAccent: RoleAccent.color(for: store.selectedRole?.config.accent),
                    onSelect: { store.gotoMessage(messageID: $0) },
                    onClose: { store.closeTreeOverview() }
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if controller.searchVisible && controller.treeOverview == nil {
                ChatSearchBar(controller: controller)
                    .padding(.top, 10)
                    .padding(.trailing, 18)
                    .transition(.opacity)
            }
        }
    }
}

/// The in-chat search field: match count and previous/next buttons, like a browser's.
private struct ChatSearchBar: View {
    @ObservedObject var controller: ChatListController
    @FocusState private var focused: Bool

    private var summary: String {
        guard !controller.searchQuery.isEmpty else { return "" }
        let s = controller.searchStatus
        guard let current = s.current, s.count > 0 else { return "No results" }
        return "\(current + 1) of \(s.count)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in chat", text: $controller.searchQuery)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    controller.stepSearch(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    controller.closeSearch()
                    return .handled
                }
            Text(summary)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 62, alignment: .trailing)
            Divider().frame(height: 14)
            Button {
                controller.stepSearch(-1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Previous match (⇧⌘G)")
            Button {
                controller.stepSearch(1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Next match (⌘G)")
            Button {
                controller.closeSearch()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .onAppear { focus() }
        .onChange(of: controller.searchFocusRequest) { _, _ in focus() }
    }

    /// Focuses the field with its text selected, so typing replaces the last query.
    private func focus() {
        focused = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            if focused { NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil) }
        }
    }
}

private struct NativeChatRepresentable: NSViewRepresentable {
    let controller: ChatListController

    func makeNSView(context: Context) -> ChatListView {
        controller.listView
    }

    func updateNSView(_ nsView: ChatListView, context: Context) {}
}

/// Feeds the list and routes what the user does in it to `AppViewModel`.
/// Chat content goes through `ChatRenderQueue`, which projects and diffs off
/// the main actor and delivers typed ops back here in order.
@MainActor
final class ChatListController: ObservableObject {
    let listView = ChatListView(frame: .zero)

    /// The tree overview shown in place of the list, while it's open.
    /// The list is hidden meanwhile: its text views' cursor rects would otherwise
    /// show through the overlay as an I-beam.
    @Published private(set) var treeOverview: TreeOverviewContent? {
        didSet { listView.isHidden = treeOverview != nil }
    }
    private var treeOverviewTask: Task<Void, Never>?

    @Published private(set) var searchVisible = false
    @Published var searchQuery = "" {
        didSet { if searchVisible { listView.setSearchQuery(searchQuery) } }
    }
    @Published private(set) var searchStatus = ChatSearchStatus()
    /// Bumped on every Find request so an already open bar takes focus again.
    @Published private(set) var searchFocusRequest = 0

    private weak var store: AppViewModel?
    private lazy var renderQueue = ChatRenderQueue { [weak self] ops in
        await self?.apply(ops)
    }
    /// Tail of a task chain serializing `renderQueue.enqueue` calls so jobs
    /// reach the actor in exactly the order they were issued here.
    private var renderQueueTail: Task<Void, Never>?

    /// The chat the list currently shows; nil while blank.
    @Published private(set) var shownChatID: String?
    private var shownState = ChatRenderState()
    private var expandThinking = false
    private var expandToolUse = false

    init() {
        listView.onAction = { [weak self] action in self?.perform(action) }
        listView.onPinnedChange = { [weak self] atBottom in self?.store?.selectedChatAtBottom = atBottom }
        listView.onSearchChange = { [weak self] status in self?.searchStatus = status }
    }

    // MARK: - Binding to the store

    func bind(store: AppViewModel) {
        self.store = store
        store.chatListController = self
        updatePreferences()
        pushSnapshot()
    }

    func unbind() {
        if store?.chatListController === self {
            store?.chatListController = nil
        }
        store = nil
    }

    /// Applies the interface scale and the expand-thinking/tool-use defaults
    /// in place.
    func updatePreferences() {
        guard let store else { return }
        expandThinking = store.preferencesExpandThinking
        expandToolUse = store.preferencesExpandToolUse
        listView.interfaceScale = ChatFeaturesConfig.normalizedInterfaceScale(store.preferencesInterfaceScale)
        listView.context = makeContext()
    }

    // MARK: - Pushing chat state

    /// Called whenever the store's published state changes. Captures the
    /// current chat state (cheap — arrays are COW value types) and hands it
    /// to `ChatRenderQueue`, which projects and diffs it off the main actor.
    /// Queued snapshots coalesce, which also caps the update rate while
    /// streaming.
    ///
    /// `records` overrides the store's published `chatItems` for the lookup.
    /// The store content-gates `chatItems` during streaming (to avoid
    /// invalidating the whole view tree per token), so the streaming caller
    /// passes the engine's fresh records here — otherwise the list would
    /// render stale content mid-stream.
    func pushSnapshot(records: [ChatRecord]? = nil) {
        guard let store else { return }
        let source = records ?? store.chatItems
        guard let item = source.first(where: { $0.id == store.selectedChatID }),
            let chat = item.chat
        else { return }

        let role = store.selectedRole
        let state = ChatRenderState(
            roleName: item.effectiveRoleName,
            roleIcon: role?.icon,
            roleAccent: role?.config.accent,
            features: ChatRowFeatures(
                responseRegen: role?.hasResponseRegen ?? false, chatTrees: role?.hasChatTrees ?? false),
            isStreaming: item.isStreaming)
        enqueue(.snapshot(chatId: item.id, chat: chat, state: state))
    }

    /// Blanks the list (no chat is selected).
    func unload() {
        enqueue(.unload)
    }

    /// Enqueues a render-queue job, preserving call order: unstructured tasks
    /// give no start-order guarantee, so each job chains onto the previous one.
    private func enqueue(_ job: RenderJob) {
        let prev = renderQueueTail
        renderQueueTail = Task {
            await prev?.value
            await renderQueue.enqueue(job)
        }
    }

    private func apply(_ ops: [RenderOp]) {
        let isEdit = ops.allSatisfy {
            switch $0 {
            case .insert, .update, .delete, .state: true
            default: false
            }
        }
        if isEdit {
            listView.performEdits { applyOps(ops) }
        } else {
            applyOps(ops)
        }
    }

    private func applyOps(_ ops: [RenderOp]) {
        for op in ops {
            switch op {
            case .unload:
                shownChatID = nil
                shownState = ChatRenderState()
                listView.setMessages([], context: makeContext())
            case .snapshot(let chatID, let rows, let state):
                shownChatID = chatID
                shownState = state
                listView.setMessages(rows, context: makeContext())
            case .state(let state):
                shownState = state
                listView.context = makeContext()
            case .insert(let row, let index):
                listView.insert(row, at: index)
            case .update(let row):
                listView.update(row)
            case .delete(let id):
                listView.delete(id: id)
            case .scrollTo(let messageID):
                listView.scrollToMessage(id: messageID)
            }
        }
    }

    private func makeContext() -> ChatRowContext {
        var context = ChatRowContext()
        context.roleName = shownState.roleName
        context.roleIcon = shownState.roleIcon
        context.roleAccent = RoleAccent.nsColor(for: shownState.roleAccent) ?? .controlAccentColor
        context.features = shownState.features
        context.isStreaming = shownState.isStreaming
        context.expandThinking = expandThinking
        context.expandToolUse = expandToolUse
        context.attachmentsDirectory = shownChatID.map { EnvironmentManager.shared.attachmentsDirectoryURL(for: $0) }
        return context
    }

    // MARK: - Commands from the store

    /// Pins the list to the bottom (e.g. when the user sends a message).
    func scrollToBottom() {
        listView.jumpToBottom()
    }

    /// Scrolls to a message and highlights it, once everything pushed before
    /// has been applied (so it works right after a branch switch).
    func scrollToMessage(_ messageID: String) {
        enqueue(.scrollTo(messageID: messageID))
    }

    /// Shows the search bar (or refocuses it) and searches for the last query.
    func startSearch() {
        guard treeOverview == nil else { return }
        searchVisible = true
        searchFocusRequest &+= 1
        listView.setSearchQuery(searchQuery)
    }

    func closeSearch(refocusInput: Bool = true) {
        guard searchVisible else { return }
        searchVisible = false
        listView.setSearchQuery("")
        if refocusInput { store?.focusChatInput() }
    }

    /// Find Next / Find Previous. Opens the bar if it isn't, like Find does.
    func stepSearch(_ direction: Int) {
        guard searchVisible else { return startSearch() }
        listView.stepSearch(direction)
    }

    /// Projects and lays out the selected chat's tree off the main actor, then
    /// shows it.
    func enterTreeOverview() {
        guard let store, let chat = store.selectedChatItem?.chat else { return }
        closeSearch(refocusInput: false)
        let scale = CGFloat(ChatFeaturesConfig.normalizedInterfaceScale(store.preferencesInterfaceScale) / 100)
        treeOverviewTask?.cancel()
        treeOverviewTask = Task {
            let content = await Task.detached { TreeOverviewContent(chat: chat, scale: scale) }.value
            guard !Task.isCancelled else { return }
            treeOverview = content
        }
    }

    func exitTreeOverview() {
        treeOverviewTask?.cancel()
        treeOverviewTask = nil
        treeOverview = nil
    }

    // MARK: - Commands from the list

    private func perform(_ action: ChatRowAction) {
        guard let store else { return }
        switch action {
        case .copy(let messageID):
            copyMessage(messageID)
        case .edit(let messageID):
            store.pendingEditMessageID = UUID(uuidString: messageID)
        case .delete(let messageID):
            store.pendingDeleteMessageID = UUID(uuidString: messageID)
        case .retry:
            store.retryLastMessage()
        case .regenerate(let messageID):
            if let id = UUID(uuidString: messageID) {
                store.regenerateMessage(assistantMessageID: id)
            }
        case .switchBranch(let messageID, let direction):
            store.switchBranch(messageID: messageID, direction: direction)
        case .allowToolCall(let callID):
            store.allowToolCall(callID: callID)
        case .allowToolCallForChat(let callID):
            store.allowToolCallForChat(callID: callID)
        case .denyToolCall(let callID):
            store.pendingDenyToolCallID = callID
        }
    }

    private func copyMessage(_ messageID: String) {
        guard let item = store?.selectedChatItem,
            let uuid = UUID(uuidString: messageID),
            let msg = item.chat?.message(id: uuid)
        else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(msg.content, forType: .string)
    }
}
