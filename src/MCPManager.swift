// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MCP
import Logging
import ProcessExit
import LoginShell
#if canImport(System)
    import System
#else
    import SystemPackage
#endif

/// A `Logger` backend that routes MCP SDK log messages through our `debugLog`
/// facility under the "MCP/SDK" topic, so transport-level events (connect,
/// send, receive, EOF, errors) are visible in the debug log alongside our own.
private let mcpLogger = Logger(label: "iCanHazAI.mcp") { _ in
    MCPDebugLogHandler()
}

/// A `LogHandler` that forwards to `debugLog("MCP/SDK", message)`.
private struct MCPDebugLogHandler: LogHandler {
    func log(level: Logging.Logger.Level, message: Logging.Logger.Message, metadata: Logging.Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        debugLog("MCP/SDK", "\(level): \(message)")
    }
    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { nil }
        set { }
    }
    var metadata: Logging.Logger.Metadata {
        get { [:] }
        set { }
    }
    var logLevel: Logging.Logger.Level {
        get { .debug }
        set { }
    }
}

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

    // MARK: - In-house (builtin) MCP servers

    /// The in-house MCP servers, always present in the list regardless of
    /// on-disk config. Each is a stdio on-demand server that runs as a
    /// per-chat copy when selected. `command` points at the bundled binary
    /// (or the SwiftPM build output in dev/test). Servers whose binary can't
    /// be located are omitted — the app still works, just without them.
    static func builtinServers() -> [MCPServer] {
        // (display name, tool prefix, binary name). Ordered as in build.sh.
        // `binary` is the SwiftPM product name (prefixed `iCanHazAI-` so the
        // spawned processes are distinguishable in `ps` / Activity Monitor).
        // `prefix` is empty: in-house tools are exposed under their own names
        // (e.g. `shell`, `calc`) without namespacing.
        let defs: [(name: String, prefix: String, binary: String)] = [
            ("Utils",      "", "iCanHazAI-UtilsMCP"),
            ("Filesystem", "", "iCanHazAI-FilesystemMCP"),
            ("Code",       "", "iCanHazAI-CodeMCP"),
            ("Shell",      "", "iCanHazAI-ShellMCP"),
        ]
        return defs.compactMap { d in
            guard let path = builtinBinaryPath(for: d.binary) else {
                debugLog("MCP", "in-house server \"\(d.name)\" binary not found (\(d.binary)), skipping")
                return nil
            }
            // Quote the path so `exec` survives spaces in the build path.
            return MCPServer(
                name: d.name,
                prefix: d.prefix,
                transport: .stdio,
                runPolicy: .onDemand,
                command: "\"\(path)\"",
                endpoint: nil,
                token: nil,
                tools: nil,
                isBuiltin: true
            )
        }
    }

    /// Locates a bundled MCP server binary. Checks the app bundle's
    /// `Contents/Resources/MCPServers/` first (production and dev bundles),
    /// then the SwiftPM build output (for `swift run` / tests): walks up from
    /// the main bundle (or CWD) to find the package root containing `mcps/`.
    nonisolated static func builtinBinaryPath(for binary: String) -> String? {
        let fm = FileManager.default
        // 1. Bundled app: Contents/Resources/MCPServers/<binary>
        if let dir = Bundle.main.url(forResource: "MCPServers", withExtension: nil) {
            let p = dir.appendingPathComponent(binary).path
            if fm.isExecutableFile(atPath: p) { return p }
        }
        // 2. SwiftPM build output relative to the package root.
        let root = packageRoot()
        let candidates = [
            "\(root)/.build/debug/\(binary)",
            "\(root)/.build/arm64-apple-macosx/debug/\(binary)",
            "\(root)/.build/apple/Products/release/\(binary)",
        ]
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        return nil
    }

    /// Walks up from the main bundle's directory (falling back to CWD) until
    /// a `mcps/` directory is found, identifying the package root. Mirrors
    /// `MCPTestHarness.packageRoot` for use at runtime.
    nonisolated private static func packageRoot() -> String {
        let fm = FileManager.default
        var url = Bundle.main.bundleURL.deletingLastPathComponent()
        // If running unbundled (swift run), Bundle.main.bundleURL is the
        // .build/<arch>/debug dir; the walk-up still finds the package root.
        if url.path == "." || !fm.fileExists(atPath: url.path) {
            url = URL(fileURLWithPath: fm.currentDirectoryPath)
        }
        while url.path != "/" {
            if fm.fileExists(atPath: url.appendingPathComponent("mcps").path) {
                return url.path
            }
            url = url.deletingLastPathComponent()
        }
        return fm.currentDirectoryPath
    }

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

    // MARK: - Per-chat (in-house) connections
    /// In-house (builtin) MCP servers run as a separate process copy per chat
    /// that has them selected, so two chats using UtilsMCP get two independent
    /// subprocesses. These dicts are keyed by `chatFilename` then by server
    /// name. The tool list is shared via `toolsCache` (all copies of a given
    /// in-house server expose identical tools), so only the connection itself
    /// is per-chat.
    private var perChatConnections: [String: [String: Connection]] = [:]
    private var perChatLastActivity: [String: [String: Date]] = [:]
    private var perChatIdleTasks: [String: [String: Task<Void, Never>]] = [:]
    /// Seconds an on-demand server stays alive after the last tool activity
    /// before being shut down.
    private let idleTimeout: TimeInterval = 600
    /// Grace period (seconds) given to a stdio subprocess before attempting
    /// the MCP handshake during configuration/wizard connects. If the process
    /// exits within this window (e.g. "command not found"), we fail fast with
    /// the stderr reason instead of hanging on the handshake. See
    /// [`connectAndListTools`](src/MCPManager.swift).
    private let startupGrace: TimeInterval = 1.0
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
        await resetAll()

        let newByName = Dictionary(servers.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
        knownServers = newByName

        var state = MCPConfigurationState(
            isConfiguring: true,
            entries: servers.map {
                MCPConfigurationEntry(name: $0.name, status: .pending, toolCount: nil, errorMessage: nil)
            }
        )
        reportStatus(state)

        await withTaskGroup(of: (String, [MCPTool]?, String?).self) { group in
            for server in servers {
                let name = server.name
                group.addTask { [weak self] in
                    guard let self else { return (name, nil, nil) }
                    do {
                        let tools = try await self.connectAndListTools(server)
                        return (name, tools, nil)
                    } catch {
                        let reason = error.localizedDescription
                        debugLog("MCP", "configure connectAndListTools failed — server=\"\(name)\": \(reason)")
                        return (name, nil, reason)
                    }
                }
            }
            for await (name, tools, errorReason) in group {
                if let tools {
                    toolsCache[name] = tools
                    state.set(name: name, status: .success, toolCount: tools.count, errorMessage: nil)
                } else {
                    await disconnect(name: name)
                    toolsCache.removeValue(forKey: name)
                    state.set(name: name, status: .failed, toolCount: nil,
                              errorMessage: errorReason ?? "failed to list tools")
                }
                reportStatus(state)
            }
        }

        // Stop on-demand stdio servers; they're not needed until a chat request activates them.
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
        var state = MCPConfigurationState(isConfiguring: true, entries: [entry])
        reportStatus(state)

        await disconnect(name: server.name)

        do {
            let tools = try await connectAndListTools(server)
            toolsCache[server.name] = tools
            entry.status = .success
            entry.toolCount = tools.count
            entry.errorMessage = nil
        } catch {
            debugLog("MCP", "reconfigure connectAndListTools failed — server=\"\(server.name)\": \(error.localizedDescription)")
            await disconnect(name: server.name)
            toolsCache.removeValue(forKey: server.name)
            entry.status = .failed
            entry.errorMessage = error.localizedDescription
        }
        state.entries[0] = entry

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
        await disconnectAllInHouse()
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
    ///
    /// This is the "lightweight" connect used for on-demand stdio servers at
    /// chat-request time: it does **not** apply the startup grace period or
    /// race against process death, to avoid adding latency to every chat
    /// request. Configuration-time and wizard connects use
    /// [`connectAndListTools`](src/MCPManager.swift) instead, which performs
    /// full liveness checking and captures stderr.
    func connect(_ server: MCPServer) async {
        if let existing = connections[server.name], existing.server == server { return }
        debugLog("MCP", "connect — server=\"\(server.name)\", transport=\(server.transport)")
        do {
            let conn = try await makeConnection(server)
            connections[server.name] = conn
            debugLog("MCP", "connected — server=\"\(server.name)\", serverName=\"\(conn.initResult.serverInfo.name)\", serverVersion=\"\(conn.initResult.serverInfo.version)\", protocolVersion=\"\(conn.initResult.protocolVersion)\", capabilities=\(capabilitySummary(conn.initResult.capabilities))")
        } catch {
            debugLog("MCP", "connect failed — server=\"\(server.name)\": \(error.localizedDescription)")
            reportError("MCP server \"\(server.name)\" failed to connect: \(error.localizedDescription)")
        }
    }

    /// Spawns the stdio subprocess (or builds the http transport), performs the
    /// MCP `initialize` handshake, and returns a live `Connection` without
    /// storing it. Shared by the shared-connection `connect(_:)` and the
    /// per-chat in-house connect path. On failure the spawned process is
    /// terminated and the error is rethrown.
    private func makeConnection(_ server: MCPServer) async throws -> Connection {
        let transport: any Transport
        var process: Process? = nil
        switch server.transport {
        case .stdio:
            guard let command = server.command, !command.isEmpty else {
                throw MCPManagerError.invalidConfig(server.name, "stdio server missing 'command'")
            }
            let proc = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            proc.standardInput = stdin
            proc.standardOutput = stdout
            proc.standardError = Pipe()
            // Always launch via the user's login shell so their full PATH
            // (homebrew, nvm, etc.) is available. The shell sources its login profile,
            // then `exec` replaces it with the target command.
            proc.executableURL = URL(fileURLWithPath: LoginShell.path())
            proc.arguments = ["-l"]
            try proc.run()
            try stdin.fileHandleForWriting.write(contentsOf: Data(LoginShell.execLine(command: command).utf8))
            process = proc
            debugLog("MCP", "stdio server \"\(server.name)\" started — pid=\(proc.processIdentifier), command=\(command)")
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
            if let process { await awaitProcessExit(process) }
            throw error
        }
        return Connection(server: server, client: client, process: process, initResult: initResult)
    }

    /// Spawns the stdio subprocess (or builds the http transport), performs the
    /// MCP `initialize` handshake, and queries the tool list — all while
    /// watching for early process termination. Used by the configuration flow
    /// (`configure`/`reconfigure`) and the wizard's Test step.
    ///
    /// The MCP SDK's `StdioTransport` does not surface a subprocess that dies
    /// before or during a request: its read loop simply hits EOF and finishes
    /// the message stream without resuming the pending request, so
    /// `client.connect(transport:)` / `listTools` would hang forever on a
    /// misconfigured or crashing stdio server. To avoid that we:
    ///
    /// 1. spawn the process and capture its stderr into a pipe;
    /// 2. give it a short grace period (`startupGrace`) — if the process exits
    ///    within that window (e.g. "command not found"), we fail fast with the
    ///    stderr text as the reason;
    /// 3. otherwise run the handshake + listTools raced against process death,
    ///    so a crash during initialization or the tool query is also caught.
    ///
    /// On success the connection is stored in `connections` and the tool list
    /// is returned. On failure the process is killed and a descriptive error
    /// (carrying stderr) is thrown; `connections` is left without an entry.
    func connectAndListTools(_ server: MCPServer) async throws -> [MCPTool] {
        if let existing = connections[server.name], existing.server == server {
            return try await queryTools(for: server.name)
        }
        debugLog("MCP", "connectAndListTools — server=\"\(server.name)\", transport=\(server.transport)")

        let transport: any Transport
        var process: Process? = nil
        var stderrPipe: Pipe? = nil

        switch server.transport {
        case .stdio:
            guard let command = server.command, !command.isEmpty else {
                throw MCPManagerError.invalidConfig(server.name, "stdio server missing 'command'")
            }
            let proc = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardInput = stdin
            proc.standardOutput = stdout
            proc.standardError = stderr
            // Always launch via the user's login shell so their full PATH
            // (homebrew, nvm, etc.) is available. The shell sources its login profile,
            // then `exec` replaces it with the target command.
            proc.executableURL = URL(fileURLWithPath: LoginShell.path())
            proc.arguments = ["-l"]
            try proc.run()
            try stdin.fileHandleForWriting.write(contentsOf: Data(LoginShell.execLine(command: command).utf8))
            process = proc
            stderrPipe = stderr
            debugLog("MCP", "stdio server \"\(server.name)\" started — pid=\(proc.processIdentifier), command=\(command)")
            let inputFD = try fileDescriptor(for: stdout.fileHandleForReading)
            let outputFD = try fileDescriptor(for: stdin.fileHandleForWriting)
            transport = StdioTransport(input: inputFD, output: outputFD, logger: mcpLogger)
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
        await client.onNotification(ProgressNotification.self) { [weak self] message in
            guard let self else { return }
            let params = message.params
            let text = params.message ?? "progress \(Int(params.progress))\(params.total.map { "/\(Int($0))" } ?? "")"
            await self.forwardProgress(token: params.progressToken, text: text)
        }

        do {
            // For stdio servers, we apply a startup grace period (fail fast if
            // the process exits immediately, e.g. "command not found"), then
            // call client.connect() directly. We can't use a task group to race
            // the handshake against process death because the Client actor's
            // internal Task scheduling (in `send()`) deadlocks when called from
            // a @Sendable task-group child. Instead, we install a termination
            // handler that, if the process dies during the handshake, cancels
            // the enclosing Task — which cancels the pending `sendAndAwait`
            // continuation via the SDK's disconnect path.
            if let proc = process {
                let box = TerminationBox()
                proc.terminationHandler = { p in
                    box.setTerminated(status: p.terminationStatus, reason: p.terminationReason)
                }
                let grace: UInt64 = UInt64(startupGrace * 1_000_000_000)
                try await Task.sleep(nanoseconds: grace)
                if box.hasTerminated() {
                    let err = box.makeError(serverName: server.name, stderrPipe: stderrPipe)
                    debugLog("MCP", "stdio server \"\(server.name)\" died during startup grace — \(err.localizedDescription)")
                    proc.terminationHandler = nil
                    throw err
                }
                let initResult: Initialize.Result
                do {
                    initResult = try await client.connect(transport: transport)
                } catch {
                    proc.terminationHandler = nil
                    if box.hasTerminated() {
                        let err = box.makeError(serverName: server.name, stderrPipe: stderrPipe)
                        debugLog("MCP", "stdio server \"\(server.name)\" died during handshake — \(err.localizedDescription)")
                        await client.disconnect()
                        proc.terminate()
                        await awaitProcessExit(proc)
                        throw err
                    }
                    throw error
                }
                proc.terminationHandler = nil
                debugLog("MCP", "connected — server=\"\(server.name)\", serverName=\"\(initResult.serverInfo.name)\", serverVersion=\"\(initResult.serverInfo.version)\", protocolVersion=\"\(initResult.protocolVersion)\", capabilities=\(capabilitySummary(initResult.capabilities))")
                connections[server.name] = Connection(server: server, client: client, process: proc, initResult: initResult)
                return try await queryTools(for: server.name)
            } else {
                let initResult = try await client.connect(transport: transport)
                debugLog("MCP", "connected — server=\"\(server.name)\", serverName=\"\(initResult.serverInfo.name)\", serverVersion=\"\(initResult.serverInfo.version)\", protocolVersion=\"\(initResult.protocolVersion)\", capabilities=\(capabilitySummary(initResult.capabilities))")
                connections[server.name] = Connection(server: server, client: client, process: nil, initResult: initResult)
                return try await queryTools(for: server.name)
            }
        } catch {
            debugLog("MCP", "connectAndListTools failed — server=\"\(server.name)\": \(error.localizedDescription)")
            if connections[server.name] != nil {
                await disconnect(name: server.name)
            } else {
                await client.disconnect()
                process?.terminate()
                if let process { await awaitProcessExit(process) }
            }
            throw error
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
        idleTasks.removeValue(forKey: name)?.cancel()
        lastActivity.removeValue(forKey: name)
        guard let conn = connections.removeValue(forKey: name) else { return }
        debugLog("MCP", "disconnect — server=\"\(name)\"")
        await conn.client.disconnect()
        if let process = conn.process {
            process.terminate()
            await awaitProcessExit(process)
            debugLog("MCP", "stdio server \"\(name)\" terminated — pid=\(process.processIdentifier), exitStatus=\(process.terminationStatus), reason=\(process.terminationReason.rawValue)")
        }
    }

    /// Disconnects all servers (e.g. on app shutdown or full reset).
    func disconnectAll() async {
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

    /// Returns the known config for `server` (as last loaded from disk), or
    /// nil if the server isn't configured. Used by `ChatEngine.gatherTools` to
    /// read the per-server tool allowlist (`tools`) so only allowed tools are
    /// advertised to the LLM.
    func serverConfig(for server: String) -> MCPServer? {
        knownServers[server]
    }

    /// Connects to `server` and queries its tool list, returning the tools
    /// and the server's reported name (from the MCP `initialize` response's
    /// `serverInfo.name`). Throws on any failure (connect or listTools). Used
    /// by the MCP wizard's connection test step. The caller is responsible for
    /// disconnecting the transient connection afterwards (via
    /// `disconnect(name:)`).
    ///
    /// Uses [`connectAndListTools`](src/MCPManager.swift) so a misconfigured or
    /// crashing stdio server is reported with its stderr reason (exit code +
    /// error text) instead of hanging the wizard's Test step forever.
    func testConnection(_ server: MCPServer) async throws -> (tools: [MCPTool], serverName: String?) {
        await disconnect(name: server.name)
        let tools = try await connectAndListTools(server)
        let reportedName = connections[server.name]?.initResult.serverInfo.name
        return (tools, reportedName)
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
        idleTasks.removeValue(forKey: name)?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.idleTimeout ?? 600) * 1_000_000_000))
            guard let self else { return }
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
        if let server = knownServers[name], server.runPolicy == .onDemand {
            debugLog("MCP", "idle timeout — shutting down on-demand server \"\(name)\" after \(Int(elapsed))s of inactivity")
            await disconnect(name: name)
            lastActivity.removeValue(forKey: name)
            idleTasks.removeValue(forKey: name)
        }
    }

    // MARK: - Per-chat in-house server lifecycle

    /// Whether `name` refers to an in-house (builtin) MCP server. In-house
    /// servers run as per-chat copies rather than the shared connection pool.
    func isBuiltinServer(_ name: String) -> Bool {
        knownServers[name]?.isBuiltin == true
    }

    /// Ensures a per-chat copy of each selected in-house server is running for
    /// `chatFilename` before a chat request. If a copy is already running for
    /// that chat (with a matching launch command), its idle timer is refreshed;
    /// otherwise a fresh subprocess is spawned. Servers without a cached tool
    /// list (failed/never configured) are skipped. Called by
    /// `ChatEngine.gatherTools`.
    ///
    /// `workingDirectory` (the chat's effective working directory, with `~`
    /// expanded) is forwarded as `--workdir` to servers that understand it, so
    /// relative paths resolve against it. When a server entry has
    /// `directoryIsolation` set, `--confine` is also appended (chroot-like
    /// confinement) for the servers that support it (Filesystem, Code). If the
    /// desired launch command differs from the already-running copy (e.g. the
    /// user changed the working directory), the old copy is torn down and a
    /// fresh one is spawned with the new args.
    func ensureInHouseRunning(
        chatFilename: String,
        servers: [(name: String, directoryIsolation: Bool)],
        workingDirectory: String?
    ) async {
        for entry in servers {
            let name = entry.name
            guard let server = knownServers[name], server.isBuiltin else { continue }
            let launchServer = makeInHouseCommand(
                server: server,
                workingDirectory: workingDirectory,
                directoryIsolation: entry.directoryIsolation
            )
            if let existing = perChatConnections[chatFilename]?[name] {
                if existing.server.command == launchServer.command {
                    touchInHouseActivity(chatFilename: chatFilename, server: name)
                    continue
                }
                // The workdir / isolation flags changed since the copy was
                // started — tear it down so a fresh one spawns with the new args.
                debugLog("MCP", "ensureInHouseRunning — relaunching copy (args changed) — server=\"\(name)\", chat=\(chatFilename)")
                await disconnectInHouse(chatFilename: chatFilename, server: name)
            }
            guard toolsCache[name] != nil else { continue }
            debugLog("MCP", "ensureInHouseRunning — starting per-chat copy — server=\"\(name)\", chat=\(chatFilename), command=\(launchServer.command ?? "")")
            do {
                let conn = try await makeConnection(launchServer)
                if perChatConnections[chatFilename] == nil { perChatConnections[chatFilename] = [:] }
                perChatConnections[chatFilename]?[name] = conn
                debugLog("MCP", "in-house copy connected — server=\"\(name)\", chat=\(chatFilename)")
            } catch {
                debugLog("MCP", "in-house copy connect failed — server=\"\(name)\", chat=\(chatFilename): \(error.localizedDescription)")
                reportError("MCP server \"\(name)\" failed to start for chat: \(error.localizedDescription)")
            }
            touchInHouseActivity(chatFilename: chatFilename, server: name)
        }
    }

    /// Builtin servers that accept `--workdir <path>` (setting the working
    /// directory for relative-path resolution). Utils ignores it.
    private static let workdirCapableServers: Set<String> = ["Filesystem", "Code", "Shell"]
    /// Builtin servers that also accept `--confine` (chroot-like confinement).
    /// Shell deliberately does no confinement.
    private static let confineCapableServers: Set<String> = ["Filesystem", "Code"]

    /// Returns a copy of `server` whose `command` has `--workdir` (and
    /// optionally `--confine`) appended according to the role/chat settings.
    /// Servers that don't understand these flags, or when no working directory
    /// is set, are returned unchanged. The working directory is `~`-expanded
    /// here (rather than relying on shell expansion, which is suppressed by
    /// quoting) and double-quoted so paths with spaces survive `exec`.
    private func makeInHouseCommand(
        server: MCPServer,
        workingDirectory: String?,
        directoryIsolation: Bool
    ) -> MCPServer {
        var s = server
        guard let base = s.command, !base.isEmpty,
              let wd = workingDirectory, !wd.isEmpty,
              Self.workdirCapableServers.contains(server.name) else { return s }
        let expanded = (wd as NSString).standardizingPath
        var cmd = "\(base) --workdir \"\(expanded)\""
        if directoryIsolation, Self.confineCapableServers.contains(server.name) {
            cmd += " --confine"
        }
        s.command = cmd
        return s
    }

    /// Records activity and (re)schedules the per-chat idle-shutdown task.
    private func touchInHouseActivity(chatFilename: String, server: String) {
        if perChatLastActivity[chatFilename] == nil { perChatLastActivity[chatFilename] = [:] }
        perChatLastActivity[chatFilename]?[server] = Date()
        if perChatIdleTasks[chatFilename] == nil { perChatIdleTasks[chatFilename] = [:] }
        perChatIdleTasks[chatFilename]?[server]?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.idleTimeout ?? 600) * 1_000_000_000))
            guard let self else { return }
            await self.handleInHouseIdleTimeout(chatFilename: chatFilename, server: server)
        }
        perChatIdleTasks[chatFilename]?[server] = task
    }

    /// Actor-isolated per-chat idle-timeout handler. Shuts the per-chat copy
    /// down if no activity has occurred since the timer was scheduled.
    private func handleInHouseIdleTimeout(chatFilename: String, server: String) async {
        guard let last = perChatLastActivity[chatFilename]?[server] else { return }
        let elapsed = Date().timeIntervalSince(last)
        guard elapsed >= idleTimeout else { return }
        debugLog("MCP", "idle timeout — shutting down in-house copy — server=\"\(server)\", chat=\(chatFilename), after \(Int(elapsed))s")
        await disconnectInHouse(chatFilename: chatFilename, server: server)
    }

    /// Tears down a single per-chat in-house connection.
    func disconnectInHouse(chatFilename: String, server: String) async {
        perChatIdleTasks[chatFilename]?.removeValue(forKey: server)?.cancel()
        perChatLastActivity[chatFilename]?.removeValue(forKey: server)
        guard let conn = perChatConnections[chatFilename]?.removeValue(forKey: server) else { return }
        debugLog("MCP", "disconnectInHouse — server=\"\(server)\", chat=\(chatFilename)")
        await conn.client.disconnect()
        if let process = conn.process {
            process.terminate()
            await awaitProcessExit(process)
        }
    }

    /// Tears down all per-chat in-house connections for one chat (used on chat
    /// deletion) or for all chats when `chatFilename` is nil (reset/shutdown).
    func disconnectAllInHouse(chatFilename: String? = nil) async {
        let chats: [String]
        if let chatFilename {
            chats = [chatFilename]
        } else {
            chats = Array(perChatConnections.keys)
        }
        for chat in chats {
            let names = perChatConnections[chat].map { Array($0.keys) } ?? []
            for name in names {
                await disconnectInHouse(chatFilename: chat, server: name)
            }
            perChatConnections.removeValue(forKey: chat)
            perChatLastActivity.removeValue(forKey: chat)
            if let tasks = perChatIdleTasks.removeValue(forKey: chat) {
                for t in tasks.values { t.cancel() }
            }
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
        return await performCall(conn: conn, server: server, name: name, arguments: arguments, callID: callID, chatFilename: chatFilename, onFailure: { [weak self] in
            await self?.disconnect(name: server)
        })
    }

    /// Calls a tool on a per-chat in-house copy. The copy is started lazily if
    /// it isn't currently running for `chatFilename`. `workingDirectory` and
    /// `directoryIsolation` are forwarded to the launch command (matching what
    /// `ensureInHouseRunning` would use) so a lazily-started copy is confined
    /// the same way as one started up front. On failure the per-chat copy is
    /// torn down so the next call starts fresh.
    func callInHouseTool(chatFilename: String, server: String, name: String, arguments: String, callID: String, workingDirectory: String?, directoryIsolation: Bool) async -> ToolResult {
        debugLog("MCP", "callInHouseTool — server=\"\(server)\", tool=\"\(name)\", callID=\(callID), chat=\(chatFilename)")
        await ensureInHouseRunning(
            chatFilename: chatFilename,
            servers: [(server, directoryIsolation)],
            workingDirectory: workingDirectory
        )
        guard let conn = perChatConnections[chatFilename]?[server] else {
            debugLog("MCP", "callInHouseTool — server \"\(server)\" unreachable for chat=\(chatFilename), returning error in RESULT")
            return ToolResult(callID: callID, content: "MCP server \"\(server)\" is currently unreachable. Please retry.", isError: false)
        }
        touchInHouseActivity(chatFilename: chatFilename, server: server)
        return await performCall(conn: conn, server: server, name: name, arguments: arguments, callID: callID, chatFilename: chatFilename, onFailure: { [weak self] in
            await self?.disconnectInHouse(chatFilename: chatFilename, server: server)
        })
    }

    /// Shared tool-call core used by both the shared-connection `callTool` and
    /// the per-chat `callInHouseTool`. Parses arguments, attaches a progress
    /// token, invokes the client, and maps content. `onFailure` is invoked
    /// when the call throws (so each path tears down its own connection).
    private func performCall(conn: Connection, server: String, name: String, arguments: String, callID: String, chatFilename: String, onFailure: @escaping () async -> Void) async -> ToolResult {
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
            debugLog("MCP", "callTool result — server=\"\(server)\", tool=\"\(name)\", isError=\(isError ?? false), contentSize=\(text.count)")
            return ToolResult(callID: callID, content: text, isError: isError ?? false)
        } catch is CancellationError {
            debugLog("MCP", "callTool cancelled — server=\"\(server)\", tool=\"\(name)\", callID=\(callID)")
            return ToolResult(callID: callID, content: "Tool call was cancelled.", isError: true)
        } catch {
            debugLog("MCP", "callTool failed — server=\"\(server)\", tool=\"\(name)\", callID=\(callID), error=\(error), type=\(String(describing: error))")
            await onFailure()
            return ToolResult(callID: callID, content: "MCP server \"\(server)\" error during tool call: \(error.localizedDescription). Please retry.", isError: false)
        }
    }

    // MARK: - Helpers

    /// Whether a server is currently connected.
    func isConnected(_ server: String) -> Bool {
        connections[server] != nil
    }

    private func fileDescriptor(for handle: FileHandle) throws -> FileDescriptor {
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
    /// The stdio subprocess exited before the MCP handshake/listTools completed.
    /// Carries the server name, exit status, and captured stderr so a crashing
    /// server is reported with its actual failure reason.
    case stdioExitedEarly(String, Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let name, let reason):
            return "MCP server \"\(name)\" has an invalid configuration: \(reason)"
        case .unavailable(let name):
            return "MCP server \"\(name)\" is not available."
        case .toolListFailed(let name, let reason):
            return "Failed to list tools from MCP server \"\(name)\": \(reason)"
        case .stdioExitedEarly(let name, let status, let stderr):
            let stderrTrimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if stderrTrimmed.isEmpty {
                return "MCP stdio server \"\(name)\" exited before initializing (exit code \(status))."
            }
            return "MCP stdio server \"\(name)\" exited before initializing (exit code \(status)): \(stderrTrimmed)"
        }
    }
}

