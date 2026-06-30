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

    /// Information about the frontend's rendering capabilities, appended to
    /// every role's system prompt so the model knows what it can use.
    /// Built dynamically from the current config so disabled features are not
    /// advertised to the model.
    private func renderingCapabilities() async -> String {
        let mermaid = await ConfigManager.shared.getMermaidEnabled()
        let katex = await ConfigManager.shared.getKatexEnabled()
        var lines: [String] = [
            "",
            "--- Rendering capabilities ---",
            "Your responses are rendered in a chat UI with the following features:",
            "- GitHub-Flavored Markdown (tables, strikethrough, task lists, autolinks)",
            "- Syntax-highlighted code blocks (fenced with a language tag)",
        ]
        if katex {
            lines.append("- LaTeX math via KaTeX: use `$...$` for inline and `$$...$$` for block equations")
        } else {
            lines.append("- LaTeX math is NOT supported")
        }
        if mermaid {
            lines.append("- Mermaid diagrams: use a fenced code block with language `mermaid`")
        } else {
            lines.append("- Mermaid diagrams are NOT supported")
        }
        lines.append(contentsOf: [
            "- Inline HTML is allowed",
            "Use these features where appropriate to make your answers clearer.",
            "--- End rendering capabilities ---",
            "",
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - State

    private(set) var records: [ChatRecord] = []
    private(set) var roles: [Role] = []
    private(set) var connections: [Connection] = []
    /// Configured MCP servers. Loaded from disk and kept in sync via FSEvents.
    private(set) var mcps: [MCPServer] = []

    /// The filename of the chat the user is currently viewing. Used to suppress
    /// the unread marker when a stream finishes for the chat that's already on
    /// screen — the user has seen the answer, so no notification is needed.
    private(set) var selectedFilename: String?

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

    /// Filenames of chats for which a name-generation request is in flight.
    /// Prevents duplicate concurrent naming attempts for the same chat.
    private var namingInProgress: Set<String> = []

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
        // Wire MCPManager errors into the engine's error event bus so the UI
        // can surface connection failures without crashing the stream.
        Task { await MCPManager.shared.setErrorHandler { [weak self] message in
            Task { await self?.emit(.error(message)) }
        } }
        // Wire MCPManager progress notifications into the engine so streaming
        // tool output is folded onto the live `tool`-role message in the
        // originating chat (identified by chatFilename + callID) and pushed to
        // the renderer as it arrives. No global scan: the sink carries the
        // chatFilename so we update one message in one chat directly.
        Task { await MCPManager.shared.setProgressHandler { [weak self] chatFilename, callID, partial in
            Task { await self?.updateStreamingToolResult(chatFilename: chatFilename, callID: callID, partial: partial) }
        } }
        reloadAll(shouldEmit: false)
        startWatching()
        emit(.chatsChanged(records))
        emit(.rolesChanged(roles))
        emit(.connectionsChanged(connections))
        emit(.mcpsChanged(mcps))
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
            continuation.yield(.mcpsChanged(self.mcps))
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
            (env.connectionsURL.path, .connections),
            (env.mcpsURL.path, .mcps)
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
        case .mcps:
            reloadMCPs()
        }
        // Validate config references after any environment change so that
        // stale default_connection / default_role / utility_connection
        // entries are cleared from the config file.
        Task { await ConfigManager.shared.validateReferences() }
    }

    /// Reloads MCP servers from disk, reconciles the runtime connections in
    /// `MCPManager`, and emits the updated set. Called on launch and whenever
    /// the `mcp/` directory changes via FSEvents.
    private func reloadMCPs() {
        mcps = env.loadMCPs()
        let snapshot = mcps
        Task { await MCPManager.shared.reload(snapshot) }
        emit(.mcpsChanged(mcps))
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
        mcps = env.loadMCPs()
        // Reconcile MCP runtime connections with the loaded config.
        let mcpSnapshot = mcps
        Task { await MCPManager.shared.reload(mcpSnapshot) }
        // Drop bookkeeping for chats that no longer exist.
        let validIDs = Set(records.map { $0.id })
        streamTasks = streamTasks.filter { validIDs.contains($0.key) }
        if shouldEmit {
            emit(.chatsChanged(records))
            emit(.rolesChanged(roles))
            emit(.connectionsChanged(connections))
            emit(.mcpsChanged(mcps))
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
    /// blank "New chat" entries. Applies default connection and role from the
    /// app config if set.
    @discardableResult
    func createNewChat() async -> String {
        pruneEmptyChats(except: nil)
        let filename = env.newChatFilename()
        var chat = Chat()

        // Apply config defaults for new chats (read from ConfigManager).
        let config = ConfigManager.shared
        let dc = await config.getDefaultConnection()
        let dr = await config.getDefaultRole()
        // Verify the defaults still reference valid items.
        if let conn = dc, self.connections.contains(where: { $0.id == conn }) {
            chat.connection = conn
        }
        if let role = dr, self.roles.contains(where: { $0.name == role }) {
            chat.role = role
        }
        // Seed the chat with all configured MCP servers by default.
        let allMcpNames = self.mcps.map(\.name)
        if !allMcpNames.isEmpty {
            chat.mcps = allMcpNames
        }
        env.saveChat(chat, filename: filename)
        let record = ChatRecord(filename: filename, chat: chat)
        records.insert(record, at: 0)
        emit(.chatsChanged(records))
        return filename
    }

    /// Deletes a chat file and removes it from memory, including its image
    /// folder on disk.
    func deleteChat(filename: String) {
        streamTasks[filename]?.cancel()
        streamTasks[filename] = nil
        env.deleteChat(filename: filename)
        env.deleteAllImages(for: filename)
        records.removeAll(where: { $0.filename == filename })
        if lastRetryableFilename == filename { lastRetryableFilename = nil }
        if selectedFilename == filename { selectedFilename = nil }
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
        selectedFilename = filename
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
    ///
    /// `pendingImages` are in-memory attachments that are committed to disk
    /// (resized + re-encoded + saved) only at this point — i.e. when the user
    /// actually sends the message. If the user cancels, nothing is written.
    @discardableResult
    func sendMessage(filename: String, text: String, pendingImages: [PendingImageAttachment] = []) async -> Bool {
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

        // Commit pending images to disk now that the user has actually sent.
        // Each attachment is resized/re-encoded and saved into the chat's
        // image folder; the returned ImageAttachment refs are persisted on
        // the user message and used to build the request payload.
        let committed: [ImageAttachment] = pendingImages.compactMap {
            ImageManager.commit($0, chatFilename: filename)
        }

        // Build the message list including the system prompt from the selected role.
        var messages: [ChatMessage] = []
        if let roleName = baseChat.role,
           let role = roles.first(where: { $0.name == roleName }) {
            let caps = await renderingCapabilities()
            messages.append(ChatMessage(role: .system, content: role.content + caps))
        }
        messages.append(contentsOf: baseChat.messages)
        let userMessage = ChatMessage(role: .user, content: text, images: committed.isEmpty ? nil : committed)
        messages.append(userMessage)

        // Add the user message immediately and create a placeholder assistant message.
        var updatedChat = baseChat
        updatedChat.messages.append(userMessage)
        updatedChat.messages.append(ChatMessage(role: .assistant, content: "", connectionName: connection.displayName))
        saveChat(updatedChat, filename: filename)
        sortAndEmit()

        lastRetryableFilename = filename
        runToolLoop(for: filename, connection: connection, messages: messages)

        // Fire-and-forget: try to generate a chat name via the utility connection
        // if this chat doesn't have a title yet.
        maybeGenerateChatName(filename: filename)

        return true
    }

    /// Retries the last request for the given chat.
    func retryLastMessage(filename: String) async {
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
            let caps = await renderingCapabilities()
            messages.append(ChatMessage(role: .system, content: role.content + caps))
        }
        for msg in updatedChat.messages.dropLast() {
            messages.append(msg)
        }

        runToolLoop(for: filename, connection: connection, messages: messages)
    }

    /// Whether a stream is currently in flight for the given chat.
    func isStreaming(filename: String) -> Bool {
        records.first(where: { $0.filename == filename })?.isStreaming ?? false
    }

    /// Starts (or restarts) the tool-calling loop for the given chat. The loop
    /// iterates: stream a completion with tools attached → if the model emitted
    /// tool calls, execute them via `MCPManager`, append the results, and stream
    /// again. Repeats until the model responds with no tool calls or the
    /// max-iteration guard is hit.
    private func runToolLoop(for filename: String, connection: Connection, messages: [ChatMessage]) {
        if let idx = records.firstIndex(where: { $0.filename == filename }) {
            records[idx].isStreaming = true
            records[idx].lastError = nil
        }
        emit(.chatsChanged(records))

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performToolLoop(filename: filename, connection: connection, messages: messages)
        }
        streamTasks[filename] = task
    }

    /// The body of the tool-calling loop. Runs as a detached task so it can
    /// await MCP calls and re-stream without holding the actor.
    private func performToolLoop(filename: String, connection: Connection, messages: [ChatMessage]) async {
        // The working message history grows as tool calls + results are appended.
        var history = messages
        // Max iterations to prevent infinite tool-calling loops.
        let maxIterations = 10

        for _ in 0..<maxIterations {
            // Gather tools from the chat's active MCP servers. Individual
            // server failures are collected and surfaced but don't abort the
            // whole request — the model still gets the working servers' tools.
            let toolDefs = await gatherTools(filename: filename)

            do {
                let result = try await ChatService.shared.stream(
                    connection: connection,
                    messages: history,
                    chatFilename: filename,
                    tools: toolDefs.isEmpty ? nil : toolDefs
                ) { @Sendable [weak self] chunk in
                    await self?.applyChunk(chunk, filename: filename)
                }

                // No tool calls → the loop is done; finalize the stream.
                if result.toolCalls.isEmpty {
                    finishStream(filename: filename)
                    return
                }

                // The model emitted tool calls. They were already accumulated
                // onto the assistant message during streaming (via
                // `applyChunk(.toolCall)`); ensure they're set in case the
                // service returned them only in the final result.
                applyToolCalls(result.toolCalls, filename: filename)
                // Flush immediately so the tool-call block appears in the UI
                // before we begin (potentially slow) tool execution.
                flushCoalescedEmit()
                emit(.chatsChanged(records))

                // Append the assistant message (with tool calls) to history.
                // We read the finalized assistant message from the record so
                // its content/thinking/toolCalls match what was streamed.
                if let idx = records.firstIndex(where: { $0.filename == filename }) {
                    let assistantMsg = records[idx].chat.messages.last(where: { $0.role == .assistant })
                    if let assistantMsg {
                        history.append(assistantMsg)
                    }
                }

                // Execute each tool call and append its result as its own
                // `tool`-role `ChatMessage` tagged with `callID` — the natural
                // provider shape. The renderer folds these back onto the
                // preceding assistant `toolCalls` as a view projection, so the
                // visible inline tool block is unchanged. The provider history
                // is built directly from these messages by `ChatService` (no
                // un-folding `flatMap` needed).
                for call in result.toolCalls {
                    let toolResult = await executeToolCall(call, filename: filename)
                    // Append the result as a `tool`-role message and persist.
                    appendToolResult(toolResult, filename: filename)
                    // Mirror into the working history so the next stream
                    // request includes it.
                    history.append(ChatMessage(role: .tool, content: toolResult.content, toolResults: [toolResult]))
                }

                // Create a new assistant message for the model's follow-up
                // response so it doesn't get appended to the tool-result
                // message.
                appendAssistantMessage(filename: filename, connection: connection)

                // Loop again: the model will see the tool results and either
                // call more tools or produce a final answer.
            } catch is CancellationError {
                finishStream(filename: filename)
                return
            } catch let error as URLError where error.code == .cancelled {
                finishStream(filename: filename)
                return
            } catch {
                recordError(error.localizedDescription, filename: filename)
                finishStream(filename: filename)
                return
            }
        }

        // Max iterations exceeded — surface an error and stop.
        recordError("Tool-calling loop exceeded \(maxIterations) iterations.", filename: filename)
        finishStream(filename: filename)
    }

    /// Gathers tool definitions from the chat's active MCP servers. Failures
    /// of individual servers are collected and surfaced via `.error` but don't
    /// abort the request; the model still gets the working servers' tools.
    private func gatherTools(filename: String) async -> [ToolDefinition] {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return [] }
        let activeNames = records[idx].chat.mcps ?? []
        guard !activeNames.isEmpty else { return [] }

        var defs: [ToolDefinition] = []
        for serverName in activeNames {
            do {
                let tools = try await MCPManager.shared.listTools(for: serverName)
                defs.append(contentsOf: tools.map { tool in
                    ToolDefinition(
                        serverName: serverName,
                        name: tool.name,
                        description: tool.description,
                        inputSchema: tool.inputSchema
                    )
                })
            } catch {
                emit(.error("MCP server \"\(serverName)\" tools unavailable: \(error.localizedDescription)"))
            }
        }
        return defs
    }

    /// Records tool calls onto the last assistant message of the chat so the
    /// renderer can display them (and show a "running" state until results arrive).
    private func applyToolCalls(_ calls: [ToolCall], filename: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        var chat = records[idx].chat
        if let lastIdx = chat.messages.indices.last, chat.messages[lastIdx].role == .assistant {
            chat.messages[lastIdx].toolCalls = calls
        }
        records[idx].chat = chat
        scheduleCoalescedEmit()
    }

    /// Executes a single tool call via `MCPManager`, going through the approval
    /// hook (which auto-approves in this iteration). Returns the tool result.
    /// `filename` is the owning chat's filename, forwarded to `MCPManager` so
    /// progress notifications route to this chat's live `tool`-role message.
    private func executeToolCall(_ call: ToolCall, filename: String) async -> ToolResult {
        // The approval hook. This iteration auto-approves every call; a future
        // UI can intercept here to present a deny/allow-once/allow-always sheet.
        let approval = await approveToolCall(chatFilename: filename, call: call)
        switch approval {
        case .allow:
            // Resolve the server + tool name from the namespaced call name.
            guard let parsed = ToolDefinition.parse(call.name) else {
                return ToolResult(callID: call.id, content: "Could not parse tool name \"\(call.name)\".", isError: true)
            }
            return await MCPManager.shared.callTool(server: parsed.server, name: parsed.tool, arguments: call.arguments, callID: call.id, chatFilename: filename)
        case .deny(let reason):
            return ToolResult(callID: call.id, content: "User denied the tool call: \(reason)", isError: true)
        }
    }

    /// The tool-call approval decision point. This iteration auto-approves
    /// every call (equivalent to "allow always"). A future UI can replace the
    /// body to present a sheet and await the user's choice.
    private func approveToolCall(chatFilename: String, call: ToolCall) async -> ToolApproval {
        return .allow
    }

    /// Appends a tool result as its own `tool`-role `ChatMessage` (tagged with
    /// `callID` via `toolResults`) — the natural provider shape. If a streaming
    /// placeholder message for this `callID` already exists (created by
    /// `updateStreamingToolResult`), it is replaced in place rather than
    /// duplicated, so the final result supersedes the partial content. Persists
    /// and emits.
    private func appendToolResult(_ result: ToolResult, filename: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        var chat = records[idx].chat
        // If a streaming placeholder `tool`-role message exists for this
        // callID, replace it in place with the final result.
        if let tIdx = chat.messages.indices.reversed().first(where: {
            chat.messages[$0].role == .tool
                && chat.messages[$0].toolResults?.contains(where: { $0.callID == result.callID }) ?? false
        }) {
            chat.messages[tIdx] = ChatMessage(role: .tool, content: result.content, toolResults: [result])
        } else {
            // No placeholder yet — append a new `tool`-role message.
            chat.messages.append(ChatMessage(role: .tool, content: result.content, toolResults: [result]))
        }
        records[idx].chat = chat
        env.saveChat(chat, filename: filename)
        scheduleCoalescedEmit()
    }

    /// Updates a `tool`-role message's content live as the MCP server streams
    /// progress notifications. Called from the progress sink registered in
    /// `start()`. Routes directly to the one chat identified by `chatFilename`
    /// and the one `tool`-role message carrying `callID` (creating a streaming
    /// placeholder if none exists yet), appends the partial text, marks it
    /// `isStreaming = true`, persists, and emits. When the call completes,
    /// `appendToolResult` replaces the placeholder with the final result.
    private func updateStreamingToolResult(chatFilename: String, callID: String, partial: String) {
        guard let idx = records.firstIndex(where: { $0.filename == chatFilename }) else { return }
        var chat = records[idx].chat
        // Find the `tool`-role message carrying an in-flight result for this
        // callID and append to its streaming content.
        if let tIdx = chat.messages.indices.reversed().first(where: {
            chat.messages[$0].role == .tool
                && chat.messages[$0].toolResults?.contains(where: { $0.callID == callID }) ?? false
        }), var results = chat.messages[tIdx].toolResults, let rIdx = results.firstIndex(where: { $0.callID == callID }) {
            results[rIdx].content += partial + "\n"
            results[rIdx].isStreaming = true
            chat.messages[tIdx].toolResults = results
            records[idx].chat = chat
            env.saveChat(chat, filename: chatFilename)
            scheduleCoalescedEmit()
            return
        }
        // No existing `tool`-role message yet — the progress notification
        // arrived before `appendToolResult` created one. Create a streaming
        // placeholder now so the user sees output immediately. It will be
        // replaced by the final result when the call completes.
        let placeholder = ToolResult(callID: callID, content: partial + "\n", isError: false, isStreaming: true)
        chat.messages.append(ChatMessage(role: .tool, content: placeholder.content, toolResults: [placeholder]))
        records[idx].chat = chat
        env.saveChat(chat, filename: chatFilename)
        scheduleCoalescedEmit()
    }

    /// Appends a new (empty) assistant message that the next stream iteration
    /// will fill with the model's follow-up response. After a tool call, the
    /// conversation has three distinct blocks: the user message, the assistant
    /// message carrying the tool call + result, and this new assistant message
    /// with the final answer. Persists and emits immediately so the new row
    /// appears right away.
    private func appendAssistantMessage(filename: String, connection: Connection) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        var chat = records[idx].chat
        chat.messages.append(ChatMessage(role: .assistant, content: "", connectionName: connection.displayName))
        records[idx].chat = chat
        env.saveChat(chat, filename: filename)
        flushCoalescedEmit()
        emit(.chatsChanged(records))
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
        case .toolCall(let call):
            // Accumulate tool calls as they're emitted at stream end.
            var calls = chat.messages[lastIdx].toolCalls ?? []
            calls.append(call)
            chat.messages[lastIdx].toolCalls = calls
        case .finishReason:
            // No state change needed; the finish reason is used by the loop
            // via the StreamResult return value.
            break
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
        // Flag as unread so the user is notified of new activity — but only if
        // this isn't the chat the user is currently looking at. When the
        // finished chat is the selected one the user has already seen the
        // answer, so marking it unread would only surface a stale circle once
        // they switch away.
        if records[idx].filename != selectedFilename {
            records[idx].hasUnreadActivity = true
        }
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

    // MARK: - Chat naming

    /// Kicks off a background request to generate a chat name via the utility
    /// connection, if one is configured and the chat still has no title.
    /// This is fire-and-forget and runs in parallel to the main stream.
    private func maybeGenerateChatName(filename: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }),
              records[idx].chat.title == nil,
              !namingInProgress.contains(filename) else { return }

        guard let firstUserMsg = records[idx].chat.messages.first(where: { $0.role == .user }) else { return }
        let firstUserText = firstUserMsg.content

        namingInProgress.insert(filename)

        Task { [weak self] in
            defer {
                Task { [weak self] in
                    await self?.clearNamingInProgress(filename)
                }
            }

            let config = ConfigManager.shared
            guard let utilityConnID = await config.getUtilityConnection() else { return }
            guard let self else { return }
            guard let utilityConn = await self.connections.first(where: { $0.id == utilityConnID }) else { return }

            let systemPrompt = """
                The user just started a new chat and the following is their first message. \
                This message is NOT a request to you, we only need to figure out a good chat name based on it.
                Generate a short, descriptive chat name that captures the essence of their request. \
                The name must be in the same language as the user's message. \
                Respond with ONLY the chat name — no quotes, no punctuation, no explanations, no markdown. \
                Keep it concise, ideally under 50 characters.
                """

            let messages: [ChatMessage] = [
                ChatMessage(role: .system, content: systemPrompt),
                ChatMessage(role: .user, content: firstUserText),
            ]

            do {
                let result = try await ChatService.shared.stream(
                    connection: utilityConn,
                    messages: messages,
                    chatFilename: filename,
                    onChunk: { _ in }
                )
                let trimmed = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                await self.applyGeneratedName(filename: filename, name: trimmed)
            } catch {
                // Silently ignore — naming is best-effort.
            }
        }
    }

    /// Applies a generated name to a chat only if it still has no title
    /// (the user may have renamed it in the meantime).
    ///
    /// When the chat is still streaming we only update the title in memory;
    /// the next coalesced emit (for a content chunk) will push it to the UI,
    /// and `finishStream` will persist it to disk.  When the stream has already
    /// finished we persist and emit right away so the sidebar updates immediately.
    private func applyGeneratedName(filename: String, name: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }),
              records[idx].chat.title == nil else { return }
        records[idx].chat.title = name
        if !records[idx].isStreaming {
            env.saveChat(records[idx].chat, filename: filename)
            emit(.chatsChanged(records))
        }
    }

    /// Removes a filename from the naming-in-progress set.
    private func clearNamingInProgress(_ filename: String) {
        namingInProgress.remove(filename)
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
    /// updated chat to disk and removes any image files owned by the message.
    func deleteMessage(filename: String, messageID: UUID) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        var chat = records[idx].chat
        guard let msgIdx = chat.messages.firstIndex(where: { $0.id == messageID }) else { return }
        // Clean up image files owned by the deleted message.
        if let images = chat.messages[msgIdx].images {
            for img in images {
                env.deleteImage(img, chatFilename: filename)
            }
        }
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

    /// Updates the set of active MCP servers for a chat. `names` is the list
    /// of server names to enable; pass an empty array (or nil) to disable all.
    func setActiveMCPs(filename: String, names: [String]?) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        var chat = records[idx].chat
        let filtered = (names ?? []).filter { name in self.mcps.contains(where: { $0.name == name }) }
        chat.mcps = filtered.isEmpty ? nil : filtered
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

// MARK: - Tool approval

/// The outcome of the tool-call approval decision point. This iteration auto-
/// approves every call (`.allow`); a future UI can return `.deny` to block a
/// call and feed an error result back to the model.
enum ToolApproval: Sendable {
    case allow
    case deny(reason: String)
}
