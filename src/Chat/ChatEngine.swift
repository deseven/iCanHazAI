// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import FSEventsWrapper
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
    private(set) var prompts: [Prompt] = []
    private(set) var connections: [Connection] = []
    /// The chat data abstraction layer. Owns the SwiftData metadata cache and
    /// all chat file I/O. The engine never reads/writes chat files directly.
    private let store = ChatStore.shared
    /// Custom MCP servers loaded from disk (`~/iCanHazAI/mcp/*.toml`), kept in
    /// sync via FSEvents. Built-in tool groups (Utils/Filesystem/Code/Shell)
    /// are no longer MCP servers — they run in-process via
    /// [`BuiltinTools`](src/Tools/BuiltinTools.swift).
    private var customMcps: [MCPServer] = []
    /// The full server list shown to the UI: custom servers sorted by name.
    /// Built-in tool groups are not represented here (they're configured per
    /// role via `[utils]`/`[filesystem]`/`[code]`/`[shell]` groups, not as
    /// MCP server entries).
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

    /// Runtime cache for `{load_first_available:...}` prompt variables:
    /// remembers which file was picked, its modification date, and contents.
    private let loadFirstAvailableCache = LoadFirstAvailableCache()

    /// In-flight streaming tasks keyed by chat filename, used for cancellation.
    private var streamTasks: [String: Task<Void, Never>] = [:]

    /// CLI one-shot event sinks keyed by chat filename (then by sink id).
    /// Tapped directly from `applyChunk` (uncoalesced — the CLI sees tokens as
    /// they arrive) and completed from `finishStream`. A sink that outlives
    /// its CLI connection is removed via the stream's `onTermination`. When
    /// the last sink of a chat goes away mid-stream the CLI that drove it is
    /// gone, so the stream is stopped (see `removeOneShotSink`).
    private var oneShotSinks: [String: [UUID: AsyncStream<OneShotEvent>.Continuation]] = [:]

    /// Filenames of chats driven by a CLI one-shot request (created or
    /// continued via the CLI). Non-interactive CLI chats have nobody to
    /// answer an approval prompt: tool calls that need confirmation are
    /// auto-approved (--allow-all) or skipped with a notice (interactive
    /// sessions are the exception — see `cliInteractive`). A CLI chat never
    /// gets the unread marker — its output was already shown in the terminal.
    private var cliDriven: Set<String> = []

    /// CLI-driven chats whose client passed --allow-all: every tool call is
    /// auto-approved without confirmation.
    private var cliAllowAll: Set<String> = []

    /// CLI-driven chats owned by an interactive CLI session (-i): tool calls
    /// that need confirmation are relayed to the client as approval requests
    /// (answered in the terminal) instead of being skipped.
    private var cliInteractive: Set<String> = []

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
    private let emitCoalesceInterval: UInt64 = 50_000_000  // 50ms in nanoseconds

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
    private let reloadDebounceInterval: UInt64 = 1_000_000_000  // 1s
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
        // Leftover attachments of temporary chats from a previous run — those
        // chats are gone for good, so wipe their attachment storage.
        env.deleteAllTemporaryAttachments()
        // Seed bundled default prompts/roles into the user directory (copies
        // only missing files, so user edits are preserved). Done before the
        // FSEvents watcher starts so the copies don't trigger reload bursts.
        env.seedDefaults()
        // Wire the ConfigManager self-write hook so our own config.toml writes
        // are registered in the per-path suppression registry before the
        // atomic-write burst hits FSEvents.
        let configPath = env.rootURL.appendingPathComponent("config.toml").path
        Task {
            await ConfigManager.shared.setWillWriteConfigHook { [configPath] in
                // The hook runs on the ConfigManager actor; hop into the engine to
                // register the suppressed path. We use a non-isolated registration
                // method so we don't deadlock waiting on the engine actor.
                ChatEngine.shared.registerSelfWrite(path: configPath)
            }
        }
        // Wire MCPManager errors into the engine's error event bus so the UI
        // can surface connection failures without crashing the stream.
        Task {
            await MCPManager.shared.setErrorHandler { [weak self] message in
                Task { await self?.emit(.error(message)) }
            }
        }
        // Wire MCPManager progress notifications into the engine so streaming
        // tool output is folded onto the live `tool`-role message in the
        // originating chat (identified by chatFilename + callID) and pushed to
        // the renderer as it arrives. No global scan: the sink carries the
        // chatFilename so we update one message in one chat directly.
        Task {
            await MCPManager.shared.setProgressHandler { [weak self] chatFilename, callID, partial in
                Task {
                    await self?.updateStreamingToolResult(chatFilename: chatFilename, callID: callID, partial: partial)
                }
            }
        }
        // Wire MCPManager configuration-status updates into the engine so the
        // UI overlay can reflect each server's connect/listTools progress. The
        // handler hops back into the engine actor to update `mcpConfiguration`
        // and emit the snapshot.
        Task {
            await MCPManager.shared.setStatusHandler { [weak self] state in
                Task { await self?.handleMCPConfigurationState(state) }
            }
        }
        // Load in dependency order: connections / MCPs / prompts first, then
        // roles (validated against them), then chats from the cache.
        let snapshot = env.loadEnvironment()
        connections = snapshot.connections
        customMcps = snapshot.mcps
        rebuildMcpList()
        prompts = snapshot.prompts
        roles = snapshot.roles
        for kind in [ConfigError.Kind.connection, .mcpConfig, .prompt, .role] {
            replaceConfigErrors(kind: kind, with: snapshot.errors.filter { $0.kind == kind })
        }
        loadFromCache()
        startWatching()
        debugLog(
            "Engine",
            "start complete — \(records.count) chats, \(connections.count) connections, \(mcps.count) MCP servers, \(roles.count) roles, \(prompts.count) prompts"
        )
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
            debugLog(
                "FSEvents",
                "mustScanSubDirs at \(env.relativePath(URL(fileURLWithPath: path))) — reason=\(reason) → full rescan")
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
        debugLog(
            "FSEvents",
            "armed debounce for \(env.relativePath(URL(fileURLWithPath: path))) (\(pendingReloads.count) pending)")
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
        case .chats: return env.chatCount()
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
                    records[idx].cachedArchive = info.archive
                    records[idx].cachedWorkingDirectory = info.workingDirectory
                    records[idx].cachedLastActivity = info.lastActivity
                    records[idx].lastError = nil
                } else {
                    // New chat appeared on disk — never loaded.
                    records.append(
                        ChatRecord(
                            filename: filename,
                            chat: nil,
                            cachedName: info.name,
                            cachedRole: info.role,
                            cachedModificationTime: info.modificationTime,
                            cachedArchive: info.archive,
                            cachedWorkingDirectory: info.workingDirectory,
                            cachedLastActivity: info.lastActivity
                        ))
                }
            }
            sortAndEmit()
        case .itemRemoved:
            // Remove from store cache, cancel streaming, and remove the record.
            store.handleExternalDeletion(filename: filename)
            streamTasks[filename]?.cancel()
            streamTasks[filename] = nil
            env.deleteAllAttachments(for: filename)
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
            let (role, error) = env.loadSingleRoleReportingError(name: name, references: knownRoleReferences())
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
            emit(.rolesChanged(roles))
        case .itemRemoved:
            roles.removeAll(where: { $0.name == name })
            clearConfigError(kind: .role, name: name)
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
            let (prompt, error) = env.loadSinglePromptReportingError(name: name)
            if let prompt {
                if let idx = prompts.firstIndex(where: { $0.name == name }) {
                    prompts[idx] = prompt
                } else {
                    prompts.append(prompt)
                    prompts.sort { $0.name < $1.name }
                }
                clearConfigError(kind: .prompt, name: name)
            } else {
                prompts.removeAll(where: { $0.name == name })
                if let error {
                    setConfigError(error)
                } else {
                    clearConfigError(kind: .prompt, name: name)
                }
            }
            emit(.promptsChanged(prompts))
            revalidateRoles()
        case .itemRemoved:
            prompts.removeAll(where: { $0.name == name })
            clearConfigError(kind: .prompt, name: name)
            emit(.promptsChanged(prompts))
            revalidateRoles()
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
            revalidateRoles()
        default:
            break
        }
    }

    /// Handles an FSEvent for an MCP config file. On create/modify/rename, the
    /// server config is (re)loaded into memory and a single-flight reconfigure
    /// is scheduled for that server in `MCPManager`. On remove, the server is
    /// forgotten (disconnected + caches cleared). Every change revalidates
    /// roles, since they may reference the added/removed server.
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
            revalidateRoles()
        case .itemRemoved:
            customMcps.removeAll(where: { $0.name == name })
            rebuildMcpList()
            clearConfigError(kind: .mcpConfig, name: name)
            clearConfigError(kind: .mcpFailure, name: name)
            scheduleForget(name)
            revalidateRoles()
        default:
            break
        }
    }

    /// The reference sets roles are validated against, built from in-memory
    /// state: loaded entities plus configs that failed to decode (a broken
    /// config still exists on disk and reports its own error, so roles
    /// referencing it are not flagged for a missing entity).
    private func knownRoleReferences() -> RoleReferences {
        func errorNames(_ kind: ConfigError.Kind) -> Set<String> {
            Set(configErrorMap.values.filter { $0.kind == kind }.map(\.entityName))
        }
        return RoleReferences(
            connectionIDs: Set(connections.map(\.id)).union(errorNames(.connection)),
            promptNames: Set(prompts.map(\.name)).union(errorNames(.prompt)),
            mcpNames: Set(customMcps.map(\.name)).union(errorNames(.mcpConfig))
        )
    }

    /// Reloads all roles against the current reference sets. Called when a
    /// connection, prompt, or MCP config appears/disappears so roles
    /// referencing it flip between valid and invalid without waiting for a
    /// role-file event.
    private func revalidateRoles() {
        let result = env.loadAllRolesReportingErrors(references: knownRoleReferences())
        roles = result.loaded
        replaceConfigErrors(kind: .role, with: result.errors)
        emit(.rolesChanged(roles))
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
        emit(
            .loaderActivity(
                LoaderActivity(counts: [
                    .connections: env.connectionCount(),
                    .prompts: env.promptCount(),
                    .roles: env.roleCount(),
                ])))
        // Load in dependency order: connections / MCPs / prompts first, then
        // roles (validated against them), then chats.
        let snapshot = env.loadEnvironment()
        connections = snapshot.connections
        customMcps = snapshot.mcps
        rebuildMcpList()
        prompts = snapshot.prompts
        roles = snapshot.roles
        for kind in [ConfigError.Kind.connection, .mcpConfig, .prompt, .role] {
            replaceConfigErrors(kind: kind, with: snapshot.errors.filter { $0.kind == kind })
        }
        fullRescanChats()
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
            _ = await MCPManager.shared.configure(snapshot)
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
        _ = await MCPManager.shared.reconfigure(server)
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
    /// records a [`ConfigError`](src/Chat/Models.swift) (kind `.mcpFailure`); a
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

    /// Rebuilds the `mcps` list (custom servers sorted by name) and emits the
    /// change. Built-in tool groups are not MCP servers and are not listed
    /// here.
    private func rebuildMcpList() {
        mcps = customMcps.sorted { $0.name < $1.name }
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
            newRecords.append(
                ChatRecord(
                    filename: info.filename,
                    chat: existing?.chat,
                    cachedName: info.name,
                    cachedRole: info.role,
                    cachedModificationTime: info.modificationTime,
                    cachedArchive: info.archive,
                    cachedWorkingDirectory: info.workingDirectory,
                    cachedLastActivity: info.lastActivity,
                    isStreaming: existing?.isStreaming ?? false,
                    stopAfterIteration: existing?.stopAfterIteration ?? false,
                    hasUnreadActivity: existing?.hasUnreadActivity ?? false,
                    lastError: existing?.lastError,
                    createdAt: existing?.createdAt ?? info.lastActivity
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
            newRecords.append(
                ChatRecord(
                    filename: info.filename,
                    chat: existing?.chat,
                    cachedName: info.name,
                    cachedRole: info.role,
                    cachedModificationTime: info.modificationTime,
                    cachedArchive: info.archive,
                    cachedWorkingDirectory: info.workingDirectory,
                    cachedLastActivity: info.lastActivity,
                    isStreaming: existing?.isStreaming ?? false,
                    stopAfterIteration: existing?.stopAfterIteration ?? false,
                    hasUnreadActivity: existing?.hasUnreadActivity ?? false,
                    lastError: existing?.lastError,
                    createdAt: existing?.createdAt ?? info.lastActivity
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
    ///
    /// When `temporary` is true, the chat is NEVER persisted: it gets a
    /// UUID-based `temp-` filename, stays in memory only, is hidden from the
    /// sidebar, and is destroyed irreversibly as soon as another chat is
    /// selected or created. Any existing temporary chat is destroyed first —
    /// at most one temporary chat can exist at a time.
    @discardableResult
    func createNewChat(
        role roleName: String, temporary: Bool = false, outputRendering: ChatOutputRendering? = nil,
        workingDirectory overrideWorkdir: String? = nil
    ) async -> String {
        pruneEmptyChats(except: nil)
        destroyAllTemporaryChats()
        let filename = temporary ? env.newTemporaryChatFilename() : store.newChatFilename()
        var chat = Chat()
        chat.role = roleName
        chat.outputRendering = outputRendering

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
        // Pre-set the working directory: an explicit override (e.g. from the
        // sidebar's "By Directory" mode) is applied only when the role
        // doesn't pre-set its own — a role with a fixed directory always wins.
        if let roleWorkdir = role?.workingDirectory, !roleWorkdir.isEmpty {
            chat.workingDirectory = roleWorkdir
        } else if let override = overrideWorkdir, !override.isEmpty {
            chat.workingDirectory = override
        }
        // Seed the chat's active custom MCPs from the role. The selection is
        // stored per chat so it stays stable if the role is edited later, and
        // can be changed per chat when the role allows MCP overrides.
        if let roleMCPs = role?.config.mcps, !roleMCPs.isEmpty {
            chat.mcps = roleMCPs.map(\.mcp)
        }
        // In-memory only — no disk write until the first message is sent
        // (and never at all for temporary chats).
        let record = ChatRecord(filename: filename, chat: chat, isTemporary: temporary)
        records.insert(record, at: 0)
        emit(.chatsChanged(records))
        return filename
    }

    /// Destroys the given temporary chats, if they exist. Used by the CLI
    /// server to clean up temporary chats whose client disconnected.
    func destroyTemporaryChats(filenames: [String]) {
        for filename in filenames {
            destroyTemporaryChat(filename: filename)
        }
    }

    /// Irreversibly destroys a temporary chat: cancels any in-flight stream,
    /// deletes its temporary attachment folder, and removes the record. No chat
    /// file cleanup is needed — temporary chats never touch the chats dir.
    private func destroyTemporaryChat(filename: String) {
        guard records.first(where: { $0.filename == filename })?.isTemporary == true else { return }
        streamTasks[filename]?.cancel()
        streamTasks[filename] = nil
        env.deleteAllAttachments(for: filename)
        records.removeAll(where: { $0.filename == filename })
        if selectedFilename == filename { selectedFilename = nil }
        cliDriven.remove(filename)
        cliAllowAll.remove(filename)
        cliInteractive.remove(filename)
        debugLog("Engine", "destroyed temporary chat \(filename)")
    }

    /// Destroys every temporary chat in memory (at most one can exist by
    /// construction, but this doesn't rely on that invariant).
    private func destroyAllTemporaryChats() {
        for record in records where record.isTemporary {
            destroyTemporaryChat(filename: record.filename)
        }
    }

    /// Deletes a chat file and removes it from memory, including its
    /// attachment folder on disk. Safe to call for chats that were never
    /// persisted (the store handles missing files gracefully).
    func deleteChat(filename: String) {
        streamTasks[filename]?.cancel()
        streamTasks[filename] = nil
        cliDriven.remove(filename)
        cliAllowAll.remove(filename)
        cliInteractive.remove(filename)
        // Suppress the FSEvent for the file we're about to remove.
        markSelfWrite(path: env.chatsURL.appendingPathComponent(filename).path)
        store.deleteChat(filename: filename)
        env.deleteAllAttachments(for: filename)
        records.removeAll(where: { $0.filename == filename })
        if selectedFilename == filename { selectedFilename = nil }
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

    /// Archives or unarchives a chat by setting its `archive` flag. Loads the
    /// chat from disk if it's not currently in memory. Archived chats are
    /// hidden from the chat list but kept on disk.
    func setChatArchived(filename: String, archived: Bool) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        var chat = records[idx].chat ?? store.loadChat(filename: filename) ?? Chat()
        chat.archive = archived ? true : nil
        saveChat(chat, filename: filename)
        // Archiving may have loaded a chat the user isn't viewing; release it
        // so its content doesn't linger in memory.
        releaseChat(filename: filename)
        // If the archived chat was selected, clear the selection so the UI
        // doesn't keep showing a hidden chat.
        if archived && selectedFilename == filename { selectedFilename = nil }
        emit(.chatsChanged(records))
    }

    /// Removes all chats that have no messages, except the one identified by
    /// `keep` (pass nil to prune every empty chat). Since empty chats are
    /// never written to disk (see `saveChat`), pruning only removes the
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
        if let previous, previous != filename {
            if records.first(where: { $0.filename == previous })?.isTemporary == true {
                // Switching away from a temporary chat destroys it
                // irreversibly — even mid-stream.
                destroyTemporaryChat(filename: previous)
            } else {
                // The chat the user just switched away from is no longer open.
                // If it isn't doing agentic work, drop its in-memory content
                // now rather than waiting for a sweep. A still-streaming chat
                // is kept.
                releaseChat(filename: previous)
            }
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
    /// The chat's stored MCP selection is sanitized on load: entries whose
    /// server config no longer exists are silently dropped (and the cleaned
    /// chat is persisted when something was dropped).
    /// Temporary chats are always kept loaded (they can't be reloaded from
    /// disk), so this is a no-op for them.
    func ensureChatLoaded(filename: String) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard !records[idx].isTemporary else { return }
        guard records[idx].chat == nil else { return }
        records[idx].chat = store.loadChat(filename: filename)
        if var chat = records[idx].chat, sanitizeMCPSelection(&chat) {
            saveChat(chat, filename: filename)
        }
        emit(.chatsChanged(records))
    }

    /// Drops names of MCP servers whose config no longer exists (and
    /// duplicates) from the chat's stored per-chat selection. Returns true
    /// when the chat was changed.
    private func sanitizeMCPSelection(_ chat: inout Chat) -> Bool {
        guard let selected = chat.mcps else { return false }
        let existing = Set(mcps.map(\.name))
        var seen: Set<String> = []
        let kept = selected.filter { existing.contains($0) && seen.insert($0).inserted }
        guard kept.count != selected.count else { return false }
        chat.mcps = kept.isEmpty ? nil : kept
        return true
    }

    /// Persists a chat to disk via the store and updates the in-memory record
    /// (without clobbering streaming/unread flags). Marks a per-path self-write
    /// suppression so the resulting FSEvents don't trigger a redundant reload.
    /// Also updates the cached metadata from the store.
    /// Temporary chats are never persisted — only the in-memory record
    /// is updated. Empty chats (no messages and no title) are also never
    /// persisted: they're in-memory placeholders until the first message is
    /// sent, and writing them would leave orphan files on disk if the user
    /// quits before sending. The in-memory record is still updated so the
    /// UI reflects the change (e.g. a picked working directory).
    private func saveChat(_ chat: Chat, filename: String) {
        if let idx = records.firstIndex(where: { $0.filename == filename }),
            records[idx].isTemporary
        {
            records[idx].chat = chat
            return
        }
        // Don't persist empty chats — they have no content yet and would
        // become orphan files if the user quits before sending a message.
        // The in-memory record is still updated below so the UI reflects the
        // change. Once the first message is sent, `finishStream` persists the
        // chat (now non-empty) to disk.
        if !chat.shouldPersist {
            if let idx = records.firstIndex(where: { $0.filename == filename }) {
                records[idx].chat = chat
            }
            return
        }
        markSelfWrite(path: env.chatsURL.appendingPathComponent(filename).path)
        store.saveChat(chat, filename: filename)
        if let idx = records.firstIndex(where: { $0.filename == filename }) {
            records[idx].chat = chat
            if let info = store.getEntry(filename: filename) {
                records[idx].cachedName = info.name
                records[idx].cachedRole = info.role
                records[idx].cachedModificationTime = info.modificationTime
                records[idx].cachedArchive = info.archive
                records[idx].cachedWorkingDirectory = info.workingDirectory
                records[idx].cachedLastActivity = info.lastActivity
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
        // Temporary chats exist only in memory — unloading their content
        // would lose them entirely. They're destroyed whole instead.
        if records[idx].isTemporary { return false }
        if filename == selectedFilename { return false }
        if records[idx].isStreaming { return false }
        records[idx].chat = nil
        // The snapshot store is derived from the chat's message history —
        // dropping it with the chat frees memory, and the next request
        // rebuilds it on demand.
        records[idx].snapshotStore = nil
        debugLog("Engine", "released chat \(filename) — no longer needed")
        return true
    }

    // MARK: - Role resolution

    /// A resolved tool source: either a built-in group (Utils/Filesystem/Code/
    /// Shell, running in-process) or a custom MCP server (running as a
    /// subprocess). Carries the tool selection filter, the auto-allow set, and
    /// (for isolation-capable built-in groups) the role's directory-isolation
    /// flag.
    struct ResolvedToolSource: Equatable {
        let name: String
        let isBuiltinGroup: Bool
        let toolsFilter: [String]
        let autoAllow: Set<String>
        let autoAllowAll: Bool
        let directoryIsolation: Bool
        let shellWhitelist: Set<String>

        /// Whether a tool (by raw name) should be auto-approved.
        func autoAllows(tool name: String) -> Bool {
            autoAllowAll || autoAllow.contains(name)
        }

        /// Whether a shell command passes the shell whitelist. Returns false
        /// when the command is nil (too complex to parse) or any command name
        /// is not in the whitelist. Returns true when the whitelist is empty
        /// (no whitelist configured — the caller checks autoAllow first).
        func shellCommandAllowed(_ command: String) -> Bool {
            guard !shellWhitelist.isEmpty else { return false }
            guard let commands = ShellCommandExtractor.extractCommands(command) else { return false }
            return commands.allSatisfy { shellWhitelist.contains($0) }
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
            let conn = connections.first(where: { $0.id == id })
        {
            return conn
        }
        if let roleConn = role?.connection, !roleConn.isEmpty,
            let conn = connections.first(where: { $0.id == roleConn })
        {
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

    /// Builds the system message for a chat by loading the prompt's raw content
    /// and substituting variables (`{output_rendering}`, `{user}`, `{date}`,
    /// `{current_directory}`, `{load_first_available:...}`) at request time. Returns nil when the role has no
    /// prompt or the referenced prompt can't be found. Substitution happens here
    /// — never at load time — so each request gets fresh values (e.g. the
    /// current date) and the raw prompt text stays available for editing.
    private func systemMessage(for chat: Chat) async -> ChatMessage? {
        guard let promptContent = systemPromptContent(for: chat) else { return nil }
        let mermaid = await ConfigManager.shared.getMermaidEnabled()
        let katex = await ConfigManager.shared.getKatexEnabled()
        let role = self.role(for: chat)
        // The rendering target is sticky per chat: whichever surface created
        // the chat (GUI vs CLI) decides what capabilities are advertised.
        let outputRendering =
            chat.outputRendering == .plain
            ? PromptVariables.plainTextRendering()
            : PromptVariables.renderingCapabilities(mermaid: mermaid, katex: katex)
        let workdir = effectiveWorkingDirectory(for: chat)
        let values: [String: String] = [
            "output_rendering": outputRendering,
            "user": PromptVariables.currentUserName(),
            "date": PromptVariables.currentDate(),
            "current_directory": PromptVariables.currentDirectory(
                workdirCapable: role?.hasWorkdirCapableMCP ?? false,
                isolated: role?.hasDirectoryIsolation ?? false,
                directory: workdir
            ),
        ]
        let cache = loadFirstAvailableCache
        var content = PromptVariables.substitute(text: promptContent, values: values) { args in
            cache.resolve(args: args, baseDirectory: workdir)
        }
        // Provider-backed web tools are advertised even without a configured
        // provider; tell the model about it so it can nudge the user.
        let webFilter = resolvedToolSources(for: chat)
            .first(where: { $0.isBuiltinGroup && $0.name == BuiltinTools.webGroup })?.toolsFilter
        let webConfigured = await ConfigManager.shared.getWebSearchConfig().isConfigured
        if let notice = BuiltinToolsWeb.providerMissingNotice(
            webGroupToolsFilter: webFilter, isConfigured: webConfigured)
        {
            content += "\n\n" + notice
        }
        return ChatMessage(role: .system, content: content)
    }

    /// Resolves the chat's tool sources: the role's enabled built-in groups
    /// (in-process) plus the chat's active custom MCP servers whose config
    /// exists. Custom MCP entries whose server doesn't exist (e.g. a deleted
    /// config) are dropped.
    private func resolvedToolSources(for chat: Chat) -> [ResolvedToolSource] {
        guard let role = self.role(for: chat) else { return [] }
        var sources: [ResolvedToolSource] = []
        // Built-in groups: enabled when their `[group]` table is present.
        for group in role.enabledGroups {
            let cfg = role.groupConfig(group) ?? RoleToolGroup()
            sources.append(
                ResolvedToolSource(
                    name: group,
                    isBuiltinGroup: true,
                    toolsFilter: cfg.tools ?? [],
                    autoAllow: Set(cfg.autoAllow ?? []),
                    autoAllowAll: cfg.autoAllowAll ?? false,
                    // Isolation is a role-level switch applied to the
                    // isolation-capable groups (Filesystem/Code).
                    directoryIsolation: role.hasDirectoryIsolation
                        && BuiltinTools.isolationCapableGroups.contains(group),
                    shellWhitelist: Set(cfg.shellWhitelist ?? [])
                ))
        }
        // Custom MCP servers: the chat's own selection (seeded from the role,
        // possibly overridden per chat). Chats that predate the per-chat
        // selection (nil) fall back to the role's entries. Servers whose
        // config no longer exists are dropped; entries also present in the
        // role keep the role's tool selection and auto-allow rules, extra
        // per-chat additions get all tools with no auto-allow.
        let customNames = Set(mcps.map(\.name))
        let roleEntries = Dictionary(
            (role.config.mcps ?? []).map { ($0.mcp, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let selectedNames = chat.mcps ?? (role.config.mcps ?? []).map(\.mcp)
        var seen: Set<String> = []
        for name in selectedNames where customNames.contains(name) && seen.insert(name).inserted {
            let entry = roleEntries[name]
            sources.append(
                ResolvedToolSource(
                    name: name,
                    isBuiltinGroup: false,
                    toolsFilter: entry?.tools ?? [],
                    autoAllow: Set(entry?.autoAllow ?? []),
                    autoAllowAll: entry?.autoAllowAll ?? false,
                    directoryIsolation: false,
                    shellWhitelist: []
                ))
        }
        return sources
    }

    /// The effective working directory for a chat: the per-chat value (seeded
    /// from the role at creation or picked by the user — permanent either way),
    /// falling back to the role's working directory. Nil when neither is set.
    /// Forwarded to built-in Filesystem/Code/Shell tools so relative paths
    /// resolve against it.
    private func effectiveWorkingDirectory(for chat: Chat) -> String? {
        if let dir = chat.workingDirectory, !dir.isEmpty { return dir }
        return self.role(for: chat)?.workingDirectory
    }

    // MARK: - Sending messages

    /// Whether the chat's role enables chat trees (non-destructive regen/edit
    /// branching). When false, regen/edit are destructive (phase 2 behavior).
    private func hasChatTrees(for chat: Chat) -> Bool {
        role(for: chat)?.hasChatTrees ?? false
    }

    /// Removes a message and its entire subtree from the chat (for linear
    /// chats: the message and everything after it), cleaning up attachment
    /// files owned by every removed message.
    private func removeMessageAndSubtree(messageID: UUID, from chat: inout Chat, filename: String) {
        for msg in chat.deleteSubtree(of: messageID) {
            if let attachments = msg.attachments {
                for attachment in attachments {
                    env.deleteAttachment(attachment, chatFilename: filename)
                }
            }
        }
    }

    /// Sends a user message and streams the assistant response for the given chat.
    /// Returns false (and emits an error) if no valid connection is selected.
    ///
    /// `pendingAttachments` are in-memory attachments that are committed to
    /// disk only at this point — i.e. when the user actually sends the
    /// message. Images are resized/re-encoded; text/documents have their
    /// original copied and text extracted. If the user cancels, nothing is
    /// written.
    @discardableResult
    func sendMessage(filename: String, text: String, pendingAttachments: [PendingAttachment] = []) async -> Bool {
        debugLog(
            "Chat", "sendMessage — chat=\(filename), text length=\(text.count), attachments=\(pendingAttachments.count)"
        )
        // Ensure the chat is loaded before sending.
        await ensureChatLoaded(filename: filename)
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return false }
        guard let chat = records[idx].chat else { return false }
        guard let connection = effectiveConnection(for: chat) else {
            emit(.error("Please select a connection in the status bar."))
            return false
        }

        var baseChat = chat
        // If the active leaf is a failed/error placeholder, drop it so the
        // new user message follows the previous message directly. An errored
        // placeholder that never received content is not preserved as a branch.
        if let leafID = baseChat.activeLeafID,
            let leaf = baseChat.message(id: leafID),
            leaf.role == .assistant,
            leaf.error != nil
        {
            removeMessageAndSubtree(messageID: leafID, from: &baseChat, filename: filename)
        }

        // Safety net for chats persisted with an incomplete tool-call turn
        // (a stop before this was handled reliably): an assistant `tool_calls`
        // message without all of its results is rejected by providers.
        // Finalize it the same way a stop would.
        baseChat.finalizeActiveStoppedTurn()
        if baseChat.messages != chat.messages, let idx = records.firstIndex(where: { $0.filename == filename }) {
            records[idx].chat = baseChat
        }

        // Build the per-chat snapshot store before the tool loop begins: the
        // model is about to act, so replay what it has already seen from the
        // chat's message history (the finalized active path — the same history
        // the request is built from). Derived data — rebuilt on demand, kept
        // alive for the duration of the request, updated live as tools execute.
        // The workdir must carry the role's isolation flag: the live tools
        // resolve display paths against an isolated workdir (jail-relative),
        // and the rebuild resolves the same display paths, so mismatched
        // isolation would produce store keys that never match.
        if let idx = records.firstIndex(where: { $0.filename == filename }), records[idx].snapshotStore == nil {
            let isolation = role(for: baseChat)?.hasDirectoryIsolation ?? false
            let wd = Workdir(
                root: effectiveWorkingDirectory(for: baseChat), isolated: isolation, chatID: baseChat.id.uuidString)
            records[idx].snapshotStore = BuiltinTools.rebuildSnapshots(from: baseChat.activeMessages, workdir: wd)
        }

        // Commit pending attachments to disk now that the user has actually
        // sent. Images are resized/re-encoded; text/documents have their
        // original copied and (for documents) text extracted. The returned
        // Attachment refs are persisted on the user message and used to build
        // the request payload. Defensive strip: the UI gates attachments on
        // the role's `with_attachments` flag, but a CLI-driven send against
        // a chat whose role doesn't allow attachments drops them here so they
        // never reach the request payload.
        let roleAllowsAttachments = self.role(for: baseChat)?.hasAttachments ?? false
        let effectiveAttachments = roleAllowsAttachments ? pendingAttachments : []
        let committed: [Attachment] = effectiveAttachments.compactMap {
            AttachmentManager.commit($0, chatFilename: filename)
        }

        // Build the message list including the system prompt from the role's
        // prompt (or the chat's per-chat prompt override when allowed), with
        // variables substituted at request time. The request history is built
        // from the active path (derived for forked chats, identity for linear).
        var messages: [ChatMessage] = []
        if let systemMsg = await systemMessage(for: baseChat) {
            messages.append(systemMsg)
        }
        messages.append(contentsOf: baseChat.activeMessages)
        let userMessage = ChatMessage(role: .user, content: text, attachments: committed.isEmpty ? nil : committed)
        messages.append(userMessage)

        // Add the user message immediately and create a placeholder assistant message.
        // We keep this in memory only — the chat is persisted to disk once the
        // stream finishes (successfully or with an error) so no incomplete
        // content is ever written to disk during streaming. Both messages land
        // at the active leaf — structurally, they cannot end up grafted onto
        // a non-active branch.
        var updatedChat = baseChat
        let assistantPlaceholder = ChatMessage(role: .assistant, content: "", connectionName: connection.displayName)
        updatedChat.appendToActiveLeaf(userMessage)
        updatedChat.appendToActiveLeaf(assistantPlaceholder)
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

    // MARK: - CLI one-shot requests

    /// Resolves a user-supplied chat name to an actual chat filename,
    /// accepting the name with or without the ".json" extension.
    static func resolveChatFilename(_ name: String, among filenames: some Sequence<String>) -> String? {
        let names = Set(filenames)
        if names.contains(name) { return name }
        if !name.hasSuffix(".json"), names.contains(name + ".json") { return name + ".json" }
        return nil
    }

    /// Performs a CLI one-shot request: creates a new plain-rendering chat
    /// (or reuses an existing one when `chatName` is given, with or without
    /// the ".json" extension) and starts streaming `message`. Returns the
    /// chat filename plus an event stream carrying uncoalesced content deltas
    /// and a terminal `finished`.
    ///
    /// When `temporary` is true the chat is created as a temporary one
    /// (in-memory only); the CLI server destroys it when the client
    /// disconnects. For regular chats the chat itself stays visible and
    /// continuable in the GUI, but a client disconnecting mid-stream stops
    /// the stream — nobody is consuming it anymore.
    func performOneShot(
        message: String, role requestedRole: String?, connection requestedConnection: String?, chatName: String?,
        temporary: Bool = false, workdir: String? = nil, workdirExplicit: Bool = false, allowAll: Bool = false,
        interactive: Bool = false
    ) async -> OneShotStart {
        let filename: String
        if let chatName {
            guard !temporary else {
                return .failed("a temporary chat cannot continue an existing chat")
            }
            guard let resolved = Self.resolveChatFilename(chatName, among: records.map(\.filename)) else {
                return .failed("chat \"\(chatName)\" not found")
            }
            filename = resolved
        } else {
            if let requestedRole, !roles.contains(where: { $0.name == requestedRole }) {
                return .failed("role \"\(requestedRole)\" not found")
            }
            if let requestedConnection, !connections.contains(where: { $0.id == requestedConnection }) {
                return .failed("connection \"\(requestedConnection)\" not found")
            }
            let defaultRole = await ConfigManager.shared.getDefaultRole()
            let roleName = requestedRole ?? defaultRole ?? "Assistant"
            filename = await createNewChat(role: roleName, temporary: temporary, outputRendering: .plain)
            if let requestedConnection, let idx = records.firstIndex(where: { $0.filename == filename }) {
                records[idx].chat?.connection = requestedConnection
            }
        }

        cliDriven.insert(filename)
        if allowAll { cliAllowAll.insert(filename) }
        if interactive { cliInteractive.insert(filename) }

        // Register the sink before sending so no early chunk can be missed.
        let sinkID = UUID()
        let (stream, continuation) = AsyncStream<OneShotEvent>.makeStream()
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in await self?.removeOneShotSink(filename: filename, id: sinkID) }
        }
        oneShotSinks[filename, default: [:]][sinkID] = continuation

        // Apply the CLI's working directory (the client process's cwd, or the
        // explicit --workdir value) — but only for roles that actually consume
        // one and don't already fix the directory themselves: a role's pre-set
        // working directory is permanent and always wins. An explicitly-passed
        // workdir that can't be applied triggers a warning.
        if let workdir, !workdir.isEmpty {
            await ensureChatLoaded(filename: filename)
            if let idx = records.firstIndex(where: { $0.filename == filename }),
                var chat = records[idx].chat
            {
                let role = role(for: chat)
                if role?.workingDirectory?.isEmpty == false {
                    if workdirExplicit {
                        notifyOneShot(
                            filename: filename,
                            .notice("--workdir has no effect: role \"\(chat.role ?? "?")\" fixes the working directory")
                        )
                    }
                } else if role?.hasWorkdirCapableMCP == true {
                    chat.workingDirectory = workdir
                    records[idx].chat = chat
                    // Persisted by finishStream once the stream settles.
                } else if workdirExplicit {
                    notifyOneShot(
                        filename: filename,
                        .notice(
                            "--workdir has no effect: role \"\(chat.role ?? "?")\" does not use a working directory"))
                }
            }
        }

        // For branched chats continued from the CLI, resolve the path to the
        // leaf with the most recent timestamp and make it the active path
        // (ignoring the GUI's `activeChild` choices). The CLI appends there.
        if let idx = records.firstIndex(where: { $0.filename == filename }),
            var chat = records[idx].chat, chat.hasForks
        {
            chat.setActivePathToMostRecentLeaf()
            records[idx].chat = chat
        }

        guard await sendMessage(filename: filename, text: message) else {
            oneShotSinks[filename]?[sinkID] = nil
            if records.contains(where: { $0.filename == filename }) {
                return .failed("no usable connection — set a default connection in Preferences")
            }
            // A concurrent one-shot's createNewChat pruned this empty chat
            // while we were suspended fetching config — a microscopic race.
            return .failed("the chat disappeared before the message could be sent")
        }
        return .started(filename: filename, events: stream)
    }

    /// Yields an event to every CLI one-shot sink of the chat. No-op for
    /// GUI-driven chats (no sinks registered).
    private func notifyOneShot(filename: String, _ event: OneShotEvent) {
        guard let sinks = oneShotSinks[filename] else { return }
        for sink in sinks.values { sink.yield(event) }
    }

    private func removeOneShotSink(filename: String, id: UUID) {
        oneShotSinks[filename]?[id] = nil
        if oneShotSinks[filename]?.isEmpty == true { oneShotSinks[filename] = nil }
        // The last sink went away while the chat is still streaming: the CLI
        // client that initiated the stream is gone (disconnected/killed), so
        // stop the stream instead of generating for nobody. On normal stream
        // completion `finishStream` clears `isStreaming` before the sinks are
        // finished, so this stays a no-op there.
        if oneShotSinks[filename] == nil, isStreaming(filename: filename) {
            debugLog("Stream", "last CLI sink gone mid-stream — stopping chat=\(filename)")
            stopStreaming(filename: filename)
        }
    }

    /// Completes and removes every one-shot sink for the chat. Called from
    /// `finishStream`'s `defer` so it runs on every exit path (success,
    /// error, cancellation, deleted-mid-stream).
    private func completeOneShotSinks(filename: String) {
        guard let sinks = oneShotSinks.removeValue(forKey: filename), !sinks.isEmpty else { return }
        let record = records.first(where: { $0.filename == filename })
        for sink in sinks.values {
            sink.yield(.finished(error: record?.lastError, chatName: record?.displayTitle))
            sink.finish()
        }
    }

    /// Regenerates the assistant response at `assistantMessageID`. When the
    /// chat's role has chat trees enabled, the discarded assistant message
    /// stays in storage as a sibling child of the same parent; the new
    /// placeholder is appended as another child and made active. When trees
    /// are off, the original response and everything after it are deleted
    /// (destructive regen).
    ///
    /// Fully data-driven: works from any chat state (including chats reloaded
    /// from disk after a restart) and does not depend on any in-memory flag.
    /// The request is rebuilt from the chat's role + the surviving prefix
    /// (system prompt + all messages before the target). The preceding message
    /// can be anything (user, tool-result, or another assistant message) —
    /// truncating right before an assistant message always yields a
    /// provider-valid prefix, because tool results are persisted immediately
    /// after the assistant message that issued them.
    ///
    /// No-ops when the chat is streaming, the message can't be found, isn't an
    /// assistant message, or is the first message in the chat (empty prefix).
    func regenerate(filename: String, assistantMessageID: UUID) async {
        guard !isStreaming(filename: filename) else { return }
        await ensureChatLoaded(filename: filename)
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard let chat = records[idx].chat else { return }
        guard let connection = effectiveConnection(for: chat) else {
            emit(.error("Please select a connection in the status bar."))
            return
        }
        guard let target = chat.message(id: assistantMessageID) else { return }
        // Only assistant messages can be regenerated, and never the first
        // message (empty prefix — nothing to rebuild a request from).
        guard target.role == .assistant else { return }
        guard let parent = chat.parent(of: assistantMessageID) else { return }

        var updatedChat = chat
        // Safety net for chats persisted with an incomplete tool-call turn
        // (a stop before this was handled reliably): an assistant `tool_calls`
        // message without all of its results is rejected by providers.
        updatedChat.finalizeActiveStoppedTurn()
        // Re-locate the target after finalize (it may have shifted if the
        // safety net removed trailing placeholders before it).
        guard updatedChat.message(id: assistantMessageID) != nil else { return }

        let treesEnabled = hasChatTrees(for: updatedChat)
        // An errored placeholder that never received content is NOT preserved
        // as a branch — there's nothing worth keeping. Replace it in place.
        let isNeverStreamedError =
            target.error != nil
            && target.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (target.thinking?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (target.toolCalls?.isEmpty ?? true)

        if treesEnabled && !isNeverStreamedError {
            // Branching regen: the target stays stored as an inactive sibling
            // branch; the new placeholder becomes the active branch head.
            let placeholder = ChatMessage(role: .assistant, content: "", connectionName: connection.displayName)
            updatedChat.forkRegenerating(assistantMessageID, adding: placeholder)
        } else {
            // Destructive regen: remove the target and its whole continuation,
            // then append the placeholder right after the target's parent
            // (as the new active continuation when sibling branches survive).
            removeMessageAndSubtree(messageID: assistantMessageID, from: &updatedChat, filename: filename)
            let placeholder = ChatMessage(role: .assistant, content: "", connectionName: connection.displayName)
            updatedChat.forkContinuing(after: parent.id, adding: placeholder)
        }
        records[idx].chat = updatedChat
        emit(.chatsChanged(records))

        // Rebuild the request history: system prompt (from the role's prompt,
        // with variables substituted) followed by the surviving prefix (the
        // active path up to but not including the new placeholder).
        var messages: [ChatMessage] = []
        if let systemMsg = await systemMessage(for: updatedChat) {
            messages.append(systemMsg)
        }
        messages.append(contentsOf: updatedChat.activeMessages.dropLast())

        runToolLoop(for: filename, connection: connection, messages: messages)
    }

    /// Retries (regenerates) the last assistant turn for the given chat.
    ///
    /// When the active leaf is an assistant message, this delegates to
    /// [`regenerate`](#) on that message. When the active leaf is a user
    /// message (the empty-input send shortcut), it appends a fresh placeholder
    /// and re-runs the request from that user message — the standard
    /// "re-send my last message" behavior.
    func retryLastMessage(filename: String) async {
        guard !isStreaming(filename: filename) else { return }
        await ensureChatLoaded(filename: filename)
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard let chat = records[idx].chat else { return }
        // If the active leaf is an assistant message, regenerate it directly.
        if let leafID = chat.activeLeafID,
            let leaf = chat.message(id: leafID),
            leaf.role == .assistant,
            chat.activeMessages.count > 1
        {
            await regenerate(filename: filename, assistantMessageID: leaf.id)
            return
        }
        guard let connection = effectiveConnection(for: chat) else {
            emit(.error("Please select a connection in the status bar."))
            return
        }
        // Find the last user message on the active path. Everything after it
        // is the assistant's previous turn (response, tool calls, tool
        // results) and is discarded so we regenerate from the last user
        // message forward.
        let active = chat.activeMessages
        guard let lastUserIdx = active.lastIndex(where: { $0.role == .user }) else { return }
        let lastUser = active[lastUserIdx]

        var updatedChat = chat
        // Truncate the active path back to (and including) the last user
        // message: deleting the first message after it removes that whole
        // subtree — everything the old loop removed message by message.
        if lastUserIdx + 1 < active.count {
            removeMessageAndSubtree(messageID: active[lastUserIdx + 1].id, from: &updatedChat, filename: filename)
        }
        // Append a fresh placeholder assistant message for the new response,
        // right after the last user message.
        let placeholder = ChatMessage(role: .assistant, content: "", connectionName: connection.displayName)
        updatedChat.forkContinuing(after: lastUser.id, adding: placeholder)
        records[idx].chat = updatedChat
        emit(.chatsChanged(records))

        // Rebuild the request history: system prompt (from the role's prompt,
        // with variables substituted) followed by all messages up to (and
        // including) the last user message.
        var messages: [ChatMessage] = []
        if let systemMsg = await systemMessage(for: updatedChat) {
            messages.append(systemMsg)
        }
        messages.append(contentsOf: updatedChat.activeMessages.dropLast())

        runToolLoop(for: filename, connection: connection, messages: messages)
    }

    /// Whether a stream is currently in flight for the given chat.
    func isStreaming(filename: String) -> Bool {
        records.first(where: { $0.filename == filename })?.isStreaming ?? false
    }

    /// Starts (or restarts) the tool-calling loop for the given chat. The loop
    /// iterates: stream a completion with tools attached → if the model emitted
    /// tool calls, execute them via `MCPManager`, append the results, and stream
    /// again. Repeats until the model responds with no tool calls, an error
    /// occurs, or the user cancels the stream.
    private func runToolLoop(for filename: String, connection: Connection, messages: [ChatMessage]) {
        debugLog("Stream", "start — chat=\(filename), connection=\(connection.id)")
        if let idx = records.firstIndex(where: { $0.filename == filename }) {
            records[idx].isStreaming = true
            records[idx].stopAfterIteration = false
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

        // Unbounded: the loop terminates naturally when the model stops
        // emitting tool calls, on error, or on user cancellation. See the
        // doc comment on `runToolLoop` for rationale.
        while true {
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
                            message =
                                "The model reached the token limit before producing any output. It likely spent all its tokens on internal thinking. Try increasing max_tokens, then retry."
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
                // service returned them only in the final result. Each call is
                // stamped with its schema's required argument names so the
                // renderer can order the collapsed header's argument summary
                // (required first) for tools it has no built-in knowledge of,
                // and with an `internalTool` flag for the in-process
                // Configurator tools so the renderer's per-tool display hints
                // (syntax highlighting) can't misfire on a same-named
                // external MCP tool.
                let stampedCalls = result.toolCalls.map { call -> ToolCall in
                    var stamped = call
                    let def = toolDefs.first(where: { $0.namespacedName == call.name })
                    stamped.requiredArgs = def?.requiredArgs
                    stamped.internalTool = def?.serverName == ConfiguratorTools.serverName
                    // The collapsed one-line argument summary, shared by the
                    // chat renderer and the CLI.
                    stamped.summary = ToolSummary.callLine(
                        name: call.name, arguments: call.arguments, requiredArgs: stamped.requiredArgs)
                    return stamped
                }
                // `applyToolCalls` may rewrite colliding provider IDs — the
                // returned calls are the ones execution and results must use.
                let executedCalls = applyToolCalls(stampedCalls, filename: filename)
                // Flush immediately so the tool-call block appears in the UI
                // before we begin (potentially slow) tool execution.
                flushCoalescedEmit()
                emit(.chatsChanged(records))

                // Append the assistant message (with tool calls) to history.
                // We read the finalized assistant message from the record so
                // its content/thinking/toolCalls match what was streamed.
                if let idx = records.firstIndex(where: { $0.filename == filename }) {
                    let assistantMsg = records[idx].chat?.activeMessages.last(where: { $0.role == .assistant })
                    if let assistantMsg {
                        history.append(assistantMsg)
                    }
                }

                // Tool calls run in two phases: first every approval is
                // gathered (prompts are answered back to back, without tool
                // executions in between), then the approved calls execute in
                // order. This trades a bit of coherence — approval requests
                // are detached from their executions, and diff previews are
                // computed against the pre-execution state — for not
                // re-prompting the user after each (potentially slow) call.
                var preparedCalls: [PreparedToolCall] = []
                preparedCalls.reserveCapacity(executedCalls.count)
                for call in executedCalls {
                    // `prepareToolCall` awaits user approval, which can be
                    // cancelled (stop). Throws `CancellationError` in that case.
                    preparedCalls.append(try await prepareToolCall(call, filename: filename, tools: toolDefs))
                }

                // Execute each prepared call and append its result as its own
                // `tool`-role `ChatMessage` tagged with `callID` — the natural
                // provider shape. The renderer folds these back onto the
                // preceding assistant `toolCalls` as a view projection, so the
                // visible inline tool block is unchanged. The provider history
                // is built directly from these messages by `ChatService` (no
                // un-folding `flatMap` needed).
                for prepared in preparedCalls {
                    let toolResult = try await executePreparedToolCall(prepared, filename: filename)
                    // A stop requested during execution must unwind here:
                    // MCP/built-in tool calls may swallow task cancellation
                    // and return a result instead of throwing. Without this
                    // check the loop would keep appending results for a
                    // stream that's already stopped.
                    try Task.checkCancellation()
                    // Append the result as a `tool`-role message and persist.
                    appendToolResult(toolResult, filename: filename)
                    // Mirror into the working history so the next stream
                    // request includes it.
                    history.append(ChatMessage(role: .tool, content: "", toolResults: [toolResult]))
                }

                // "Stop after streaming" requested: the current iteration is
                // complete (all tool calls executed and their results
                // appended), so stop here without sending the results back to
                // the model. The next user message will carry them along.
                if consumeStopAfterIteration(filename: filename) {
                    finishStream(filename: filename)
                    return
                }

                // Create a new assistant message for the model's follow-up
                // response so it doesn't get appended to the tool-result
                // message.
                try Task.checkCancellation()
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
    }

    /// Gathers tool definitions from the chat's role-selected tool sources:
    /// built-in groups (in-process, always available) and custom MCP servers
    /// (using cached tool lists from configuration). The role's per-source
    /// `tools` selection is applied (intersected with the server's own tool
    /// allowlist for custom MCPs). Custom servers that failed configuration
    /// (no cached tools) are silently excluded. On-demand custom stdio servers
    /// are started before the request.
    private func gatherTools(filename: String) async -> [ToolDefinition] {
        guard let idx = records.firstIndex(where: { $0.filename == filename }),
            let chat = records[idx].chat
        else { return [] }
        let resolved = resolvedToolSources(for: chat)
        // The configurator role has no tool sources — it uses in-process config
        // tools instead — so don't bail out when its resolved list is empty.
        let isConfigurator = role(for: chat)?.name == ConfiguratorTools.configuratorRoleName
        guard !resolved.isEmpty || isConfigurator else { return [] }

        // Start on-demand custom stdio servers before the request.
        let custom = resolved.filter { !$0.isBuiltinGroup }.map(\.name)
        if !custom.isEmpty {
            await MCPManager.shared.ensureOnDemandRunning(custom)
        }

        var defs: [ToolDefinition] = []
        var perSourceCounts: [(String, Int)] = []
        // Local-only tools (macOS automation) are meaningless against an SSH
        // working directory and are not advertised at all.
        let sshWorkdir = effectiveWorkingDirectory(for: chat).map { SSHSpec.isSSH($0) } ?? false
        for r in resolved {
            if r.isBuiltinGroup {
                // Built-in groups: tools are always available (in-process).
                // Provider-backed web tools (web_search/web_extract) are
                // advertised even without a configured provider — the system
                // prompt carries a notice and calls fail with a clear error.
                let groupTools = BuiltinTools.tools(for: r.name)
                let roleAllow = Set(r.toolsFilter)
                let filtered = groupTools.filter { t in
                    if sshWorkdir, BuiltinTools.sshUnavailableToolNames.contains(t.name) { return false }
                    return roleAllow.isEmpty || roleAllow.contains(t.name)
                }
                perSourceCounts.append((r.name, filtered.count))
                defs.append(
                    contentsOf: filtered.map { tool in
                        ToolDefinition(
                            serverName: r.name,
                            prefix: "",
                            name: tool.name,
                            description: tool.description,
                            inputSchema: tool.schema
                        )
                    })
            } else {
                // Custom MCP server: read the cached tool list.
                guard let tools = await MCPManager.shared.cachedTools(for: r.name) else {
                    debugLog("MCP", "no cached tools — server=\"\(r.name)\", chat=\(filename) (skipped)")
                    perSourceCounts.append((r.name, 0))
                    continue
                }
                let serverConfig = await MCPManager.shared.serverConfig(for: r.name)
                let serverAllow = Set(serverConfig?.tools ?? [])
                let roleAllow = Set(r.toolsFilter)
                let filtered = tools.filter { t in
                    (serverAllow.isEmpty || serverAllow.contains(t.name))
                        && (roleAllow.isEmpty || roleAllow.contains(t.name))
                }
                perSourceCounts.append((r.name, filtered.count))
                let prefix = serverConfig?.prefix ?? r.name
                defs.append(
                    contentsOf: filtered.map { tool in
                        ToolDefinition(
                            serverName: r.name,
                            prefix: prefix,
                            name: tool.name,
                            description: tool.description,
                            inputSchema: tool.inputSchema
                        )
                    })
            }
        }
        // Deduplicate by namespaced name.
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
        // The bundled Configurator role uses in-process config tools.
        if role(for: chat)?.name == ConfiguratorTools.configuratorRoleName {
            unique.append(contentsOf: ConfiguratorTools.toolDefinitions)
        }
        debugLog("MCP", "gathered tools — chat=\(filename), total=\(unique.count), sources=\(resolved.count)")
        for (sourceName, count) in perSourceCounts {
            debugLog("MCP", "  source=\"\(sourceName)\" contributed \(count) tool(s)")
        }
        return unique
    }

    /// Records tool calls onto the active leaf assistant message of the chat
    /// so the renderer can display them (and show a "running" state until
    /// results arrive). Returns the calls with chat-wide-unique IDs: providers
    /// only guarantee per-response ID uniqueness (e.g. Kimi-style `name:index`
    /// IDs repeat every turn), but result correlation, approvals, and renderer
    /// folding key off `callID` across the whole chat. Providers treat these
    /// IDs as opaque pairing tokens, so rewriting them is transparent.
    @discardableResult
    private func applyToolCalls(_ calls: [ToolCall], filename: String) -> [ToolCall] {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return calls }
        guard var chat = records[idx].chat else { return calls }
        var calls = calls
        if let leafID = chat.activeLeafID, chat.message(id: leafID)?.role == .assistant {
            // The active leaf carries this turn's own (not yet uniqued)
            // streamed calls — exclude it from the collision set.
            let existingIDs = Set(chat.allMessages.filter { $0.id != leafID }.flatMap { $0.toolCalls ?? [] }.map(\.id))
            calls = calls.ensuringUniqueCallIDs(existingIDs: existingIDs)
            chat.updateMessage(id: leafID) { $0.toolCalls = calls }
        }
        records[idx].chat = chat
        // Let the CLI render the collapsed tool-call header as each call starts.
        for call in calls {
            let summary =
                call.summary
                ?? ToolSummary.callLine(name: call.name, arguments: call.arguments, requiredArgs: call.requiredArgs)
            notifyOneShot(filename: filename, .toolCall(name: call.name, summary: summary))
        }
        scheduleCoalescedEmit()
        return calls
    }

    /// Phase 1 of tool-call handling: resolves everything short of running the
    /// tool — matches the call against the advertised tools, computes
    /// auto-approval, builds diff previews / runs preflight checks, and (when
    /// needed) awaits the user's approval decision. The loop runs this for
    /// every call of the turn before any execution, so multiple approval
    /// prompts are answered back to back instead of being spread across
    /// (potentially slow) tool executions. Tools flagged as auto-allowed by
    /// the chat's role (`auto_allow` / `auto_allow_all`) skip the approval
    /// prompt. Throws `CancellationError` when a pending approval is cancelled
    /// by a stop.
    private func prepareToolCall(_ call: ToolCall, filename: String, tools: [ToolDefinition]) async throws
        -> PreparedToolCall
    {
        // Don't start new work (or a new approval prompt) once the stream was
        // stopped — the task is cancelled but MCP/built-in calls don't throw.
        try Task.checkCancellation()
        // Match the model-issued call name directly against the namespaced
        // names we advertised. This is unambiguous and doesn't depend on
        // prefix parsing, which mis-splits prefixless tools.
        guard let match = tools.first(where: { $0.namespacedName == call.name }) else {
            debugLog("Tool", "no advertised tool matches name \"\(call.name)\" — chat=\(filename)")
            return PreparedToolCall(
                call: call,
                immediateResult: ToolResult(
                    callID: call.id, content: "No tool found for name \"\(call.name)\".", isError: true))
        }
        let sourceName = match.serverName
        let toolName = match.name

        // In-process configurator tools run directly in the app (no MCP
        // subprocess) and are always auto-approved: their writes are validated
        // before touching disk, so there's nothing destructive to confirm.
        if sourceName == ConfiguratorTools.serverName {
            return PreparedToolCall(call: call, sourceName: sourceName, toolName: toolName)
        }

        // Auto-allow: if the role marks this tool (or all tools from this
        // source) as auto-approved, or the user previously allowed this tool
        // for this chat ("Allow for this chat"), skip the approval prompt —
        // unless the chat explicitly re-requires approval for it (auto_deny).
        let chat = records.first(where: { $0.filename == filename })?.chat
        let resolved = chat.map { resolvedToolSources(for: $0) } ?? []
        let roleAllows = resolved.first(where: { $0.name == sourceName })?.autoAllows(tool: toolName) ?? false
        let autoAllowed = chat?.isToolAutoApproved(namespacedName: call.name, roleDefault: roleAllows) ?? roleAllows
        // Shell whitelist: when the shell tool requires confirmation but the
        // role configures a command whitelist, a command whose every command
        // name is whitelisted skips the approval prompt. No-op when the tool
        // is already auto-allowed (role or chat level override).
        var shellWhitelisted = false
        if !autoAllowed, sourceName == BuiltinTools.shellGroup, toolName == "shell" {
            let source = resolved.first(where: { $0.name == sourceName })
            if let argsData = call.arguments.data(using: .utf8),
                let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
                let command = args["command"] as? String,
                source?.shellCommandAllowed(command) == true
            {
                shellWhitelisted = true
            }
        }
        // Working directory + isolation for built-in groups.
        let workdir = chat.flatMap { effectiveWorkingDirectory(for: $0) }
        let isolation = resolved.first(where: { $0.name == sourceName })?.directoryIsolation ?? false
        // Per-chat identity for SSH control-socket naming (one master
        // connection per chat+host).
        let chatID = chat?.id.uuidString ?? filename

        // For write_file, build a unified diff now so the renderer can show it
        // during the approval prompt (and after execution). The diff is
        // computed against the file's current content (read locally, or
        // fetched over SSH for remote workdirs), so it must be built before
        // the tool runs. Cleared on denial since the changes were never
        // applied.
        //
        // If a write_file call is missing arguments, there's nothing for the
        // user to approve — fail fast. For SSH workdirs a transport failure
        // only skips the preview — the tool itself runs and reports the error.
        if sourceName == BuiltinTools.filesystemGroup, toolName == "write_file" {
            let wd = Workdir(root: workdir, isolated: isolation, chatID: chatID)
            if let ssh = wd.ssh {
                do {
                    if let d = try await BuiltinToolsSSH.diffForWriteFile(
                        arguments: call.arguments, workdir: wd, ssh: ssh)
                    {
                        setToolCallDiff(callID: call.id, filename: filename, diff: d)
                    } else {
                        debugLog("Tool", "write_file arguments invalid (no diff) — callID=\(call.id), chat=\(filename)")
                        return PreparedToolCall(
                            call: call,
                            immediateResult: ToolResult(
                                callID: call.id, content: "Invalid arguments: expected 'path' and 'content' strings.",
                                isError: true))
                    }
                } catch {
                    debugLog(
                        "Tool",
                        "write_file SSH diff preview failed (\(error.localizedDescription)) — proceeding without diff, callID=\(call.id), chat=\(filename)"
                    )
                }
            } else {
                if let d = DiffBuilder.diffForWriteFile(arguments: call.arguments, workdir: wd) {
                    setToolCallDiff(callID: call.id, filename: filename, diff: d)
                } else {
                    debugLog("Tool", "write_file arguments invalid (no diff) — callID=\(call.id), chat=\(filename)")
                    return PreparedToolCall(
                        call: call,
                        immediateResult: ToolResult(
                            callID: call.id, content: "Invalid arguments: expected 'path' and 'content' strings.",
                            isError: true))
                }
            }
        }

        // For edit_file, run a preflight: parse the hashline patch, validate
        // the #TAGs against current file content, and build the diff preview
        // for the approval UI. A preflight failure (parse error, stale tag,
        // non-text file, unseen anchor lines) is relayed to the model as an
        // immediate error instead of asking the user to approve a call that
        // can't succeed. SSH runs the same checks locally on fetched content.
        if sourceName == BuiltinTools.codeGroup, toolName == "edit_file" {
            let wd = Workdir(root: workdir, isolated: isolation, chatID: chatID)
            let store = records.first(where: { $0.filename == filename })?.snapshotStore
            if let ssh = wd.ssh {
                do {
                    if let d = try await BuiltinToolsSSH.diffForEditFile(
                        arguments: call.arguments, workdir: wd, ssh: ssh, snapshotStore: store)
                    {
                        setToolCallDiff(callID: call.id, filename: filename, diff: d)
                    }
                } catch let err as BuiltinToolError {
                    return PreparedToolCall(
                        call: call,
                        immediateResult: ToolResult(callID: call.id, content: err.message, isError: true))
                } catch let err as HashlineEditError {
                    return PreparedToolCall(
                        call: call,
                        immediateResult: ToolResult(callID: call.id, content: err.localizedDescription, isError: true))
                } catch {
                    debugLog(
                        "Tool",
                        "edit_file SSH preflight failed (\(error.localizedDescription)) — proceeding without diff, callID=\(call.id), chat=\(filename)"
                    )
                }
            } else {
                switch DiffBuilder.preflightEditFile(arguments: call.arguments, workdir: wd, snapshotStore: store) {
                case .ok(let diff):
                    setToolCallDiff(callID: call.id, filename: filename, diff: diff)
                case .error(let message):
                    debugLog("Tool", "edit_file preflight failed — callID=\(call.id), chat=\(filename)")
                    return PreparedToolCall(
                        call: call,
                        immediateResult: ToolResult(callID: call.id, content: message, isError: true))
                }
            }
        }

        let approval: ToolApproval
        if autoAllowed {
            debugLog("Tool", "auto-allowed \(sourceName)/\(toolName) — callID=\(call.id), chat=\(filename)")
            approval = .allow
        } else if shellWhitelisted {
            debugLog("Tool", "shell whitelist approved \(sourceName)/\(toolName) — callID=\(call.id), chat=\(filename)")
            approval = .allow
        } else if cliDriven.contains(filename) {
            if cliAllowAll.contains(filename) {
                debugLog(
                    "Tool",
                    "auto-approved via --allow-all \(sourceName)/\(toolName) — callID=\(call.id), chat=\(filename)")
                approval = .allow
            } else if cliInteractive.contains(filename) {
                // Interactive CLI session: the approval prompt is relayed to
                // the client and answered in the terminal.
                approval = try await approveToolCall(chatFilename: filename, call: call)
            } else {
                // Non-interactive CLI: there's nobody to answer an approval
                // prompt. The call is skipped: the CLI user gets a warning
                // and the model gets a cancellation result explaining what
                // happened.
                debugLog(
                    "Tool",
                    "skipping unconfirmed CLI tool call \(sourceName)/\(toolName) — callID=\(call.id), chat=\(filename)"
                )
                notifyOneShot(
                    filename: filename,
                    .notice(
                        "tool call \"\(call.name)\" requires confirmation — skipped (re-run with --allow-all to auto-approve tool calls)"
                    ))
                // The changes were never applied — drop any diff preview.
                setToolCallDiff(callID: call.id, filename: filename, diff: nil)
                return PreparedToolCall(
                    call: call,
                    immediateResult: ToolResult(
                        callID: call.id,
                        content:
                            "The tool call was not executed: it requires user confirmation, but the request is running in non-interactive CLI mode. Tell the user to re-run the command with --allow-all (-y) to auto-approve tool calls.",
                        isError: true,
                        isCancelled: true
                    ))
            }
        } else {
            // The approval hook. Suspends until the user allows or denies the
            // call (or cancels via stop, which throws `CancellationError`). The
            // chat remains in its streaming state throughout — a pause, not a
            // stop.
            approval = try await approveToolCall(chatFilename: filename, call: call)
        }

        return PreparedToolCall(
            call: call, sourceName: sourceName, toolName: toolName, workdir: workdir, isolation: isolation,
            chatID: chatID, approval: approval)
    }

    /// Phase 2 of tool-call handling: executes a call prepared by
    /// [`prepareToolCall`](#) and returns its result. Calls with an
    /// `immediateResult` (preflight failures, non-interactive CLI skips)
    /// report it as-is; denied calls produce the denial result. Built-in
    /// groups and configurator tools run in-process; custom MCP server tools
    /// run via [`MCPManager`](src/MCP/MCPManager.swift).
    private func executePreparedToolCall(_ prepared: PreparedToolCall, filename: String) async throws -> ToolResult {
        // Don't start new work once the stream was stopped — the task is
        // cancelled but MCP/built-in calls don't throw.
        try Task.checkCancellation()
        if let immediate = prepared.immediateResult { return immediate }
        let call = prepared.call
        let sourceName = prepared.sourceName
        let toolName = prepared.toolName

        switch prepared.approval {
        case .allow:
            debugLog("Tool", "executing \(sourceName)/\(toolName) — callID=\(call.id), chat=\(filename)")
            let result: ToolResult
            if sourceName == ConfiguratorTools.serverName {
                result = await ConfiguratorTools.call(name: toolName, arguments: call.arguments, callID: call.id)
            } else if BuiltinTools.allGroups.contains(sourceName) {
                // Built-in group: run in-process with the chat's workdir.
                let wd = Workdir(root: prepared.workdir, isolated: prepared.isolation, chatID: prepared.chatID)
                result = await BuiltinTools.call(
                    name: toolName, arguments: call.arguments, callID: call.id, group: sourceName, workdir: wd,
                    chatFilename: filename,
                    snapshotStore: records.first(where: { $0.filename == filename })?.snapshotStore)
            } else {
                // Custom MCP server: use the shared connection pool.
                result = await MCPManager.shared.callTool(
                    server: sourceName, name: toolName, arguments: call.arguments, callID: call.id,
                    chatFilename: filename)
            }
            debugLog(
                "Tool",
                "result \(sourceName)/\(toolName) — isError=\(result.isError), contentSize=\(result.content.count), chat=\(filename)"
            )
            return result
        case .deny(let reason):
            let message = ToolApproval.denialMessage(for: reason)
            debugLog("Tool", "denied callID=\(call.id) — \(message), chat=\(filename)")
            // The changes were never applied, so drop the diff to avoid keeping
            // stale data around.
            setToolCallDiff(callID: call.id, filename: filename, diff: nil)
            // `isError` stays true so the provider treats this as a tool error,
            // but `isDenied` lets the renderer show "denied" rather than "error".
            return ToolResult(callID: call.id, content: message, isError: true, isDenied: true)
        }
    }

    /// Sets the `diff` field on a tool call (matched by `callID`) on the last
    /// assistant message of the active path, so the renderer can show a
    /// colorized diff instead of raw arguments. Pass `nil` to clear it (e.g.
    /// on denial). Persists in-memory only and emits.
    private func setToolCallDiff(callID: String, filename: String, diff: String?) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard var chat = records[idx].chat else { return }
        guard let targetID = chat.activeMessages.last(where: { $0.role == .assistant })?.id,
            var calls = chat.message(id: targetID)?.toolCalls,
            let cIdx = calls.firstIndex(where: { $0.id == callID })
        else { return }
        calls[cIdx].diff = diff
        chat.updateMessage(id: targetID) { $0.toolCalls = calls }
        records[idx].chat = chat
        flushCoalescedEmit()
        emit(.chatsChanged(records))
    }

    /// The tool-call approval decision point. For GUI chats: marks the call
    /// as pending and draws the UI's attention (`.toolApprovalRequested`).
    /// For interactive CLI chats: relays the request to the client as a
    /// one-shot event instead (the prompt lives in the terminal — the GUI
    /// stays out of it). Either way, suspends on a continuation until
    /// `resolveToolCallApproval` (allow/deny) or `cancelPendingApprovals`
    /// (stop) resumes it.
    private func approveToolCall(chatFilename: String, call: ToolCall) async throws -> ToolApproval {
        if cliInteractive.contains(chatFilename) {
            let summary =
                call.summary
                ?? ToolSummary.callLine(name: call.name, arguments: call.arguments, requiredArgs: call.requiredArgs)
            notifyOneShot(
                filename: chatFilename, .toolApprovalRequest(callID: call.id, name: call.name, summary: summary))
        } else {
            setPendingApproval(callID: call.id, filename: chatFilename, pending: true)
            emit(.toolApprovalRequested(filename: chatFilename, callID: call.id))
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingApprovals[call.id] = PendingToolApproval(filename: chatFilename, continuation: continuation)
        }
    }

    /// Resolves a tool-call approval coming from an interactive CLI session.
    /// `decision` is "allow" (once), "allow_chat" (remember for this chat),
    /// or "deny" (with an optional reason). Unknown decisions and stale call
    /// ids are ignored.
    func resolveCLIToolApproval(callID: String, decision: String, reason: String?) {
        switch decision {
        case "allow":
            resolveToolCallApproval(callID: callID, approval: .allow)
        case "allow_chat":
            allowToolCallForChat(callID: callID)
        case "deny":
            resolveToolCallApproval(callID: callID, approval: .deny(reason: reason ?? ""))
        default:
            debugLog("Tool", "ignoring CLI approval with unknown decision \"\(decision)\" — callID=\(callID)")
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

    /// Approves a pending tool call and remembers the tool as auto-approved
    /// for this chat only: the call's namespaced name is appended to the
    /// chat's `auto_allow` list (persisted), so future calls to the same tool
    /// skip the approval prompt. No-op when there's no pending approval or
    /// the call can't be found; resolves with `.allow` either way when a
    /// pending approval exists.
    func allowToolCallForChat(callID: String) {
        guard let pending = pendingApprovals[callID] else { return }
        if let idx = records.firstIndex(where: { $0.filename == pending.filename }),
            var chat = records[idx].chat,
            let call = chat.allMessages.lazy.compactMap(\.toolCalls).joined().first(where: { $0.id == callID })
        {
            var changed = false
            if chat.autoDeny?.contains(call.name) == true {
                chat.autoDeny?.removeAll { $0 == call.name }
                if chat.autoDeny?.isEmpty == true { chat.autoDeny = nil }
                changed = true
            }
            var allowed = chat.autoAllow ?? []
            if !allowed.contains(call.name) {
                allowed.append(call.name)
                chat.autoAllow = allowed
                changed = true
            }
            if changed {
                records[idx].chat = chat
                saveChat(chat, filename: pending.filename)
                debugLog("Tool", "auto-allowing \(call.name) for chat \(pending.filename)")
            }
        }
        resolveToolCallApproval(callID: callID, approval: .allow)
    }

    /// Sets the `pendingApproval` flag on a tool call (matched by `callID`) on
    /// the last assistant message of the active path, so the renderer expands
    /// the block and shows Allow/Deny buttons. Persists in-memory only and
    /// emits.
    private func setPendingApproval(callID: String, filename: String, pending: Bool) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard var chat = records[idx].chat else { return }
        guard let targetID = chat.activeMessages.last(where: { $0.role == .assistant })?.id,
            var calls = chat.message(id: targetID)?.toolCalls,
            let cIdx = calls.firstIndex(where: { $0.id == callID })
        else { return }
        calls[cIdx].pendingApproval = pending
        chat.updateMessage(id: targetID) { $0.toolCalls = calls }
        records[idx].chat = chat
        flushCoalescedEmit()
        emit(.chatsChanged(records))
    }

    /// Cancels every pending approval for a chat (used when the user stops the
    /// stream). Resumes each continuation with `CancellationError` so the
    /// streaming loop unwinds. The incomplete turn itself is dropped by
    /// `stopStreaming` (via `trimStoppedTurn`), not here.
    private func cancelPendingApprovals(filename: String) {
        let toCancel = pendingApprovals.filter { $0.value.filename == filename }
        guard !toCancel.isEmpty else { return }
        for (callID, pending) in toCancel {
            pendingApprovals.removeValue(forKey: callID)
            pending.continuation.resume(throwing: CancellationError())
        }
        flushCoalescedEmit()
        emit(.chatsChanged(records))
        for (callID, _) in toCancel {
            emit(.toolApprovalResolved(filename: filename, callID: callID))
        }
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
        // Ignore late results for calls that are no longer in the chat — e.g.
        // a cancelled tool finishing after `stopStreaming` already trimmed the
        // incomplete turn. Appending here would leave a dangling `tool`-role
        // message with no matching tool call.
        guard
            chat.allMessages.contains(where: {
                $0.role == .assistant && $0.toolCalls?.contains(where: { $0.id == result.callID }) == true
            })
        else {
            debugLog("Tool", "ignoring result for unknown/trimmed call — callID=\(result.callID), chat=\(filename)")
            return
        }
        // Stamp the persisted one-line status summary (shared by the chat
        // renderer and the CLI) and forward it to the CLI sinks.
        var result = result
        let callName =
            chat.allMessages.lazy.compactMap(\.toolCalls).joined().first(where: { $0.id == result.callID })?.name ?? ""
        if result.summary == nil {
            result.summary = ToolSummary.resultStatus(name: callName, result: result)
        }
        if let summary = result.summary {
            notifyOneShot(filename: filename, .toolResult(name: callName, summary: summary))
        }
        // If a streaming placeholder `tool`-role message exists for this
        // callID (current turn, active path), replace its results in place
        // with the final result — keeping the message id stable so the
        // renderer diffs it as an update.
        if let tID = chat.activeToolResultMessageID(callID: result.callID) {
            chat.updateMessage(id: tID) { $0.toolResults = [result] }
        } else {
            // No placeholder yet — append a new `tool`-role message to the
            // active leaf.
            chat.appendToActiveLeaf(ChatMessage(role: .tool, content: "", toolResults: [result]))
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
        // Ignore late progress after a stop: the turn was finalized and its
        // unexecuted calls already carry synthesized "cancelled" results.
        guard records[idx].isStreaming else { return }
        guard var chat = records[idx].chat else { return }
        // Find the `tool`-role message carrying an in-flight result for this
        // callID (current turn only, active path) and append to its streaming
        // content.
        if let tID = chat.activeToolResultMessageID(callID: callID),
            var results = chat.message(id: tID)?.toolResults,
            let rIdx = results.firstIndex(where: { $0.callID == callID })
        {
            results[rIdx].content += partial + "\n"
            results[rIdx].isStreaming = true
            chat.updateMessage(id: tID) { $0.toolResults = results }
            records[idx].chat = chat
            // In-memory only during streaming; persisted once by `finishStream`.
            scheduleCoalescedEmit()
            return
        }
        // No existing `tool`-role message yet — the progress notification
        // arrived before `appendToolResult` created one. Create a streaming
        // placeholder now so the user sees output immediately. It will be
        // replaced by the final result when the call completes. Skip when no
        // assistant message carries this call (e.g. the turn was trimmed by a
        // stop) — appending would leave a dangling `tool`-role message.
        guard
            chat.allMessages.contains(where: {
                $0.role == .assistant && $0.toolCalls?.contains(where: { $0.id == callID }) == true
            })
        else { return }
        let placeholder = ToolResult(callID: callID, content: partial + "\n", isError: false, isStreaming: true)
        chat.appendToActiveLeaf(ChatMessage(role: .tool, content: "", toolResults: [placeholder]))
        records[idx].chat = chat
        // In-memory only during streaming; persisted once by `finishStream`.
        scheduleCoalescedEmit()
    }

    /// Appends a new (empty) assistant message that the next stream iteration
    /// will fill with the model's follow-up response. After a tool call, the
    /// conversation has three distinct blocks: the user message, the assistant
    /// message carrying the tool call + result, and this new assistant message
    /// with the final answer. Appends to the active leaf. Persists and emits
    /// immediately so the new row appears right away.
    private func appendAssistantMessage(filename: String, connection: Connection) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard var chat = records[idx].chat else { return }
        chat.appendToActiveLeaf(ChatMessage(role: .assistant, content: "", connectionName: connection.displayName))
        records[idx].chat = chat
        // In-memory only during streaming; persisted once by `finishStream`.
        flushCoalescedEmit()
        emit(.chatsChanged(records))
    }

    /// Applies a streamed chunk to the active leaf assistant message of the
    /// given chat.
    private func applyChunk(_ chunk: StreamChunk, filename: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard var chat = records[idx].chat else { return }
        // Late chunks can arrive after a stop trimmed the placeholder; only
        // ever write to an assistant message, never to a user/tool message.
        // The streaming target is the active leaf (the placeholder appended
        // when the turn started).
        guard let leafID = chat.activeLeafID,
            chat.message(id: leafID)?.role == .assistant
        else { return }
        switch chunk {
        case .thinking(let text):
            chat.updateMessage(id: leafID) { $0.thinking = ($0.thinking ?? "") + text }
        case .content(let text):
            chat.updateMessage(id: leafID) { $0.content += text }
            if let sinks = oneShotSinks[filename] {
                for sink in sinks.values { sink.yield(.delta(text)) }
            }
        case .error(let text):
            chat.updateMessage(id: leafID) { $0.error = text }
        case .toolCallDelta(let index, let id, let name, let argsDelta):
            // Incremental tool call update — grow the tool call at `index`
            // in place so the UI shows the arguments populating live. The
            // final `.toolCall` chunk (emitted at stream end) replaces this
            // entry with the authoritative, complete ToolCall.
            chat.updateMessage(id: leafID) { msg in
                var calls = msg.toolCalls ?? []
                while calls.count <= index { calls.append(ToolCall(id: "", name: "", arguments: "")) }
                if let id, !id.isEmpty { calls[index].id = id }
                if let name, !name.isEmpty { calls[index].name = name }
                calls[index].arguments += argsDelta
                msg.toolCalls = calls
            }
        case .toolCall(let call):
            // The final, authoritative tool call emitted at stream end.
            // Replace the entry at the matching index (or append if none).
            chat.updateMessage(id: leafID) { msg in
                var calls = msg.toolCalls ?? []
                if let matchIdx = calls.firstIndex(where: { $0.id == call.id && !call.id.isEmpty }) {
                    calls[matchIdx] = call
                } else {
                    calls.append(call)
                }
                msg.toolCalls = calls
            }
        case .finishReason:
            // No state change needed; the finish reason is used by the loop
            // via the StreamResult return value.
            break
        case .usage(let usage):
            // Provider-reported token usage for this assistant response.
            // Stored on the message and surfaced in the chat info panel.
            chat.updateMessage(id: leafID) { $0.tokenUsage = usage }
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
        defer { completeOneShotSinks(filename: filename) }
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else {
            streamTasks[filename] = nil
            return
        }
        records[idx].stopAfterIteration = false
        // Persist the final accumulated state to disk via the store
        // (temporary chats are never persisted).
        guard let finalChat = records[idx].chat else {
            streamTasks[filename] = nil
            return
        }
        if !records[idx].isTemporary {
            markSelfWrite(path: env.chatsURL.appendingPathComponent(filename).path)
            store.saveChat(finalChat, filename: filename)
        }
        if let info = store.getEntry(filename: filename) {
            records[idx].cachedName = info.name
            records[idx].cachedRole = info.role
            records[idx].cachedModificationTime = info.modificationTime
            records[idx].cachedArchive = info.archive
            records[idx].cachedWorkingDirectory = info.workingDirectory
            records[idx].cachedLastActivity = info.lastActivity
        }
        records[idx].isStreaming = false
        streamTasks[filename] = nil
        // Flag as unread so the user is notified of new activity — but only if
        // this isn't the chat the user is currently looking at. When the
        // finished chat is the selected one the user has already seen the
        // answer, so marking it unread would only surface a stale circle once
        // they switch away.
        if records[idx].filename != selectedFilename, !cliDriven.contains(records[idx].filename) {
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

    /// Records an error onto the active leaf assistant message of the given
    /// chat and persists it.
    private func recordError(_ text: String, filename: String) {
        emit(.error(text))
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        guard var chat = records[idx].chat else { return }
        if let leafID = chat.activeLeafID,
            chat.message(id: leafID)?.role == .assistant
        {
            chat.updateMessage(id: leafID) { $0.error = text }
        }
        records[idx].chat = chat
        records[idx].lastError = text
        // Not persisted here: `finishStream` (always called right after an
        // error) writes the final state — including this error — to disk.
    }

    /// Cancels the in-flight stream for the given chat. Flips the streaming
    /// flag immediately so the UI reflects the stop right away; the stream
    /// task finalizes the message content asynchronously via `finishStream`.
    /// Requests a graceful stop for the given chat: the in-flight iteration
    /// (model response + any tool calls it emitted) runs to completion, then
    /// the loop stops without sending the tool results back to the model.
    /// No-op when the chat isn't streaming; a regular `stopStreaming` always
    /// takes precedence and clears this request.
    func stopStreamingAfterIteration(filename: String) {
        guard let idx = records.firstIndex(where: { $0.filename == filename }),
            records[idx].isStreaming, !records[idx].stopAfterIteration
        else { return }
        debugLog("Stream", "stop-after-iteration requested — chat=\(filename)")
        records[idx].stopAfterIteration = true
        emit(.chatsChanged(records))
    }

    /// Checks and clears a pending "stop after current iteration" request.
    private func consumeStopAfterIteration(filename: String) -> Bool {
        guard let idx = records.firstIndex(where: { $0.filename == filename }),
            records[idx].stopAfterIteration
        else { return false }
        records[idx].stopAfterIteration = false
        return true
    }

    func stopStreaming(filename: String) {
        debugLog("Stream", "stop requested — chat=\(filename)")
        // If we were awaiting tool-call approval, resume those continuations
        // with a cancellation so the loop unwinds.
        cancelPendingApprovals(filename: filename)
        streamTasks[filename]?.cancel()
        if let idx = records.firstIndex(where: { $0.filename == filename }) {
            records[idx].stopAfterIteration = false
            // Finalize the incomplete trailing turn on the active path: empty
            // placeholder assistant messages are removed, and tool calls that
            // never got a result receive a synthesized "cancelled" result — a
            // state providers accept, which also tells the model exactly which
            // actions did and didn't happen. Only the last (incomplete) turn
            // is touched; earlier completed tool-call loops are kept.
            if var chat = records[idx].chat {
                chat.finalizeActiveStoppedTurn()
                records[idx].chat = chat
            }
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
            !namingInProgress.contains(filename)
        else { return }

        guard let firstUserMsg = records[idx].chat?.activeMessages.first(where: { $0.role == .user }) else { return }
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
            chat.title == nil
        else { return }
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

    /// Edits a message's content. User-message edits restart the turn: the
    /// edited content is applied to the same message id, the continuation is
    /// handled per the chat's tree setting (preserved as a sibling branch
    /// when trees are on, deleted when off), a fresh assistant placeholder is
    /// appended, and the tool loop re-runs (edit & resend). Assistant-message
    /// edits stay in-place text fixes (no request re-run — nothing to
    /// regenerate from).
    func editMessage(filename: String, messageID: UUID, newText: String) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        guard var chat = records[idx].chat else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let target = chat.message(id: messageID) else { return }
        if target.role == .user {
            // Edit & resend: apply the new content to the same message id,
            // then handle the continuation per the tree setting.
            guard let connection = effectiveConnection(for: chat) else {
                emit(.error("Please select a connection in the status bar."))
                return
            }
            chat.updateMessage(id: messageID) {
                $0.content = trimmed
                $0.error = nil
            }
            let placeholder = ChatMessage(role: .assistant, content: "", connectionName: connection.displayName)
            if hasChatTrees(for: chat) {
                // Branching edit: the edited message is the fork point. Its
                // existing continuation is preserved as an inactive sibling
                // branch; the new placeholder becomes the active branch. No
                // deletion warning needed — nothing is lost.
                chat.forkContinuing(after: messageID, adding: placeholder)
            } else {
                // Destructive: remove everything after the edited message on
                // the active path, then append the placeholder right after it
                // (as the new active continuation when sibling branches
                // survive).
                let active = chat.activeMessages
                if let activeIdx = active.firstIndex(where: { $0.id == messageID }), activeIdx + 1 < active.count {
                    removeMessageAndSubtree(messageID: active[activeIdx + 1].id, from: &chat, filename: filename)
                }
                chat.finalizeActiveStoppedTurn()
                chat.forkContinuing(after: messageID, adding: placeholder)
            }
            records[idx].chat = chat
            emit(.chatsChanged(records))
            // Rebuild the request history: system prompt + surviving prefix
            // (the active path up to but not including the new placeholder).
            var messages: [ChatMessage] = []
            if let systemMsg = await systemMessage(for: chat) {
                messages.append(systemMsg)
            }
            messages.append(contentsOf: chat.activeMessages.dropLast())
            runToolLoop(for: filename, connection: connection, messages: messages)
        } else {
            // Assistant-message edit: in-place text fix only.
            chat.updateMessage(id: messageID) {
                $0.content = trimmed
                $0.error = nil
            }
            saveChat(chat, filename: filename)
            emit(.chatsChanged(records))
        }
    }

    /// Deletes a message and its continuation along the active path only.
    /// For forked chats, sibling branches hanging off the message's ancestors
    /// are untouched (they become reachable via the nearest surviving fork).
    /// After the deletion, tree metadata is pruned and the active choice is
    /// reassigned to the most recent surviving sibling. For linear chats,
    /// deletes the message and everything after it. Attachment-file cleanup
    /// applies to all removed messages.
    func deleteMessage(filename: String, messageID: UUID) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        guard var chat = records[idx].chat else { return }
        guard chat.message(id: messageID) != nil else { return }
        removeMessageAndSubtree(messageID: messageID, from: &chat, filename: filename)
        chat.finalizeActiveStoppedTurn()
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    // MARK: - Branch switching

    /// Switches the active branch at a fork point: makes the branch starting
    /// with `childID` the active continuation of `parentID`, persists, and
    /// emits. The active path below the switch re-derives automatically (each
    /// deeper fork follows its own recorded choice). No-op when the chat
    /// isn't forked, the parent isn't a fork point, or the child doesn't
    /// head one of its branches.
    func setActiveBranch(filename: String, parentID: UUID, childID: UUID) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        guard var chat = records[idx].chat, chat.hasForks else { return }
        guard chat.switchActiveBranch(parentID: parentID, to: childID) else { return }
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    /// Points the active path at `messageID` (tree overview jump): every
    /// fork on the way switches to the branch containing the message.
    /// Persists and emits; no-op for unknown messages or linear chats.
    func activatePath(filename: String, messageID: UUID) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        guard var chat = records[idx].chat, chat.hasForks else { return }
        guard chat.activatePath(to: messageID) else { return }
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    /// Resolves the sibling to switch to when the user clicks ◀ or ▶ on a
    /// message with siblings. Returns the target sibling id, or nil when
    /// there's only one sibling (no switch possible) or the message can't be
    /// found. `direction` is -1 for ◀ (previous) or +1 for ▶ (next), wrapping
    /// around at the ends.
    func siblingForSwitch(filename: String, messageID: UUID, direction: Int) -> UUID? {
        guard let idx = records.firstIndex(where: { $0.filename == filename }),
            let chat = records[idx].chat
        else { return nil }
        return chat.siblingID(of: messageID, direction: direction)
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

    /// Updates the selected role for a chat. The chat's active custom MCP
    /// selection is re-seeded from the new role (mirroring `createNewChat`).
    func setRole(filename: String, roleName: String) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        guard var chat = records[idx].chat else { return }
        chat.role = roleName
        let roleMCPs = roles.first(where: { $0.name == roleName })?.config.mcps ?? []
        chat.mcps = roleMCPs.isEmpty ? nil : roleMCPs.map(\.mcp)
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    /// Builds the tool snapshot for the chat-info sidebar: every tool currently
    /// available to the chat, split into built-in groups and external (custom
    /// MCP) sources, each entry carrying its effective auto-approval state
    /// (role default adjusted by the chat's `auto_allow` / `auto_deny`).
    /// Read-only: uses cached MCP tool lists and never starts on-demand
    /// servers, so servers that are down simply contribute no tools.
    func toolSnapshot(filename: String) async -> ChatToolSnapshot {
        guard let idx = records.firstIndex(where: { $0.filename == filename }),
            let chat = records[idx].chat
        else { return ChatToolSnapshot(builtin: [], external: []) }
        let resolved = resolvedToolSources(for: chat)
        let sshWorkdir = effectiveWorkingDirectory(for: chat).map { SSHSpec.isSSH($0) } ?? false
        var builtin: [ChatToolEntry] = []
        var external: [ChatToolEntry] = []
        // Mirror the request-time gating: provider-backed web tools only
        // exist when a provider is configured.
        let webProviderConfigured = await ConfigManager.shared.getWebSearchConfig().isConfigured
        for r in resolved {
            if r.isBuiltinGroup {
                let roleAllow = Set(r.toolsFilter)
                for tool in BuiltinTools.tools(for: r.name) {
                    if sshWorkdir, BuiltinTools.sshUnavailableToolNames.contains(tool.name) { continue }
                    if r.name == BuiltinTools.webGroup, !webProviderConfigured,
                        BuiltinToolsWeb.providerToolNames.contains(tool.name)
                    {
                        continue
                    }
                    if !roleAllow.isEmpty && !roleAllow.contains(tool.name) { continue }
                    builtin.append(
                        ChatToolEntry(
                            name: tool.name,
                            description: tool.description,
                            autoApproved: chat.isToolAutoApproved(
                                namespacedName: tool.name, roleDefault: r.autoAllows(tool: tool.name)),
                            roleAutoApproved: r.autoAllows(tool: tool.name),
                            source: r.name,
                            hasShellWhitelist: r.name == BuiltinTools.shellGroup && !r.shellWhitelist.isEmpty
                        ))
                }
            } else {
                guard let tools = await MCPManager.shared.cachedTools(for: r.name) else { continue }
                let serverConfig = await MCPManager.shared.serverConfig(for: r.name)
                let serverAllow = Set(serverConfig?.tools ?? [])
                let roleAllow = Set(r.toolsFilter)
                let prefix = serverConfig?.prefix ?? r.name
                for tool in tools {
                    if !serverAllow.isEmpty && !serverAllow.contains(tool.name) { continue }
                    if !roleAllow.isEmpty && !roleAllow.contains(tool.name) { continue }
                    let namespaced = prefix.isEmpty ? tool.name : "\(prefix)_\(tool.name)"
                    external.append(
                        ChatToolEntry(
                            name: namespaced,
                            description: tool.description ?? "",
                            autoApproved: chat.isToolAutoApproved(
                                namespacedName: namespaced, roleDefault: r.autoAllows(tool: tool.name)),
                            roleAutoApproved: r.autoAllows(tool: tool.name),
                            source: serverConfig?.name ?? r.name,
                            hasShellWhitelist: false
                        ))
                }
            }
        }
        return ChatToolSnapshot(
            builtin: Self.deduplicated(builtin),
            external: Self.deduplicated(external)
        )
    }

    /// Dedupes entries by name (first occurrence wins) and sorts them
    /// alphabetically, mirroring the request-time tool dedup.
    private static func deduplicated(_ entries: [ChatToolEntry]) -> [ChatToolEntry] {
        var seen = Set<String>()
        return
            entries
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Toggles the effective auto-approval state of a single tool for a chat,
    /// relative to the role's default, and persists the chat. When the new
    /// state matches the role default no override is written. Tool names that
    /// aren't currently available to the chat are ignored.
    func toggleToolAutoApproval(filename: String, toolName: String) async {
        guard records.contains(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        let snapshot = await toolSnapshot(filename: filename)
        guard let entry = (snapshot.builtin + snapshot.external).first(where: { $0.name == toolName }) else { return }
        guard let idx = records.firstIndex(where: { $0.filename == filename }),
            var chat = records[idx].chat
        else { return }
        chat.toggleToolAutoApproval(namespacedName: toolName, roleDefault: entry.roleAutoApproved)
        saveChat(chat, filename: filename)
        emit(.chatsChanged(records))
    }

    /// Updates the per-chat custom MCP selection (names of active servers).
    /// Only meaningful when the chat's role allows MCP overrides; the engine
    /// stores the value regardless and resolution falls back to it.
    func setChatMCPs(filename: String, names: [String]) async {
        guard let idx = records.firstIndex(where: { $0.filename == filename }) else { return }
        await ensureChatLoaded(filename: filename)
        guard var chat = records[idx].chat else { return }
        chat.mcps = names.isEmpty ? nil : names
        saveChat(chat, filename: filename)
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

/// One tool row for the chat-info sidebar: the namespaced display name (what
/// the model sees), the description (empty when the tool provides none), and
/// the effective auto-approval state for the chat.
struct ChatToolEntry: Equatable, Sendable {
    let name: String
    let description: String
    /// Effective state: role default adjusted by per-chat overrides.
    let autoApproved: Bool
    /// The role's default auto-approval state, used when toggling so a state
    /// matching the default persists no override.
    let roleAutoApproved: Bool
    /// The source group this tool belongs to: a built-in group name (e.g.
    /// "Filesystem") for built-in tools, or the MCP server name for external
    /// tools. Used by the chat-info sidebar to render subsections.
    let source: String
    /// Whether a `shell_whitelist` is defined for this tool (shell only).
    /// When true, the sidebar renders the tag in yellow/green instead of
    /// grey/green to signify partial auto-approval.
    let hasShellWhitelist: Bool
}

/// The tools available to a chat, split into built-in groups ("Tools") and
/// external custom MCP servers ("External Tools"), each sorted alphabetically.
struct ChatToolSnapshot: Equatable, Sendable {
    var builtin: [ChatToolEntry]
    var external: [ChatToolEntry]
}

/// A tool call that went through the approval phase
/// (`ChatEngine.prepareToolCall`) and is ready for execution
/// (`ChatEngine.executePreparedToolCall`). `immediateResult`, when set,
/// short-circuits execution: it's the result to report as-is (unmatched tool
/// name, argument/preflight failures, non-interactive CLI skips).
struct PreparedToolCall: Sendable {
    let call: ToolCall
    var immediateResult: ToolResult? = nil
    var sourceName: String = ""
    var toolName: String = ""
    var workdir: String? = nil
    var isolation: Bool = false
    var chatID: String = ""
    var approval: ToolApproval = .allow
}

/// A tool-call approval awaiting a user decision, stored in
/// `ChatEngine.pendingApprovals` keyed by call id. The continuation resumes
/// `approveToolCall` with the user's `ToolApproval` (or throws
/// `CancellationError` on stop).
struct PendingToolApproval: Sendable {
    let filename: String
    let continuation: CheckedContinuation<ToolApproval, Error>
}
