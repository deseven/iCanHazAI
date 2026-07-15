// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - Message

enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    /// Tool-result message (OpenAI `tool` role). For Anthropic, rendered as a
    /// `tool_result` content block on a `user` message — handled in ChatService.
    case tool
}

struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var role: MessageRole
    var content: String
    /// Optional thinking/reasoning content (for thinking models).
    var thinking: String?
    /// Optional error text captured while streaming this assistant message.
    /// When non-nil, the message is rendered as an error block with a retry button.
    var error: String?
    /// Wall-clock time the message was created (set once, when the message is
    /// first added to a chat; never updated thereafter). Encoded as a JSON date
    /// so it persists to disk.
    var timestamp: Date
    /// For assistant messages: the display name of the connection that produced
    /// this response. Persisted so it survives reloads. Nil for non-assistant
    /// messages or messages produced before this field existed.
    var connectionName: String?
    /// Images attached to this message (user messages only). Each entry is a
    /// reference to a processed image file stored in the chat's image folder.
    /// Nil/empty for messages without images.
    var images: [ImageAttachment]?
    /// For assistant messages: tool calls issued by the model. Nil for messages
    /// without tool calls.
    var toolCalls: [ToolCall]?
    /// For `tool`-role messages: the result of a tool call. Nil otherwise.
    var toolResults: [ToolResult]?
    /// For assistant messages: token usage reported by the provider for this
    /// response. Nil when the provider didn't report usage (shown as N/A in
    /// the UI) or for non-assistant messages.
    var tokenUsage: TokenUsage?

    init(id: UUID = UUID(), role: MessageRole, content: String, thinking: String? = nil, error: String? = nil, timestamp: Date = Date(), connectionName: String? = nil, images: [ImageAttachment]? = nil, toolCalls: [ToolCall]? = nil, toolResults: [ToolResult]? = nil, tokenUsage: TokenUsage? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.error = error
        self.timestamp = timestamp
        self.connectionName = connectionName
        self.images = images
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.tokenUsage = tokenUsage
    }
}

// MARK: - Chat

struct Chat: Codable, Identifiable, Equatable {
    var id: UUID
    var messages: [ChatMessage]
    /// Selected connection identifier in the form "provider/name", e.g. "openai/myconn".
    /// When the chat's role allows connection overrides this is the per-chat
    /// override; otherwise the role's connection is used and this is ignored.
    /// If role connection is not defined, a default model will be used.
    var connection: String?
    /// Selected role name.
    var role: String?
    /// Per-chat prompt override (name of a prompt file, without extension).
    /// Only honored when the role's `prompt_override_allowed` is true.
    var prompt: String?
    /// Per-chat working-directory override. Only honored when the role's
    /// `working_directory_override_allowed` is true.
    var workingDirectory: String?
    /// Optional user-defined display title. When nil the UI derives a title
    /// from the first user message (or "New chat").
    var title: String?
    init(id: UUID = UUID(), messages: [ChatMessage] = [], connection: String? = nil, role: String? = nil, prompt: String? = nil, workingDirectory: String? = nil, title: String? = nil) {
        self.id = id
        self.messages = messages
        self.connection = connection
        self.role = role
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.title = title
    }

    /// Wall-clock time of the most recent message, used to order chats in the
    /// sidebar by last activity. Falls back to `Date.distantPast` for empty chats.
    var lastActivity: Date {
        messages.last?.timestamp ?? Date.distantPast
    }
}

// MARK: - ChatRecord

/// A chat plus its live runtime status, as owned by `ChatEngine`.
/// This is the UI-facing representation that flows through `AppViewModel`.
///
/// `chat` is nil when the chat is not loaded — the full message history is
/// only in memory while the chat is needed (the user has it open, or agentic
/// work is in flight). It is dropped the instant neither holds, via
/// `ChatEngine.releaseChat`. Cached metadata (`cachedName`,
/// `cachedModificationTime`) comes from the SwiftData cache and is always
/// available, even when the chat is unloaded, so the sidebar can display and
/// sort chats without touching disk.
struct ChatRecord: Identifiable, Equatable, Sendable {
    var id: String { filename }
    let filename: String
    /// Full chat data, or nil when unloaded. Loaded on demand via
    /// `ChatStore.loadChat` when the user opens the chat or streaming starts.
    var chat: Chat?
    /// Whether a streaming request is currently in flight for this chat.
    var isStreaming: Bool
    /// Whether this chat has new activity (a finished stream or new message)
    /// since the user last viewed it.
    var hasUnreadActivity: Bool
    /// Last error captured for this chat, if any.
    var lastError: String?
    /// In-memory creation time. Used to order empty chats (which have no
    /// messages yet) in the sidebar; once a message exists the chat switches
    /// to ordering by the last message timestamp.
    var createdAt: Date
    /// Cached display name from SwiftData. Available even when `chat` is nil.
    var cachedName: String?
    /// Cached role name from SwiftData. Mirrors `Chat.role` so the sidebar
    /// can badge each chat with its role without loading the full chat.
    var cachedRole: String?
    /// Cached file modification time from SwiftData. Used as the sort key
    /// when the chat is unloaded.
    var cachedModificationTime: Date

