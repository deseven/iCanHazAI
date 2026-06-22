// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import OpenAI

// MARK: - Message

enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
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

    init(id: UUID = UUID(), role: MessageRole, content: String, thinking: String? = nil, error: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.error = error
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

    init(id: UUID = UUID(), messages: [ChatMessage] = [], connection: String? = nil, role: String? = nil) {
        self.id = id
        self.messages = messages
        self.connection = connection
        self.role = role
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

    init(filename: String, chat: Chat, isStreaming: Bool = false, hasUnreadActivity: Bool = false, lastError: String? = nil) {
        self.filename = filename
        self.chat = chat
        self.isStreaming = isStreaming
        self.hasUnreadActivity = hasUnreadActivity
        self.lastError = lastError
    }
}

// MARK: - EngineEvent

/// Events emitted by `ChatEngine` to its subscribers.
enum EngineEvent: Sendable {
    /// The full set of chat records changed (load, add, edit, delete, streaming state).
    case chatsChanged([ChatRecord])
    case rolesChanged([Role])
    case connectionsChanged([Connection])
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

    /// Display name shown in the UI.
    var displayName: String { "\(name) (\(provider.rawValue))" }
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
    var vendorParameters: [String: JSONValue]?
}
