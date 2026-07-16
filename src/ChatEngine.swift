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
    private(set) var prompts: [Prompt] = []
    private(set) var connections: [Connection] = []
    /// The chat data abstraction layer. Owns the SwiftData metadata cache and
    /// all chat file I/O. The engine never reads/writes chat files directly.
    private let store = ChatStore.shared
    /// Custom MCP servers loaded from disk (`~/iCanHazAI/mcp/*.toml`), kept in
    /// sync via FSEvents. In-house (builtin) servers are prepended separately
    /// in `rebuildMcpList()` so they always lead the list.
    private var customMcps: [MCPServer] = []
    /// The full server list shown to the UI: in-house servers first, then
    /// custom servers sorted by name. Rebuilt whenever either set changes.
    private(set) var mcps: [MCPServer] = []
    /// The in-house servers, captured once at startup. They don't change at
    /// runtime (their binaries are bundled), so this is stable.
    private let builtinMcps: [MCPServer] = MCPManager.builtinServers()
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

    // MARK: - Config error registry

    /// Current configuration errors, keyed by `ConfigError.id`
    /// (`"<kind>:<entityName>"`). Rebuilt from the on-disk loaders
    /// (connection/role/mcp config errors) and the live MCP configuration
    /// state (mcp runtime failures). Runtime-only: never persisted — it is
    /// repopulated from disk on every launch. Emitted to subscribers via
    /// `.configErrorsChanged` whenever it changes.
    private var configErrorMap: [String: ConfigError] = [:]
    /// Last snapshot emitted, so we only emit when the set actually changes.
    private var lastEmittedConfigErrors: [ConfigError] = []

    /// The filename of the chat the user is currently viewing. Used to suppress
    /// the unread marker when a stream finishes for the chat that's already on
    /// screen — the user has seen the answer, so no notification is needed.
    private(set) var selectedFilename: String?

    /// In-flight streaming tasks keyed by chat filename, used for cancellation.
    private var streamTasks: [String: Task<Void, Never>] = [:]

    /// Tool-call approvals awaiting a user decision, keyed by call id. The
    /// continuation is registered from `approveToolCall` (running on this
    /// actor) and resumed by `resolveToolCallApproval` / `cancelPendingApprovals`.
    /// Marked `nonisolated(unsafe)` because `withCheckedThrowingContinuation`'s
    /// body is `@Sendable` and thus can't reference actor-isolated state, even
    /// though that body executes synchronously on the actor. All real access is
    /// confined to actor methods.
    private nonisolated(unsafe) var pendingApprovals: [String: PendingToolApproval] = [:]

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

    // MARK: - Self-write suppression & debouncing

    /// Paths we just wrote ourselves, mapped to the time their suppression
    /// expires. Events for these paths are ignored until the expiry passes.
    /// This is per-path: writing `chats/foo.json` does not suppress events for
    /// `chats/bar.json`. Replaces the former global `selfWriteSuppressionUntil`.
    private var selfWriteSuppressedPaths: [String: Date] = [:]
    /// How long after one of our own saves we ignore FSEvents for that path.
    /// Covers the atomic-write burst (temp file create → temp remove → rename).
    private let selfWriteSuppressionInterval: TimeInterval = 1.0
    /// Accumulated unique file paths awaiting a debounced reload, mapped to the
    /// latest (kind, event) seen for that path. A burst of events across many
    /// files is coalesced into a single flush once the burst settles.
    private var pendingReloads: [String: (kind: FileKind, event: FSEvent)] = [:]
    /// The single global debounce task. Reset on every incoming event; when it
    /// fires (1s after the last event) all accumulated paths are reloaded.
    private var pendingReloadTask: Task<Void, Never>?
    /// Settle interval for debouncing of external FSEvents: 1s after the last
    /// event, all unique files that changed are reloaded together.
    private let reloadDebounceInterval: UInt64 = 1_000_000_000 // 1s
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
        case prompt
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
        // Seed bundled default prompts/roles into the user directory (copies
        // only missing files, so user edits are preserved). Done before the
        // FSEvents watcher starts so the copies don't trigger reload bursts.
        env.seedDefaults()
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
        loadFromCache()
        let rolesResult = env.loadAllRolesReportingErrors()
        roles = rolesResult.loaded
        replaceConfigErrors(kind: .role, with: rolesResult.errors)
        prompts = env.loadAllPrompts()
        let connsResult = env.loadConnectionsReportingErrors()
        connections = connsResult.loaded
        replaceConfigErrors(kind: .connection, with: connsResult.errors)
        let mcpsResult = env.loadMCPsReportingErrors()
        customMcps = mcpsResult.loaded
        rebuildMcpList()
        replaceConfigErrors(kind: .mcpConfig, with: mcpsResult.errors)
        startWatching()
        debugLog("Engine", "start complete — \(records.count) chats, \(connections.count) connections, \(mcps.count) MCP servers, \(roles.count) roles, \(prompts.count) prompts")
        emit(.chatsChanged(records))
        emit(.rolesChanged(roles))
        emit(.promptsChanged(prompts))
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
            continuation.yield(.promptsChanged(self.prompts))
            continuation.yield(.connectionsChanged(self.connections))
            continuation.yield(.mcpsChanged(self.mcps))
            continuation.yield(.configErrorsChanged(self.currentConfigErrors()))
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
    /// registry, debounced globally, and dispatched to the appropriate
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
        // roles/*.toml
        if url.deletingLastPathComponent().path == env.rolesURL.path, ext == "toml" {
            return .role
        }
        // prompts/*.md
        if url.deletingLastPathComponent().path == env.promptsURL.path, ext == "md" {
            return .prompt
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

    // MARK: - Global debouncing

    /// Records the path and (re)arms the single global debounce task. Every
    /// incoming event resets the 1s timer; when it finally fires, all unique
    /// paths accumulated in `pendingReloads` are reloaded together.
    private func scheduleReload(path: String, kind: FileKind, event: FSEvent) {
        pendingReloads[path] = (kind, event)
        pendingReloadTask?.cancel()
        let interval = reloadDebounceInterval
        pendingReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled else { return }
            await self?.flushPendingReloads()
        }
        debugLog("FSEvents", "armed debounce for \(env.relativePath(URL(fileURLWithPath: path))) (\(pendingReloads.count) pending)")
    }

    /// Drains all accumulated reloads once the debounce settles. Each unique
    /// path is reloaded via its latest recorded event, then config references
    /// are validated once for the whole batch.
    private func flushPendingReloads() {
        pendingReloadTask = nil
        let batch = pendingReloads
        pendingReloads.removeAll(keepingCapacity: false)
        guard !batch.isEmpty else { return }
        debugLog("FSEvents", "flushing \(batch.count) debounced reload(s)")
        // Surface the Application resources in this batch to the loader so it
        // can show a partial "Application" column while the reload runs.
        // `counts` is the on-disk total per resource (drives the
        // success/warning/failed derivation); `refreshCounts` is how many items
        // are actually being refreshed in this batch (drives the subtitle, e.g.
        // "1 entry" for a single-file edit). The matching "completed" signal is
        // the per-resource changed event emitted by the handlers below. MCP /
        // chat files are excluded — MCPs are reported via `.mcpConfiguration`.
        var appCounts: [AppResource: Int] = [:]
        var refreshCounts: [AppResource: Int] = [:]
        for (_, entry) in batch {
            if let r = appResource(for: entry.kind) {
                appCounts[r] = resourceTotalCount(r)
                refreshCounts[r, default: 0] += 1
            }
        }
        if !appCounts.isEmpty {
            emit(.loaderActivity(LoaderActivity(counts: appCounts, refreshCounts: refreshCounts)))
        }
        for (path, entry) in batch {
            executeReload(path: path, kind: entry.kind, event: entry.event)
        }
        Task { await ConfigManager.shared.validateReferences() }
    }

    /// Maps a file kind to the Application resource it belongs to, or nil for
    /// kinds the loader doesn't report (chats, MCPs).
    private func appResource(for kind: FileKind) -> AppResource? {
        switch kind {
        case .config: return .configuration
        case .connectionOpenai, .connectionAnthropic: return .connections
        case .prompt: return .prompts
        case .role: return .roles
        case .mcp, .chat: return nil
        }
    }

    /// Total number of items of a resource type currently on disk (plus bundled
    /// built-ins for roles/prompts). Used for the loader's `[num]` labels and
    /// the success/warning/failed derivation.
    private func resourceTotalCount(_ resource: AppResource) -> Int {
        switch resource {
        case .configuration: return 1
        case .connections: return env.connectionCount()
        case .prompts: return env.promptCount()
        case .roles: return env.roleCount()
        }
    }

    /// Executes the single-file reload for a debounced event. Dispatches to the
    /// per-kind handler based on the event type.
    private func executeReload(path: String, kind: FileKind, event: FSEvent) {
        let url = URL(fileURLWithPath: path)
        let relPath = env.relativePath(url)
        debugLog("FSEvents", "executing reload — kind=\(kind), path=\(relPath)")

        switch kind {
        case .chat:
            handleChatFileEvent(event, url: url)
        case .role:
            handleRoleFileEvent(event, url: url)
        case .prompt:
            handlePromptFileEvent(event, url: url)
        case .connectionOpenai, .connectionAnthropic:
            handleConnectionFileEvent(event, url: url)
        case .mcp:
            handleMCPFileEvent(event, url: url)
        case .config:
            handleConfigFileEvent(event, url: url)
        }
    }

    // MARK: - Per-kind handlers

    /// Handles an FSEvent for a chat file. External modifications reload the
    /// chat via the store (which updates the cache), then update the in-memory
    /// record only if the chat was already loaded. Chats that are not loaded
    /// are left unloaded — their cache metadata is updated by the store.
    /// `itemRenamed` is treated as removed(old) + created(new); since the
    /// wrapper fires two events, each is handled independently here.
    private func handleChatFileEvent(_ event: FSEvent, url: URL) {
        let filename = url.lastPathComponent
        switch event {
        case .itemCreated, .itemClonedAtPath, .itemDataModified, .itemRenamed:
            // Ask the store to reload from disk and update the cache.
            let chat = store.handleExternalChange(filename: filename)
            guard chat != nil else {
                debugLog("FSEvents", "chat reload failed (undecodable/missing) — \(filename)")
                return
            }
            // Streaming chat protection: don't clobber in-memory streaming state.
            if let idx = records.firstIndex(where: { $0.filename == filename }), records[idx].isStreaming {
                debugLog("FSEvents", "chat \(filename) is streaming — keeping in-memory state")
                return
            }
            // Refresh cache metadata for the sidebar. Only swap in the
            // reloaded content when the chat was already loaded (the user has
            // it open); an unloaded chat stays unloaded — its cache metadata
            // is enough for the sidebar, and loading it here would pin it in
            // memory with no event to release it.
            if let info = store.getEntry(filename: filename) {
                if let idx = records.firstIndex(where: { $0.filename == filename }) {
                    if records[idx].chat != nil {
                        records[idx].chat = chat
                    }
                    records[idx].cachedName = info.name
                    records[idx].cachedRole = info.role
                    records[idx].cachedModificationTime = info.modificationTime
                    records[idx].lastError = nil
                } else {
                    // New chat appeared on disk — never loaded.
                    records.append(ChatRecord(
                        filename: filename,
                        chat: nil,
                        cachedName: info.name,
                        cachedRole: info.role,
                        cachedModificationTime: info.modificationTime
                    ))
                }
            }
            sortAndEmit()
        case .itemRemoved:
            // Remove from store cache, cancel streaming, and remove the record.
            store.handleExternalDeletion(filename: filename)
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

    /// Handles an FSEvent for a role TOML file.
    private func handleRoleFileEvent(_ event: FSEvent, url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        // Protected built-ins are served from the bundle and never modified
        // via the user directory — ignore any user-dir events for them so a
        // user shadow file can't clobber or remove the built-in role.
        if EnvironmentManager.protectedBundleNames.contains(name) { return }
        switch event {
        case .itemCreated, .itemClonedAtPath, .itemDataModified, .itemRenamed:
            // Reload the single role and merge into the in-memory list.
            let (role, error) = env.loadSingleRoleReportingError(name: name)
            if let role {
                if let idx = roles.firstIndex(where: { $0.name == name }) {
                    roles[idx] = role
                } else {
                    roles.append(role)
                    roles.sort { $0.name < $1.name }
                }
                clearConfigError(kind: .role, name: name)
            } else {
                // File gone or undecodable — treat as removal.
                roles.removeAll(where: { $0.name == name })
                if let error {
                    setConfigError(error)
                } else {
                    clearConfigError(kind: .role, name: name)
                }
            }
            // Working directory / MCP isolation may have changed: relaunch
            // in-house MCP copies for chats using this role so they pick up the
            // new args on the next request (deferred if a chat is streaming).
            relaunchInHouseForRole(name)
            emit(.rolesChanged(roles))
        case .itemRemoved:
            roles.removeAll(where: { $0.name == name })
            clearConfigError(kind: .role, name: name)
            relaunchInHouseForRole(name)
            emit(.rolesChanged(roles))
        default:
            break
        }
    }

    /// Handles an FSEvent for a prompt file.
    private func handlePromptFileEvent(_ event: FSEvent, url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        // Protected built-ins are served from the bundle and never modified
        // via the user directory — ignore any user-dir events for them.
        if EnvironmentManager.protectedBundleNames.contains(name) { return }
        switch event {
        case .itemCreated, .itemClonedAtPath, .itemDataModified, .itemRenamed:
            if let prompt = env.loadSinglePrompt(name: name) {
                if let idx = prompts.firstIndex(where: { $0.name == name }) {
                    prompts[idx] = prompt
                } else {
                    prompts.append(prompt)
                    prompts.sort { $0.name < $1.name }
                }
            } else {
                prompts.removeAll(where: { $0.name == name })
            }
            emit(.promptsChanged(prompts))
        case .itemRemoved:
            prompts.removeAll(where: { $0.name == name })
            emit(.promptsChanged(prompts))
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
            let result = env.loadConnectionsReportingErrors()
            connections = result.loaded
            replaceConfigErrors(kind: .connection, with: result.errors)
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
            let (server, error) = env.loadSingleMCPReportingError(name: name)
            if let server {
                if let idx = customMcps.firstIndex(where: { $0.name == name }) {
                    customMcps[idx] = server
                } else {
                    customMcps.append(server)
                }
                rebuildMcpList()
                clearConfigError(kind: .mcpConfig, name: name)
                // Single-flight reconfigure: coalesce a burst of events for the
                // same server into one reconfigure. The reconfigure will clear
                // (or set) the runtime failure for this server.
                scheduleReconfigure(server)
            } else {
                // Undecodable — treat as removal.
                customMcps.removeAll(where: { $0.name == name })
                rebuildMcpList()
                if let error {
                    setConfigError(error)
                    // A server with a broken config can't run; drop any stale
                    // runtime failure so only the config error is shown.
                    clearConfigError(kind: .mcpFailure, name: name)
                } else {
                    clearConfigError(kind: .mcpConfig, name: name)
                    clearConfigError(kind: .mcpFailure, name: name)
                }
                scheduleForget(name)
            }
        case .itemRemoved:
            customMcps.removeAll(where: { $0.name == name })
            rebuildMcpList()
            clearConfigError(kind: .mcpConfig, name: name)
            clearConfigError(kind: .mcpFailure, name: name)
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
    /// `mustScanSubDirs` / `rootChanged` events (dropped events). Reconciles
    /// the chat cache with disk and re-runs the MCP configuration pass since
    /// the set of servers may have changed in ways we couldn't track per-file.
    private func fullRescan() {
        // A full rescan reloads every Application resource; surface it to the
        // loader so the user sees what's being reconciled.
        emit(.loaderActivity(LoaderActivity(counts: [
            .connections: env.connectionCount(),
            .prompts: env.promptCount(),
            .roles: env.roleCount(),
        ])))
        fullRescanChats()
        let rolesResult = env.loadAllRolesReportingErrors()
        roles = rolesResult.loaded
        replaceConfigErrors(kind: .role, with: rolesResult.errors)
        prompts = env.loadAllPrompts()
        let connsResult = env.loadConnectionsReportingErrors()
        connections = connsResult.loaded
        replaceConfigErrors(kind: .connection, with: connsResult.errors)
        let mcpsResult = env.loadMCPsReportingErrors()
        customMcps = mcpsResult.loaded
        rebuildMcpList()
        replaceConfigErrors(kind: .mcpConfig, with: mcpsResult.errors)
        emit(.rolesChanged(roles))
        emit(.promptsChanged(prompts))
        emit(.connectionsChanged(connections))
        emit(.mcpsChanged(mcps))
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
        let mcpsResult = env.loadMCPsReportingErrors()
        customMcps = mcpsResult.loaded
        rebuildMcpList()
        replaceConfigErrors(kind: .mcpConfig, with: mcpsResult.errors)
        // Builtins are always present, so the list is never empty; the
        // configure pass initializes every server (in-house included).
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
        clearConfigError(kind: .mcpFailure, name: name)
        Task { await MCPManager.shared.forget(name) }
    }

    /// Receives a configuration-state snapshot from `MCPManager`'s status
    /// sink, stores it, and emits it so the UI overlay can update. The UI
    /// layer is responsible for any display delay.
    ///
    /// Also derives runtime MCP failures for custom servers: a `.failed` entry
    /// records a [`ConfigError`](src/Models.swift) (kind `.mcpFailure`); a
    /// `.success` entry clears it. Built-in servers are app internals (not
    /// user-configurable) and are ignored. A single-server reconfigure pass
    /// carries only that server, so other servers' failures are left intact.
    private func handleMCPConfigurationState(_ state: MCPConfigurationState) {
        mcpConfiguration = state
        let customNames = Set(customMcps.map { $0.name })
        for entry in state.entries where customNames.contains(entry.name) {
            switch entry.status {
            case .failed:
                let msg = entry.errorMessage?.isEmpty == false ? entry.errorMessage! : "failed to connect or list tools"
                setConfigError(ConfigError(kind: .mcpFailure, entityName: entry.name, message: msg))
            case .success:
                clearConfigError(kind: .mcpFailure, name: entry.name)
            case .pending, .inProgress:
                break
            }
        }
        emit(.mcpConfiguration(state))
    }

    /// Reloads custom MCP servers from disk and rebuilds the combined list
    /// (in-house + custom). The runtime configuration is performed separately
    /// by `configureMCPs()` (on launch and "Reload MCPs…") or
    /// `scheduleReconfigure` (on per-file FSEvents).
    private func reloadMCPs() {
        let mcpsResult = env.loadMCPsReportingErrors()
        customMcps = mcpsResult.loaded
        rebuildMcpList()
        replaceConfigErrors(kind: .mcpConfig, with: mcpsResult.errors)
        debugLog("MCP", "reloaded \(customMcps.count) custom server config(s) from disk")
    }

    /// Rebuilds the combined `mcps` list (in-house first, then custom sorted
    /// by name) and emits the change. In-house servers always lead the list so
    /// the UI can render the separator between them and the custom ones.
    private func rebuildMcpList() {
        mcps = builtinMcps + customMcps.sorted { $0.name < $1.name }
        emit(.mcpsChanged(mcps))
    }

    // MARK: - Config error registry

    /// The current configuration errors, ordered by kind then entity name for
    /// stable display.
    private func currentConfigErrors() -> [ConfigError] {
        configErrorMap.values.sorted { a, b in
            if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue < b.kind.rawValue }
            return a.entityName < b.entityName
        }
    }

    /// Records (or replaces) a single error, then emits if the snapshot changed.
    private func setConfigError(_ error: ConfigError) {
        configErrorMap[error.id] = error
        emitConfigErrorsIfChanged()
    }

    /// Clears a single entity's error (by kind + name). No-op (and no emit) if
    /// there was none.
    private func clearConfigError(kind: ConfigError.Kind, name: String) {
        let id = "\(kind.rawValue):\(name)"
        if configErrorMap.removeValue(forKey: id) != nil {
            emitConfigErrorsIfChanged()
        }
    }

    /// Replaces every error of `kind` with `errors` (the full failing set for
    /// that kind, as reported by a loader). Entities that now load cleanly (or
    /// were removed) drop out automatically because they're absent from `errors`.
    private func replaceConfigErrors(kind: ConfigError.Kind, with errors: [ConfigError]) {
        let prefix = "\(kind.rawValue):"
        let toRemove = configErrorMap.keys.filter { $0.hasPrefix(prefix) }
        for key in toRemove { configErrorMap.removeValue(forKey: key) }
        for e in errors { configErrorMap[e.id] = e }
        if !toRemove.isEmpty || !errors.isEmpty {
            emitConfigErrorsIfChanged()
        }
    }

    /// Emits `.configErrorsChanged` only when the snapshot actually changed,
    /// so a no-op reload doesn't flood subscribers with identical events.
    private func emitConfigErrorsIfChanged() {
        let snapshot = currentConfigErrors()
        if snapshot != lastEmittedConfigErrors {
            lastEmittedConfigErrors = snapshot
            emit(.configErrorsChanged(snapshot))
        }
    }

    // MARK: - Loading

    /// Populates `records` from the SwiftData cache, syncing the cache with
    /// disk first. No chat files are loaded — each record's `chat` is nil
    /// (lazy loading). Only metadata (name, modification time) is read from
    /// the cache, which already reflects the on-disk state after the sync.
    private func loadFromCache() {
        let entries = store.startupSync()
        var newRecords: [ChatRecord] = []
        for info in entries {
            let existing = records.first(where: { $0.filename == info.filename })
            newRecords.append(ChatRecord(
                filename: info.filename,
                chat: existing?.chat,
                cachedName: info.name,
                cachedRole: info.role,
                cachedModificationTime: info.modificationTime,
                isStreaming: existing?.isStreaming ?? false,
                hasUnreadActivity: existing?.hasUnreadActivity ?? false,
                lastError: existing?.lastError,
                createdAt: existing?.createdAt ?? info.modificationTime
            ))
        }
        sortRecordsByActivity(&newRecords)
        records = newRecords
        // Drop bookkeeping for chats that no longer exist.
        let validIDs = Set(records.map { $0.id })
        streamTasks = streamTasks.filter { validIDs.contains($0.key) }
    }

    /// Full rescan of chat state from disk. Used as a fallback for
    /// `mustScanSubDirs` / `rootChanged` FSEvents. Rebuilds the cache from
    /// scratch by reconciling with disk, then populates records (with
    /// `chat = nil`). In-memory loaded chats are preserved.
    private func fullRescanChats() {
        let entries = store.startupSync()
        var newRecords: [ChatRecord] = []
        for info in entries {
            let existing = records.first(where: { $0.filename == info.filename })
            newRecords.append(ChatRecord(
                filename: info.filename,
                chat: existing?.chat,
                cachedName: info.name,
                cachedRole: info.role,
                cachedModificationTime: info.modificationTime,
                isStreaming: existing?.isStreaming ?? false,
                hasUnreadActivity: existing?.hasUnreadActivity ?? false,
                lastError: existing?.lastError,
                createdAt: existing?.createdAt ?? info.modificationTime
            ))
        }
        sortRecordsByActivity(&newRecords)
        records = newRecords
        let validIDs = Set(records.map { $0.id })
        streamTasks = streamTasks.filter { validIDs.contains($0.key) }
        emit(.chatsChanged(records))
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

    /// Creates a new empty chat for the given role and returns its filename.
    /// The chat is held in memory only — it is NOT written to disk until the
    /// user sends the first message. Any other empty chats (no messages) are
    /// pruned first. The connection is seeded from the role (or the app's
    /// default connection when the role has none).
    @discardableResult
    func createNewChat(role roleName: String) async -> String {
        pruneEmptyChats(except: nil)
        let filename = store.newChatFilename()
        var chat = Chat()
        chat.role = roleName

        let role = self.roles.first(where: { $0.name == roleName })
        // Seed the connection from the role, falling back to the app default.
        if let roleConn = role?.connection, self.connections.contains(where: { $0.id == roleConn }) {
            chat.connection = roleConn
        } else {
            let dc = await ConfigManager.shared.getDefaultConnection()
            if let conn = dc, self.connections.contains(where: { $0.id == conn }) {
                chat.connection = conn
            }
        }
        // In-memory only — no disk write until the first message is sent.
        let record = ChatRecord(filename: filename, chat: chat)
        records.insert(record, at: 0)
        emit(.chatsChanged(records))
        return filename
    }

    /// Deletes a chat file and removes it from memory, including its image
    /// folder on disk. Safe to call for chats that were never persisted (the
    /// store handles missing files gracefully).
    func deleteChat(filename: String) {
        streamTasks[filename]?.cancel()
        streamTasks[filename] = nil
        // Suppress the FSEvent for the file we're about to remove.
        markSelfWrite(path: env.chatsURL.appendingPathComponent(filename).path)
        store.deleteChat(filename: filename)
        env.deleteAllImages(for: filename)
        records.removeAll(where: { $0.filename == filename })
        if selectedFilename == filename { selectedFilename = nil }
        // Tear down any per-chat in-house MCP copies owned by this chat so we
        // don't leak subprocesses after the chat is gone.
        Task { await MCPManager.shared.disconnectAllInHouse(chatFilename: filename) }
        emit(.chatsChanged(records))
    }

    /// Renames a chat by setting its user-defined display title. Loads the
    /// chat from disk if it's not currently in memory.
    func renameChat(filename: String, to newTitle: String) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var chat = records[idx].chat ?? store.loadChat(filename: filename) ?? Chat()
        chat.title = trimmed.isEmpty ? nil : trimmed
        saveChat(chat, filename: filename)
        // Renaming may have loaded a chat the user isn't viewing; release it
        // so its content doesn't linger in memory.
        releaseChat(filename: filename)
        emit(.chatsChanged(records))
    }

    /// Removes all chats that have no messages, except the one identified by
    /// `keep` (pass nil to prune every empty chat). Since empty chats are
    /// never written to disk (see `createNewChat`), pruning only removes the
    /// in-memory record — no file deletion is needed.
    func pruneEmptyChats(except keep: String?) {
        // Only prune chats that are loaded AND have no messages — these are
        // new, unsaved chats (empty chats are never persisted to disk).
        // Unloaded chats (chat == nil) have messages on disk and must not
        // be pruned.
        let toRemove = records.filter {
            guard let chat = $0.chat else { return false }
            return chat.messages.isEmpty && $0.filename != keep
        }
        guard !toRemove.isEmpty else { return }
        for record in toRemove {
            streamTasks[record.filename]?.cancel()
            streamTasks[record.filename] = nil
        }
        records.removeAll(where: { toRemove.contains($0) })
    }

    /// Called when the user selects a chat: prunes other empty chats, loads
    /// the selected chat from disk if it's not already in memory, and emits
    /// the updated state.
    func selectChat(filename: String) async {
        let previous = selectedFilename
        selectedFilename = filename
        pruneEmptyChats(except: filename)
        await ensureChatLoaded(filename: filename)
        // The chat the user just switched away from is no longer open. If it
        // isn't doing agentic work, drop its in-memory content now rather than
        // waiting for a sweep. A still-streaming chat is kept.
        if let previous, previous != filename {
            releaseChat(filename: previous)
        }
        emit(.chatsChanged(records))
    }

    /// Returns the record for a filename, if any.
    func record(for filename: String) -> ChatRecord? {
        records.first(where: { $0.filename == filename })
    }

    /// Loads a chat from disk via the store if it's not already in memory.
    /// No-op if the chat is already loaded or doesn't exist in records.
    /// Emits `chatsChanged` after loading so the UI reflects the new state.
    func ensureChatLoaded(filename: String) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard records[idx].chat == nil else { return }
        records[idx].chat = store.loadChat(filename: filename)
        emit(.chatsChanged(records))
    }

    /// Persists a chat to disk via the store and updates the in-memory record
    /// (without clobbering streaming/unread flags). Marks a per-path self-write
    /// suppression so the resulting FSEvents don't trigger a redundant reload.
    /// Also updates the cached metadata from the store.
    private func saveChat(_ chat: Chat, filename: String) {
        markSelfWrite(path: env.chatsURL.appendingPathComponent(filename).path)
        store.saveChat(chat, filename: filename)
        if let idx = records.firstIndex(where: { $0.filename == filename }) {
            records[idx].chat = chat
            if let info = store.getEntry(filename: filename) {
                records[idx].cachedName = info.name
                records[idx].cachedRole = info.role
                records[idx].cachedModificationTime = info.modificationTime
            }
        }
    }

    // MARK: - Chat memory reclamation

    /// Unloads the chat's in-memory content if it is no longer needed.
    ///
    /// A chat is "needed" only while one of these conditions holds:
    ///   - the user has it open (it is the selected chat), or
    ///   - agentic work is in flight for it (`isStreaming`).
    ///
    /// Rather than periodically sweeping all chats, the events that end a
    /// "needed" condition invoke this directly: `selectChat` (when the user
    /// switches away from a chat) and `finishStream` (when agentic work
    /// completes). This reclaims memory the instant a chat becomes unneeded
    /// instead of up to a minute later.
    ///
    /// The cache metadata (`cachedName`, `cachedModificationTime`) is
    /// preserved, so the sidebar keeps displaying the chat correctly; the full
    /// history is reloaded on demand via `ensureChatLoaded`. Safe to call at
    /// any time — a no-op when the chat is already unloaded or still needed.
    /// Does not emit; callers emit the resulting state.
    @discardableResult
    func releaseChat(filename: String) -> Bool {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return false }
        guard records[idx].chat != nil else { return false }
        if filename == selectedFilename { return false }
        if records[idx].isStreaming { return false }
        records[idx].chat = nil
        debugLog("Engine", "released chat \(filename) — no longer needed")
        return true
    }

    // MARK: - Role resolution

    /// A role's MCP entry resolved against the known servers: the bare server
    /// name (with `bundled::` stripped), whether it's a builtin, the tool
    /// selection filter, the auto-allow set, and directory-isolation flag.
    struct ResolvedRoleMCP: Equatable {
        let serverName: String
        let isBuiltin: Bool
        let toolsFilter: [String]
        let autoAllow: Set<String>
        let autoAllowAll: Bool
        let directoryIsolation: Bool

        /// Whether a tool (by raw name) should be auto-approved.
        func autoAllows(tool name: String) -> Bool {
            autoAllowAll || autoAllow.contains(name)
        }
    }

    /// Looks up the role referenced by a chat. Nil if the chat has no role or
    /// the role no longer exists.
    private func role(for chat: Chat) -> Role? {
        guard let roleName = chat.role else { return nil }
        return roles.first(where: { $0.name == roleName })
    }

    /// The effective connection for a chat: the per-chat override when the role
    /// allows it, otherwise the role's connection, otherwise nil. The caller is
    /// responsible for falling back to the app default when nil.
    private func effectiveConnection(for chat: Chat) -> Connection? {
        let role = self.role(for: chat)
        if role?.connectionOverrideAllowed == true, let id = chat.connection,
           let conn = connections.first(where: { $0.id == id }) {
            return conn
        }
        if let roleConn = role?.connection, !roleConn.isEmpty,
           let conn = connections.first(where: { $0.id == roleConn }) {
            return conn
        }
        if let id = chat.connection, let conn = connections.first(where: { $0.id == id }) {
            return conn
        }
        return nil
    }

    /// The system prompt content for a chat: the per-chat prompt override when
    /// the role allows it, otherwise the role's prompt. Nil when the role has
    /// no prompt or the referenced prompt can't be found.
    private func systemPromptContent(for chat: Chat) -> String? {
        guard let role = self.role(for: chat) else { return nil }
        let promptName: String?
        if role.promptOverrideAllowed, let override = chat.prompt {
            promptName = override
        } else {
            promptName = role.promptName
        }
        guard let name = promptName else { return nil }
        return prompts.first(where: { $0.name == name })?.content
    }

    /// Resolves the role's MCP entries against the known servers. Entries whose
    /// server doesn't exist (e.g. a deleted custom MCP) are dropped.
    private func resolvedMCPs(for chat: Chat) -> [ResolvedRoleMCP] {
        guard let role = self.role(for: chat), let entries = role.config.mcps else { return [] }
        let builtinNames = Set(builtinMcps.map(\.name))
        let customNames = Set(mcps.map(\.name))
        return entries.compactMap { entry in
            let isBuiltin = entry.mcp.hasPrefix("bundled::")
            let serverName = isBuiltin ? String(entry.mcp.dropFirst("bundled::".count)) : entry.mcp
            if isBuiltin {
                guard builtinNames.contains(serverName) else { return nil }
            } else {
                guard customNames.contains(serverName) else { return nil }
            }
            return ResolvedRoleMCP(
                serverName: serverName,
                isBuiltin: isBuiltin,
                toolsFilter: entry.tools ?? [],
                autoAllow: Set(entry.autoAllow ?? []),
                autoAllowAll: entry.autoAllowAll ?? false,
                directoryIsolation: entry.directoryIsolation ?? false
            )
        }
    }

    /// The effective working directory for a chat: the per-chat override when
    /// the role allows it, otherwise the role's working directory. Nil when
    /// neither is set. Forwarded to in-house MCP servers that support
    /// `--workdir` (Filesystem, Code, Shell) so relative paths resolve against
    /// it. `~` is expanded by `MCPManager` when building the launch command.
    private func effectiveWorkingDirectory(for chat: Chat) -> String? {
        guard let role = self.role(for: chat) else { return nil }
        if role.workingDirectoryOverrideAllowed, let override = chat.workingDirectory, !override.isEmpty {
            return override
        }
        return role.workingDirectory
    }

    /// Filenames whose in-house MCP copies must be torn down once the current
    /// request finishes. Populated when the working directory or role config
    /// changes mid-stream — we can't kill a copy mid-tool-call without failing
    /// the in-flight call — and drained by `finishStream`.
    private var pendingInHouseRelaunch: Set<String> = []

    /// Tears down the per-chat in-house MCP copies for `filename` so the next
    /// request relaunches them with the current working directory / isolation
    /// flags. If a request is streaming for this chat, the teardown is deferred
    /// to `finishStream` to avoid killing an in-flight tool call.
    private func scheduleInHouseRelaunch(filename: String) async {
        if isStreaming(filename: filename) {
            pendingInHouseRelaunch.insert(filename)
        } else {
            pendingInHouseRelaunch.remove(filename)
            await MCPManager.shared.disconnectAllInHouse(chatFilename: filename)
        }
    }

    /// Schedules an in-house relaunch for every chat currently using `roleName`.
    /// Used when a role's config (working directory, MCP isolation) is edited
    /// on disk, so running copies pick up the new args on the next request.
    private func relaunchInHouseForRole(_ roleName: String) {
        let affected = records.filter { $0.effectiveRoleName == roleName }.map(\.filename)
        for filename in affected {
            if isStreaming(filename: filename) {
                pendingInHouseRelaunch.insert(filename)
            } else {
                Task { await MCPManager.shared.disconnectAllInHouse(chatFilename: filename) }
            }
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
        // Ensure the chat is loaded before sending.
        await ensureChatLoaded(filename: filename)
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return false }
        guard let chat = records[idx].chat else { return false }
        guard let connection = effectiveConnection(for: chat) else {
            emit(.error("Please select a connection in the status bar."))
            return false
        }

        // If the last assistant message was a failed/error placeholder, drop it so the
        // new user message follows the previous user message directly.
        var baseChat = chat
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

        // Build the message list including the system prompt from the role's
        // prompt (or the chat's per-chat prompt override when allowed).
        var messages: [ChatMessage] = []
        if let promptContent = systemPromptContent(for: baseChat) {
            let caps = await renderingCapabilities()
            messages.append(ChatMessage(role: .system, content: promptContent + caps))
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
        await ensureChatLoaded(filename: filename)
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard let chat = records[idx].chat else { return }
        guard let connection = effectiveConnection(for: chat) else {
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

        // Rebuild the request history: system prompt (from the role's prompt)
        // followed by all messages up to (and including) the last user message.
        var messages: [ChatMessage] = []
        if let promptContent = systemPromptContent(for: updatedChat) {
            let caps = await renderingCapabilities()
            messages.append(ChatMessage(role: .system, content: promptContent + caps))
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
                    // If the model produced no usable content (and no tool
                    // calls), treat it as an error so the user can retry
                    // rather than being left with a blank response.
                    if result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let message: String
                        if result.finishReason == "max_tokens" {
                            // Anthropic reports max_tokens when the model
                            // exhausted its token budget on (omitted) thinking
                            // before emitting any visible content.
                            message = "The model reached the token limit before producing any output. It likely spent all its tokens on internal thinking. Try increasing max_tokens, then retry."
                        } else {
                            message = "The model produced no output. The provider may be overloaded — please try again."
                        }
                        recordError(message, filename: filename)
                        finishStream(filename: filename)
                        return
                    }
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
                    let assistantMsg = records[idx].chat?.messages.last(where: { $0.role == .assistant })
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
                    // `executeToolCall` awaits user approval, which can be
                    // cancelled (stop). Throws `CancellationError` in that case.
                    let toolResult = try await executeToolCall(call, filename: filename, tools: toolDefs)
                    // Append the result as a `tool`-role message and persist.
                    appendToolResult(toolResult, filename: filename)
                    // Mirror into the working history so the next stream
                    // request includes it.
                    history.append(ChatMessage(role: .tool, content: "", toolResults: [toolResult]))
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

    /// Gathers tool definitions from the chat's role-selected MCPs using the
    /// cached tool lists populated during MCP configuration. The role's per-MCP
    /// `tools` selection is applied (intersected with the server's own tool
    /// allowlist). Servers that failed configuration (no cached tools) are
    /// silently excluded. On-demand / in-house stdio servers are started before
    /// the request.
    ///
    /// No per-request listTools call is made: the cache is authoritative for
    /// the duration of a configuration pass. If a server becomes unreachable
    /// mid-conversation, `callTool` returns a clear error in the RESULT field
    /// and the model can retry on the next call.
    private func gatherTools(filename: String) async -> [ToolDefinition] {
        guard let idx = records.firstIndex(where: { $0.filename == filename }),
              let chat = records[idx].chat else { return [] }
        let resolved = resolvedMCPs(for: chat)
        // The configurator role has no MCP servers — it uses in-process config
        // tools instead — so don't bail out when its resolved MCP list is empty.
        let isConfigurator = role(for: chat)?.name == ConfiguratorTools.configuratorRoleName
        guard !resolved.isEmpty || isConfigurator else { return [] }

        // Route each server by kind: in-house (builtin) servers run as per-chat
        // copies, custom on-demand servers run in the shared pool. Always-on /
        // http servers are already connected from configuration. In-house copies
        // are launched with the chat's effective working directory and the
        // per-entry isolation flag so Filesystem/Code/Shell confine themselves
        // to the role's working directory when configured.
        let inHouse = resolved.filter { $0.isBuiltin }.map { ($0.serverName, $0.directoryIsolation) }
        let custom = resolved.filter { !$0.isBuiltin }.map(\.serverName)
        if !inHouse.isEmpty {
            let workdir = effectiveWorkingDirectory(for: chat)
            await MCPManager.shared.ensureInHouseRunning(
                chatFilename: filename,
                servers: inHouse,
                workingDirectory: workdir
            )
        }
        if !custom.isEmpty {
            await MCPManager.shared.ensureOnDemandRunning(custom)
        }

        var defs: [ToolDefinition] = []
        var perServerCounts: [(String, Int)] = []
        for r in resolved {
            // Read the cached tool list. Servers with no cache entry either
            // failed configuration or were never configured; skip them.
            guard let tools = await MCPManager.shared.cachedTools(for: r.serverName) else {
                debugLog("MCP", "no cached tools — server=\"\(r.serverName)\", chat=\(filename) (skipped)")
                perServerCounts.append((r.serverName, 0))
                continue
            }
            // Apply both the server's own tool allowlist and the role's tool
            // selection. An empty list means "all tools".
            let serverConfig = await MCPManager.shared.serverConfig(for: r.serverName)
            let serverAllow = Set(serverConfig?.tools ?? [])
            let roleAllow = Set(r.toolsFilter)
            let filtered = tools.filter { t in
                (serverAllow.isEmpty || serverAllow.contains(t.name)) &&
                (roleAllow.isEmpty || roleAllow.contains(t.name))
            }
            perServerCounts.append((r.serverName, filtered.count))
            let prefix = serverConfig?.prefix ?? r.serverName
            defs.append(contentsOf: filtered.map { tool in
                ToolDefinition(
                    serverName: r.serverName,
                    prefix: prefix,
                    name: tool.name,
                    description: tool.description,
                    inputSchema: tool.inputSchema
                )
            })
        }
        // Deduplicate by namespaced name. Some MCP servers expose tools with
        // duplicate names, which makes the LLM API reject the request with
        // "Tool names must be unique". Keep the first occurrence.
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
        // The bundled Configurator role uses a set of in-process config
        // tools (no subprocess) instead of MCP servers. They are dispatched
        // directly from `executeToolCall`, bypassing `MCPManager`.
        if role(for: chat)?.name == ConfiguratorTools.configuratorRoleName {
            unique.append(contentsOf: ConfiguratorTools.toolDefinitions)
        }
        debugLog("MCP", "gathered tools — chat=\(filename), total=\(unique.count), servers=\(resolved.count)")
        for (serverName, count) in perServerCounts {
            debugLog("MCP", "  server=\"\(serverName)\" contributed \(count) tool(s)")
        }
        return unique
    }

    /// Records tool calls onto the last assistant message of the chat so the
    /// renderer can display them (and show a "running" state until results arrive).
    private func applyToolCalls(_ calls: [ToolCall], filename: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard var chat = records[idx].chat else { return }
        if let lastIdx = chat.messages.indices.last, chat.messages[lastIdx].role == .assistant {
            chat.messages[lastIdx].toolCalls = calls
        }
        records[idx].chat = chat
        scheduleCoalescedEmit()
    }

    /// Executes a single tool call via `MCPManager`. Returns the tool result.
    /// `filename` is the owning chat's filename, forwarded to `MCPManager` so
    /// progress notifications route to this chat's live `tool`-role message.
    /// `tools` is the exact set of tool definitions advertised to the model for
    /// this turn; the call name is matched directly against their
    /// `namespacedName` to recover the owning server + raw tool name, which
    /// avoids the ambiguity of splitting on the first underscore (prefixless
    /// servers expose tools like `tavily_search` whose own name contains `_`).
    ///
    /// Tools flagged as auto-allowed by the chat's role (`auto_allow` /
    /// `auto_allow_all`) skip the approval prompt and execute immediately.
    private func executeToolCall(_ call: ToolCall, filename: String, tools: [ToolDefinition]) async throws -> ToolResult {
        // Match the model-issued call name directly against the namespaced
        // names we advertised. This is unambiguous and doesn't depend on
        // prefix parsing, which mis-splits prefixless tools.
        guard let match = tools.first(where: { $0.namespacedName == call.name }) else {
            debugLog("Tool", "no advertised tool matches name \"\(call.name)\" — chat=\(filename)")
            return ToolResult(callID: call.id, content: "No MCP tool found for name \"\(call.name)\".", isError: true)
        }
        let serverName = match.serverName
        let toolName = match.name

        // In-process configurator tools run directly in the app (no MCP
        // subprocess) and are always auto-approved: their writes are validated
        // before touching disk, so there's nothing destructive to confirm.
        if serverName == ConfiguratorTools.serverName {
            debugLog("Tool", "executing configurator tool \(toolName) — callID=\(call.id), chat=\(filename)")
            return await ConfiguratorTools.call(name: toolName, arguments: call.arguments, callID: call.id)
        }

        // Auto-allow: if the role marks this tool (or all tools from this
        // server) as auto-approved, skip the approval prompt entirely.
        let chat = records.first(where: { $0.filename == filename })?.chat
        let resolved = chat.map { resolvedMCPs(for: $0) } ?? []
        let autoAllowed = resolved.first(where: { $0.serverName == serverName })?.autoAllows(tool: toolName) ?? false
        // Working directory + isolation for the owning in-house server, used
        // when a per-chat copy is (re)started lazily from this call.
        let workdir = chat.flatMap { effectiveWorkingDirectory(for: $0) }
        let isolation = resolved.first(where: { $0.serverName == serverName })?.directoryIsolation ?? false

        let approval: ToolApproval
        if autoAllowed {
            debugLog("Tool", "auto-allowed \(serverName)/\(toolName) — callID=\(call.id), chat=\(filename)")
            approval = .allow
        } else {
            // The approval hook. Suspends until the user allows or denies the
            // call (or cancels via stop, which throws `CancellationError`). The
            // chat remains in its streaming state throughout — a pause, not a
            // stop.
            approval = try await approveToolCall(chatFilename: filename, call: call)
        }

        switch approval {
        case .allow:
            debugLog("Tool", "executing \(serverName)/\(toolName) — callID=\(call.id), chat=\(filename)")
            // In-house servers run as per-chat copies; custom servers use the
            // shared connection pool. Routing uses `builtinMcps` (captured at
            // init) so it doesn't depend on the configure pass.
            let result: ToolResult
            if builtinMcps.contains(where: { $0.name == serverName }) {
                result = await MCPManager.shared.callInHouseTool(
                    chatFilename: filename, server: serverName, name: toolName,
                    arguments: call.arguments, callID: call.id,
                    workingDirectory: workdir, directoryIsolation: isolation
                )
            } else {
                result = await MCPManager.shared.callTool(server: serverName, name: toolName, arguments: call.arguments, callID: call.id, chatFilename: filename)
            }
            debugLog("Tool", "result \(serverName)/\(toolName) — isError=\(result.isError), contentSize=\(result.content.count), chat=\(filename)")
            return result
        case .deny(let reason):
            let message = ToolApproval.denialMessage(for: reason)
            debugLog("Tool", "denied callID=\(call.id) — \(message), chat=\(filename)")
            // `isError` stays true so the provider treats this as a tool error,
            // but `isDenied` lets the renderer show "denied" rather than "error".
            return ToolResult(callID: call.id, content: message, isError: true, isDenied: true)
        }
    }

    /// The tool-call approval decision point. Marks the call as pending, draws
    /// the UI's attention (`.toolApprovalRequested`), then suspends on a
    /// continuation until `resolveToolCallApproval` (allow/deny) or
    /// `cancelPendingApprovals` (stop) resumes it.
    private func approveToolCall(chatFilename: String, call: ToolCall) async throws -> ToolApproval {
        setPendingApproval(callID: call.id, filename: chatFilename, pending: true)
        emit(.toolApprovalRequested(filename: chatFilename, callID: call.id))
        return try await withCheckedThrowingContinuation { continuation in
            pendingApprovals[call.id] = PendingToolApproval(filename: chatFilename, continuation: continuation)
        }
    }

    /// Resolves a pending approval with the user's decision. Called from the UI
    /// (via `AppViewModel`) when the user presses Allow or confirms a Deny.
    /// No-op (and safe) if there is no pending approval for `callID` — e.g. a
    /// double click or a late resolve after cancellation.
    func resolveToolCallApproval(callID: String, approval: ToolApproval) {
        guard let pending = pendingApprovals.removeValue(forKey: callID) else { return }
        setPendingApproval(callID: callID, filename: pending.filename, pending: false)
        emit(.toolApprovalResolved(filename: pending.filename, callID: callID))
        pending.continuation.resume(returning: approval)
    }

    /// Sets the `pendingApproval` flag on a tool call (matched by `callID`) on
    /// the last assistant message of the chat, so the renderer expands the
    /// block and shows Allow/Deny buttons. Persists in-memory only and emits.
    private func setPendingApproval(callID: String, filename: String, pending: Bool) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard var chat = records[idx].chat else { return }
        guard let aIdx = chat.messages.indices.reversed().first(where: { chat.messages[$0].role == .assistant }),
              var calls = chat.messages[aIdx].toolCalls,
              let cIdx = calls.firstIndex(where: { $0.id == callID }) else { return }
        calls[cIdx].pendingApproval = pending
        chat.messages[aIdx].toolCalls = calls
        records[idx].chat = chat
        flushCoalescedEmit()
        emit(.chatsChanged(records))
    }

    /// Cancels every pending approval for a chat (used when the user stops the
    /// stream). Resumes each continuation with `CancellationError` so the
    /// streaming loop unwinds, then drops the incomplete tool-call turn (the
    // trailing assistant message carrying tool calls + any partial results)
    /// so the conversation isn't left with a `tool_call` that has no matching
    /// `tool_result` — a state providers reject on the next request.
    private func cancelPendingApprovals(filename: String) {
        let toCancel = pendingApprovals.filter { $0.value.filename == filename }
        guard !toCancel.isEmpty else { return }
        for (callID, pending) in toCancel {
            pendingApprovals.removeValue(forKey: callID)
            pending.continuation.resume(throwing: CancellationError())
        }
        trimIncompleteToolTurn(filename: filename)
        flushCoalescedEmit()
        emit(.chatsChanged(records))
        for (callID, _) in toCancel {
            emit(.toolApprovalResolved(filename: filename, callID: callID))
        }
    }

    /// Removes the last assistant message and everything after it, but only if
    /// that assistant message carries tool calls — i.e. the turn was a
    /// tool-call turn that didn't complete (some results are missing). Leaves
    /// normal (content-only) assistant messages intact.
    private func trimIncompleteToolTurn(filename: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard var chat = records[idx].chat else { return }
        guard let lastAssistant = chat.messages.indices.reversed().first(where: { chat.messages[$0].role == .assistant }) else { return }
        guard chat.messages[lastAssistant].toolCalls?.isEmpty == false else { return }
        chat.messages.removeSubrange(lastAssistant...)
        records[idx].chat = chat
    }

    /// Appends a tool result as its own `tool`-role `ChatMessage` (tagged with
    /// `callID` via `toolResults`) — the natural provider shape. If a streaming
    /// placeholder message for this `callID` already exists (created by
    /// `updateStreamingToolResult`), it is replaced in place rather than
    /// duplicated, so the final result supersedes the partial content. Persists
    /// and emits.
    private func appendToolResult(_ result: ToolResult, filename: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard var chat = records[idx].chat else { return }
        // If a streaming placeholder `tool`-role message exists for this
        // callID, replace it in place with the final result.
        if let tIdx = chat.messages.indices.reversed().first(where: {
            chat.messages[$0].role == .tool
                && chat.messages[$0].toolResults?.contains(where: { $0.callID == result.callID }) ?? false
        }) {
            chat.messages[tIdx] = ChatMessage(role: .tool, content: "", toolResults: [result])
        } else {
            // No placeholder yet — append a new `tool`-role message.
            chat.messages.append(ChatMessage(role: .tool, content: "", toolResults: [result]))
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
        guard var chat = records[idx].chat else { return }
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
        chat.messages.append(ChatMessage(role: .tool, content: "", toolResults: [placeholder]))
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
        guard var chat = records[idx].chat else { return }
        chat.messages.append(ChatMessage(role: .assistant, content: "", connectionName: connection.displayName))
        records[idx].chat = chat
        // In-memory only during streaming; persisted once by `finishStream`.
        flushCoalescedEmit()
        emit(.chatsChanged(records))
    }

    /// Applies a streamed chunk to the last assistant message of the given chat.
    private func applyChunk(_ chunk: StreamChunk, filename: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard var chat = records[idx].chat else { return }
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
        case .usage(let usage):
            // Provider-reported token usage for this assistant response.
            // Stored on the message and surfaced in the chat info panel.
            chat.messages[lastIdx].tokenUsage = usage
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
        // Persist the final accumulated state to disk via the store.
        guard let finalChat = records[idx].chat else {
            streamTasks[filename] = nil
            return
        }
        markSelfWrite(path: env.chatsURL.appendingPathComponent(filename).path)
        store.saveChat(finalChat, filename: filename)
        if let info = store.getEntry(filename: filename) {
            records[idx].cachedName = info.name
            records[idx].cachedRole = info.role
            records[idx].cachedModificationTime = info.modificationTime
        }
        records[idx].isStreaming = false
        streamTasks[filename] = nil
        // If a working-directory / role change was deferred while this chat was
        // streaming, tear down its in-house MCP copies now so the next request
        // relaunches them with the current args.
        if pendingInHouseRelaunch.remove(filename) != nil {
            Task { await MCPManager.shared.disconnectAllInHouse(chatFilename: filename) }
        }
        // Flag as unread so the user is notified of new activity — but only if
        // this isn't the chat the user is currently looking at. When the
        // finished chat is the selected one the user has already seen the
        // answer, so marking it unread would only surface a stale circle once
        // they switch away.
        if records[idx].filename != selectedFilename {
            records[idx].hasUnreadActivity = true
        }
        // Agentic work is done; if the user isn't viewing this chat, its
        // in-memory content is no longer needed. The final state was just
        // persisted above, so reopening reloads it from disk.
        releaseChat(filename: filename)
        // Flush any pending coalesced emit first, then emit the final state
        // immediately so the UI reflects "stopped/finished" without delay.
        flushCoalescedEmit()
        emit(.chatsChanged(records))
    }

    /// Records an error onto the last assistant message of the given chat and persists it.
    private func recordError(_ text: String, filename: String) {
        emit(.error(text))
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard var chat = records[idx].chat else { return }
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
        // If we were awaiting tool-call approval, resume those continuations
        // with a cancellation and drop the incomplete tool-call turn so the
        // conversation isn't left with a dangling tool_call. Done before
        // flipping `isStreaming` so the trimmed state is what we emit.
        cancelPendingApprovals(filename: filename)
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
              records[idx].chat?.title == nil,
              !namingInProgress.contains(filename) else { return }

        guard let firstUserMsg = records[idx].chat?.messages.first(where: { $0.role == .user }) else { return }
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
                The user just started a new chat and we need to generate a name for this chat. \
                The user message is NOT a request to you, we only need to figure out a good chat name based on it. \
                Generate a short, descriptive chat name that captures the essence of their request. \
                The name must be in the same language as the user's message. \
                Respond with ONLY the chat name — no quotes, no punctuation, no explanations, no markdown. \
                Keep it concise, ideally under 50 characters. \
                The following is how the user started this chat:
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
              var chat = records[idx].chat,
              chat.title == nil else { return }
        chat.title = name
        records[idx].chat = chat
        if !records[idx].isStreaming {
            saveChat(chat, filename: filename)
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
    func editMessage(filename: String, messageID: UUID, newText: String) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        guard var chat = records[idx].chat else { return }
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
    ///
    /// When deleting an assistant message that issued tool calls, the
    /// following `tool`-role result messages whose `callID` matches one of the
    /// assistant's tool calls are removed as well — they are view projections
    /// of that assistant turn and would otherwise be orphaned (folded onto a
    /// now-deleted message and silently dropped by the renderer).
    func deleteMessage(filename: String, messageID: UUID) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        guard var chat = records[idx].chat else { return }
        guard let msgIdx = chat.messages.firstIndex(where: { $0.id == messageID }) else { return }
        // Collect the callIDs of tool calls issued by the deleted assistant
        // message so we can also remove their result messages.
        let callIDs: Set<String> = Set(chat.messages[msgIdx].toolCalls?.map(\.id) ?? [])
        // Clean up image files owned by the deleted message.
        if let images = chat.messages[msgIdx].images {
            for img in images {
                env.deleteImage(img, chatFilename: filename)
            }
        }
        chat.messages.remove(at: msgIdx)
        // Remove any following tool-result messages whose callID belongs to the
        // deleted assistant message. They are consecutive (the tool loop
        // appends results right after the assistant message), so we scan
        // forward from the removal point and stop at the first non-matching
        // message.
        if !callIDs.isEmpty {
            var i = msgIdx
            while i < chat.messages.count {
                let m = chat.messages[i]
                if m.role == .tool,
                   let results = m.toolResults,
                   results.contains(where: { callIDs.contains($0.callID) }) {
                    chat.messages.remove(at: i)
                    continue
                }
                break
            }
        }
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    // MARK: - Selection updates

    /// Updates the selected connection for a chat.
    func setConnection(filename: String, connectionID: String) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        guard var chat = records[idx].chat else { return }
        chat.connection = connectionID
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    /// Updates the selected role for a chat.
    func setRole(filename: String, roleName: String) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        guard var chat = records[idx].chat else { return }
        chat.role = roleName
        saveChat(chat, filename: filename)
        // The new role may carry a different working directory / isolation
        // config: relaunch the chat's in-house MCP copies accordingly.
        await scheduleInHouseRelaunch(filename: filename)
        emit(.chatsChanged(records))
    }

    /// Updates the per-chat prompt override for a chat.
    func setPrompt(filename: String, promptName: String?) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        guard var chat = records[idx].chat else { return }
        chat.prompt = promptName
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    /// Updates the per-chat working-directory override for a chat.
    func setWorkingDirectory(filename: String, path: String?) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        guard var chat = records[idx].chat else { return }
        chat.workingDirectory = path
        saveChat(chat, filename: filename)
        // The working directory drives in-house MCP `--workdir`/`--confine`:
        // relaunch the chat's copies so they pick up the new path.
        await scheduleInHouseRelaunch(filename: filename)
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

/// The outcome of the tool-call approval decision point. `.allow` executes the
/// call; `.deny(reason:)` blocks it and feeds a denial message back to the
/// model (generic when the reason is empty, otherwise the reason is included).
enum ToolApproval: Sendable {
    case allow
    case deny(reason: String)

    /// The denial text forwarded to the model for a `.deny(reason:)` decision.
    /// A reason that is empty after trimming leading/trailing whitespace yields
    /// a generic denial; otherwise the trimmed reason is included verbatim.
    static func denialMessage(for reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "User denied this tool call"
            : "User denied this tool call with the following reason: \(trimmed)"
    }
}

/// A tool-call approval awaiting a user decision, stored in
/// `ChatEngine.pendingApprovals` keyed by call id. The continuation resumes
/// `approveToolCall` with the user's `ToolApproval` (or throws
/// `CancellationError` on stop).
struct PendingToolApproval: Sendable {
    let filename: String
    let continuation: CheckedContinuation<ToolApproval, Error>
}
