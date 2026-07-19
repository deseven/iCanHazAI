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
    case alwaysOn = "always_on"
    case onDemand = "on_demand"
}

/// A configured MCP server. One server per file in `~/iCanHazAI/mcp/<name>.toml`.
/// `id` is the filesystem-safe name (unique).
struct MCPServer: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    /// Short, lowercase-alphanumeric identifier used to namespace this server's
    /// tools for the LLM (e.g. a tool `search` under prefix `gdocs` becomes
    /// `gdocs_search`). Must match `^[a-z0-9]+$` and be unique across servers
    /// when non-empty. Optional: when empty (the default), tools are exposed
    /// to the model under their own names without a prefix. Provider APIs
    /// reject tool names containing spaces or punctuation (the server `name`
    /// is filesystem-derived and may contain such characters), which is why a
    /// prefix is offered — but it is no longer required.
    let prefix: String
    let transport: MCPTransport
    /// When the server process is started/stopped. Only meaningful for stdio
    /// servers (where we own the subprocess); nil for http servers. Defaults
    /// to `alwaysOn` for backwards compatibility with stdio configs that
    /// predate the field.
    var runPolicy: MCPRunPolicy?
    /// stdio: the full command line to launch the server, including arguments
    /// (e.g. "node /path/to/index.js"). It is sent to the user's login shell
    /// via stdin as `exec <command>`, so the shell sources the login profile
    /// (making the user's PATH available) and then replaces itself with the
    /// server process.
    var command: String?
    /// http: the streamable HTTP endpoint URL.
    var endpoint: String?
    /// http: optional bearer token.
    var token: String?
    /// Allowlist of tool names exposed by this server. When non-empty, only
    /// tools whose `name` matches an entry here are advertised to the LLM and
    /// callable. An empty array (or nil) means all tools are allowed.
    var tools: [String]?

    init(name: String, prefix: String, transport: MCPTransport, runPolicy: MCPRunPolicy?, command: String?, endpoint: String?, token: String?, tools: [String]?) {
        self.name = name
        self.prefix = prefix
        self.transport = transport
        self.runPolicy = runPolicy
        self.command = command
        self.endpoint = endpoint
        self.token = token
        self.tools = tools
    }
}

/// Raw structure decoded from an MCP server TOML file.
/// Mirrors `ConnectionConfig` with snake_case keys.
struct MCPConfig: Codable {
    var transport: String
    /// Optional tool namespace. Omitted entirely (rather than written as an
    /// empty string) when the server has no prefix, so a hand-written config
    /// without a `prefix` key decodes cleanly. Defaults to "" on the server.
    var prefix: String?
    var runPolicy: String?
    var command: String?
    var endpoint: String?
    var token: String?
    var tools: [String]?

    enum CodingKeys: String, CodingKey {
        case transport
        case prefix
        case runPolicy = "run_policy"
        case command
        case endpoint
        case token
        case tools
    }
}

extension MCPServer {
    /// Builds an `MCPServer` from a decoded `MCPConfig` and a name (from the filename).
    init(name: String, config: MCPConfig) {
        let transport = MCPTransport(rawValue: config.transport) ?? .stdio
        let runPolicy: MCPRunPolicy?
        if transport == .stdio {
            runPolicy = MCPRunPolicy(rawValue: config.runPolicy ?? "") ?? .alwaysOn
        } else {
            runPolicy = nil
        }
        self.init(
            name: name,
            prefix: config.prefix ?? "",
            transport: transport,
            runPolicy: runPolicy,
            command: config.command,
            endpoint: config.endpoint,
            token: config.token,
            tools: config.tools
        )
    }

