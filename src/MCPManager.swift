// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MCP
#if canImport(System)
    import System
#else
    import SystemPackage
#endif

/// A tool exposed by an MCP server, in a provider-agnostic shape ready to be
/// mapped onto OpenAI/Anthropic tool definitions by `ChatService`.
struct MCPTool: Sendable, Equatable {
    let name: String
    let description: String?
    /// Raw JSON string of the tool's input schema (a JSON Schema object).
    let inputSchema: String
}

/// Owns the runtime MCP client connections. A singleton `actor` that keeps
/// `MCP.Client` instances alive, reconnects on config change, caches the
/// discovered tool list per server, and exposes `callTool()` for the
/// agent loop. Lives alongside `ChatEngine`.
///
/// The configuration flow (`configure`/`reconfigure`) is driven by
/// `ChatEngine`. It connects stdio servers, queries tools, discards servers
/// that fail, stops on-demand stdio servers, and reports live status via
/// `statusHandler` so the UI can show a configuration overlay.
///
/// During chat requests, `cachedTools(for:)` returns the saved tool list
/// without re-querying, and `callTool` starts on-demand stdio servers on
/// demand. Servers that become unreachable mid-conversation are never
/// permanently disabled: a clear error is returned to the LLM in the RESULT
/// field, and the next tool call retries the connection.
actor MCPManager {

    static let shared = MCPManager()

    /// A connected MCP server: its config, the SDK client, and (for stdio) the
    /// spawned subprocess so we can terminate it on disconnect.
    private final class Connection: @unchecked Sendable {
        let server: MCPServer
        let client: Client
        /// For stdio servers: the spawned process. Nil for http.
        let process: Process?
        /// The `Initialize.Result` returned by the server on connect. Carries
        /// `serverInfo` (name/version), negotiated `protocolVersion`, and the
        /// server's `capabilities`. Kept for later queries (e.g. UI display).
        let initResult: Initialize.Result

        init(server: MCPServer, client: Client, process: Process? = nil, initResult: Initialize.Result) {
            self.server = server
            self.client = client
            self.process = process
            self.initResult = initResult
        }
    }

    private var connections: [String: Connection] = [:]
    /// The full set of servers known from the last `configure`. Used to look
    /// up config when an on-demand server needs to be started for a chat
    /// request, and to know each server's run policy.
    private var knownServers: [String: MCPServer] = [:]
    /// Cached tool lists per server, populated during `configure` /
    /// `reconfigure`. Read by `cachedTools(for:)` during chat requests so we
    /// don't re-query servers on every LLM turn.
    private var toolsCache: [String: [MCPTool]] = [:]
    /// Wall-clock time of the last tool activity (callTool) for an on-demand
    /// server. Used to compute the 600s idle timeout.
    private var lastActivity: [String: Date] = [:]
    /// Pending idle-shutdown tasks for on-demand servers, keyed by server name.
    /// Cancelled when activity resumes or the server is disconnected.
    private var idleTasks: [String: Task<Void, Never>] = [:]
    /// Seconds an on-demand server stays alive after the last tool activity
    /// before being shut down.
    private let idleTimeout: TimeInterval = 600
    /// Optional sink for human-readable error messages (wired to ChatEngine).
    private var errorHandler: ((String) -> Void)?
    /// Optional sink for streaming tool-output progress. Called with the
    /// `chatFilename` of the chat that owns the in-flight tool call, the
    /// `callID` of the call, and the human-readable progress `message` (or a
    /// fallback) emitted by the server via `notifications/progress`. Wired by
    /// `ChatEngine` so partial results can be folded onto the live `tool`-role
    /// message in that one chat directly. Marked `@Sendable` because the
    /// notification handler closure may escape the actor.
    private var progressHandler: (@Sendable (String, String, String) -> Void)?
    /// Optional sink for live MCP configuration status updates. Called by
    /// `configure`/`reconfigure` as each server's connect/listTools step
    /// starts, succeeds, or fails. Wired by `ChatEngine` so the UI can show
    /// the configuration overlay. The closure is `@Sendable` because it is
    /// invoked from the actor and hops to the engine.
    private var statusHandler: (@Sendable (MCPConfigurationState) -> Void)?

    private init() {}

    /// Sets the error sink. Called once by `ChatEngine` at startup.
    func setErrorHandler(_ handler: @escaping (String) -> Void) {
        self.errorHandler = handler
    }

    /// Sets the streaming-progress sink. Called once by `ChatEngine` at
    /// startup. The handler receives `(chatFilename, callID, partialText)` for
    /// each progress notification a server emits during a `tools/call`. The
    /// closure is `@Sendable` because it is invoked from the MCP notification
    /// handler which may run off the actor.
    func setProgressHandler(_ handler: @escaping @Sendable (String, String, String) -> Void) {
        self.progressHandler = handler
    }

    /// Sets the MCP configuration status sink. Called once by `ChatEngine` at
    /// startup. The handler receives the full `MCPConfigurationState` snapshot
    /// whenever a server's status changes during `configure`/`reconfigure`.
    func setStatusHandler(_ handler: @escaping @Sendable (MCPConfigurationState) -> Void) {
        self.statusHandler = handler
    }

    private func reportError(_ message: String) {
        errorHandler?(message)
    }

    /// Pushes a configuration status snapshot to the status sink (if set).
    private func reportStatus(_ state: MCPConfigurationState) {
        statusHandler?(state)
    }

    /// Maps an MCP progress token back to the originating call's
    /// `(chatFilename, callID)` so progress notifications can be correlated
    /// with the chat + call that issued them. Populated in `callTool`, cleared
    /// when the call completes.
    private var progressTokenToCall: [String: (chatFilename: String, callID: String)] = [:]

    /// Looks up the `(chatFilename, callID)` for a progress token. Actor-isolated.
    private func call(forProgressToken token: ProgressToken) -> (chatFilename: String, callID: String)? {
        switch token {
        case .string(let s): return progressTokenToCall[s]
        case .integer(let i): return progressTokenToCall[String(i)]
        }
    }

    /// Actor-isolated helper that resolves a progress token to its
    /// `(chatFilename, callID)` and forwards the partial text to the progress
    /// sink. Called from the non-isolated notification handler closure via
    /// `await`.
    private func forwardProgress(token: ProgressToken, text: String) {
        guard let call = call(forProgressToken: token) else { return }
        progressHandler?(call.chatFilename, call.callID, text)
    }

    // MARK: - Run-policy helpers

    /// Returns true if the server should be kept alive continuously (always-on
    /// or http/nil policy). Only stdio on-demand servers are started lazily.
    private func isAlwaysOn(_ server: MCPServer) -> Bool {
        server.runPolicy != .onDemand
    }

    // MARK: - Configuration flow

    /// Full configuration pass: connects stdio servers one by one, queries all
    /// servers for their tool lists in parallel, discards servers that fail,
    /// stops on-demand stdio servers, and reports live status via
    /// `statusHandler`. Called on app start (via `ChatEngine.start()`) and
    /// from the "File > Reload MCPs…" menu item (after a full reset).
    ///
    /// If `servers` is empty, this is a no-op (the overlay is skipped by the
    /// caller). Returns the final configuration state so the caller can emit
    /// it once more after the 1-second display delay.
    func configure(_ servers: [MCPServer]) async -> MCPConfigurationState {
        debugLog("MCP", "configure — \(servers.count) server(s) configured")
        // Full reset: clear all known state so we start from a clean slate.
        await resetAll()

        let newByName = Dictionary(servers.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
        knownServers = newByName

        // Build the initial status snapshot: all servers pending.
        var state = MCPConfigurationState(
            isConfiguring: true,
            entries: servers.map {
                MCPConfigurationEntry(name: $0.name, status: .pending, toolCount: nil, errorMessage: nil)
            }
        )
        reportStatus(state)

        // Phase 1: start stdio servers one by one. We connect each in turn so
        // startup errors are attributable and we don't fork a burst of
        // subprocesses simultaneously. HTTP servers don't need a startup
        // phase (they connect on first request), but we mark them inProgress
        // here for the overlay.
        for server in servers {
            // Mark this server in-progress.
            state.set(name: server.name, status: .inProgress)
            reportStatus(state)

            if server.transport == .stdio {
                // Connect the stdio server. On failure, discard it and mark
                // failed; the tool-list query phase will skip it.
                await connect(server)
                if connections[server.name] == nil {
                    state.set(name: server.name, status: .failed, toolCount: nil,
                              errorMessage: "stdio server failed to start")
                    reportStatus(state)
                }
            }
            // HTTP servers: connection is established during the listTools
            // call below; stay inProgress.
        }

        // Phase 2: query all servers for their tool lists in parallel. For
        // HTTP servers this is the first (and only) contact. For stdio servers
        // that started successfully, this queries the live process.
        await withTaskGroup(of: (String, [MCPTool]?).self) { group in
            for server in servers {
                let name = server.name
                // Skip stdio servers that failed to start.
                if server.transport == .stdio && connections[name] == nil {
                    continue
                }
                group.addTask { [weak self] in
                    guard let self else { return (name, nil) }
                    // For http servers, connect first (lazily) so the listTools
                    // call has a live client. connect() is idempotent.
                    if server.transport == .http {
                        await self.connect(server)
                        if await self.connections[name] == nil {
                            return (name, nil)
                        }
                    }
                    do {
                        let tools = try await self.queryTools(for: name)
                        return (name, tools)
                    } catch {
                        debugLog("MCP", "configure listTools failed — server=\"\(name)\": \(error.localizedDescription)")
                        return (name, nil)
                    }
                }
            }
            for await (name, tools) in group {
                if let tools {
                    // Success: cache the tools and mark success.
                    toolsCache[name] = tools
                    state.set(name: name, status: .success, toolCount: tools.count, errorMessage: nil)
                } else {
                    // Failure: discard the server (disconnect if connected)
                    // and mark failed.
                    await disconnect(name: name)
                    toolsCache.removeValue(forKey: name)
                    state.set(name: name, status: .failed, toolCount: nil,
                              errorMessage: "failed to list tools")
                }
                reportStatus(state)
            }
        }

        // Phase 3: stop on-demand stdio servers. They're not needed until a
        // chat request activates them; keeping them alive wastes resources.
        for server in servers where server.transport == .stdio && server.runPolicy == .onDemand {
            if connections[server.name] != nil {
                debugLog("MCP", "configure — stopping on-demand stdio server \"\(server.name)\" after config")
                await disconnect(name: server.name)
            }
        }

        state.isConfiguring = false
        reportStatus(state)
        debugLog("MCP", "configure complete — \(toolsCache.count) server(s) healthy, \(servers.count - toolsCache.count) failed")
        return state
    }

    /// Reconfigures a single server after its config was created or edited.
    /// Disconnects the old connection (if any), starts the stdio server (if
    /// stdio), queries tools, and stops on-demand stdio servers. Reports live
    /// status via `statusHandler` for just this server. Other servers are
    /// unaffected.
    func reconfigure(_ server: MCPServer) async -> MCPConfigurationState {
        debugLog("MCP", "reconfigure — server=\"\(server.name)\", transport=\(server.transport)")
        knownServers[server.name] = server

        var entry = MCPConfigurationEntry(name: server.name, status: .inProgress, toolCount: nil, errorMessage: nil)
        // Start with a single-entry in-progress state.
        var state = MCPConfigurationState(isConfiguring: true, entries: [entry])
        reportStatus(state)

        // Tear down any existing connection for this server (config changed).
        await disconnect(name: server.name)

        if server.transport == .stdio {
            await connect(server)
            if connections[server.name] == nil {
                entry.status = .failed
                entry.errorMessage = "stdio server failed to start"
                state.entries[0] = entry
                state.isConfiguring = false
                reportStatus(state)
                return state
            }
        } else {
            // HTTP: connect lazily.
            await connect(server)
            if connections[server.name] == nil {
                entry.status = .failed
                entry.errorMessage = "http server failed to connect"
                state.entries[0] = entry
                state.isConfiguring = false
                reportStatus(state)
                return state
            }
        }

        // Query tools.
        do {
            let tools = try await queryTools(for: server.name)
            toolsCache[server.name] = tools
            entry.status = .success
            entry.toolCount = tools.count
            entry.errorMessage = nil
        } catch {
            debugLog("MCP", "reconfigure listTools failed — server=\"\(server.name)\": \(error.localizedDescription)")
            await disconnect(name: server.name)
            toolsCache.removeValue(forKey: server.name)
            entry.status = .failed
            entry.errorMessage = "failed to list tools"
        }
        state.entries[0] = entry

        // Stop on-demand stdio servers after config.
        if server.transport == .stdio && server.runPolicy == .onDemand {
            await disconnect(name: server.name)
        }

        state.isConfiguring = false
        reportStatus(state)
        debugLog("MCP", "reconfigure complete — server=\"\(server.name)\"")
        return state
    }

    /// Disconnects and forgets a server that was removed from disk. Clears its
    /// cached tools and known config.
    func forget(_ name: String) async {
        debugLog("MCP", "forget — server=\"\(name)\"")
        await disconnect(name: name)
        knownServers.removeValue(forKey: name)
        toolsCache.removeValue(forKey: name)
        lastActivity.removeValue(forKey: name)
        idleTasks.removeValue(forKey: name)?.cancel()
    }

    /// Full reset: disconnects all servers and clears all caches. Used before
    /// a fresh `configure` pass (e.g. "File > Reload MCPs…").
    func resetAll() async {
        debugLog("MCP", "resetAll — clearing all connections and caches")
        await disconnectAll()
        knownServers.removeAll()
        toolsCache.removeAll()
        lastActivity.removeAll()
        for task in idleTasks.values { task.cancel() }
        idleTasks.removeAll()
    }

    // MARK: - Connect / disconnect

    /// Builds the transport and initializes the MCP client for `server`.
    /// Failures are reported via `errorHandler` and the server is simply left
    /// disconnected (no entry in `connections`). Never throws to the caller;
    /// the configuration flow inspects `connections` to determine success.
    func connect(_ server: MCPServer) async {
        // Don't retry if already connected with the same config.
        if let existing = connections[server.name], existing.server == server { return }
        debugLog("MCP", "connect — server=\"\(server.name)\", transport=\(server.transport)")

        do {
            let transport: any Transport
            var process: Process? = nil
            switch server.transport {
            case .stdio:
                guard let command = server.command, !command.isEmpty else {
                    throw MCPManagerError.invalidConfig(server.name, "stdio server missing 'command'")
                }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: command)
                if command.contains("/") == false {
                    // Resolve via PATH if not an absolute path.
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    proc.arguments = [command] + (server.args ?? [])
                } else {
                    proc.arguments = server.args ?? []
                }
                let stdin = Pipe()
                let stdout = Pipe()
                proc.standardInput = stdin
                proc.standardOutput = stdout
                proc.standardError = Pipe()
                try proc.run()
                process = proc
                debugLog("MCP", "stdio server \"\(server.name)\" started — pid=\(proc.processIdentifier), command=\(command) args=\(server.args ?? [])")
                // StdioTransport reads from `output` (server stdout) and writes to
                // `input` (server stdin). We pass the pipe file handles' descriptors.
                let inputFD = try fileDescriptor(for: stdout.fileHandleForReading)
                let outputFD = try fileDescriptor(for: stdin.fileHandleForWriting)
                transport = StdioTransport(input: inputFD, output: outputFD)
            case .http:
                guard let endpointString = server.endpoint, let url = URL(string: endpointString) else {
                    throw MCPManagerError.invalidConfig(server.name, "http server missing or invalid 'endpoint'")
                }
                let token = server.token
                transport = HTTPClientTransport(
                    endpoint: url,
                    streaming: true,
                    requestModifier: { request in
                        var modified = request
                        if let token, !token.isEmpty {
                            modified.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        }
                        return modified
                    }
                )
            }

            let client = Client(name: "iCanHazAI", version: "1.0.0")
            // Register a progress-notification handler for this client. The
            // server emits `notifications/progress` (with the progress token we
            // attached to the `tools/call` request) to stream incremental tool
            // output. We map the token back to the model-assigned `callID`
            // via `progressTokenToCallID` and forward the human-readable
            // `message` (falling back to a numeric progress value) to the
            // engine's progress sink so it can update the live tool result.
            await client.onNotification(ProgressNotification.self) { [weak self] message in
                guard let self else { return }
                let params = message.params
                let text = params.message ?? "progress \(Int(params.progress))\(params.total.map { "/\(Int($0))" } ?? "")"
                await self.forwardProgress(token: params.progressToken, text: text)
            }
            let initResult: Initialize.Result
            do {
                initResult = try await client.connect(transport: transport)
            } catch {
                process?.terminate()
                throw error
            }
            connections[server.name] = Connection(server: server, client: client, process: process, initResult: initResult)
            debugLog("MCP", "connected — server=\"\(server.name)\", serverName=\"\(initResult.serverInfo.name)\", serverVersion=\"\(initResult.serverInfo.version)\", protocolVersion=\"\(initResult.protocolVersion)\", capabilities=\(capabilitySummary(initResult.capabilities))")
        } catch {
            debugLog("MCP", "connect failed — server=\"\(server.name)\": \(error.localizedDescription)")
            reportError("MCP server \"\(server.name)\" failed to connect: \(error.localizedDescription)")
        }
    }

    /// Produces a compact, human-readable summary of a server's capabilities,
    /// e.g. `"tools,resources,logging"`. Used for connect logging and UI.
    nonisolated private func capabilitySummary(_ capabilities: Server.Capabilities) -> String {
        var parts: [String] = []
        if capabilities.tools != nil { parts.append("tools") }
        if capabilities.resources != nil { parts.append("resources") }
        if capabilities.prompts != nil { parts.append("prompts") }
        if capabilities.logging != nil { parts.append("logging") }
        if capabilities.completions != nil { parts.append("completions") }
        return parts.isEmpty ? "none" : parts.joined(separator: ",")
    }

    /// Disconnects and tears down the client for `name`. Closes the MCP
    /// client (which closes the transport pipes) and terminates any spawned
    /// stdio subprocess so we don't leak orphaned processes. No-op if the
    /// server isn't connected.
    func disconnect(name: String) async {
        // Cancel any pending idle-shutdown task for this server.
        idleTasks.removeValue(forKey: name)?.cancel()
        lastActivity.removeValue(forKey: name)
        guard let conn = connections.removeValue(forKey: name) else { return }
        debugLog("MCP", "disconnect — server=\"\(name)\"")
        await conn.client.disconnect()
        if let process = conn.process {
            process.terminate()
            // Give the subprocess a moment to exit, then reap it so we don't
            // leave a zombie. `waitUntilExit` blocks the actor briefly, but
            // termination is infrequent and the delay is typically <100ms.
            process.waitUntilExit()
            debugLog("MCP", "stdio server \"\(name)\" terminated — pid=\(process.processIdentifier), exitStatus=\(process.terminationStatus), reason=\(process.terminationReason.rawValue)")
        }
    }

    /// Disconnects all servers (e.g. on app shutdown or full reset).
    func disconnectAll() async {
        // Cancel all pending idle-shutdown tasks.
        for task in idleTasks.values { task.cancel() }
        idleTasks.removeAll()
        lastActivity.removeAll()
        let names = Array(connections.keys)
        debugLog("MCP", "disconnectAll — \(names.count) server(s)")
        for name in names {
            await disconnect(name: name)
        }
    }

    // MARK: - Tool list (configuration-time query)

    /// Queries the live tool list from a connected server, paginating through
    /// all cursors. Throws on any failure. Used by the configuration flow
    /// (`configure`/`reconfigure`) to populate `toolsCache`. Unlike
    /// `cachedTools`, this always hits the live server.
    private func queryTools(for server: String) async throws -> [MCPTool] {
        guard let conn = connections[server] else {
            throw MCPManagerError.unavailable(server)
        }
        var tools: [MCPTool] = []
        var cursor: String? = nil
        repeat {
            let (batch, next) = try await conn.client.listTools(cursor: cursor)
            for tool in batch {
                let schemaData = try JSONEncoder().encode(tool.inputSchema)
                let schemaString = String(data: schemaData, encoding: .utf8) ?? "{}"
                tools.append(MCPTool(
                    name: tool.name,
                    description: tool.description,
                    inputSchema: schemaString
                ))
            }
            cursor = next
        } while cursor != nil
        debugLog("MCP", "queryTools — server=\"\(server)\", count=\(tools.count)")
        return tools
    }

    // MARK: - Cached tools (request-time read)

    /// Returns the cached tool list for `server`, or nil if the server has no
    /// cached tools (it failed configuration or was never configured). Used by
    /// `ChatEngine.gatherTools` during chat requests so we don't re-query
    /// servers on every LLM turn.
    func cachedTools(for server: String) -> [MCPTool]? {
        toolsCache[server]
    }

    /// Connects to `server` and queries its tool list, returning the tools.
    /// Throws on any failure (connect or listTools). Used by the MCP wizard's
    /// connection test step. The caller is responsible for disconnecting the
    /// transient connection afterwards (via `disconnect(name:)`).
    func testConnection(_ server: MCPServer) async throws -> [MCPTool] {
        // Tear down any existing connection with this name first so we test
        // the fresh config.
        await disconnect(name: server.name)
        await connect(server)
        guard connections[server.name] != nil else {
            throw MCPManagerError.unavailable(server.name)
        }
        return try await queryTools(for: server.name)
    }

    // MARK: - On-demand server lifecycle

    /// Ensures an on-demand stdio server is connected before a chat request.
    /// If the server is already connected, this refreshes its idle timer. If
    /// not, it looks up the current config from `knownServers` and starts it.
    /// No-op for always-on / http servers. Called by `ChatEngine` before
    /// building the request when the chat has on-demand MCP servers active.
    func ensureOnDemandRunning(_ names: [String]) async {
        for name in names {
            guard let server = knownServers[name], server.runPolicy == .onDemand else { continue }
            if connections[name] != nil {
                touchActivity(name)
                continue
            }
            // If the server was configured successfully (it's in toolsCache),
            // start it now. Servers that failed configuration are skipped;
            // their cached tools are nil and gatherTools already excluded them.
            guard toolsCache[name] != nil else { continue }
            debugLog("MCP", "ensureOnDemandRunning — starting on-demand server \"\(name)\"")
            await connect(server)
            touchActivity(name)
        }
    }

    /// Records the current time as the last activity for an on-demand server
    /// and (re)schedules its idle-shutdown task.
    private func touchActivity(_ name: String) {
        lastActivity[name] = Date()
        // Cancel any previously scheduled idle shutdown and schedule a fresh one.
        idleTasks.removeValue(forKey: name)?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.idleTimeout ?? 600) * 1_000_000_000))
            guard let self else { return }
            // Re-check on the actor: only shut down if still on-demand and the
            // timeout has genuinely elapsed (no newer activity superseded this).
            await self.handleIdleTimeout(name)
        }
        idleTasks[name] = task
    }

    /// Actor-isolated idle-timeout handler. If the server is still on-demand
    /// and no activity has occurred since the timer was scheduled, disconnect
    /// it. Otherwise the timer is stale and ignored.
    private func handleIdleTimeout(_ name: String) async {
        guard let last = lastActivity[name] else { return }
        let elapsed = Date().timeIntervalSince(last)
        guard elapsed >= idleTimeout else { return }
        // Only auto-shut-down on-demand servers.
        if let server = knownServers[name], server.runPolicy == .onDemand {
            debugLog("MCP", "idle timeout — shutting down on-demand server \"\(name)\" after \(Int(elapsed))s of inactivity")
            await disconnect(name: name)
            lastActivity.removeValue(forKey: name)
            idleTasks.removeValue(forKey: name)
        }
    }

    // MARK: - Tool calling

    /// Calls a tool on `server` with JSON-encoded `arguments` and maps the
    /// result into our `ToolResult`. `callID` is the model-assigned tool call
    /// id, propagated onto the result so the provider can correlate them.
    /// `chatFilename` identifies the chat that owns this call so progress
    /// notifications can be routed to that chat's live `tool`-role message
    /// directly. Non-text content is summarized.
    ///
    /// If the server is unreachable, the error is returned as the RESULT
    /// content (with `isError: false` per spec — the tool call didn't
    /// "fail" from the model's perspective, the server was just momentarily
    /// unreachable). The server is NOT permanently disabled; the next tool
    /// call will retry the connection. On-demand stdio servers are started
    /// lazily here if needed.
    func callTool(server: String, name: String, arguments: String, callID: String, chatFilename: String) async -> ToolResult {
        debugLog("MCP", "callTool — server=\"\(server)\", tool=\"\(name)\", callID=\(callID), chat=\(chatFilename)")
        // Start on-demand stdio servers lazily before calling tools.
        if let known = knownServers[server], known.runPolicy == .onDemand {
            await ensureOnDemandRunning([server])
        }
        guard let conn = connections[server] else {
            // Server unreachable. Return a clear error as the RESULT field.
            // isError is false per spec: the tool call itself didn't error,
            // the server was just unreachable. The LLM sees the message and
            // can retry on the next call.
            debugLog("MCP", "callTool — server \"\(server)\" unreachable, returning error in RESULT")
            return ToolResult(callID: callID, content: "MCP server \"\(server)\" is currently unreachable. Please retry.", isError: false)
        }
        // Parse the raw JSON arguments string into an MCP `Value`.
        let argsValue: [String: Value]?
        if let data = arguments.data(using: .utf8), !data.isEmpty {
            do {
                let decoded = try JSONDecoder().decode(Value.self, from: data)
                if case .object(let dict) = decoded {
                    argsValue = dict
                } else {
                    argsValue = nil
                }
            } catch {
                return ToolResult(callID: callID, content: "Failed to parse tool arguments JSON: \(error.localizedDescription)", isError: true)
            }
        } else {
            argsValue = nil
        }

        // Attach a unique progress token so the server can stream incremental
        // output via `notifications/progress`. The handler registered in
        // `connect` maps this token back to `(chatFilename, callID)` and
        // forwards the text to the engine's progress sink, which folds it onto
        // the live `tool`-role message in that chat.
        let progressToken = ProgressToken.unique()
        let tokenKey: String = {
            switch progressToken {
            case .string(let s): return s
            case .integer(let i): return String(i)
            }
        }()
        progressTokenToCall[tokenKey] = (chatFilename, callID)
        defer { progressTokenToCall.removeValue(forKey: tokenKey) }

        do {
            let (content, isError) = try await conn.client.callTool(
                name: name,
                arguments: argsValue,
                meta: Metadata(progressToken: progressToken)
            )
            let text = content.map { item -> String in
                switch item {
                case .text(let text, _, _):
                    return text
                case .image(_, let mimeType, _, _):
                    return "[image: \(mimeType)]"
                case .audio(_, let mimeType, _, _):
                    return "[audio: \(mimeType)]"
                case .resource(let resource, _, _):
                    return "[resource: \(resource.uri)]"
                case .resourceLink(let uri, let name, _, _, _, _):
                    return "[resource link: \(name) at \(uri)]"
                }
            }.joined(separator: "\n")
            // Per spec: if the tool itself errored and MCP returned an error,
            // this is normal — we provide the error text as the RESULT field.
            // The `isError` flag from MCP is preserved so the provider can
            // surface it appropriately. We do NOT mark the server as failed.
            debugLog("MCP", "callTool result — server=\"\(server)\", tool=\"\(name)\", isError=\(isError ?? false), contentSize=\(text.count)")
            return ToolResult(callID: callID, content: text, isError: isError ?? false)
        } catch is CancellationError {
            debugLog("MCP", "callTool cancelled — server=\"\(server)\", tool=\"\(name)\", callID=\(callID)")
            return ToolResult(callID: callID, content: "Tool call was cancelled.", isError: true)
        } catch {
            // Server errored during the call (transport failure, timeout, etc).
            // Per spec: return the error as the RESULT field. We do NOT
            // permanently disable the server — the next tool call will retry.
            // Disconnect so a subsequent call reconnects cleanly.
            debugLog("MCP", "callTool failed — server=\"\(server)\", tool=\"\(name)\", callID=\(callID), error=\(error), type=\(String(describing: error))")
            await disconnect(name: server)
            return ToolResult(callID: callID, content: "MCP server \"\(server)\" error during tool call: \(error.localizedDescription). Please retry.", isError: false)
        }
    }

    // MARK: - Helpers

    /// Whether a server is currently connected.
    func isConnected(_ server: String) -> Bool {
        connections[server] != nil
    }

    /// Extracts a `FileDescriptor` from a `FileHandle`. The SDK's `StdioTransport`
    /// uses `SystemPackage.FileDescriptor`, which on Darwin is backed by the
    /// raw file descriptor integer.
    private func fileDescriptor(for handle: FileHandle) throws -> FileDescriptor {
        // FileHandle.fileDescriptor is the raw Int32 fd.
        return FileDescriptor(rawValue: handle.fileDescriptor)
    }
}

// MARK: - MCPConfigurationState mutation helper

extension MCPConfigurationState {
    /// Updates the entry for `name` with a new status (and optional tool count
    /// / error message). No-op if the entry doesn't exist.
    mutating func set(name: String, status: MCPConfigStatus, toolCount: Int? = nil, errorMessage: String? = nil) {
        guard let idx = entries.firstIndex(where: { $0.name == name }) else { return }
        entries[idx].status = status
        if let toolCount { entries[idx].toolCount = toolCount }
        if let errorMessage { entries[idx].errorMessage = errorMessage }
    }
}

// MARK: - Errors

enum MCPManagerError: Error, LocalizedError {
    case invalidConfig(String, String)
    case unavailable(String)
    case toolListFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let name, let reason):
            return "MCP server \"\(name)\" has an invalid configuration: \(reason)"
        case .unavailable(let name):
            return "MCP server \"\(name)\" is not available."
        case .toolListFailed(let name, let reason):
            return "Failed to list tools from MCP server \"\(name)\": \(reason)"
        }
    }
}
