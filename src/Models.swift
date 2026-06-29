// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import OpenAI

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

    init(id: UUID = UUID(), role: MessageRole, content: String, thinking: String? = nil, error: String? = nil, timestamp: Date = Date(), connectionName: String? = nil, images: [ImageAttachment]? = nil, toolCalls: [ToolCall]? = nil, toolResults: [ToolResult]? = nil) {
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

    /// Approximate token count for the whole conversation (all messages,
    /// including thinking). Updated live as content streams in.
    var tokenCount: Int {
        chat.messages.reduce(0) { $0 + TokenEstimator.estimate($1.content) + TokenEstimator.estimate($1.thinking ?? "") }
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

// MARK: - Token estimation

/// A lightweight, dependency-free token estimator. Real BPE tokenizers are
/// model-specific and heavy; for a UI counter a rough heuristic is enough.
/// The approximation (~4 chars/token) tracks the OpenAI family closely enough
/// for display purposes and updates in real time as content streams in.
enum TokenEstimator {
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        // ~4 characters per token is the commonly cited heuristic for English
        // text on GPT-family tokenizers. Round up so the counter never reads 0
        // for non-empty content.
        return max(1, (text.count + 3) / 4)
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
    case error(String)
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
    let endpoint: String?
    let token: String?
    let model: String
    let maxTokens: Int?

    // Common optional parameters
    let temperature: Double?
    let topP: Double?

    // OpenAI-specific
    let reasoningEffort: String?
    let frequencyPenalty: Double?
    let presencePenalty: Double?
    let maxCompletionTokens: Int?
    let seed: Int?

    // Anthropic-specific
    let topK: Int?
    let stopSequences: [String]?
    let thinkingEnabled: Bool?
    let thinkingBudget: Int?

    /// Arbitrary vendor-specific parameters injected into the request JSON (OpenAI only).
    let vendorParameters: [String: JSONValue]?

    /// Meta flag indicating whether the model supports image input. False by
    /// default. Not yet used by the chat engine; preparation for future tasks.
    let imageInput: Bool?

    /// Display name shown in the UI.
    var displayName: String { name }
}

/// Raw structure decoded from a connection TOML file.
struct ConnectionConfig: Codable {
    var endpoint: String?
    var token: String?
    var model: String
    var maxTokens: Int?

    // Common optional parameters
    var temperature: Double?
    var topP: Double?

    // OpenAI-specific
    var reasoningEffort: String?
    var frequencyPenalty: Double?
    var presencePenalty: Double?
    var maxCompletionTokens: Int?
    var seed: Int?

    // Anthropic-specific
    var topK: Int?
    var stopSequences: [String]?
    var thinkingEnabled: Bool?
    var thinkingBudget: Int?

    /// Arbitrary vendor-specific parameters injected into the request JSON (OpenAI-compatible only).
    /// Raw JSON string, e.g. `{"thinking":{"type":"disabled"}}`.
    var vendorParameters: String?

    /// Meta flag indicating whether the model supports image input. Optional,
    /// defaults to false (nil) when absent from the TOML file.
    var imageInput: Bool?

    enum CodingKeys: String, CodingKey {
        case endpoint
        case token
        case model
        case maxTokens = "max_tokens"
        case temperature
        case topP = "top_p"
        case reasoningEffort = "reasoning_effort"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case maxCompletionTokens = "max_completion_tokens"
        case seed
        case topK = "top_k"
        case stopSequences = "stop_sequences"
        case thinkingEnabled = "thinking_enabled"
        case thinkingBudget = "thinking_budget"
        case vendorParameters = "vendor_parameters"
        case imageInput = "image_input"
    }
}
