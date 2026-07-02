// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - MCP server model

/// Transport type for an MCP server connection.
enum MCPTransport: String, Codable, Sendable {
    case stdio
    case http
}

/// Controls when a stdio MCP server is started and kept alive.
///
/// - `alwaysOn`: the server is started on app launch (or when its config is
///   created), reloaded when its config changes on disk, and stopped when its
///   config is deleted.
/// - `onDemand`: the server is started only when a chat that has it active
///   sends a request, and is shut down 600 seconds after the last use. The
///   same reload-on-config-change rules apply; if the config changes during
///   the idle timeout the server is simply stopped until the next request.
enum MCPRunPolicy: String, Codable, Sendable {
    case alwaysOn
    case onDemand
}

/// A configured MCP server. One server per file in `~/iCanHazAI/mcp/<name>.toml`.
/// `id` is the filesystem-safe name (unique).
struct MCPServer: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let transport: MCPTransport
    /// When the server process is started/stopped. Only meaningful for stdio
    /// servers (where we own the subprocess); nil for http servers. Defaults
    /// to `alwaysOn` for backwards compatibility with stdio configs that
    /// predate the field.
    var runPolicy: MCPRunPolicy?
    /// stdio: the executable command (e.g. "npx").
    var command: String?
    /// stdio: arguments passed to the command.
    var args: [String]?
    /// http: the streamable HTTP endpoint URL.
    var endpoint: String?
    /// http: optional bearer token.
    var token: String?
}

/// Raw structure decoded from an MCP server TOML file.
/// Mirrors `ConnectionConfig` with snake_case keys.
struct MCPConfig: Codable {
    var transport: String
    var runPolicy: String?
    var command: String?
    var args: [String]?
    var endpoint: String?
    var token: String?

    enum CodingKeys: String, CodingKey {
        case transport
        case runPolicy
        case command
        case args
        case endpoint
        case token
    }
}

extension MCPServer {
    /// Builds an `MCPServer` from a decoded `MCPConfig` and a name (from the filename).
    init(name: String, config: MCPConfig) {
        let transport = MCPTransport(rawValue: config.transport) ?? .stdio
        // run_policy only applies to stdio servers. For http it is ignored.
        let runPolicy: MCPRunPolicy?
        if transport == .stdio {
            runPolicy = MCPRunPolicy(rawValue: config.runPolicy ?? "") ?? .alwaysOn
        } else {
            runPolicy = nil
        }
        self.init(
            name: name,
            transport: transport,
            runPolicy: runPolicy,
            command: config.command,
            args: config.args,
            endpoint: config.endpoint,
            token: config.token
        )
    }

    /// Encodes this server back into a `MCPConfig` for TOML serialization.
    /// `runPolicy` is only written for stdio servers.
    var config: MCPConfig {
        MCPConfig(
            transport: transport.rawValue,
            runPolicy: transport == .stdio ? runPolicy?.rawValue : nil,
            command: command,
            args: args,
            endpoint: endpoint,
            token: token
        )
    }
}

// MARK: - Tool call / result model

/// A single tool call issued by the assistant. `arguments` is the raw JSON
/// string as returned by the model (portable across providers).
struct ToolCall: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
}

/// The result of executing a tool call. Carried on a `tool`-role message.
struct ToolResult: Codable, Identifiable, Equatable, Sendable {
    var id: String { callID }
    var callID: String
    var content: String
    var isError: Bool
    /// True while the tool is still running and `content` is being streamed in
    /// via MCP progress notifications. The renderer shows a spinner and the
    /// partial content; when the call completes this flips to false.
    var isStreaming: Bool = false
}

// MARK: - Tool definition (provider-agnostic)

/// A tool exposed by an MCP server, in a provider-agnostic shape ready to be
/// mapped onto OpenAI/Anthropic tool definitions by `ChatService`.
///
/// The `namespacedName` (`{server}_{tool}`) is what the model sees and
/// calls back; it guarantees uniqueness across servers. `ToolDefinition.parse`
/// recovers the server + tool name from a call.
struct ToolDefinition: Sendable, Equatable {
    let serverName: String
    let name: String
    let description: String?
    /// Raw JSON string of the tool's input schema (a JSON Schema object).
    let inputSchema: String

    /// The namespaced name sent to the model: `{server}_{tool}`.
    var namespacedName: String { "\(serverName)_\(name)" }

    /// Parses a namespaced tool name back into (server, tool).
    /// Returns nil if the name doesn't follow the `{server}_{tool}` format.
    static func parse(_ namespacedName: String) -> (server: String, tool: String)? {
        // Split on the first "_" to separate server from tool name.
        guard let range = namespacedName.range(of: "_") else { return nil }
        let server = String(namespacedName[namespacedName.startIndex..<range.lowerBound])
        let tool = String(namespacedName[range.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }
}
