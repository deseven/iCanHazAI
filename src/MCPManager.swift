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
    /// Optional sink for human-readable error messages (wired to ChatEngine).
    private var errorHandler: ((String) -> Void)?

    private init() {}

    /// Sets the error sink. Called once by `ChatEngine` at startup.
    func setErrorHandler(_ handler: @escaping (String) -> Void) {
        self.errorHandler = handler
    }

    private func reportError(_ message: String) {
        errorHandler?(message)
    }

    // MARK: - Reload / diff

    /// Reconciles the active connection set against `servers`: disconnects
    /// removed servers (terminating any spawned stdio subprocesses), connects
    /// added/changed ones. Idempotent.
    func reload(_ servers: [MCPServer]) async {
        let newByName = Dictionary(servers.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
        let newNames = Set(newByName.keys)

        // Disconnect removed servers (their config file was deleted or renamed).
        // This terminates any spawned stdio subprocess so we don't leak orphans.
        let currentNames = Set(connections.keys)
        for name in currentNames where !newNames.contains(name) {
            await disconnect(name: name)
        }
        // Clean up stale `unavailable` entries for servers that no longer exist
        // on disk. These have no process to terminate, but leaving them would
        // prevent a same-named server from being retried after a re-create.
        for name in unavailable where !newNames.contains(name) {
            unavailable.remove(name)
        }
        // Reconnect changed servers (config differs).
        for server in servers {
            if let existing = connections[server.name] {
                if existing.server != server {
                    await disconnect(name: server.name)
                    await connect(server)
                }
            } else if unavailable.contains(server.name) || !connections.keys.contains(server.name) {
                // (Re)connect servers not yet connected or previously failed.
                await connect(server)
            }
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
        let names = Array(connections.keys)
        for name in names {
            await disconnect(name: name)
        }
    }

    // MARK: - Tools

    /// Lists the tools exposed by `server`. Throws if the server is not
    /// connected or the call fails.
    func listTools(for server: String) async throws -> [MCPTool] {
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
    /// result into our `ToolResult`. Non-text content is summarized.
    func callTool(server: String, name: String, arguments: String) async -> ToolResult {
        guard let conn = connections[server] else {
            return ToolResult(callID: UUID().uuidString, content: "MCP server \"\(server)\" is not available.", isError: true)
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
                return ToolResult(callID: UUID().uuidString, content: "Failed to parse tool arguments JSON: \(error.localizedDescription)", isError: true)
            }
        } else {
            argsValue = nil
        }

        do {
            let (content, isError) = try await conn.client.callTool(name: name, arguments: argsValue)
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
            return ToolResult(callID: UUID().uuidString, content: text, isError: isError ?? false)
        } catch is CancellationError {
            return ToolResult(callID: UUID().uuidString, content: "Tool call was cancelled.", isError: true)
        } catch {
            unavailable.insert(server)
            return ToolResult(callID: UUID().uuidString, content: "Tool call failed: \(error.localizedDescription)", isError: true)
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
