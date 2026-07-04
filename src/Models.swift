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
    var connection: String?
    /// Selected role name.
    var role: String?
    /// Optional user-defined display title. When nil the UI derives a title
    /// from the first user message (or "New chat").
    var title: String?
    /// Names of MCP servers active for this chat. Nil when no MCP servers are
    /// configured or selected. New chats are seeded with servers flagged
    /// "default for new chats".
    var mcps: [String]?

    init(id: UUID = UUID(), messages: [ChatMessage] = [], connection: String? = nil, role: String? = nil, title: String? = nil, mcps: [String]? = nil) {
        self.id = id
        self.messages = messages
        self.connection = connection
        self.role = role
        self.title = title
        self.mcps = mcps
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
struct ChatRecord: Identifiable, Equatable, Sendable {
    var id: String { filename }
    let filename: String
    var chat: Chat
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

    init(filename: String, chat: Chat, isStreaming: Bool = false, hasUnreadActivity: Bool = false, lastError: String? = nil, createdAt: Date = Date()) {
        self.filename = filename
        self.chat = chat
        self.isStreaming = isStreaming
        self.hasUnreadActivity = hasUnreadActivity
        self.lastError = lastError
        self.createdAt = createdAt
    }

    /// Token usage reported by the provider for the most recent assistant
    /// response that has usage. A new (in-progress) assistant message has no
    /// usage yet, so we skip back to the last one that does — the counter
    /// holds its previous value while a new response streams in. Nil (shown
    /// as N/A) until the first assistant response with usage completes.
    var tokenCount: Int? {
        chat.messages.reversed()
            .first(where: { $0.role == .assistant && $0.tokenUsage != nil })?
            .tokenUsage?.totalTokens
    }

    /// Key used to order chats in the sidebar. Empty chats use their in-memory
    /// creation time; chats with messages use the last message timestamp.
    var sortKey: Date {
        chat.messages.last?.timestamp ?? createdAt
    }

    /// Display title derived from the user-defined title, the first user
    /// message, or "New chat" for empty chats.
    var displayTitle: String {
        if let title = chat.title, !title.isEmpty {
            return title
        }
        if let firstUser = chat.messages.first(where: { $0.role == .user }) {
            return String(firstUser.content.prefix(40))
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
    case connectionsChanged([Connection])
    /// The set of configured MCP servers changed (load, add, edit, delete).
    case mcpsChanged([MCPServer])
    /// The live MCP configuration status changed (a server's connect/listTools
    /// step started, succeeded, or failed). The UI uses this to drive the
    /// configuration overlay. Carries the full snapshot so the overlay always
    /// reflects the current state.
    case mcpConfiguration(MCPConfigurationState)
    /// `config.toml` was reloaded from disk (external edit picked up via FSEvents).
    /// The UI should refresh its cached preferences from `ConfigManager`.
    case configChanged
    case error(String)
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

// MARK: - Role

struct Role: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let content: String
    /// Whether this role is bundled with the app (read-only) or user-defined.
    let isDefault: Bool
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
