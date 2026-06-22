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
                lastError: existing?.lastError
            ))
        }
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
                        lastError: nil
                    ))
                }
            } else {
                // New chat appeared on disk.
                newRecords.append(ChatRecord(filename: filename, chat: diskChat))
            }
        }
        records = newRecords
        // Drop bookkeeping for deleted chats.
        streamTasks = streamTasks.filter { loadedIDs.contains($0.key) }
        emit(.chatsChanged(records))
    }

    // MARK: - Chat management

    /// Creates a new empty chat and returns its filename.
    @discardableResult
    func createNewChat() -> String {
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
        updatedChat.messages.append(ChatMessage(role: .assistant, content: ""))
        saveChat(updatedChat, filename: filename)

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
        } else {
            updatedChat.messages.append(ChatMessage(role: .assistant, content: ""))
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
                // User-initiated stop: finalize whatever was streamed so far.
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
        emit(.chatsChanged(records))
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

    /// Cancels the in-flight stream for the given chat.
    func stopStreaming(filename: String) {
        streamTasks[filename]?.cancel()
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
