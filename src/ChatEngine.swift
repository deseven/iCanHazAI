// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The UI-free core of the app. Owns all chat/connection/role state and
/// orchestrates streaming requests. It is a singleton `actor` so it outlives
/// any window and can later be driven by a CLI.
///
/// Subscribers receive state updates via an `AsyncStream<EngineEvent>`.
/// The engine reconciles disk changes with in-memory state so that chats
/// currently being streamed are never clobbered by a disk reload.
actor ChatEngine {

    static let shared = ChatEngine()

    // MARK: - State

    private(set) var records: [ChatRecord] = []
    private(set) var roles: [Role] = []
    private(set) var connections: [Connection] = []

    /// In-flight streaming tasks keyed by chat filename, used for cancellation.
    private var streamTasks: [String: Task<Void, Never>] = [:]

    /// Coalesced-emit bookkeeping. While a chat is streaming, rapid chunks
    /// would otherwise each trigger a full `chatsChanged` event, flooding the
    /// UI's main-actor queue and making the stop button feel unresponsive
    /// (especially for OpenAI-compatible providers that emit 1–4 char deltas).
    /// Instead we defer the emit: the first chunk schedules a flush task that
    /// fires after `emitCoalesceInterval`; subsequent chunks just mark state
    /// dirty. This collapses dozens of events per second into ~20.
    private var pendingEmitTask: Task<Void, Never>?
    private var emitDirty = false
    private let emitCoalesceInterval: UInt64 = 50_000_000 // 50ms in nanoseconds

    /// Filename of the chat whose last assistant message can be retried.
    private var lastRetryableFilename: String?

    private let env = EnvironmentManager.shared
    private var watcher: EnvironmentWatcher?

    // MARK: - Event bus

    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    private init() {}

    /// Starts loading and watching the environment. Must be called once at launch.
    /// Whether `start()` has already run. Idempotency guard.
    private var didStart = false

    func start() {
        guard !didStart else { return }
        didStart = true
        env.ensureDirectories()
        reloadAll(shouldEmit: false)
        startWatching()
        emit(.chatsChanged(records))
        emit(.rolesChanged(roles))
        emit(.connectionsChanged(connections))
    }

    // MARK: - Subscription

    /// Returns an async stream of engine events. The current snapshot is emitted
    /// immediately upon subscription so the subscriber doesn't need a separate fetch.
    func subscribe() -> AsyncStream<EngineEvent> {
        let id = UUID()
        let stream = AsyncStream<EngineEvent> { continuation in
            // Clean up when the subscriber stops iterating.
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id)
                }
            }
            self.continuations[id] = continuation
            // Emit the current snapshot right away.
            continuation.yield(.chatsChanged(self.records))
            continuation.yield(.rolesChanged(self.roles))
            continuation.yield(.connectionsChanged(self.connections))
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: EngineEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    /// Schedules a coalesced `chatsChanged` emit. The first call starts a
    /// timer; subsequent calls just mark state dirty. When the timer fires we
    /// emit once with the latest `records`. This collapses a burst of streaming
    /// chunks into a single UI event every `emitCoalesceInterval`.
    private func scheduleCoalescedEmit() {
        emitDirty = true
        guard pendingEmitTask == nil else { return }
        let interval = emitCoalesceInterval
        pendingEmitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: interval)
            await self?.flushCoalescedEmit()
        }
    }

    /// Emits a pending coalesced `chatsChanged` (if any) and clears the timer.
    /// Called by the timer, and also directly by state transitions that must
    /// reach the UI immediately (stop, finish, error).
    private func flushCoalescedEmit() {
        pendingEmitTask?.cancel()
        pendingEmitTask = nil
        guard emitDirty else { return }
        emitDirty = false
        emit(.chatsChanged(records))
    }

    // MARK: - Watching

    private func startWatching() {
        let paths: [(path: String, area: EnvironmentWatcher.Area)] = [
            (env.chatsURL.path, .chats),
            (env.rolesURL.path, .roles),
            (env.connectionsURL.path, .connections)
        ]
        // The watcher callback hops back into the actor via a Task.
        watcher = EnvironmentWatcher(paths: paths) { [weak self] area in
            Task { [weak self] in
                await self?.handleEnvironmentChange(area)
            }
        }
        watcher?.start()
    }

    private func handleEnvironmentChange(_ area: EnvironmentWatcher.Area) {
        switch area {
        case .chats:
            reconcileChatsFromDisk()
        case .roles:
            roles = env.loadAllRoles()
            emit(.rolesChanged(roles))
        case .connections:
            connections = env.loadConnections()
            emit(.connectionsChanged(connections))
        }
    }

    // MARK: - Loading

    private func reloadAll(shouldEmit: Bool = true) {
        let loaded = env.loadChats()
        // Preserve streaming/unread flags for chats that already exist in memory.
        var newRecords: [ChatRecord] = []
        for (filename, chat) in loaded {
            let existing = records.first(where: { $0.filename == filename })
            newRecords.append(ChatRecord(
                filename: filename,
                chat: chat,
                isStreaming: existing?.isStreaming ?? false,
                hasUnreadActivity: existing?.hasUnreadActivity ?? false,
                lastError: existing?.lastError,
                createdAt: existing?.createdAt ?? Date()
            ))
        }
        sortRecordsByActivity(&newRecords)
        records = newRecords
        roles = env.loadAllRoles()
        connections = env.loadConnections()
        // Drop bookkeeping for chats that no longer exist.
        let validIDs = Set(records.map { $0.id })
        streamTasks = streamTasks.filter { validIDs.contains($0.key) }
        if shouldEmit {
            emit(.chatsChanged(records))
            emit(.rolesChanged(roles))
            emit(.connectionsChanged(connections))
        }
    }

    /// Orders records so the chat with the most recent activity comes first.
    /// Empty chats (no messages) are ordered by their in-memory creation time;
    /// once a chat has messages it switches to ordering by the last message
    /// timestamp.
    private func sortRecordsByActivity(_ list: inout [ChatRecord]) {
        list.sort { a, b in
            a.sortKey > b.sortKey
        }
    }

    private func sortAndEmit() {
        sortRecordsByActivity(&records)
        emit(.chatsChanged(records))
    }

    /// Reconciles in-memory chat state with disk. Chats that are currently
    /// streaming are left untouched (their final state is persisted on
    /// completion); all others are reloaded from disk so external edits are
    /// picked up. This is the fix for the "responses get cut" bug.
    private func reconcileChatsFromDisk() {
        let loaded = env.loadChats()
        let loadedMap = Dictionary(uniqueKeysWithValues: loaded.map { ($0.filename, $0.chat) })
        let loadedIDs = Set(loadedMap.keys)

        var newRecords: [ChatRecord] = []
        // Preserve order from disk.
        for (filename, diskChat) in loaded {
            if let existing = records.first(where: { $0.filename == filename }) {
                if existing.isStreaming {
                    // Keep the in-memory (streaming) version; do not clobber.
                    newRecords.append(existing)
                } else {
                    // Reload from disk, preserving runtime flags.
                    newRecords.append(ChatRecord(
                        filename: filename,
                        chat: diskChat,
                        isStreaming: false,
                        hasUnreadActivity: existing.hasUnreadActivity,
                        lastError: nil,
                        createdAt: existing.createdAt
                    ))
                }
            } else {
                // New chat appeared on disk.
                newRecords.append(ChatRecord(filename: filename, chat: diskChat))
            }
        }
        sortRecordsByActivity(&newRecords)
        records = newRecords
        // Drop bookkeeping for deleted chats.
        streamTasks = streamTasks.filter { loadedIDs.contains($0.key) }
        emit(.chatsChanged(records))
    }

    // MARK: - Chat management

    /// Creates a new empty chat and returns its filename. Any other empty
    /// chats (no messages) are pruned first so the sidebar doesn't accumulate
    /// blank "New chat" entries.
    @discardableResult
    func createNewChat() -> String {
        pruneEmptyChats(except: nil)
        let filename = env.newChatFilename()
        let chat = Chat()
        env.saveChat(chat, filename: filename)
        let record = ChatRecord(filename: filename, chat: chat)
        records.insert(record, at: 0)
        emit(.chatsChanged(records))
        return filename
    }

    /// Deletes a chat file and removes it from memory.
    func deleteChat(filename: String) {
        streamTasks[filename]?.cancel()
        streamTasks[filename] = nil
        env.deleteChat(filename: filename)
        records.removeAll(where: { $0.filename == filename })
        if lastRetryableFilename == filename { lastRetryableFilename = nil }
        emit(.chatsChanged(records))
    }

    /// Renames a chat by setting its user-defined display title.
    func renameChat(filename: String, to newTitle: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var chat = records[idx].chat
        chat.title = trimmed.isEmpty ? nil : trimmed
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    /// Removes all chats that have no messages, except the one identified by
    /// `keep` (pass nil to prune every empty chat). Used when the user selects
    /// or creates a different chat so blank placeholders don't linger.
    func pruneEmptyChats(except keep: String?) {
        let toRemove = records.filter { $0.chat.messages.isEmpty && $0.filename != keep }
        guard !toRemove.isEmpty else { return }
        for record in toRemove {
            streamTasks[record.filename]?.cancel()
            streamTasks[record.filename] = nil
            env.deleteChat(filename: record.filename)
            if lastRetryableFilename == record.filename { lastRetryableFilename = nil }
        }
        records.removeAll(where: { toRemove.contains($0) })
    }

    /// Called when the user selects a chat: prunes other empty chats so the
    /// sidebar stays tidy.
    func selectChat(filename: String) {
        pruneEmptyChats(except: filename)
        emit(.chatsChanged(records))
    }

    /// Returns the record for a filename, if any.
    func record(for filename: String) -> ChatRecord? {
        records.first(where: { $0.filename == filename })
    }

    /// Persists a chat to disk and updates the in-memory record (without
    /// clobbering streaming/unread flags).
    private func saveChat(_ chat: Chat, filename: String) {
        env.saveChat(chat, filename: filename)
        if let idx = records.firstIndex(where: { $0.filename == filename }) {
            records[idx].chat = chat
        }
    }

    // MARK: - Sending messages

    /// Sends a user message and streams the assistant response for the given chat.
    /// Returns false (and emits an error) if no valid connection is selected.
    @discardableResult
    func sendMessage(filename: String, text: String) -> Bool {
        guard let record = records.first(where: { $0.filename == filename }) else { return false }
        guard let connectionID = record.chat.connection,
              !connectionID.isEmpty,
              let connection = connections.first(where: { $0.id == connectionID }) else {
            emit(.error("Please select a connection in the status bar."))
            return false
        }

        // If the last assistant message was a failed/error placeholder, drop it so the
        // new user message follows the previous user message directly.
        var baseChat = record.chat
        if let lastIdx = baseChat.messages.indices.last,
           baseChat.messages[lastIdx].role == .assistant,
           baseChat.messages[lastIdx].error != nil {
            baseChat.messages.remove(at: lastIdx)
        }

        // Build the message list including the system prompt from the selected role.
        var messages: [ChatMessage] = []
        if let roleName = baseChat.role,
           let role = roles.first(where: { $0.name == roleName }) {
            messages.append(ChatMessage(role: .system, content: role.content))
        }
        messages.append(contentsOf: baseChat.messages)
        messages.append(ChatMessage(role: .user, content: text))

        // Add the user message immediately and create a placeholder assistant message.
        var updatedChat = baseChat
        updatedChat.messages.append(ChatMessage(role: .user, content: text))
        updatedChat.messages.append(ChatMessage(role: .assistant, content: "", connectionName: connection.displayName))
        saveChat(updatedChat, filename: filename)
        sortAndEmit()

        lastRetryableFilename = filename
        runStream(for: filename, connection: connection, messages: messages)
        return true
    }

    /// Retries the last request for the given chat.
    func retryLastMessage(filename: String) {
        guard !isStreaming(filename: filename) else { return }
        guard lastRetryableFilename == filename else { return }
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        let chat = records[idx].chat
        guard let connectionID = chat.connection,
              let connection = connections.first(where: { $0.id == connectionID }) else {
            emit(.error("Please select a connection in the status bar."))
            return
        }

        // Reset the failed assistant message (the last one) to an empty placeholder.
        var updatedChat = chat
        if let lastIdx = updatedChat.messages.indices.last, updatedChat.messages[lastIdx].role == .assistant {
            updatedChat.messages[lastIdx].content = ""
            updatedChat.messages[lastIdx].thinking = nil
            updatedChat.messages[lastIdx].error = nil
            updatedChat.messages[lastIdx].connectionName = connection.displayName
        } else {
            updatedChat.messages.append(ChatMessage(role: .assistant, content: "", connectionName: connection.displayName))
        }
        records[idx].chat = updatedChat
        emit(.chatsChanged(records))

        // Rebuild the message history excluding the placeholder assistant message.
        var messages: [ChatMessage] = []
        if let roleName = updatedChat.role,
           let role = roles.first(where: { $0.name == roleName }) {
            messages.append(ChatMessage(role: .system, content: role.content))
        }
        for msg in updatedChat.messages.dropLast() {
            messages.append(msg)
        }

        runStream(for: filename, connection: connection, messages: messages)
    }

    /// Whether a stream is currently in flight for the given chat.
    func isStreaming(filename: String) -> Bool {
        records.first(where: { $0.filename == filename })?.isStreaming ?? false
    }

    /// Starts (or restarts) a streaming request for the given chat.
    private func runStream(for filename: String, connection: Connection, messages: [ChatMessage]) {
        if let idx = records.firstIndex(where: { $0.filename == filename }) {
            records[idx].isStreaming = true
            records[idx].lastError = nil
        }
        emit(.chatsChanged(records))

        let task = Task { [weak self] in
            do {
                let result = try await ChatService.shared.stream(
                    connection: connection,
                    messages: messages
                ) { @Sendable [weak self] chunk in
                    await self?.applyChunk(chunk, filename: filename)
                }
                _ = result
                await self?.finishStream(filename: filename)
            } catch is CancellationError {
                await self?.finishStream(filename: filename)
            } catch let error as URLError where error.code == .cancelled {
                await self?.finishStream(filename: filename)
            } catch {
                await self?.recordError(error.localizedDescription, filename: filename)
                await self?.finishStream(filename: filename)
            }
        }
        streamTasks[filename] = task
    }

    /// Applies a streamed chunk to the last assistant message of the given chat.
    private func applyChunk(_ chunk: StreamChunk, filename: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        var chat = records[idx].chat
        guard let lastIdx = chat.messages.indices.last else { return }
        switch chunk {
        case .thinking(let text):
            let existing = chat.messages[lastIdx].thinking ?? ""
            chat.messages[lastIdx].thinking = existing + text
        case .content(let text):
            chat.messages[lastIdx].content += text
        case .error(let text):
            chat.messages[lastIdx].error = text
        }
        records[idx].chat = chat
        // Coalesce: don't emit on every chunk. The flush fires on a timer,
        // collapsing a burst of deltas into one UI event. This keeps the
        // main-actor queue from backing up (the root cause of the sluggish
        // stop button for OpenAI-compatible providers with tiny deltas).
        scheduleCoalescedEmit()
    }

    /// Marks a stream as finished for the given chat, persisting the final
    /// state and clearing bookkeeping.
    private func finishStream(filename: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else {
            streamTasks[filename] = nil
            return
        }
        // Persist the final accumulated state to disk.
        let finalChat = records[idx].chat
        env.saveChat(finalChat, filename: filename)
        records[idx].isStreaming = false
        streamTasks[filename] = nil
        // Flag as unread so the user is notified of new activity (the UI clears
        // this when the chat is viewed).
        records[idx].hasUnreadActivity = true
        // Flush any pending coalesced emit first, then emit the final state
        // immediately so the UI reflects "stopped/finished" without delay.
        flushCoalescedEmit()
        emit(.chatsChanged(records))
    }

    /// Records an error onto the last assistant message of the given chat and persists it.
    private func recordError(_ text: String, filename: String) {
        emit(.error(text))
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        var chat = records[idx].chat
        if let lastIdx = chat.messages.indices.last, chat.messages[lastIdx].role == .assistant {
            chat.messages[lastIdx].error = text
        }
        records[idx].chat = chat
        records[idx].lastError = text
        env.saveChat(chat, filename: filename)
    }

    /// Cancels the in-flight stream for the given chat. Flips the streaming
    /// flag immediately so the UI reflects the stop right away; the stream
    /// task finalizes the message content asynchronously via `finishStream`.
    func stopStreaming(filename: String) {
        streamTasks[filename]?.cancel()
        if let idx = records.firstIndex(where: { $0.filename == filename }) {
            records[idx].isStreaming = false
            // Flush any pending coalesced emit first so the latest streamed
            // content is visible, then emit the stopped state immediately so
            // the stop button reacts without waiting for the coalesce timer.
            flushCoalescedEmit()
            emit(.chatsChanged(records))
        }
    }

    // MARK: - Message editing / deletion

    /// Edits the content of a message in place (plain text). Used by the
    /// message hover "edit" action. Persists the updated chat to disk.
    func editMessage(filename: String, messageID: UUID, newText: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        var chat = records[idx].chat
        guard let msgIdx = chat.messages.firstIndex(where: { $0.id == messageID }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.messages[msgIdx].content = trimmed
        // Clear any stale error/thinking on edit so the message renders cleanly.
        chat.messages[msgIdx].error = nil
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    /// Deletes a single message from the message tree by id. Persists the
    /// updated chat to disk.
    func deleteMessage(filename: String, messageID: UUID) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        var chat = records[idx].chat
        guard let msgIdx = chat.messages.firstIndex(where: { $0.id == messageID }) else { return }
        chat.messages.remove(at: msgIdx)
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    // MARK: - Selection updates

    /// Updates the selected connection for a chat.
    func setConnection(filename: String, connectionID: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        var chat = records[idx].chat
        chat.connection = connectionID
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    /// Updates the selected role for a chat.
    func setRole(filename: String, roleName: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        var chat = records[idx].chat
        chat.role = roleName
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    /// Clears the unread marker for a chat once the user views it.
    func markViewed(filename: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard records[idx].hasUnreadActivity else { return }
        records[idx].hasUnreadActivity = false
        emit(.chatsChanged(records))
    }
}
