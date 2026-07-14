// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import TOML

/// In-process tools exposed only to the bundled **iCHAI Configurator** role.
///
/// Unlike the in-house MCP servers (Utils/Filesystem/Code/Shell), these tools
/// are not a subprocess — they run directly inside the app so they can validate
/// config text via the same loading methods the app uses
/// ([`JSONC`](src/JSONC.swift) for connections, [`TOMLDecoder`](src/ConfigManager.swift)
/// for MCP/role/app configs) before anything is written to disk. A write that
/// fails validation is rejected outright; a write that passes is saved to the
/// data directory and picked up by the standard FSEvents reload routines, so
/// nothing is "applied" directly here.
///
/// The tools are injected by [`ChatEngine`](src/ChatEngine.swift) when the chat's
/// role is [`configuratorRoleName`](src/ConfiguratorTools.swift), and dispatched
/// in-process from `executeToolCall` (bypassing `MCPManager` entirely).
enum ConfiguratorTools {

    /// The virtual "server" name these tools are advertised under. Also the
    /// `serverName` stamped onto each `ToolDefinition` so `executeToolCall` can
    /// route calls back here.
    static let serverName = "Configurator"

    /// The role name that activates these tools. Matches the protected built-in
    /// role bundled at `default/roles/iCHAI Configurator.toml`.
    static let configuratorRoleName = "iCHAI Configurator"

    // MARK: - Tool definitions

    /// The tool definitions advertised to the model, in a provider-agnostic
    /// shape. Exposed under the bare tool names (empty prefix).
    static let toolDefinitions: [ToolDefinition] = tools.map { tool in
        ToolDefinition(
            serverName: serverName,
            prefix: "",
            name: tool.name,
            description: tool.description,
            inputSchema: tool.schema
        )
    }

    /// The set of raw tool names exposed here, for fast membership checks.
    static let toolNames: Set<String> = Set(tools.map(\.name))