/// A lock-protected box that records the exit status of a stdio subprocess,
/// used by `connectAndListTools` to detect process death during the startup
/// grace period or MCP handshake.
private final class TerminationBox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "iCanHazAI.mcp.terminationBox")
    private var _terminated: (status: Int32, reason: Process.TerminationReason)?

    func setTerminated(status: Int32, reason: Process.TerminationReason) {
        queue.sync { _terminated = (status, reason) }
    }

    func hasTerminated() -> Bool {
        queue.sync { _terminated != nil }
    }

    /// Builds a descriptive error from the recorded termination (exit code +
    /// drained stderr). Falls back to an unknown-status early exit if the
    /// termination wasn't recorded.
    func makeError(serverName: String, stderrPipe: Pipe?) -> Error {
        let terminated = queue.sync { _terminated }
        let status = terminated?.status ?? -1
        let stderr = Self.drainStderr(stderrPipe)
        return MCPManagerError.stdioExitedEarly(serverName, Int(status), stderr)
    }

    /// Reads whatever the subprocess wrote to stderr (best-effort, non-blocking)
    /// and returns it as a UTF-8 string, to surface the server's own error text
    /// in the failure reason.
    static func drainStderr(_ pipe: Pipe?) -> String {
        guard let pipe else { return "" }
        let handle = pipe.fileHandleForReading
        let data = handle.availableData
        if data.isEmpty { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
