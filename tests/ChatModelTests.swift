import Testing
import Foundation
@testable import iCanHazAI

/// Tests for the pure data model layer: `Chat`, `ChatMessage`, and the derived
/// views on `ChatRecord` (display title, sort key, token count). No disk I/O,
/// no SwiftData — these are fast, deterministic unit tests that lock down the
/// Codable contract and the sidebar-derivation logic the store/engine rely on.
///
/// Nested under [`AllAppTests`](tests/AppTestHarness.swift) so its `.serialized`
/// trait keeps these sequential with the rest of the app suites.
extension AllAppTests {

@Suite("ChatModel")
struct ChatModelTests {

    // MARK: - ChatMessage Codable

    @Test("ChatMessage round-trips all fields through JSON")
    func messageRoundTrip() throws {
        let original = Fixtures.message(
            role: .assistant,
            content: "Here is the answer.",
            thinking: "reasoning here",
            error: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_050),
            connectionName: "anthropic/claude",
            images: [ImageAttachment(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                     ext: "png", originalName: "cat.png")],
            toolCalls: [ToolCall(id: "call_1", name: "calc", arguments: "{\"expression\":\"2+2\"}")],
            toolResults: [ToolResult(callID: "call_1", content: "4", isError: false)],
            tokenUsage: TokenUsage(tokensUsed: 128)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test("ChatMessage defaults optionals to nil when absent in JSON")
    func messageDecodesSparseJSON() throws {
        // Minimal JSON a legacy/external writer might produce.
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","role":"user","content":"hi","timestamp":1700000000}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(ChatMessage.self, from: json)
        #expect(msg.role == .user)
        #expect(msg.content == "hi")
        #expect(msg.thinking == nil)
        #expect(msg.error == nil)
        #expect(msg.connectionName == nil)
        #expect(msg.images == nil)
        #expect(msg.toolCalls == nil)
        #expect(msg.toolResults == nil)
        #expect(msg.tokenUsage == nil)
    }

    // MARK: - Chat Codable

    @Test("Chat round-trips all fields through JSON")
    func chatRoundTrip() throws {
        let original = Fixtures.chat(
            messages: [Fixtures.message(role: .user, content: "ping")],
            connection: "openai/myconn",
            role: "Developer",
            title: "My Chat",
            mcps: ["filesystem", "shell"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Chat.self, from: data)
        #expect(decoded == original)
    }

    @Test("empty Chat round-trips")
    func emptyChatRoundTrip() throws {
        let original = Fixtures.chat(messages: [])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Chat.self, from: data)
        #expect(decoded == original)
        #expect(decoded.messages.isEmpty)
    }

    @Test("Chat decodes with optional fields omitted")
    func chatDecodesSparseJSON() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","messages":[]}
        """.data(using: .utf8)!
        let chat = try JSONDecoder().decode(Chat.self, from: json)
        #expect(chat.connection == nil)
        #expect(chat.role == nil)
        #expect(chat.title == nil)
        #expect(chat.mcps == nil)
        #expect(chat.messages.isEmpty)
    }

    // MARK: - cacheName derivation

    @Test("cacheName is nil for a truly empty chat")
    func cacheNameEmpty() {
        #expect(Fixtures.chat(messages: []).cacheName == nil)
    }

    @Test("cacheName prefers an explicit title over the first user message")
    func cacheNameTitleWins() {
        let chat = Fixtures.chat(
            messages: [Fixtures.message(role: .user, content: "some long user text that should be ignored")],
            title: "Project Plan"
        )
        #expect(chat.cacheName == "Project Plan")
    }

    @Test("cacheName uses the first user message when there is no title")
    func cacheNameFromFirstUser() {
        let chat = Fixtures.chat(
            messages: [
                Fixtures.message(role: .assistant, content: "ignored preamble"),
                Fixtures.message(role: .user, content: "Summarize this document for me please")
            ]
        )
        #expect(chat.cacheName == "Summarize this document for me please")
    }

    @Test("cacheName truncates long first user messages to 40 characters")
    func cacheNameTruncates() {
        let long = String(repeating: "x", count: 200)
        let chat = Fixtures.chat(messages: [Fixtures.message(role: .user, content: long)])
        #expect(chat.cacheName?.count == 40)
        #expect(chat.cacheName == String(long.prefix(40)))
    }

    @Test("cacheName is nil when the only user message is whitespace")
    func cacheNameWhitespace() {
        let chat = Fixtures.chat(messages: [Fixtures.message(role: .user, content: "   \n\t  ")])
        #expect(chat.cacheName == nil)
    }

    @Test("cacheName ignores an empty title and falls back to the first user message")
    func cacheNameEmptyTitleFallsBack() {
        let chat = Fixtures.chat(
            messages: [Fixtures.message(role: .user, content: "real preview")],
            title: ""
        )
        #expect(chat.cacheName == "real preview")
    }

    // MARK: - lastActivity

    @Test("lastActivity is the most recent message timestamp")
    func lastActivityFromMessages() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 5_000)
        let chat = Fixtures.chat(messages: [
            Fixtures.message(role: .user, content: "a", timestamp: early),
            Fixtures.message(role: .assistant, content: "b", timestamp: late)
        ])
        #expect(chat.lastActivity == late)
    }

    @Test("lastActivity is distantPast for an empty chat")
    func lastActivityEmpty() {
        #expect(Fixtures.chat(messages: []).lastActivity == .distantPast)
    }

    // MARK: - ChatRecord derived views

    @Test("displayTitle uses the title when loaded")
    func displayTitleLoadedTitle() {
        let rec = ChatRecord(filename: "a.json", chat: Fixtures.chat(title: "Titled"))
        #expect(rec.displayTitle == "Titled")
    }

    @Test("displayTitle falls back to the first user message when loaded")
    func displayTitleLoadedFirstUser() {
        let rec = ChatRecord(filename: "a.json", chat: Fixtures.chat(
            messages: [Fixtures.message(role: .assistant, content: "hi"),
                       Fixtures.message(role: .user, content: "what time is it")]
        ))
        #expect(rec.displayTitle == "what time is it")
    }

    @Test("displayTitle is 'New chat' for a loaded empty chat")
    func displayTitleLoadedEmpty() {
        let rec = ChatRecord(filename: "a.json", chat: Fixtures.chat(messages: []))
        #expect(rec.displayTitle == "New chat")
    }

    @Test("displayTitle uses cachedName when unloaded")
    func displayTitleUnloadedCached() {
        let rec = ChatRecord(filename: "a.json", chat: nil, cachedName: "Cached title")
        #expect(rec.displayTitle == "Cached title")
    }

    @Test("displayTitle is 'New chat' when unloaded with no cached name")
    func displayTitleUnloadedEmpty() {
        let rec = ChatRecord(filename: "a.json", chat: nil, cachedName: nil)
        #expect(rec.displayTitle == "New chat")
    }

    @Test("sortKey uses last message timestamp when loaded with messages")
    func sortKeyLoadedMessages() {
        let ts = Date(timeIntervalSince1970: 9_000)
        let rec = ChatRecord(filename: "a.json", chat: Fixtures.chat(
            messages: [Fixtures.message(role: .user, content: "x", timestamp: ts)]
        ))
        #expect(rec.sortKey == ts)
    }

    @Test("sortKey uses createdAt for a loaded but empty chat")
    func sortKeyLoadedEmpty() {
        let created = Date(timeIntervalSince1970: 1_234)
        let rec = ChatRecord(filename: "a.json", chat: Fixtures.chat(messages: []), createdAt: created)
        #expect(rec.sortKey == created)
    }

    @Test("sortKey uses cached modification time when unloaded")
    func sortKeyUnloaded() {
        let mod = Date(timeIntervalSince1970: 5_555)
        let rec = ChatRecord(filename: "a.json", chat: nil, cachedModificationTime: mod)
        #expect(rec.sortKey == mod)
    }

    @Test("tokenCount is nil when the chat is unloaded")
    func tokenCountUnloaded() {
        let rec = ChatRecord(filename: "a.json", chat: nil)
        #expect(rec.tokenCount == nil)
    }

    @Test("tokenCount picks the most recent assistant message with usage")
    func tokenCountFromLastAssistant() {
        let chat = Fixtures.chat(messages: [
            Fixtures.message(role: .assistant, content: "old", timestamp: Date(timeIntervalSince1970: 1),
                             tokenUsage: TokenUsage(tokensUsed: 10)),
            Fixtures.message(role: .user, content: "again", timestamp: Date(timeIntervalSince1970: 2)),
            Fixtures.message(role: .assistant, content: "new", timestamp: Date(timeIntervalSince1970: 3),
                             tokenUsage: TokenUsage(tokensUsed: 99))
        ])
        let rec = ChatRecord(filename: "a.json", chat: chat)
        #expect(rec.tokenCount == 99)
    }

    @Test("tokenCount is nil when no assistant message reported usage")
    func tokenCountNoneReported() {
        let chat = Fixtures.chat(messages: [
            Fixtures.message(role: .assistant, content: "no usage", timestamp: Date(timeIntervalSince1970: 1))
        ])
        let rec = ChatRecord(filename: "a.json", chat: chat)
        #expect(rec.tokenCount == nil)
    }
}

} // extension AllAppTests