    /// Encodes this server back into a `MCPConfig` for TOML serialization.
    /// `runPolicy` is only written for stdio servers. In-house servers are
    /// never serialized (they live in code), but this is still safe to call.
    var config: MCPConfig {
        MCPConfig(
            transport: transport.rawValue,
            prefix: prefix.isEmpty ? nil : prefix,
            runPolicy: transport == .stdio ? runPolicy?.rawValue : nil,
            command: command,
            endpoint: endpoint,
            token: token,
            tools: tools
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
    /// True while the engine is waiting for the user to approve this call.
    /// Transient UI state: the streaming loop only persists on `finishStream`,
    /// by which point this is false, so it never reaches disk in a `true`
    /// state. Decoded defensively (defaults to false) for old chat files.
    var pendingApproval: Bool = false
    /// Optional pre-rendered unified diff for `write_file`/`apply_patch` calls.
    /// Built by [`DiffBuilder`](src/DiffBuilder.swift) from the file's before/
    /// after content so the renderer can show a colorized diff instead of raw
    /// JSON arguments. Nil for tools that don't produce diffs, or when the
    /// arguments are invalid. Cleared on denial since the changes were never
    /// applied. Decoded defensively (defaults to nil) for old chat files.
    var diff: String?

    enum CodingKeys: String, CodingKey {
        case id, name, arguments, pendingApproval, diff
    }

    init(id: String, name: String, arguments: String, pendingApproval: Bool = false, diff: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.pendingApproval = pendingApproval
        self.diff = diff
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        arguments = try c.decode(String.self, forKey: .arguments)
        pendingApproval = try c.decodeIfPresent(Bool.self, forKey: .pendingApproval) ?? false
        diff = try c.decodeIfPresent(String.self, forKey: .diff)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(arguments, forKey: .arguments)
        try c.encode(pendingApproval, forKey: .pendingApproval)
        try c.encodeIfPresent(diff, forKey: .diff)
    }
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
    /// True when this result represents a user denial (not a tool failure).
    /// `isError` stays true so the provider treats it as a tool error, but the
    /// renderer shows a "denied" badge instead of "error". Decoded
    /// defensively (defaults to false) for old chat files.
    var isDenied: Bool = false

    enum CodingKeys: String, CodingKey {
        case callID, content, isError, isStreaming, isDenied
    }

    init(callID: String, content: String, isError: Bool, isStreaming: Bool = false, isDenied: Bool = false) {
        self.callID = callID
        self.content = content
        self.isError = isError
        self.isStreaming = isStreaming
        self.isDenied = isDenied
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // All fields are tolerant: a missing or wrong-typed value falls back to
        // a default so an older tool-result shape can't fail the whole message.
        callID = (try? c.decode(String.self, forKey: .callID)) ?? ""
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        isError = (try? c.decode(Bool.self, forKey: .isError)) ?? false
        isStreaming = (try? c.decode(Bool.self, forKey: .isStreaming)) ?? false
        isDenied = (try? c.decode(Bool.self, forKey: .isDenied)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(callID, forKey: .callID)
        try c.encode(content, forKey: .content)
        try c.encode(isError, forKey: .isError)
        try c.encode(isStreaming, forKey: .isStreaming)
        try c.encode(isDenied, forKey: .isDenied)
    }
}

// MARK: - Tool definition (provider-agnostic)

/// A tool exposed by an MCP server, in a provider-agnostic shape ready to be
/// mapped onto OpenAI/Anthropic tool definitions by `ChatService`.
///
/// The `namespacedName` (`{prefix}_{tool}`) is what the model sees and calls
/// back; it guarantees uniqueness across servers and keeps the name within the
/// `^[a-zA-Z0-9_-]+$` pattern required by provider APIs. Routing a model-issued
/// call back to its server is done by matching `call.name` against the
/// `namespacedName` of the advertised `ToolDefinition`s (see
/// `ChatEngine.executeToolCall`), rather than by splitting the name, since
/// prefixless servers expose tools whose own names contain `_`.
struct ToolDefinition: Sendable, Equatable {
    let serverName: String
    let prefix: String
    let name: String
    let description: String?
    /// Raw JSON string of the tool's input schema (a JSON Schema object).
    let inputSchema: String

    /// The namespaced name sent to the model. When the server has a non-empty
    /// prefix this is `{prefix}_{tool}`; when the prefix is empty (the default)
    /// the tool is exposed under its own name with no prefix.
    var namespacedName: String {
        prefix.isEmpty ? name : "\(prefix)_\(name)"
    }
}