    private static let tools: [(name: String, description: String, schema: String)] = [
        ("list_connections",
         "List configured Connections as ids (\"type/name\").",
         #"{"type":"object","properties":{}}"#),
        ("list_mcps",
         "List configured MCP servers. Built-in servers are not listed.",
         #"{"type":"object","properties":{}}"#),
        ("list_roles",
         "List configured Roles",
         #"{"type":"object","properties":{}}"#),
        ("list_prompts",
         "List available Prompts.",
         #"{"type":"object","properties":{}}"#),
        ("read_connection",
         "Read the Connection config. `id` is the connection id \"type/name\" (e.g. \"openai/gpt-4o\").",
         #"{"type":"object","properties":{"id":{"type":"string","description":"Connection id \"type/name\"."}},"required":["id"]}"#),
        ("read_mcp",
         "Read the MCP server config by name.",
         #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#),
        ("read_role",
         "Read the Role config by name.",
         #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#),
        ("read_prompt",
         "Read the Prompt by name.",
         #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#),
        ("read_config",
         "Read the main application config.",
         #"{"type":"object","properties":{}}"#),
        ("read_log",
         "Read the current session's application log.",
         #"{"type":"object","properties":{}}"#),
        ("write_connection",
         "Validate then write a Connection configuration. `id` is the Connection id \"type/name\"; `content` is JSONC text.",
         #"{"type":"object","properties":{"id":{"type":"string","description":"Connection id \"type/name\"."},"content":{"type":"string","description":"JSONC Connection config text."}},"required":["id","content"]}"#),
        ("write_mcp",
         "Validate then write an MCP server configuration. `content` is TOML text.",
         #"{"type":"object","properties":{"name":{"type":"string"},"content":{"type":"string","description":"TOML MCP config text."}},"required":["name","content"]}"#),
        ("write_role",
         "Validate then write a Role configuration. `content` is TOML text.",
         #"{"type":"object","properties":{"name":{"type":"string"},"content":{"type":"string","description":"TOML Role config text."}},"required":["name","content"]}"#),
        ("write_prompt",
         "Validate then write a Prompt. `content` is the prompt Markdown; it must be non-empty.",
         #"{"type":"object","properties":{"name":{"type":"string"},"content":{"type":"string","description":"Prompt Markdown text."}},"required":["name","content"]}"#),
        ("write_config",
         "Validate then write main application config. `content` is TOML text.",
         #"{"type":"object","properties":{"content":{"type":"string","description":"TOML app config text."}},"required":["content"]}"#),
        ("delete_connection",
         "Delete a Connection by id (\"type/name\").",
         #"{"type":"object","properties":{"id":{"type":"string","description":"Connection id \"type/name\"."}},"required":["id"]}"#),
        ("delete_mcp",
         "Delete an MCP server by name.",
         #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#),
        ("delete_role",
         "Delete a Role by name.",
         #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#),
        ("delete_prompt",
         "Delete a Prompt by name.",
         #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#),
        ("mcp_stdio_check",
         "Check a stdio MCP server: run `command`, list the tools it reports, then terminate the server. Returns the tools as a Markdown list, or a relevant error.",
         #"{"type":"object","properties":{"command":{"type":"string","description":"Full command line to launch the stdio MCP server, including args."}},"required":["command"]}"#),
        ("mcp_http_check",
         "Check a streamable HTTP MCP server: connect to `endpoint`, list the tools it reports, then disconnect. Returns the tools as a Markdown list, or a relevant error.",
         #"{"type":"object","properties":{"endpoint":{"type":"string","description":"The streamable HTTP endpoint URL."},"token":{"type":"string","description":"Optional bearer token."}},"required":["endpoint"]}"#),
        ("connection_check",
         "Check a configured Connection by sending the prompt 'say hi'. Returns the model's answer, or a relevant error. `id` is the connection id \"type/name\".",
         #"{"type":"object","properties":{"id":{"type":"string","description":"Connection id \"type/name\"."}},"required":["id"]}"#),
    ]

    // MARK: - Dispatch

    /// Executes a configurator tool call in-process. `arguments` is the raw
    /// JSON string issued by the model. Returns a `ToolResult` ready to fold
    /// onto the chat's `tool`-role message. Async because the live `*_check`
    /// tools spawn subprocesses / make network requests.
    static func call(name: String, arguments: String, callID: String) async -> ToolResult {
        await call(name: name, arguments: arguments, callID: callID, env: EnvironmentManager.shared)
    }

    /// Testable entry point that takes an explicit environment, so tests can
    /// point the tools at a throwaway temp directory instead of `~/iCanHazAI`.
    static func call(name: String, arguments: String, callID: String, env: EnvironmentManager) async -> ToolResult {
        do {
            let args = try argsDict(arguments)
            let outcome = try await dispatch(name: name, args: args, env: env)
            return ToolResult(callID: callID, content: outcome.content, isError: outcome.isError)
        } catch let err as ConfiguratorToolError {
            return ToolResult(callID: callID, content: err.message, isError: true)
        } catch let err as ConfigValidationError {
            return ToolResult(callID: callID, content: err.message, isError: true)
        } catch {
            return ToolResult(callID: callID, content: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    /// Routes a parsed argument map to the matching tool implementation.
    /// Returns the result text and whether it represents an error.
    private static func dispatch(name: String, args: [String: Any], env: EnvironmentManager) async throws -> (content: String, isError: Bool) {
        switch name {
        case "list_connections":
            return (listConnections(env: env), false)
        case "list_mcps":
            return (listNames(in: env.mcpsURL, ext: "toml"), false)
        case "list_roles":
            return (listNames(in: env.rolesURL, ext: "toml"), false)
        case "list_prompts":
            return (listNames(in: env.promptsURL, ext: "md"), false)
        case "read_connection":
            let id = try stringArg(args, "id")
            return (try readConnection(id: id, env: env), false)
        case "read_mcp":
            let n = try validated(try stringArg(args, "name"))
            return (try read(url: env.mcpsURL.appendingPathComponent("\(n).toml"), env: env, label: "MCP \"\(n)\""), false)
        case "read_role":
            let n = try validated(try stringArg(args, "name"))
            return (try read(url: env.rolesURL.appendingPathComponent("\(n).toml"), env: env, label: "Role \"\(n)\""), false)
        case "read_prompt":
            let n = try validated(try stringArg(args, "name"))
            return (try read(url: env.promptsURL.appendingPathComponent("\(n).md"), env: env, label: "Prompt \"\(n)\""), false)
        case "read_config":
            return (try read(url: env.rootURL.appendingPathComponent("config.toml"), env: env, label: "App config"), false)
        case "read_log":
            return (readLog(env: env), false)
        case "write_connection":
            let id = try stringArg(args, "id")
            let content = try stringArg(args, "content")
            return (try writeConnection(id: id, content: content, env: env), false)
        case "write_mcp":
            let n = try validated(try stringArg(args, "name"))
            let content = try stringArg(args, "content")
            return (try writeMCP(name: n, content: content, env: env), false)
        case "write_role":
            let n = try validated(try stringArg(args, "name"), protected: true)
            let content = try stringArg(args, "content")
            return (try writeRole(name: n, content: content, env: env), false)
        case "write_prompt":
            let n = try validated(try stringArg(args, "name"), protected: true)
            let content = try stringArg(args, "content")
            return (try writePrompt(name: n, content: content, env: env), false)
        case "write_config":
            let content = try stringArg(args, "content")
            return (try writeConfig(content: content, env: env), false)
        case "delete_connection":
            let id = try stringArg(args, "id")
            return (try deleteConnection(id: id, env: env), false)
        case "delete_mcp":
            let n = try validated(try stringArg(args, "name"))
            return (try delete(url: env.mcpsURL.appendingPathComponent("\(n).toml"), label: "MCP \"\(n)\"", env: env), false)
        case "delete_role":
            let n = try validated(try stringArg(args, "name"), protected: true)
            return (try delete(url: env.rolesURL.appendingPathComponent("\(n).toml"), label: "Role \"\(n)\"", env: env), false)
        case "delete_prompt":
            let n = try validated(try stringArg(args, "name"), protected: true)
            return (try delete(url: env.promptsURL.appendingPathComponent("\(n).md"), label: "Prompt \"\(n)\"", env: env), false)
        case "mcp_stdio_check":
            let command = try stringArg(args, "command")
            return (try await mcpStdioCheck(command: command), false)
        case "mcp_http_check":
            let endpoint = try stringArg(args, "endpoint")
            let token = args["token"] as? String
            return (try await mcpHttpCheck(endpoint: endpoint, token: token), false)
        case "connection_check":
            let id = try stringArg(args, "id")
            return (try await connectionCheck(id: id, env: env), false)
        default:
            throw ConfiguratorToolError("Unknown configurator tool \"\(name)\".")
        }
    }

    // MARK: - List helpers

    private static func listNames(in dir: URL, ext: String) -> String {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return "(none)"
        }
        let names = files
            .filter { $0.pathExtension == ext }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
        return markdownList(names)
    }

    /// Lists every connection across both providers, as "type/name" ids.
    private static func listConnections(env: EnvironmentManager) -> String {
        let fm = FileManager.default
        var ids: [String] = []
        for provider in [ConnectionProvider.openai, .anthropic] {
            let dir: URL
            switch provider {
            case .openai: dir = env.openaiConnectionsURL
            case .anthropic: dir = env.anthropicConnectionsURL
            }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "jsonc" {
                ids.append("\(provider.rawValue)/\(f.deletingPathExtension().lastPathComponent)")
            }
        }
        ids.sort()
        return markdownList(ids)
    }

    // MARK: - Read helpers

    private static func read(url: URL, env: EnvironmentManager, label: String) throws -> String {
        debugLog("FileRead", "configurator read \(env.relativePath(url))")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            throw ConfiguratorToolError("\(label) not found.")
        }
        return text
    }

    private static func readConnection(id: String, env: EnvironmentManager) throws -> String {
        let (provider, name) = try parseConnectionId(id)
        let url = env.connectionsURL
            .appendingPathComponent(provider.rawValue)
            .appendingPathComponent("\(name).jsonc")
        return try read(url: url, env: env, label: "Connection \"\(id)\"")
    }

    private static func readLog(env: EnvironmentManager) -> String {
        let url = env.rootURL.appendingPathComponent("app.log")
        debugLog("FileRead", "configurator read \(env.relativePath(url))")
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return text
        }
        return "(application log is empty or logging is disabled)"
    }

    // MARK: - Write helpers

    /// Each `write_` tool validates content via [`ConfigValidation`](src/ConfigValidation.swift)
    /// (the same layer the standard loaders use) before saving, so a dry-run
    /// failure produces the same helpful message a real load would log.

    private static func writeConnection(id: String, content: String, env: EnvironmentManager) throws -> String {
        let (provider, name) = try parseConnectionId(id)
        try ConfigValidation.decodeConnection(Data(content.utf8))
        let dir = env.connectionsURL.appendingPathComponent(provider.rawValue)
        let url = dir.appendingPathComponent("\(name).jsonc")
        try write(url: url, content: content, env: env)
        return "Connection \"\(provider.rawValue)/\(name)\" saved. It will be applied automatically in a second."
    }

    private static func writeMCP(name: String, content: String, env: EnvironmentManager) throws -> String {
        try ConfigValidation.decodeMCP(Data(content.utf8))
        let url = env.mcpsURL.appendingPathComponent("\(name).toml")
        try write(url: url, content: content, env: env)
        return "MCP \"\(name)\" saved. It will be applied automatically in a second."
    }

    private static func writeRole(name: String, content: String, env: EnvironmentManager) throws -> String {
        try ConfigValidation.decodeRole(Data(content.utf8))
        let url = env.rolesURL.appendingPathComponent("\(name).toml")
        try write(url: url, content: content, env: env)
        return "Role \"\(name)\" saved. It will be applied automatically in a second."
    }

    private static func writePrompt(name: String, content: String, env: EnvironmentManager) throws -> String {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfiguratorToolError("Prompt content must not be empty.")
        }
        let url = env.promptsURL.appendingPathComponent("\(name).md")
        try write(url: url, content: content, env: env)
        return "Prompt \"\(name)\" saved. It will be applied automatically in a second."
    }

    private static func writeConfig(content: String, env: EnvironmentManager) throws -> String {
        try ConfigValidation.decodeAppConfig(Data(content.utf8))
        let url = env.rootURL.appendingPathComponent("config.toml")
        try write(url: url, content: content, env: env)
        return "App config saved. It will be applied automatically in a second."
    }

    /// Atomically writes `content` to `url`, creating parent directories.
    private static func write(url: URL, content: String, env: EnvironmentManager) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        debugLog("FileWrite", "configurator write \(env.relativePath(url))")
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Delete helpers

    /// Removes the entity at `url`. Throws if it doesn't exist.
    private static func delete(url: URL, label: String, env: EnvironmentManager) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ConfiguratorToolError("\(label) not found.")
        }
        debugLog("FileWrite", "configurator delete \(env.relativePath(url))")
        try fm.removeItem(at: url)
        return "\(label) removed. The change will be applied automatically in a second."
    }

    private static func deleteConnection(id: String, env: EnvironmentManager) throws -> String {
        let (provider, name) = try parseConnectionId(id)
        let url = env.connectionsURL
            .appendingPathComponent(provider.rawValue)
            .appendingPathComponent("\(name).jsonc")
        return try delete(url: url, label: "Connection \"\(id)\"", env: env)
    }

    // MARK: - Live checks

    /// A unique, throwaway server name used for one-shot MCP checks so the
    /// transient connection never collides with a real configured server in
    /// [`MCPManager`](src/MCPManager.swift)'s connection pool (and is always
    /// torn down afterwards, never lingering as a "connected" server).
    private static func checkServerName() -> String {
        "__configurator_check_\(UUID().uuidString)"
    }

    /// Renders a discovered tool list as a Markdown bullet list. Each entry is
    /// `- name`, plus ` — description` when the server reported one. The empty
    /// case is reported explicitly so the configurator can tell a server with
    /// no tools apart from a failure (which throws).
    private static func formatToolList(_ tools: [MCPTool]) -> String {
        if tools.isEmpty { return "(no tools reported)" }
        return tools.map { t -> String in
            if let desc = t.description, !desc.isEmpty {
                return "- \(t.name) — \(desc)"
            }
            return "- \(t.name)"
        }.joined(separator: "\n")
    }

    /// Spawns a stdio MCP server via `command`, performs the MCP handshake,
    /// lists its tools, and always terminates the subprocess afterwards. Goes
    /// through [`MCPManager.testConnection`](src/MCPManager.swift) — the same
    /// path the MCP wizard's Test step uses — so a crashing or misconfigured
    /// server is reported with its stderr reason instead of hanging.
    private static func mcpStdioCheck(command: String) async throws -> String {
        guard !command.isEmpty else {
            throw ConfiguratorToolError("command must not be empty.")
        }
        let name = checkServerName()
        let server = MCPServer(
            name: name, prefix: "", transport: .stdio, runPolicy: .onDemand,
            command: command, endpoint: nil, token: nil, tools: nil
        )
        do {
            let (tools, _) = try await MCPManager.shared.testConnection(server)
            await MCPManager.shared.disconnect(name: name)
            return formatToolList(tools)
        } catch {
            await MCPManager.shared.disconnect(name: name)
            throw error
        }
    }

    /// Connects to a streamable HTTP MCP server at `endpoint` (with an optional
    /// bearer `token`), lists its tools, then disconnects. Also routes through
    /// [`MCPManager.testConnection`](src/MCPManager.swift).
    private static func mcpHttpCheck(endpoint: String, token: String?) async throws -> String {
        guard !endpoint.isEmpty else {
            throw ConfiguratorToolError("endpoint must not be empty.")
        }
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ConfiguratorToolError("endpoint is not a valid http(s) URL: \"\(endpoint)\".")
        }
        let name = checkServerName()
        let server = MCPServer(
            name: name, prefix: "", transport: .http, runPolicy: nil,
            command: nil, endpoint: endpoint, token: token, tools: nil
        )
        do {
            let (tools, _) = try await MCPManager.shared.testConnection(server)
            await MCPManager.shared.disconnect(name: name)
            return formatToolList(tools)
        } catch {
            await MCPManager.shared.disconnect(name: name)
            throw error
        }
    }

    /// Loads the connection `type/name` from disk and sends a one-shot "say hi"
    /// prompt via [`ChatService.complete`](src/ChatService.swift) — the same
    /// non-streaming path the connection wizard's "say hi" test uses —
    /// returning the model's text answer. Provider/request errors are parsed by
    /// [`LLMError`](src/LLM/LLMError.swift) and surfaced verbatim, so the user
    /// sees the actual failure reason (auth, quota, bad model, etc.).
    private static func connectionCheck(id: String, env: EnvironmentManager) async throws -> String {
        let (provider, connName) = try parseConnectionId(id)
        let url = env.connectionsURL
            .appendingPathComponent(provider.rawValue)
            .appendingPathComponent("\(connName).jsonc")
        guard let data = try? Data(contentsOf: url) else {
            throw ConfiguratorToolError("Connection \"\(id)\" not found.")
        }
        let config = try ConfigValidation.decodeConnection(data)
        let connection = Connection(
            provider: provider,
            name: connName,
            baseUrl: config.baseUrl,
            apiKey: config.apiKey,
            model: config.model,
            imageInput: config.imageInput ?? false,
            requestParameters: config.requestParameters
        )
        let messages = [ChatMessage(role: .user, content: "say hi")]
        let answer = try await ChatService.shared.complete(connection: connection, messages: messages)
        return answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(empty response)"
            : answer
    }

    // MARK: - Name / id validation

    /// Allowed characters for a bare entity name (file stem). Rejects path
    /// separators and traversal so a name can never escape its directory.
    private static let safeNamePattern = #"^[A-Za-z0-9._-]+$"#

    /// Validates a bare entity name, returning it unchanged on success.
    private static func validated(_ name: String, protected: Bool = false) throws -> String {
        guard !name.isEmpty,
              let regex = try? NSRegularExpression(pattern: safeNamePattern),
              regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else {
            throw ConfiguratorToolError("Invalid name \"\(name)\". Use only letters, digits, '.', '_', '-'.")
        }
        if protected, EnvironmentManager.protectedBundleNames.contains(name) {
            throw ConfiguratorToolError("\"\(name)\" is a protected built-in and cannot be overwritten.")
        }
        return name
    }

    /// Parses a connection id of the form "provider/name".
    private static func parseConnectionId(_ id: String) throws -> (ConnectionProvider, String) {
        let parts = id.split(separator: "/")
        guard parts.count == 2 else {
            throw ConfiguratorToolError("Connection name must be \"provider/name\" (e.g. \"openai/gpt-4o\").")
        }
        let providerStr = String(parts[0])
        guard let provider = ConnectionProvider(rawValue: providerStr) else {
            throw ConfiguratorToolError("Unknown provider \"\(providerStr)\". Use \"openai\" or \"anthropic\".")
        }
        let name = try validated(String(parts[1]))
        return (provider, name)
    }

    // MARK: - Argument parsing

    private static func argsDict(_ arguments: String) throws -> [String: Any] {
        guard let data = arguments.data(using: .utf8) else {
            throw ConfiguratorToolError("Invalid arguments (not UTF-8).")
        }
        if data.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfiguratorToolError("Invalid arguments JSON.")
        }
        return obj
    }

    private static func stringArg(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String else {
            throw ConfiguratorToolError("Missing required string argument \"\(key)\".")
        }
        return v
    }

    /// Renders a string array as a Markdown bullet list, or "(none)" if empty.
    private static func markdownList(_ items: [String]) -> String {
        items.isEmpty ? "(none)" : items.map { "- \($0)" }.joined(separator: "\n")
    }
}

/// Localized error type for configurator tool failures, so the dispatcher can
/// surface a clean message in the tool result.
private struct ConfiguratorToolError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
