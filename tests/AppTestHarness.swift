import Foundation
import Testing

@testable import iCanHazAI

// `AllAppTests` (the `.serialized` parent suite for every test in this target)
// is declared in `AllTests.swift`. App test suites extend it:
// `extension AllAppTests { @Suite struct ... }`.

// MARK: - Errors

enum AppTestError: Error, CustomStringConvertible {
    case storeInitFailed

    var description: String {
        switch self {
        case .storeInitFailed: return "ChatStore(env:) returned nil"
        }
    }
}

// MARK: - TempEnv

/// A throwaway on-disk environment for one test: a fresh temp root URL, an
/// `EnvironmentManager` rooted there, and a `ChatStore` backed by a private
/// SwiftData cache under `<root>/.cache/chat.cache`. Removed on deinit.
///
/// This mirrors how the production singletons are wired, but with a temp dir so
/// tests never touch `~/iCanHazAI`. `ensureDirectories()` creates the Chats/
/// Roles/Prompts/MCPs/ tree just like app launch does.
final class TempEnv: @unchecked Sendable {

    let rootURL: URL
    let env: EnvironmentManager
    let store: ChatStore
    private let fm = FileManager.default

    init() throws {
        let base = NSTemporaryDirectory()
        rootURL = URL(fileURLWithPath: base)
            .appendingPathComponent("ichai-app-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        env = EnvironmentManager(rootURL: rootURL)
        env.ensureDirectories()
        guard let s = ChatStore(env: env) else { throw AppTestError.storeInitFailed }
        store = s
    }

    deinit { try? fm.removeItem(at: rootURL) }

    // MARK: - Path helpers

    var chatsURL: URL { env.chatsURL }
    func chatURL(_ filename: String) -> URL { env.chatsURL.appendingPathComponent(filename) }

    // MARK: - Direct disk access (bypasses the store)

    /// Writes a chat JSON straight to disk with the same encoder settings the
    /// store uses, simulating a writer the store is unaware of.
    func writeChatDirect(_ chat: Chat, filename: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(chat)
        try data.write(to: chatURL(filename), options: .atomic)
    }

    /// Overwrites a chat file's contents without changing the store's cache —
    /// used to simulate an external modification (the store's cached mod time
    /// then goes stale until the next `startupSync`).
    func modifyChatDirect(_ filename: String, transform: (inout Chat) -> Void) throws {
        var chat = try readChatDirect(filename)
        transform(&chat)
        try writeChatDirect(chat, filename: filename)
    }

    func deleteChatDirect(_ filename: String) { try? fm.removeItem(at: chatURL(filename)) }

    func readChatDirect(_ filename: String) throws -> Chat {
        let data = try Data(contentsOf: chatURL(filename))
        return try JSONDecoder().decode(Chat.self, from: data)
    }

    func diskFilenames() -> [String] {
        guard let files = try? fm.contentsOfDirectory(at: env.chatsURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "json" }.map(\.lastPathComponent).sorted()
    }

    /// Content modification date of a chat file, rounded to the nearest second
    /// — matching the store's `URL.modificationDate` helper so comparisons line
    /// up with the SwiftData-cached value.
    func modificationDate(_ filename: String) -> Date? {
        guard let attrs = try? fm.attributesOfItem(atPath: chatURL(filename).path),
            let date = attrs[.modificationDate] as? Date
        else { return nil }
        return Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
    }

    /// Forces a chat file's mod time to the given date (rounded to the second).
    /// Used to make a cached entry deliberately stale or fresh without waiting.
    func setModificationDate(_ filename: String, _ date: Date) throws {
        let rounded = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
        try fm.setAttributes([.modificationDate: rounded], ofItemAtPath: chatURL(filename).path)
    }
}

// MARK: - Chat fixtures

/// Builders for chats/messages used across suites. Kept here so test files stay
/// focused on assertions. Timestamps are pinned (not `Date()`) so Codable
/// round-trips and ordering are deterministic.
enum Fixtures {

    static func message(
        role: MessageRole = .user,
        content: String = "hello",
        thinking: String? = nil,
        error: String? = nil,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        model: String? = nil,
        attachments: [iCanHazAI.Attachment]? = nil,
        toolCalls: [ToolCall]? = nil,
        toolResults: [ToolResult]? = nil,
        tokenUsage: TokenUsage? = nil
    ) -> ChatMessage {
        ChatMessage(
            role: role, content: content, thinking: thinking, error: error,
            timestamp: timestamp, model: model, attachments: attachments,
            toolCalls: toolCalls, toolResults: toolResults, tokenUsage: tokenUsage
        )
    }

    static func chat(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        messages: [ChatMessage] = [],
        model: String? = nil,
        role: String? = nil,
        prompt: String? = nil,
        workingDirectory: String? = nil,
        mcps: [String]? = nil,
        title: String? = nil,
        archive: Bool? = nil,
        autoAllow: [String]? = nil
    ) -> Chat {
        Chat(
            id: id, messages: messages, model: model, role: role, prompt: prompt,
            workingDirectory: workingDirectory, mcps: mcps, title: title, archive: archive, autoAllow: autoAllow)
    }

    /// Attaches fork branches to a message, making it a fork owner. The owner
    /// must end up as the last message of its branch array (tree invariant).
    static func forking(_ msg: ChatMessage, branches: [[ChatMessage]], active: Int? = nil) -> ChatMessage {
        var msg = msg
        msg.branches = branches
        msg.activeBranch = active
        return msg
    }

    /// A chat with one user + one assistant message, useful for cache/display tests.
    static func simpleChat(title: String? = nil) -> Chat {
        chat(
            messages: [
                message(role: .user, content: "What is 2+2?", timestamp: Date(timeIntervalSince1970: 1_700_000_000)),
                message(
                    role: .assistant, content: "4", timestamp: Date(timeIntervalSince1970: 1_700_000_010),
                    model: "openai:test", tokenUsage: TokenUsage(tokensUsed: 42)),
            ],
            title: title
        )
    }
}