    init(filename: String, chat: Chat? = nil, cachedName: String? = nil, cachedRole: String? = nil, cachedModificationTime: Date = Date(), isStreaming: Bool = false, hasUnreadActivity: Bool = false, lastError: String? = nil, createdAt: Date = Date()) {
        self.filename = filename
        self.chat = chat
        self.cachedName = cachedName
        self.cachedRole = cachedRole
        self.cachedModificationTime = cachedModificationTime
        self.isStreaming = isStreaming
        self.hasUnreadActivity = hasUnreadActivity
        self.lastError = lastError
        self.createdAt = createdAt
    }

    /// The role name to display for this chat: the live chat's role when
    /// loaded (authoritative), otherwise the cached role. Nil when neither
    /// is set.
    var effectiveRoleName: String? {
        chat?.role ?? cachedRole
    }

    /// Token usage reported by the provider for the most recent assistant
    /// response that has usage. Nil when the chat is unloaded.
    var tokenCount: Int? {
        guard let chat = chat else { return nil }
        return chat.messages.reversed()
            .first(where: { $0.role == .assistant && $0.tokenUsage != nil })?
            .tokenUsage?.tokensUsed
    }

    /// Key used to order chats in the sidebar. When the chat is loaded, uses
    /// the last message timestamp (or `createdAt` for empty chats). When
    /// unloaded, falls back to the cached file modification time.
    var sortKey: Date {
        if let chat = chat {
            return chat.messages.last?.timestamp ?? createdAt
        }
        return cachedModificationTime
    }

    /// Display title derived from the loaded chat's title / first user
    /// message, or from the cached name when the chat is unloaded.
    var displayTitle: String {
        if let chat = chat {
            if let title = chat.title, !title.isEmpty {
                return title
            }
            if let firstUser = chat.messages.first(where: { $0.role == .user }) {
                return String(firstUser.content.prefix(40))
            }
            return "New chat"
        }
        if let name = cachedName, !name.isEmpty {
            return name
        }
        return "New chat"
    }
}

// MARK: - ChatSummary

/// A cheap, message-free projection of a `ChatRecord` for the sidebar list.
/// The sidebar only needs a handful of scalars (title, streaming/unread/error
/// flags, sort key) — it never inspects `chat.messages`. Diffing it is
/// O(1)-per-chat, so a busy chat's per-token emits don't force the sidebar
/// to re-diff full message arrays for every chat.
struct ChatSummary: Identifiable, Equatable, Sendable {
    var id: String { filename }
    let filename: String
    let displayTitle: String
    /// Role name for this chat (live role when loaded, else cached). The
    /// sidebar badges each row with this. Nil when no role is set.
    let roleName: String?
    let isStreaming: Bool
    let hasUnreadActivity: Bool
    let lastError: String?
    /// Sort key (last message timestamp or in-memory creation time). The
    /// sidebar uses this to keep its ordering in sync with the engine without
    /// needing the message arrays.
    let sortKey: Date

    init(record: ChatRecord) {
        self.filename = record.filename
        self.displayTitle = record.displayTitle
        self.roleName = record.effectiveRoleName
        self.isStreaming = record.isStreaming
        self.hasUnreadActivity = record.hasUnreadActivity
        self.lastError = record.lastError
        self.sortKey = record.sortKey
    }
}

// MARK: - EngineEvent

