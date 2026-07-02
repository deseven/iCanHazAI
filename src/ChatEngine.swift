// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import FSEventsWrapper

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
    /// Live MCP configuration status, mirrored from `MCPManager`'s status
    /// sink. Drives the configuration overlay. The UI layer adds the display
    /// delay; the engine only carries the logical state.
    private(set) var mcpConfiguration: MCPConfigurationState = .empty
    /// Guards against concurrent MCP configuration passes (e.g. a launch
    /// configure racing with an FSEvent-driven reconfigure).
    private var isConfiguringMCPs = false
    /// A single-flight queue of pending server reconfigures, keyed by server
    /// name. Coalesces a burst of FSEvents for the same server into one
    /// reconfigure. Cleared once the reconfigure completes.
    private var pendingReconfigures: [String: Task<Void, Never>] = [:]
    /// Guards `pendingReconfigures` re-entrancy.
    private var didInitialConfigure = false

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

    /// Filenames of chats for which a name-generation request is in flight.
    /// Prevents duplicate concurrent naming attempts for the same chat.
    private var namingInProgress: Set<String> = []

    private let env = EnvironmentManager.shared
    private var watcher: EnvironmentWatcher?

    // MARK: - Self-write suppression & per-path debouncing

    /// Paths we just wrote ourselves, mapped to the time their suppression
    /// expires. Events for these paths are ignored until the expiry passes.
    /// This is per-path: writing `chats/foo.json` does not suppress events for
    /// `chats/bar.json`. Replaces the former global `selfWriteSuppressionUntil`.
    private var selfWriteSuppressedPaths: [String: Date] = [:]
    /// How long after one of our own saves we ignore FSEvents for that path.
    /// Covers the atomic-write burst (temp file create → temp remove → rename).
    private let selfWriteSuppressionInterval: TimeInterval = 1.0
    /// Pending debounced reload tasks, keyed by file path. A burst of events
    /// for the same file collapses into a single reload once the burst settles.
    private var pendingReloads: [String: Task<Void, Never>] = [:]
    /// Settle interval for per-path debouncing of external FSEvents.
    private let reloadDebounceInterval: UInt64 = 80_000_000 // 80ms
    /// Paths for which we've already logged a self-write suppression line in
    /// the current burst. Prevents the atomic-write event storm (temp create,
    /// temp rename, target rename, target modify, …) from producing one
    /// "suppressed" log line per event. Cleared shortly after the suppression
    /// window expires so a later external write is logged again.
    private var loggedSuppressionForPath: Set<String> = []

    /// The file kind classification used by the event router to dispatch
    /// per-file reloads. `nil` means the path should be ignored (noise).
    private enum FileKind: Sendable {
        case chat
        case role
        case connectionOpenai
        case connectionAnthropic
        case mcp
        case config
    }

    // MARK: - Event bus

    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    private init() {}

    /// Starts loading and watching the environment. Must be called once at launch.
    /// Whether `start()` has already run. Idempotency guard.
    private var didStart = false

    func start() async {
        guard !didStart else { return }
        didStart = true
        // Consume the synchronously-bootstrapped config before anything else
        // runs. This guarantees `didLoad` is true (and the in-memory config
        // reflects disk) before the FSEvents watcher is started, so no
        // event-driven `validateReferences()` can race ahead of the initial
        // load and persist a wiped/empty config.
        await ConfigManager.shared.load()
        debugLog("Engine", "start — ensuring directories and wiring MCP handlers")
        env.ensureDirectories()
        // Wire the ConfigManager self-write hook so our own config.toml writes
        // are registered in the per-path suppression registry before the
        // atomic-write burst hits FSEvents.
        let configPath = env.rootURL.appendingPathComponent("config.toml").path
        Task { await ConfigManager.shared.setWillWriteConfigHook { [configPath] in
            // The hook runs on the ConfigManager actor; hop into the engine to
            // register the suppressed path. We use a non-isolated registration
            // method so we don't deadlock waiting on the engine actor.
            ChatEngine.shared.registerSelfWrite(path: configPath)
        } }
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
        // Wire MCPManager configuration-status updates into the engine so the
        // UI overlay can reflect each server's connect/listTools progress. The
        // handler hops back into the engine actor to update `mcpConfiguration`
        // and emit the snapshot.
        Task { await MCPManager.shared.setStatusHandler { [weak self] state in
            Task { await self?.handleMCPConfigurationState(state) }
        } }
        reloadAll(shouldEmit: false)
        startWatching()
        debugLog("Engine", "start complete — \(records.count) chats, \(connections.count) connections, \(mcps.count) MCP servers, \(roles.count) roles")
        emit(.chatsChanged(records))
        emit(.rolesChanged(roles))
        emit(.connectionsChanged(connections))
        emit(.mcpsChanged(mcps))
        // Kick off the initial MCP configuration pass now that configs are
        // loaded. This connects stdio servers, queries tools, and reports
        // status for the overlay. Skipped if no MCPs are configured.
        configureMCPs()
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
        // Single root watch on ~/iCanHazAI. FSEvents watches recursively; each
        // event carries the full path of the affected file. The callback hops
        // back into the actor via a Task.
        watcher = EnvironmentWatcher(rootPath: env.rootURL.path) { [weak self] event in
            Task { [weak self] in
                await self?.handleFSEvent(event)
            }
        }
        watcher?.start()
    }

    // MARK: - FSEvent router

    /// The central event router. Every incoming `FSEvent` is classified by
    /// path and type, checked against the per-path self-write suppression
    /// registry, debounced per-path, and dispatched to the appropriate
    /// per-kind handler.
    private func handleFSEvent(_ event: FSEvent) {
        switch event {
        case .mustScanSubDirs(let path, let reason):
            debugLog("FSEvents", "mustScanSubDirs at \(env.relativePath(URL(fileURLWithPath: path))) — reason=\(reason) → full rescan")
            fullRescan()
            return
        case .rootChanged(let path, _):
            debugLog("FSEvents", "rootChanged at \(path) → full rescan")
            fullRescan()
            return
        // Ignore these event types entirely — they don't affect content.
        case .itemInodeMetadataModified, .itemXattrModified,
             .itemOwnershipModified, .itemFinderInfoModified,
             .volumeMounted, .volumeUnmounted,
             .eventIdsWrapped, .streamHistoryDone, .generic:
            return
        // Content-affecting events — classify and route below.
        case .itemCreated(_, let itemType, _, _),
             .itemRemoved(_, let itemType, _, _),
             .itemDataModified(_, let itemType, _, _),
             .itemRenamed(_, let itemType, _, _),
             .itemClonedAtPath(_, let itemType, _, _):
            // Ignore directory events — we only care about files.
            guard itemType == .file else { return }
            break
        }

        let path: String
        switch event {
        case .itemCreated(let p, _, _, _),
             .itemRemoved(let p, _, _, _),
             .itemDataModified(let p, _, _, _),
             .itemRenamed(let p, _, _, _),
             .itemClonedAtPath(let p, _, _, _):
            path = p
        default:
            return
        }

        // Classify the path. Unknown paths are noise (image subdirs, temp
        // files, .DS_Store, etc.) and are ignored early — without logging,
        // since the atomic-write temp files would otherwise spam the log.
        guard let kind = classifyPath(path) else {
            return
        }

        // Per-path self-write suppression: if we just wrote this file, ignore
        // the resulting event burst. The atomic-write produces several events
        // (temp create/rename, target rename/modify); we log only the first
        // suppressed event per path so a single self-write is one log line.
        if isSuppressed(path) {
            if !loggedSuppressionForPath.contains(path) {
                loggedSuppressionForPath.insert(path)
                debugLog("FSEvents", "suppressed (self-write) — \(env.relativePath(URL(fileURLWithPath: path)))")
                // Clear the flag after the suppression window so a later
                // external write to the same path is logged again.
                let clearPath = path
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await self?.clearLoggedSuppression(clearPath)
                }
            }
            return
        }

        // Per-path debounce: collapse a burst of events for the same file into
        // a single reload.
        scheduleReload(path: path, kind: kind, event: event)
    }

    /// A short label for an FSEvent, for logging.
    private func eventLabel(_ event: FSEvent) -> String {
        switch event {
        case .itemCreated: return "itemCreated"
        case .itemRemoved: return "itemRemoved"
        case .itemDataModified: return "itemDataModified"
        case .itemRenamed: return "itemRenamed"
        case .itemClonedAtPath: return "itemCloned"
        case .mustScanSubDirs: return "mustScanSubDirs"
        case .rootChanged: return "rootChanged"
        case .itemInodeMetadataModified: return "itemInodeMetaMod"
        case .itemXattrModified: return "itemXattrMod"
        case .itemOwnershipModified: return "itemOwnerMod"
        case .itemFinderInfoModified: return "itemFinderInfoMod"
        case .volumeMounted: return "volumeMounted"
        case .volumeUnmounted: return "volumeUnmounted"
        case .eventIdsWrapped: return "eventIdsWrapped"
        case .streamHistoryDone: return "streamHistoryDone"
        case .generic: return "generic"
        }
    }

    /// Maps an absolute path to a file kind, or nil if the path is noise.
    /// Chat image subdirectories, atomic-write temp files, .DS_Store, and
    /// any path outside our target file patterns return nil.
    private func classifyPath(_ path: String) -> FileKind? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent

        // config.toml at the root.
        if name == "config.toml", url.deletingLastPathComponent().path == env.rootURL.path {
            return .config
        }
        // chats/*.json — but ignore anything under chats/<name>/ (image dirs).
        if url.deletingLastPathComponent().path == env.chatsURL.path, ext == "json" {
            return .chat
        }
        // roles/*.md
        if url.deletingLastPathComponent().path == env.rolesURL.path, ext == "md" {
            return .role
        }
        // connections/openai/*.jsonc
        if url.deletingLastPathComponent().path == env.openaiConnectionsURL.path, ext == "jsonc" {
            return .connectionOpenai
        }
        // connections/anthropic/*.jsonc
        if url.deletingLastPathComponent().path == env.anthropicConnectionsURL.path, ext == "jsonc" {
            return .connectionAnthropic
        }
        // mcp/*.toml
        if url.deletingLastPathComponent().path == env.mcpsURL.path, ext == "toml" {
            return .mcp
        }
        return nil
    }

    // MARK: - Per-path self-write suppression

    /// Lock-protected suppression registry shared between the actor-isolated
    /// engine and the non-isolated `registerSelfWrite` entry point (called by
    /// the ConfigManager actor). Lives outside the actor's isolation so it can
    /// be mutated from any thread without hopping.
    private final class SuppressionRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Date] = [:]

        /// Registers a path as just-written, with the given expiry.
        func register(_ path: String, expiry: Date) {
            lock.lock()
            entries[path] = expiry
            lock.unlock()
        }

        /// Drains and returns all pending registrations, clearing the box.
        /// Called from the actor when checking suppression so new entries from
        /// other actors are merged in.
        func drain() -> [String: Date] {
            lock.lock()
            let copy = entries
            entries.removeAll()
            lock.unlock()
            return copy
        }
    }
    private let suppressionRegistry = SuppressionRegistry()

    /// Non-actor-isolated registration entry point. Safe to call from any
    /// actor/thread (e.g. the ConfigManager `willWriteConfig` hook).
    nonisolated func registerSelfWrite(path: String) {
        let expiry = Date().addingTimeInterval(1.0)
        suppressionRegistry.register(path, expiry: expiry)
        debugLog("FSEvents", "registered self-write suppression for \(path) until \(expiry)")
    }

    /// Actor-isolated check: returns true if the path is currently suppressed.
    /// Merges pending registrations from the lock-protected registry first so
    /// we don't miss registrations from other actors.
    private func isSuppressed(_ path: String) -> Bool {
        // Pull any new registrations from the lock-protected registry.
        for (k, v) in suppressionRegistry.drain() {
            selfWriteSuppressedPaths[k] = v
        }

        let now = Date()
        // Prune expired entries.
        selfWriteSuppressedPaths = selfWriteSuppressedPaths.filter { $0.value > now }
        return selfWriteSuppressedPaths[path] != nil
    }

    /// Actor-isolated registration, used by the engine's own save call sites.
    private func markSelfWrite(path: String) {
        selfWriteSuppressedPaths[path] = Date().addingTimeInterval(selfWriteSuppressionInterval)
    }

    /// Clears the "already logged suppression" flag for a path so a later
    /// external write to the same path produces a log line again.
    private func clearLoggedSuppression(_ path: String) {
        loggedSuppressionForPath.remove(path)
    }

    // MARK: - Per-path debouncing

    /// Schedules a debounced reload for the given path. A burst of events for
    /// the same file collapses into a single reload after the settle interval.
    private func scheduleReload(path: String, kind: FileKind, event: FSEvent) {
        pendingReloads[path]?.cancel()
        let interval = reloadDebounceInterval
        pendingReloads[path] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled else { return }
            await self?.executeReload(path: path, kind: kind, event: event)
        }
        debugLog("FSEvents", "scheduled debounced reload for \(env.relativePath(URL(fileURLWithPath: path)))")
    }

    /// Executes the single-file reload for a debounced event. Dispatches to the
    /// per-kind handler based on the event type.
    private func executeReload(path: String, kind: FileKind, event: FSEvent) {
        pendingReloads[path] = nil
        let url = URL(fileURLWithPath: path)
        let relPath = env.relativePath(url)
        debugLog("FSEvents", "executing reload — kind=\(kind), path=\(relPath)")

        switch kind {
        case .chat:
            handleChatFileEvent(event, url: url)
        case .role:
            handleRoleFileEvent(event, url: url)
        case .connectionOpenai, .connectionAnthropic:
            handleConnectionFileEvent(event, url: url)
        case .mcp:
            handleMCPFileEvent(event, url: url)
        case .config:
            handleConfigFileEvent(event, url: url)
        }

        // Validate config references after any environment change so stale
        // default_connection / default_role / utility_connection entries are
        // cleared from the config file.
        Task { await ConfigManager.shared.validateReferences() }
    }

    // MARK: - Per-kind handlers

    /// Handles an FSEvent for a chat file. `itemRenamed` is treated as
    /// removed(old) + created(new); since the wrapper fires two events, each
    /// is handled independently here.
    private func handleChatFileEvent(_ event: FSEvent, url: URL) {
        let filename = url.lastPathComponent
        switch event {
        case .itemCreated, .itemClonedAtPath, .itemDataModified, .itemRenamed:
            // A rename fires two events; the "new name" one is effectively a
            // create/modify. Reload the single file.
            guard let chat = env.loadSingleChat(filename: filename) else {
                debugLog("FSEvents", "chat reload failed (undecodable/missing) — \(filename)")
                return
            }
            // Streaming chat protection: don't clobber in-memory streaming state.
            if let idx = records.firstIndex(where: { $0.filename == filename }), records[idx].isStreaming {
                debugLog("FSEvents", "chat \(filename) is streaming — keeping in-memory state")
                return
            }
            if let idx = records.firstIndex(where: { $0.filename == filename }) {
                // Update existing record, preserving runtime flags.
                records[idx].chat = chat
                records[idx].lastError = nil
            } else {
                // New chat appeared on disk.
                records.append(ChatRecord(filename: filename, chat: chat))
            }
            sortAndEmit()
        case .itemRemoved:
            // Remove the chat and its image folder.
            streamTasks[filename]?.cancel()
            streamTasks[filename] = nil
            env.deleteAllImages(for: filename)
            records.removeAll(where: { $0.filename == filename })
            if selectedFilename == filename { selectedFilename = nil }
            emit(.chatsChanged(records))
        default:
            break
        }
    }

    /// Handles an FSEvent for a custom role file.
    private func handleRoleFileEvent(_ event: FSEvent, url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        switch event {
        case .itemCreated, .itemClonedAtPath, .itemDataModified, .itemRenamed:
            // Reload the single role and merge into the in-memory list.
            if let role = env.loadSingleRole(name: name) {
                if let idx = roles.firstIndex(where: { $0.name == name }) {
                    // Only update if it's a custom role (defaults are read-only).
                    if !roles[idx].isDefault {
                        roles[idx] = role
                    } else {
                        // A custom role now overrides a default with the same name.
                        roles[idx] = role
                    }
                } else {
                    roles.append(role)
                    roles.sort { $0.name < $1.name }
                }
            } else {
                // File gone or undecodable — treat as removal.
                roles.removeAll(where: { $0.name == name && !$0.isDefault })
            }
            emit(.rolesChanged(roles))
        case .itemRemoved:
            // Remove the custom role; a default with the same name (if any) re-emerges.
            roles.removeAll(where: { $0.name == name && !$0.isDefault })
            // Re-merge defaults so a shadowed default reappears.
            roles = env.loadAllRoles()
            emit(.rolesChanged(roles))
        default:
            break
        }
    }

    /// Handles an FSEvent for a connection file (openai or anthropic).
    private func handleConnectionFileEvent(_ event: FSEvent, url: URL) {
        // For connections, the simplest correct approach is to reload the full
        // set — connection files are few and the merge logic for per-file
        // updates is fiddly (id depends on provider+name). This is still far
        // cheaper than the old full-tree scan.
        switch event {
        case .itemCreated, .itemClonedAtPath, .itemDataModified, .itemRenamed, .itemRemoved:
            connections = env.loadConnections()
            emit(.connectionsChanged(connections))
        default:
            break
        }
    }

    /// Handles an FSEvent for an MCP config file. On create/modify/rename, the
    /// server config is (re)loaded into memory and a single-flight reconfigure
    /// is scheduled for that server in `MCPManager`. On remove, the server is
    /// forgotten (disconnected + caches cleared).
    private func handleMCPFileEvent(_ event: FSEvent, url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        switch event {
        case .itemCreated, .itemClonedAtPath, .itemDataModified, .itemRenamed:
            if let server = env.loadSingleMCP(name: name) {
                if let idx = mcps.firstIndex(where: { $0.name == name }) {
                    mcps[idx] = server
                } else {
                    mcps.append(server)
                    mcps.sort { $0.name < $1.name }
                }
                emit(.mcpsChanged(mcps))
                // Single-flight reconfigure: coalesce a burst of events for the
                // same server into one reconfigure.
                scheduleReconfigure(server)
            } else {
                // Undecodable — treat as removal.
                mcps.removeAll(where: { $0.name == name })
                emit(.mcpsChanged(mcps))
                scheduleForget(name)
            }
        case .itemRemoved:
            mcps.removeAll(where: { $0.name == name })
            emit(.mcpsChanged(mcps))
            scheduleForget(name)
        default:
            break
        }
    }

    /// Handles an FSEvent for `config.toml`. Reloads the config and emits
    /// `.configChanged` so the UI refreshes its cached preferences.
    private func handleConfigFileEvent(_ event: FSEvent, url: URL) {
        switch event {
        case .itemCreated, .itemClonedAtPath, .itemDataModified, .itemRenamed:
            Task {
                await ConfigManager.shared.reload()
                self.emit(.configChanged)
            }
        case .itemRemoved:
            // Config deleted — keep current in-memory state; nothing to reload.
            break
        default:
            break
        }
    }

    // MARK: - Full rescan fallback

    /// Full rescan of all environment state. Used as a fallback for
    /// `mustScanSubDirs` / `rootChanged` events (dropped events). Reloads
    /// everything from disk and re-runs the MCP configuration pass since the
    /// set of servers may have changed in ways we couldn't track per-file.
    private func fullRescan() {
        reloadAll(shouldEmit: true)
        configureMCPs()
    }

    // MARK: - MCP configuration flow

    /// Runs a full MCP configuration pass: reloads configs from disk and drives
    /// `MCPManager.configure`, which connects stdio servers, queries tools,
    /// discards failures, and stops on-demand stdio servers. Reports live
    /// status via `handleMCPConfigurationState`. Skipped (no-op) when no MCPs
    /// are configured. Guards against concurrent passes.
    ///
    /// Called on launch (from `start()`) and from "File > Reload MCPs…".
    func configureMCPs() {
        guard !isConfiguringMCPs else {
            debugLog("MCP", "configureMCPs — already in progress, skipping")
            return
        }
        // Reload the freshest configs from disk so the pass uses current state.
        mcps = env.loadMCPs()
        emit(.mcpsChanged(mcps))
        guard !mcps.isEmpty else {
            debugLog("MCP", "configureMCPs — no MCP servers configured, skipping")
            return
        }
        isConfiguringMCPs = true
        let snapshot = mcps
        Task { [weak self] in
            guard let self else { return }
            await MCPManager.shared.configure(snapshot)
            await self.markConfigureDone()
        }
    }

    /// Clears the in-progress guard. Called when a configure pass completes.
    private func markConfigureDone() {
        isConfiguringMCPs = false
        didInitialConfigure = true
    }

    /// Schedules a single-flight reconfigure for one server. Coalesces a burst
    /// of FSEvents for the same server into one `MCPManager.reconfigure` call.
    func scheduleReconfigure(_ server: MCPServer) {
        let name = server.name
        pendingReconfigures[name]?.cancel()
        pendingReconfigures[name] = Task { [weak self] in
            // Small debounce so a rapid save burst collapses into one reconfigure.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.performReconfigure(server)
            await self.clearPendingReconfigure(name)
        }
    }

    /// Performs the reconfigure for one server on the engine actor, then
    /// hands off to `MCPManager.reconfigure`.
    private func performReconfigure(_ server: MCPServer) async {
        // If a full configure is in progress, defer this slightly to avoid
        // racing the full reset.
        if isConfiguringMCPs {
            debugLog("MCP", "reconfigure deferred — full configure in progress, server=\"\(server.name)\"")
            try? await Task.sleep(for: .milliseconds(300))
            if isConfiguringMCPs {
                debugLog("MCP", "reconfigure still deferred — re-scheduling server=\"\(server.name)\"")
                scheduleReconfigure(server)
                return
            }
        }
        await MCPManager.shared.reconfigure(server)
    }

    /// Removes a completed reconfigure task from the pending map.
    private func clearPendingReconfigure(_ name: String) {
        pendingReconfigures[name] = nil
    }

    /// Schedules a single-flight forget (disconnect + cache clear) for a
    /// removed server.
    func scheduleForget(_ name: String) {
        pendingReconfigures[name]?.cancel()
        Task { await MCPManager.shared.forget(name) }
    }

    /// Receives a configuration-state snapshot from `MCPManager`'s status
    /// sink, stores it, and emits it so the UI overlay can update. The UI
    /// layer is responsible for any display delay.
    private func handleMCPConfigurationState(_ state: MCPConfigurationState) {
        mcpConfiguration = state
        emit(.mcpConfiguration(state))
    }

    /// Reloads MCP servers from disk and emits the updated set. The runtime
    /// configuration is performed separately by `configureMCPs()` (on launch
    /// and "Reload MCPs…") or `scheduleReconfigure` (on per-file FSEvents).
    private func reloadMCPs() {
        mcps = env.loadMCPs()
        debugLog("MCP", "reloaded \(mcps.count) server config(s) from disk")
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
        markSelfWrite(path: env.chatsURL.appendingPathComponent(filename).path)
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
        // Suppress the FSEvent for the file we're about to remove.
        markSelfWrite(path: env.chatsURL.appendingPathComponent(filename).path)
        env.deleteChat(filename: filename)
        env.deleteAllImages(for: filename)
        records.removeAll(where: { $0.filename == filename })
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
            // Suppress the FSEvent for each file we're removing.
            markSelfWrite(path: env.chatsURL.appendingPathComponent(record.filename).path)
            env.deleteChat(filename: record.filename)
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
    /// clobbering streaming/unread flags). Marks a per-path self-write
    /// suppression so the resulting FSEvents don't trigger a redundant reload.
    private func saveChat(_ chat: Chat, filename: String) {
        env.saveChat(chat, filename: filename)
        markSelfWrite(path: env.chatsURL.appendingPathComponent(filename).path)
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
        debugLog("Chat", "sendMessage — chat=\(filename), text length=\(text.count), images=\(pendingImages.count)")
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
        // We keep this in memory only — the chat is persisted to disk once the
        // stream finishes (successfully or with an error) so no incomplete
        // content is ever written to disk during streaming.
        var updatedChat = baseChat
        updatedChat.messages.append(userMessage)
        updatedChat.messages.append(ChatMessage(role: .assistant, content: "", connectionName: connection.displayName))
        if let idx = records.firstIndex(where: { $0.filename == filename }) {
            records[idx].chat = updatedChat
        }
        sortAndEmit()

        runToolLoop(for: filename, connection: connection, messages: messages)

        // Fire-and-forget: try to generate a chat name via the utility connection
        // if this chat doesn't have a title yet.
        maybeGenerateChatName(filename: filename)

        return true
    }

    /// Retries (regenerates) the last assistant turn for the given chat.
    ///
    /// This is fully data-driven: it works from any chat state (including chats
    /// reloaded from disk after an app restart) and does not depend on any
    /// in-memory "retryable" flag. The request is rebuilt from the chat's
    /// current role + message history: everything after the last user message
    /// (the previous assistant response, any tool calls/results) is dropped, a
    /// fresh placeholder assistant message is appended, and the tool loop is
    /// re-run — equivalent to the user just re-sending their last message.
    func retryLastMessage(filename: String) async {
        guard !isStreaming(filename: filename) else { return }
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        let chat = records[idx].chat
        guard let connectionID = chat.connection,
              let connection = connections.first(where: { $0.id == connectionID }) else {
            emit(.error("Please select a connection in the status bar."))
            return
        }
        // Find the last user message. Everything after it is the assistant's
        // previous turn (response, tool calls, tool results) and is discarded
        // so we regenerate from the last user message forward.
        guard let lastUserIdx = chat.messages.lastIndex(where: { $0.role == .user }) else { return }

        var updatedChat = chat
        // Truncate back to (and including) the last user message.
        updatedChat.messages = Array(chat.messages[0...lastUserIdx])
        // Append a fresh placeholder assistant message for the new response.
        updatedChat.messages.append(ChatMessage(role: .assistant, content: "", connectionName: connection.displayName))
        records[idx].chat = updatedChat
        emit(.chatsChanged(records))

        // Rebuild the request history: system prompt (from the selected role)
        // followed by all messages up to (and including) the last user message.
        var messages: [ChatMessage] = []
        if let roleName = updatedChat.role,
           let role = roles.first(where: { $0.name == roleName }) {
            let caps = await renderingCapabilities()
            messages.append(ChatMessage(role: .system, content: role.content + caps))
        }
        messages.append(contentsOf: updatedChat.messages.dropLast())

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
        debugLog("Stream", "start — chat=\(filename), connection=\(connection.id)")
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

    /// Gathers tool definitions from the chat's active MCP servers using the
    /// cached tool lists populated during MCP configuration. Servers that
    /// failed configuration (no cached tools) are silently excluded — they're
    /// already known to be unhealthy, and per spec we don't block LLM
    /// interactions because of them. On-demand stdio servers are started
    /// (if not already running) before the request via
    /// `ensureOnDemandRunning`.
    ///
    /// No per-request listTools call is made: the cache is authoritative for
    /// the duration of a configuration pass. If a server becomes unreachable
    /// mid-conversation, `callTool` returns a clear error in the RESULT field
    /// and the model can retry on the next call.
    private func gatherTools(filename: String) async -> [ToolDefinition] {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return [] }
        let activeNames = records[idx].chat.mcps ?? []
        guard !activeNames.isEmpty else { return [] }

        // Start selected on-demand stdio servers if they aren't already
        // running, so the tools we advertise are actually callable.
        await MCPManager.shared.ensureOnDemandRunning(activeNames)

        var defs: [ToolDefinition] = []
        var perServerCounts: [(String, Int)] = []
        for serverName in activeNames {
            // Read the cached tool list. Servers with no cache entry either
            // failed configuration or were never configured; skip them.
            guard let tools = await MCPManager.shared.cachedTools(for: serverName) else {
                debugLog("MCP", "no cached tools — server=\"\(serverName)\", chat=\(filename) (skipped)")
                perServerCounts.append((serverName, 0))
                continue
            }
            // Apply the per-server tool allowlist. An empty/nil list means all
            // tools are allowed; otherwise only tools whose name matches an
            // entry are advertised to the LLM.
            let serverConfig = await MCPManager.shared.serverConfig(for: serverName)
            let allowlist = serverConfig?.tools ?? []
            let allowSet = Set(allowlist)
            let filtered: [MCPTool]
            if allowSet.isEmpty {
                filtered = tools
            } else {
                filtered = tools.filter { allowSet.contains($0.name) }
            }
            perServerCounts.append((serverName, filtered.count))
            // The prefix namespaces the tool name sent to the model. It is
            // required config, so a server with cached tools always has one;
            // fall back to the server name only as a defensive default.
            let prefix = serverConfig?.prefix ?? serverName
            defs.append(contentsOf: filtered.map { tool in
                ToolDefinition(
                    serverName: serverName,
                    prefix: prefix,
                    name: tool.name,
                    description: tool.description,
                    inputSchema: tool.inputSchema
                )
            })
        }
        // Deduplicate by namespaced name. Some MCP servers expose tools
        // with duplicate names, which makes the LLM API reject
        // the request with "Tool names must be unique". We keep the first
        // occurrence of each name and drop the rest.
        var seen = Set<String>()
        var unique: [ToolDefinition] = []
        var dropped = 0
        for def in defs {
            if seen.insert(def.namespacedName).inserted {
                unique.append(def)
            } else {
                dropped += 1
            }
        }
        if dropped > 0 {
            debugLog("MCP", "deduplicated tools — dropped \(dropped) duplicate name(s), chat=\(filename)")
        }
        debugLog("MCP", "gathered tools — chat=\(filename), total=\(unique.count), servers=\(activeNames.count)")
        for (serverName, count) in perServerCounts {
            debugLog("MCP", "  server=\"\(serverName)\" contributed \(count) tool(s)")
        }
        return unique
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
            // Resolve the prefix + tool name from the namespaced call name,
            // then map the prefix back to the owning server.
            guard let parsed = ToolDefinition.parse(call.name) else {
                debugLog("Tool", "could not parse tool name \"\(call.name)\" — chat=\(filename)")
                return ToolResult(callID: call.id, content: "Could not parse tool name \"\(call.name)\".", isError: true)
            }
            guard let serverName = await MCPManager.shared.serverName(forPrefix: parsed.prefix) else {
                debugLog("Tool", "no server found for prefix \"\(parsed.prefix)\" — chat=\(filename)")
                return ToolResult(callID: call.id, content: "No MCP server found for tool prefix \"\(parsed.prefix)\".", isError: true)
            }
            debugLog("Tool", "executing \(serverName)/\(parsed.tool) — callID=\(call.id), chat=\(filename)")
            let result = await MCPManager.shared.callTool(server: serverName, name: parsed.tool, arguments: call.arguments, callID: call.id, chatFilename: filename)
            debugLog("Tool", "result \(serverName)/\(parsed.tool) — isError=\(result.isError), contentSize=\(result.content.count), chat=\(filename)")
            return result
        case .deny(let reason):
            debugLog("Tool", "denied callID=\(call.id) — \(reason), chat=\(filename)")
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
        // In-memory only during streaming; persisted once by `finishStream`.
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
            // In-memory only during streaming; persisted once by `finishStream`.
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
        // In-memory only during streaming; persisted once by `finishStream`.
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
        // In-memory only during streaming; persisted once by `finishStream`.
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
        case .toolCallDelta(let index, let id, let name, let argsDelta):
            // Incremental tool call update — grow the tool call at `index`
            // in place so the UI shows the arguments populating live. The
            // final `.toolCall` chunk (emitted at stream end) replaces this
            // entry with the authoritative, complete ToolCall.
            var calls = chat.messages[lastIdx].toolCalls ?? []
            while calls.count <= index { calls.append(ToolCall(id: "", name: "", arguments: "")) }
            if let id, !id.isEmpty { calls[index].id = id }
            if let name, !name.isEmpty { calls[index].name = name }
            calls[index].arguments += argsDelta
            chat.messages[lastIdx].toolCalls = calls
        case .toolCall(let call):
            // The final, authoritative tool call emitted at stream end.
            // Replace the entry at the matching index (or append if none).
            var calls = chat.messages[lastIdx].toolCalls ?? []
            if let matchIdx = calls.firstIndex(where: { $0.id == call.id && !call.id.isEmpty }) {
                calls[matchIdx] = call
            } else {
                calls.append(call)
            }
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
        debugLog("Stream", "end — chat=\(filename)")
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else {
            streamTasks[filename] = nil
            return
        }
        // Persist the final accumulated state to disk.
        let finalChat = records[idx].chat
        env.saveChat(finalChat, filename: filename)
        markSelfWrite(path: env.chatsURL.appendingPathComponent(filename).path)
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
        // Not persisted here: `finishStream` (always called right after an
        // error) writes the final state — including this error — to disk.
    }

    /// Cancels the in-flight stream for the given chat. Flips the streaming
    /// flag immediately so the UI reflects the stop right away; the stream
    /// task finalizes the message content asynchronously via `finishStream`.
    func stopStreaming(filename: String) {
        debugLog("Stream", "stop requested — chat=\(filename)")
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
            markSelfWrite(path: env.chatsURL.appendingPathComponent(filename).path)
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
