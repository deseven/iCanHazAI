// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - MCP server model

/// Transport type for an MCP server connection.
enum MCPTransport: String, Codable, Sendable {
    case stdio
    case http
}

/// A configured MCP server. One server per file in `~/iCanHazAI/mcp/<name>.toml`.
/// `id` is the filesystem-safe name (unique).
struct MCPServer: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let transport: MCPTransport
    /// stdio: the executable command (e.g. "npx").
    var command: String?
    /// stdio: arguments passed to the command.
    var args: [String]?
    /// http: the streamable HTTP endpoint URL.
    var endpoint: String?
    /// http: optional bearer token.
    var token: String?
    /// Whether this server is enabled for new chats by default.
    var defaultForNewChats: Bool
}

/// Raw structure decoded from an MCP server TOML file.
/// Mirrors `ConnectionConfig` with snake_case keys.
struct MCPConfig: Codable {
    var transport: String
    var command: String?
    var args: [String]?
    var endpoint: String?
    var token: String?
    var defaultForNewChats: Bool?

    enum CodingKeys: String, CodingKey {
        case transport
        case command
        case args
        case endpoint
        case token
        case defaultForNewChats = "default_for_new_chats"
    }
}

extension MCPServer {
    /// Builds an `MCPServer` from a decoded `MCPConfig` and a name (from the filename).
    init(name: String, config: MCPConfig) {
        let transport = MCPTransport(rawValue: config.transport) ?? .stdio
        self.init(
            name: name,
            transport: transport,
            command: config.command,
            args: config.args,
            endpoint: config.endpoint,
            token: config.token,
            defaultForNewChats: config.defaultForNewChats ?? false
        )
    }

    /// Encodes this server back into a `MCPConfig` for TOML serialization.
    var config: MCPConfig {
        MCPConfig(
            transport: transport.rawValue,
            command: command,
            args: args,
            endpoint: endpoint,
            token: token,
            defaultForNewChats: defaultForNewChats
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
/// The `namespacedName` (`mcp__{server}__{tool}`) is what the model sees and
/// calls back; it guarantees uniqueness across servers. `ToolDefinition.parse`
/// recovers the server + tool name from a call.
struct ToolDefinition: Sendable, Equatable {
    let serverName: String
    let name: String
    let description: String?
    /// Raw JSON string of the tool's input schema (a JSON Schema object).
    let inputSchema: String

    /// The namespaced name sent to the model: `mcp__{server}__{tool}`.
    var namespacedName: String { "mcp__\(serverName)__\(name)" }

    /// Parses a namespaced tool name back into (server, tool).
    /// Returns nil if the name doesn't follow the `mcp__{server}__{tool}` format.
    static func parse(_ namespacedName: String) -> (server: String, tool: String)? {
        guard namespacedName.hasPrefix("mcp__") else { return nil }
        let rest = String(namespacedName.dropFirst("mcp__".count))
        // Split on the first "__" to separate server from tool name.
        guard let range = rest.range(of: "__") else { return nil }
        let server = String(rest[rest.startIndex..<range.lowerBound])
        let tool = String(rest[range.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }
}