/// Events emitted by `ChatEngine` to its subscribers.
enum EngineEvent: Sendable {
    /// The full set of chat records changed (load, add, edit, delete, streaming state).
    case chatsChanged([ChatRecord])
    case rolesChanged([Role])
    case promptsChanged([Prompt])
    case connectionsChanged([Connection])
    /// The set of configured MCP servers changed (load, add, edit, delete).
    case mcpsChanged([MCPServer])
    /// The live MCP configuration status changed (a server's connect/listTools
    /// step started, succeeded, or failed). The UI uses this to drive the
    /// configuration overlay. Carries the full snapshot so the overlay always
    /// reflects the current state.
    case mcpConfiguration(MCPConfigurationState)
    /// A batch of external Application-resource reloads (config / connections /
    /// prompts / roles) just started. Carries the per-resource totals the
    /// loader shows in its labels. The corresponding "completed" signal is the
    /// existing `.configChanged` / `.rolesChanged` / `.promptsChanged` /
    /// `.connectionsChanged` event for each resource.
    case loaderActivity(LoaderActivity)
    /// `config.toml` was reloaded from disk (external edit picked up via FSEvents).
    /// The UI should refresh its cached preferences from `ConfigManager`.
    case configChanged
    /// The engine is waiting for the user to approve a tool call. The UI uses
    /// this to draw attention: blink the chat in the sidebar (if it isn't the
    /// active one) and bounce the dock icon (if the window isn't key/front).
    /// Note: the chat remains in its streaming state — this is a pause, not a
    /// stop.
    case toolApprovalRequested(filename: String, callID: String)
    /// A previously-requested tool approval was resolved (allowed, denied, or
    /// cancelled by a stop). The UI clears any attention it drew for it.
    case toolApprovalResolved(filename: String, callID: String)
    case error(String)
    /// The set of gathered configuration errors changed (a connection/role/MCP
    /// config failed to load, or an MCP server failed at runtime, or a
    /// previously-broken entity was fixed/removed on disk). The UI shows a
    /// warning button in the title bar while the array is non-empty. Carries
    /// the full snapshot so subscribers always reflect the current state.
    case configErrorsChanged([ConfigError])
}

// MARK: - Config errors

/// A configuration problem surfaced to the user (and the Configurator) for
/// manual repair. Each entry identifies the failing entity by `kind` and
/// `entityName`, plus a human-readable `message`. The set is rebuilt by
/// [`ChatEngine`](src/ChatEngine.swift) whenever the on-disk configuration is
/// reloaded, so it naturally shrinks as broken entities are fixed or removed.
///
/// `id` is `"<kind>:<entityName>"` — stable across rebuilds so the UI diffs the
/// list without flicker, and so the engine can replace/clear a single entity's
/// entry without touching the rest.
struct ConfigError: Identifiable, Equatable, Sendable, Hashable {
    var id: String { "\(kind.rawValue):\(entityName)" }
    let kind: Kind
    let entityName: String
    let message: String

    enum Kind: String, Sendable {
        /// A connection `.jsonc` file failed to parse/validate.
        case connection
        /// A role `.toml` file failed to parse/validate.
        case role
        /// A custom MCP `.toml` config failed to parse/validate.
        case mcpConfig
        /// A custom MCP server failed to connect / list tools at runtime.
        case mcpFailure
    }

    /// Human-readable label for the entity kind, shown in the errors window.
    var kindLabel: String {
        switch kind {
        case .connection: return "Connection"
        case .role: return "Role"
        case .mcpConfig: return "MCP config"
        case .mcpFailure: return "MCP server"
        }
    }

    /// One-line description used when pasting errors into a Configurator chat,
    /// e.g. `Connection `openai/gpt-5` is invalid (error: "Missing model").`.
    var configuratorLine: String {
        switch kind {
        case .connection:
            return "Connection `\(entityName)` is invalid (error: \"\(message)\")."
        case .role:
            return "Role `\(entityName)` is invalid (error: \"\(message)\")."
        case .mcpConfig:
            return "MCP server `\(entityName)` has an invalid config (error: \"\(message)\")."
        case .mcpFailure:
            return "MCP server `\(entityName)` failed on startup (error: \"\(message)\")."
        }
    }
}

// MARK: - MCP configuration status

/// The status of a single MCP server during the configuration flow.
enum MCPConfigStatus: String, Sendable, Equatable {
    /// Not yet started (queued).
    case pending
    /// Currently connecting / listing tools.
    case inProgress
    /// Connected and tools listed successfully.
    case success
    /// Failed to connect or list tools; the server was discarded.
    case failed
}

/// A single row in the MCP configuration overlay: the server name and its
/// current status. `toolCount` is shown for successful servers.
struct MCPConfigurationEntry: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    var status: MCPConfigStatus
    /// Number of tools discovered, for successful entries. Nil otherwise.
    var toolCount: Int?
    /// Human-readable error message for failed entries. Nil otherwise.
    var errorMessage: String?
}

/// The full state of an MCP configuration pass. Drives the overlay UI.
struct MCPConfigurationState: Sendable, Equatable {
    /// Whether a configuration pass is currently in progress. The overlay is
    /// shown while this is true (and there is at least one entry).
    var isConfiguring: Bool
    /// One entry per configured server, in the order they were started.
    var entries: [MCPConfigurationEntry]

    static let empty = MCPConfigurationState(isConfiguring: false, entries: [])
}

// MARK: - Prompt

/// A prompt file (`~/iCanHazAI/prompts/<name>.md`). The system prompt sent to
/// the model is the content of the prompt referenced by the chat's role (or
/// the chat's per-chat prompt override when allowed).
struct Prompt: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let content: String
    /// True for built-in prompts served from the app bundle (never
    /// user-editable). Derived from the protected built-in name set.
    var isBuiltin: Bool { EnvironmentManager.protectedBundleNames.contains(name) }
}

