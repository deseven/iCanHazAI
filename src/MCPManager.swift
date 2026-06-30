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
/// `MCP.Client` instances alive, reconnects on config change, and exposes
/// `listTools()`/`callTool()`. Lives alongside `ChatEngine`.
///
/// All public methods catch and rethrow typed errors; connection failures are
/// surfaced via `errorHandler` so the UI can show them. Never crashes on a
/// misbehaving server.
actor MCPManager {

    static let shared = MCPManager()

    /// A connected MCP server: its config, the SDK client, and (for stdio) the
    /// spawned subprocess so we can terminate it on disconnect.
    private final class Connection: @unchecked Sendable {
        let server: MCPServer
        let client: Client
        /// For stdio servers: the spawned process. Nil for http.
        let process: Process?

        init(server: MCPServer, client: Client, process: Process? = nil) {
            self.server = server
            self.client = client
            self.process = process
        }
    }

    private var connections: [String: Connection] = [:]
    /// Names of servers that failed to connect or died. Their tools are
    /// excluded from requests but the request still proceeds with others.
    private var unavailable: Set<String> = []
    /// The full set of servers known from the last `reload`. Used to look up
    /// run policy and config when an on-demand server needs to be started.
    private var knownServers: [String: MCPServer] = [:]
    /// Wall-clock time of the last tool activity (listTools/callTool) for an
    /// on-demand server. Used to compute the 600s idle timeout.
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

    private func reportError(_ message: String) {
        errorHandler?(message)
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

    // MARK: - Reload / diff

    /// Returns true if the server should be kept alive continuously (always-on
    /// or http/nil policy). Only stdio on-demand servers are started lazily.
    private func isAlwaysOn(_ server: MCPServer) -> Bool {
        server.runPolicy != .onDemand
    }

    /// Reconciles the active connection set against `servers`: disconnects
    /// removed servers (terminating any spawned stdio subprocesses), connects
    /// added/changed ones according to their run policy. Idempotent.
    ///
    /// Run policy handling:
    /// - `alwaysOn` servers are (re)connected immediately here.
    /// - `onDemand` servers are NOT auto-started; they are started lazily by
    ///   `ensureConnected` when a chat actually needs them. If an on-demand
    ///   server's config changed (including a run-policy change), it is
    ///   disconnected here and will be restarted on the next request. If the
    ///   config changed during the idle timeout period, the server is simply
    ///   shut down until the next request.
    func reload(_ servers: [MCPServer]) async {
        let newByName = Dictionary(servers.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
        let newNames = Set(newByName.keys)
        knownServers = newByName

        // Disconnect removed servers (their config file was deleted or renamed).
        // This terminates any spawned stdio subprocess so we don't leak orphans.
        let currentNames = Set(connections.keys)
        for name in currentNames where !newNames.contains(name) {
            await disconnect(name: name)
        }
        // Cancel any pending idle-shutdown tasks for servers that no longer
        // exist on disk, and drop their activity bookkeeping.
        for name in idleTasks.keys where !newNames.contains(name) {
            idleTasks.removeValue(forKey: name)?.cancel()
            lastActivity.removeValue(forKey: name)
        }
        // Clean up stale `unavailable` entries for servers that no longer exist
        // on disk. These have no process to terminate, but leaving them would
        // prevent a same-named server from being retried after a re-create.
        for name in unavailable where !newNames.contains(name) {
            unavailable.remove(name)
        }
        // Reconcile each known server.
        for server in servers {
            if let existing = connections[server.name] {
                if existing.server != server {
                    // Config changed (possibly including the run policy). Tear
                    // down the old connection. Always-on servers are restarted
                    // immediately; on-demand servers are left disconnected and
                    // will be started on the next request that needs them.
                    await disconnect(name: server.name)
                    if isAlwaysOn(server) {
                        await connect(server)
                    }
                }
            } else {
                // Not currently connected.
                if isAlwaysOn(server) {
                    // (Re)connect always-on servers not yet connected or
                    // previously failed.
                    if unavailable.contains(server.name) || !connections.keys.contains(server.name) {
                        await connect(server)
                    }
                }
                // on-demand servers are started lazily via ensureConnected.
            }
        }
    }

    /// Ensures an on-demand server is connected before a tool operation. If
    /// the server is already connected, this just refreshes its idle timer.
    /// If not, it looks up the current config from `knownServers` and starts
    /// it. Called by `listTools`/`callTool` for on-demand servers. No-op for
    /// always-on servers (they are kept alive by `reload`).
    private func ensureConnected(_ name: String) async {
        guard let server = knownServers[name] else { return }
        if connections[name] != nil {
            touchActivity(name)
            return
        }
        // Start (or retry) the on-demand server now.
        if unavailable.contains(name) {
            unavailable.remove(name)
        }
        await connect(server)
        touchActivity(name)
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
            await disconnect(name: name)
            lastActivity.removeValue(forKey: name)
            idleTasks.removeValue(forKey: name)
        }
    }

    // MARK: - Connect / disconnect

    /// Builds the transport and initializes the MCP client for `server`.
    /// Failures are recorded in `unavailable` and reported via `errorHandler`.
    func connect(_ server: MCPServer) async {
        // Don't retry if already connected with the same config.
        if let existing = connections[server.name], existing.server == server { return }

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
            do {
                _ = try await client.connect(transport: transport)
            } catch {
                process?.terminate()
                throw error
            }
            connections[server.name] = Connection(server: server, client: client, process: process)
            unavailable.remove(server.name)
        } catch {
            unavailable.insert(server.name)
            reportError("MCP server \"\(server.name)\" failed to connect: \(error.localizedDescription)")
        }
    }

    /// Disconnects and tears down the client for `name`. Closes the MCP
    /// client (which closes the transport pipes) and terminates any spawned
    /// stdio subprocess so we don't leak orphaned processes.
    func disconnect(name: String) async {
        // Cancel any pending idle-shutdown task for this server.
        idleTasks.removeValue(forKey: name)?.cancel()
        lastActivity.removeValue(forKey: name)
        guard let conn = connections.removeValue(forKey: name) else { return }
        await conn.client.disconnect()
        if let process = conn.process {
            process.terminate()
            // Give the subprocess a moment to exit, then reap it so we don't
            // leave a zombie. `waitUntilExit` blocks the actor briefly, but
            // termination is infrequent and the delay is typically <100ms.
            process.waitUntilExit()
        }
        unavailable.remove(name)
    }

    /// Disconnects all servers (e.g. on app shutdown).
    func disconnectAll() async {
        // Cancel all pending idle-shutdown tasks.
        for task in idleTasks.values { task.cancel() }
        idleTasks.removeAll()
        lastActivity.removeAll()
        let names = Array(connections.keys)
        for name in names {
            await disconnect(name: name)
        }
    }

    // MARK: - Tools

    /// Lists the tools exposed by `server`. Throws if the server is not
    /// connected or the call fails. For on-demand servers this first ensures
    /// the server is started (and refreshes its idle timer).
    func listTools(for server: String) async throws -> [MCPTool] {
        // Start on-demand servers lazily before listing tools.
        if let known = knownServers[server], known.runPolicy == .onDemand {
            await ensureConnected(server)
        }
        guard let conn = connections[server] else {
            throw MCPManagerError.unavailable(server)
        }
        do {
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
            return tools
        } catch {
            unavailable.insert(server)
            throw MCPManagerError.toolListFailed(server, error.localizedDescription)
        }
    }

    /// Calls a tool on `server` with JSON-encoded `arguments` and maps the
    /// result into our `ToolResult`. `callID` is the model-assigned tool call
    /// id, propagated onto the result so the provider can correlate them.
    /// `chatFilename` identifies the chat that owns this call so progress
    /// notifications can be routed to that chat's live `tool`-role message
    /// directly. Non-text content is summarized.
    func callTool(server: String, name: String, arguments: String, callID: String, chatFilename: String) async -> ToolResult {
        // Start on-demand servers lazily before calling tools.
        if let known = knownServers[server], known.runPolicy == .onDemand {
            await ensureConnected(server)
        }
        guard let conn = connections[server] else {
            return ToolResult(callID: callID, content: "MCP server \"\(server)\" is not available.", isError: true)
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
            return ToolResult(callID: callID, content: text, isError: isError ?? false)
        } catch is CancellationError {
            return ToolResult(callID: callID, content: "Tool call was cancelled.", isError: true)
        } catch {
            unavailable.insert(server)
            return ToolResult(callID: callID, content: "Tool call failed: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Helpers

    /// Whether a server is currently connected and available.
    func isAvailable(_ server: String) -> Bool {
        connections[server] != nil && !unavailable.contains(server)
    }

    /// Extracts a `FileDescriptor` from a `FileHandle`. The SDK's `StdioTransport`
    /// uses `SystemPackage.FileDescriptor`, which on Darwin is backed by the
    /// raw file descriptor integer.
    private func fileDescriptor(for handle: FileHandle) throws -> FileDescriptor {
        // FileHandle.fileDescriptor is the raw Int32 fd.
        return FileDescriptor(rawValue: handle.fileDescriptor)
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