// MARK: - Role config (TOML)

/// One MCP entry within a role config. `mcp` is either `internal::<name>` for
/// a built-in server or `<name>` for a custom server config.
struct RoleMCP: Codable, Equatable, Hashable, Sendable {
    var mcp: String
    /// Tool selection from this MCP. Empty/nil means all available tools.
    var tools: [String]?
    /// Tools to auto-approve (raw tool names, without prefix). Empty/nil = none.
    var autoAllow: [String]?
    /// When true, all available tools from this MCP are auto-approved.
    var autoAllowAll: Bool?
    /// When true, the in-house server runs confined to the working directory.
    /// Only meaningful for `internal::Filesystem` and `internal::Code`.
    var directoryIsolation: Bool?

    enum CodingKeys: String, CodingKey {
        case mcp
        case tools
        case autoAllow = "auto_allow"
        case autoAllowAll = "auto_allow_all"
        case directoryIsolation = "directory_isolation"
    }
}

/// Raw structure decoded from a role TOML file (`~/iCanHazAI/roles/<name>.toml`).
struct RoleConfig: Codable, Equatable, Hashable {
    var description: String?
    var prompt: String?
    var promptOverrideAllowed: Bool?
    var workingDirectory: String?
    var workingDirectoryOverrideAllowed: Bool?
    var connection: String?
    var connectionOverrideAllowed: Bool?
    var mcps: [RoleMCP]?
    /// SF Symbol name used to badge this role's chats in the sidebar and the
    /// role picker. Nil → falls back to `Role.defaultIcon`.
    var icon: String?
    /// Accent color alias for this role (e.g. "blue", "purple"). Resolved by
    /// `RoleAccent` to an adaptive system color. Nil/unknown → falls back to
    /// the macOS accent color (system setting).
    var accent: String?

    enum CodingKeys: String, CodingKey {
        case description
        case prompt
        case promptOverrideAllowed = "prompt_override_allowed"
        case workingDirectory = "working_directory"
        case workingDirectoryOverrideAllowed = "working_directory_override_allowed"
        case connection
        case connectionOverrideAllowed = "connection_override_allowed"
        case mcps
        case icon
        case accent
    }
}

// MARK: - Role

/// A role: a TOML config combining a prompt, connection, working directory, and
/// a set of MCPs (with per-MCP tool selection and auto-allow rules). Roles live
/// in `~/iCanHazAI/roles/<name>.toml`; bundled defaults are seeded from
/// `default/roles` on startup and are fully user-editable.
struct Role: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let config: RoleConfig

    /// Generic SF Symbol used when a role doesn't define its own `icon`.
    static let defaultIcon = "brain"

    /// True for built-in roles served from the app bundle (never
    /// user-editable). Derived from the protected built-in name set.
    var isBuiltin: Bool { EnvironmentManager.protectedBundleNames.contains(name) }
    var description: String { config.description ?? "No description." }
    var promptName: String? { config.prompt }
    var promptOverrideAllowed: Bool { config.promptOverrideAllowed ?? false }
    var connectionOverrideAllowed: Bool { config.connectionOverrideAllowed ?? false }
    var workingDirectoryOverrideAllowed: Bool { config.workingDirectoryOverrideAllowed ?? false }
    var workingDirectory: String? { config.workingDirectory }
    var connection: String? { config.connection }
    /// SF Symbol for this role, falling back to `defaultIcon`.
    var icon: String { config.icon ?? Role.defaultIcon }
    /// Number of MCPs selected by this role.
    var mcpCount: Int { config.mcps?.count ?? 0 }
}

// MARK: - Connection

enum ConnectionProvider: String, Codable {
    case openai
    case anthropic
}

struct Connection: Identifiable, Equatable, @unchecked Sendable {
    var id: String { "\(provider.rawValue)/\(name)" }
    let provider: ConnectionProvider
    let name: String
    /// Base URL of the endpoint. nil → provider default.
    let baseUrl: String?
    /// API key. nil when the endpoint doesn't require one.
    let apiKey: String?
    /// Model identifier.
    let model: String
    /// Meta flag: whether the model supports image input. Used by the UI to
    /// gate the image attach button — NOT sent to the API. Defaults to false.
    let imageInput: Bool
    /// Extra parameters inserted into every request body's root. Fully optional.
    let requestParameters: [String: LLMJSONValue]?

    /// Display name shown in the UI.
    var displayName: String { name }
}

/// Raw structure decoded from a connection `.jsonc` file.
struct ConnectionConfig: Codable {
    var baseUrl: String?
    var apiKey: String?
    var model: String
    var imageInput: Bool?
    var requestParameters: [String: LLMJSONValue]?
}
