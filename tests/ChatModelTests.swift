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
            prompt: "Developer",
            workingDirectory: "~/projects/MyProject",
            mcps: ["Tavily", "googledocs"],
            title: "My Chat"
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
        #expect(chat.prompt == nil)
        #expect(chat.workingDirectory == nil)
        #expect(chat.mcps == nil)
        #expect(chat.autoAllow == nil)
        #expect(chat.messages.isEmpty)
    }

    @Test("Chat round-trips the per-chat auto_allow list")
    func chatRoundTripsAutoAllow() throws {
        let original = Fixtures.chat(autoAllow: ["read_file", "mcp__Tavily__search"])
        let data = try JSONEncoder().encode(original)
        // The JSON key is snake_case, matching the role config files.
        let raw = String(data: data, encoding: .utf8)!
        #expect(raw.contains("\"auto_allow\""))
        let decoded = try JSONDecoder().decode(Chat.self, from: data)
        #expect(decoded == original)
        #expect(decoded.autoAllow == ["read_file", "mcp__Tavily__search"])
    }

    @Test("Chat decodes auto_allow and tolerates a wrong-typed value")
    func chatDecodesAutoAllow() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","messages":[],"auto_allow":["list_files"]}
        """.data(using: .utf8)!
        let chat = try JSONDecoder().decode(Chat.self, from: json)
        #expect(chat.autoAllow == ["list_files"])

        let bad = """
        {"id":"00000000-0000-0000-0000-000000000001","messages":[],"auto_allow":"list_files"}
        """.data(using: .utf8)!
        let badChat = try JSONDecoder().decode(Chat.self, from: bad)
        #expect(badChat.autoAllow == nil)
    }

    // MARK: - Tolerant decoding (legacy / malformed chat files)

    @Test("Chat decodes the per-chat MCP selection and ignores unknown keys")
    func chatDecodesMCPSelection() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","messages":[],"mcps":["googledocs"],"foo":42}
        """.data(using: .utf8)!
        let chat = try JSONDecoder().decode(Chat.self, from: json)
        #expect(chat.messages.isEmpty)
        #expect(chat.mcps == ["googledocs"])
    }

    @Test("Chat tolerates a wrong-typed 'mcps' field (falls back to nil)")
    func chatToleratesWrongTypedMCPs() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","messages":[],"mcps":"googledocs"}
        """.data(using: .utf8)!
        let chat = try JSONDecoder().decode(Chat.self, from: json)
        #expect(chat.mcps == nil)
    }

    @Test("Chat skips a malformed message but keeps the valid ones")
    func chatSkipsMalformedMessage() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","messages":[
          {"id":"00000000-0000-0000-0000-000000000010","role":"user","content":"first","timestamp":1700000000},
          "not even an object",
          {"id":"00000000-0000-0000-0000-000000000011","role":"assistant","content":"second","timestamp":1700000010}
        ]}
        """.data(using: .utf8)!
        let chat = try JSONDecoder().decode(Chat.self, from: json)
        #expect(chat.messages.count == 2)
        #expect(chat.messages.map(\.content) == ["first", "second"])
    }

    @Test("ChatMessage falls back to defaults for wrong-typed required fields")
    func messageToleratesWrongTypes() throws {
        // id is a number, role is unknown, content is a number, timestamp is a
        // string — none match, but the message still decodes with defaults.
        let json = """
        {"id":123,"role":"bogus","content":456,"timestamp":"notadate"}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(ChatMessage.self, from: json)
        #expect(msg.role == .user)
        #expect(msg.content == "")
        #expect(msg.thinking == nil)
    }

    @Test("ChatMessage decodes an empty object with defaults")
    func messageDecodesEmptyObject() throws {
        let msg = try JSONDecoder().decode(ChatMessage.self, from: "{}".data(using: .utf8)!)
        #expect(msg.role == .user)
        #expect(msg.content == "")
        #expect(msg.toolCalls == nil)
    }

    @Test("ToolResult falls back to defaults when fields are missing")
    func toolResultToleratesMissingFields() throws {
        let result = try JSONDecoder().decode(ToolResult.self, from: "{}".data(using: .utf8)!)
        #expect(result.callID == "")
        #expect(result.content == "")
        #expect(result.isError == false)
        #expect(result.isStreaming == false)
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

    @Test("lastActivity(fallback:) uses the fallback for an empty chat")
    func lastActivityFallbackEmpty() {
        let fallback = Date(timeIntervalSince1970: 9_000)
        #expect(Fixtures.chat(messages: []).lastActivity(fallback: fallback) == fallback)
    }

    @Test("lastActivity(fallback:) uses the last message timestamp when present")
    func lastActivityFallbackWithMessages() {
        let ts = Date(timeIntervalSince1970: 5_000)
        let fallback = Date(timeIntervalSince1970: 9_000)
        let chat = Fixtures.chat(messages: [Fixtures.message(role: .user, content: "x", timestamp: ts)])
        #expect(chat.lastActivity(fallback: fallback) == ts)
    }

    // MARK: - Chat archive field

    @Test("Chat archive defaults to nil when absent in JSON")
    func chatArchiveDefaultsNil() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","messages":[]}
        """.data(using: .utf8)!
        let chat = try JSONDecoder().decode(Chat.self, from: json)
        #expect(chat.archive == nil)
    }

    @Test("Chat archive round-trips through JSON")
    func chatArchiveRoundTrip() throws {
        let original = Fixtures.chat(archive: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Chat.self, from: data)
        #expect(decoded.archive == true)
        #expect(decoded == original)
    }

    @Test("Chat archive decodes a false value")
    func chatArchiveDecodesFalse() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","messages":[],"archive":false}
        """.data(using: .utf8)!
        let chat = try JSONDecoder().decode(Chat.self, from: json)
        #expect(chat.archive == false)
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

    // MARK: - Role projection

    @Test("effectiveRoleName prefers the live chat's role")
    func effectiveRoleNameLoaded() {
        let rec = ChatRecord(filename: "a.json", chat: Fixtures.chat(role: "Assistant"), cachedRole: "Developer")
        #expect(rec.effectiveRoleName == "Assistant")
    }

    @Test("effectiveRoleName falls back to the cached role when unloaded")
    func effectiveRoleNameUnloaded() {
        let rec = ChatRecord(filename: "a.json", chat: nil, cachedRole: "Developer")
        #expect(rec.effectiveRoleName == "Developer")
    }

    @Test("effectiveRoleName is nil with neither live nor cached role")
    func effectiveRoleNameNone() {
        #expect(ChatRecord(filename: "a.json").effectiveRoleName == nil)
    }

    @Test("ChatSummary carries the effective role name")
    func summaryRoleName() {
        let loaded = ChatSummary(record: ChatRecord(filename: "a.json", chat: Fixtures.chat(role: "Assistant")))
        #expect(loaded.roleName == "Assistant")
        let cached = ChatSummary(record: ChatRecord(filename: "a.json", chat: nil, cachedRole: "Developer"))
        #expect(cached.roleName == "Developer")
        let none = ChatSummary(record: ChatRecord(filename: "a.json"))
        #expect(none.roleName == nil)
    }

    // MARK: - Archive projection

    @Test("isArchived prefers the live chat's archive flag")
    func isArchivedLoaded() {
        let rec = ChatRecord(filename: "a.json", chat: Fixtures.chat(archive: true), cachedArchive: false)
        #expect(rec.isArchived == true)
    }

    @Test("isArchived falls back to the cached flag when unloaded")
    func isArchivedUnloaded() {
        let rec = ChatRecord(filename: "a.json", chat: nil, cachedArchive: true)
        #expect(rec.isArchived == true)
    }

    @Test("isArchived is false by default")
    func isArchivedDefault() {
        #expect(ChatRecord(filename: "a.json").isArchived == false)
    }

    @Test("ChatSummary carries the archived flag")
    func summaryArchived() {
        let loaded = ChatSummary(record: ChatRecord(filename: "a.json", chat: Fixtures.chat(archive: true)))
        #expect(loaded.isArchived == true)
        let cached = ChatSummary(record: ChatRecord(filename: "a.json", chat: nil, cachedArchive: true))
        #expect(cached.isArchived == true)
        let none = ChatSummary(record: ChatRecord(filename: "a.json"))
        #expect(none.isArchived == false)
    }

    // MARK: - sortKey

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

    @Test("sortKey uses cached last-activity time when unloaded")
    func sortKeyUnloaded() {
        let activity = Date(timeIntervalSince1970: 5_555)
        let rec = ChatRecord(filename: "a.json", chat: nil, cachedLastActivity: activity)
        #expect(rec.sortKey == activity)
    }

    @Test("sortKey falls back to distantPast when unloaded with no cached activity")
    func sortKeyUnloadedEmpty() {
        let rec = ChatRecord(filename: "a.json", chat: nil)
        #expect(rec.sortKey == .distantPast)
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

    // MARK: - Tool-call approval

    @Test("ToolCall defaults pendingApproval to false")
    func toolCallDefaultPending() {
        let call = ToolCall(id: "call_1", name: "calc", arguments: "{}")
        #expect(call.pendingApproval == false)
    }

    @Test("ToolCall decodes legacy JSON without pendingApproval as false")
    func toolCallDecodesLegacyJSON() throws {
        // JSON as written by older app versions (no pendingApproval key).
        let json = #"{"id":"call_1","name":"calc","arguments":"{}"}"#.data(using: .utf8)!
        let call = try JSONDecoder().decode(ToolCall.self, from: json)
        #expect(call.id == "call_1")
        #expect(call.pendingApproval == false)
    }

    @Test("ToolCall round-trips pendingApproval through JSON")
    func toolCallRoundTripsPending() throws {
        let original = ToolCall(id: "call_1", name: "calc", arguments: "{}", pendingApproval: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: data)
        #expect(decoded == original)
        #expect(decoded.pendingApproval == true)
    }

    @Test("ToolResult decodes legacy JSON without isDenied/isStreaming as false")
    func toolResultDecodesLegacyJSON() throws {
        let json = #"{"callID":"call_1","content":"4","isError":false}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(ToolResult.self, from: json)
        #expect(r.isDenied == false)
        #expect(r.isStreaming == false)
    }

    @Test("ToolResult round-trips isDenied through JSON")
    func toolResultRoundTripsDenied() throws {
        let original = ToolResult(callID: "call_1", content: "denied", isError: true, isDenied: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(decoded == original)
        #expect(decoded.isDenied == true)
    }

    @Test("denialMessage is generic for an empty reason")
    func denialMessageEmpty() {
        #expect(ToolApproval.denialMessage(for: "") == "User denied this tool call")
    }

    @Test("denialMessage is generic for a whitespace-only reason")
    func denialMessageWhitespace() {
        #expect(ToolApproval.denialMessage(for: "   \n\t ") == "User denied this tool call")
    }

    @Test("denialMessage trims and includes a provided reason")
    func denialMessageWithReason() {
        let msg = ToolApproval.denialMessage(for: "  not allowed now  ")
        #expect(msg == "User denied this tool call with the following reason: not allowed now")
    }

    // MARK: - finalizeStoppedTurn

    private func assistantWithCalls(_ ids: [String]) -> ChatMessage {
        Fixtures.message(
            role: .assistant,
            content: "",
            toolCalls: ids.map { ToolCall(id: $0, name: "tool", arguments: "{}") }
        )
    }

    private func toolMessage(_ callID: String) -> ChatMessage {
        Fixtures.message(
            role: .tool,
            content: "",
            toolResults: [ToolResult(callID: callID, content: "ok", isError: false)]
        )
    }

    private func cancelledResults(_ messages: [ChatMessage]) -> [ToolResult] {
        messages.flatMap { $0.toolResults ?? [] }.filter(\.isCancelled)
    }

    @Test("stop with an empty placeholder assistant removes it")
    func finalizeRemovesEmptyPlaceholder() {
        var messages = [
            Fixtures.message(role: .user, content: "hi"),
            Fixtures.message(role: .assistant, content: "")
        ]
        messages.finalizeStoppedTurn()
        #expect(messages.count == 1)
        #expect(messages.last?.role == .user)
    }

    @Test("stop keeps an assistant message with partial content")
    func finalizeKeepsPartialContent() {
        var messages = [
            Fixtures.message(role: .user, content: "hi"),
            Fixtures.message(role: .assistant, content: "partial ans")
        ]
        messages.finalizeStoppedTurn()
        #expect(messages.count == 2)
        #expect(messages.last?.content == "partial ans")
    }

    @Test("stop keeps an assistant message with only thinking")
    func finalizeKeepsThinkingOnly() {
        var messages = [
            Fixtures.message(role: .user, content: "hi"),
            Fixtures.message(role: .assistant, content: "", thinking: "reasoning…")
        ]
        messages.finalizeStoppedTurn()
        #expect(messages.count == 2)
    }

    @Test("stop keeps an assistant message with an error")
    func finalizeKeepsError() {
        var messages = [
            Fixtures.message(role: .user, content: "hi"),
            Fixtures.message(role: .assistant, content: "", error: "boom")
        ]
        messages.finalizeStoppedTurn()
        #expect(messages.count == 2)
        #expect(messages.last?.error == "boom")
    }

    @Test("stop during approval keeps the call and synthesizes a cancelled result")
    func finalizeSynthesizesCancelledResult() {
        var messages = [
            Fixtures.message(role: .user, content: "hi"),
            assistantWithCalls(["call_1"])
        ]
        messages[1].toolCalls?[0].pendingApproval = true
        messages.finalizeStoppedTurn()
        // The assistant message stays (the model asked for the call), a
        // cancelled result is appended, and no approval state lingers.
        #expect(messages.count == 3)
        #expect(messages[1].toolCalls?.count == 1)
        #expect(messages[1].toolCalls?[0].pendingApproval == false)
        let cancelled = cancelledResults(messages)
        #expect(cancelled.count == 1)
        #expect(cancelled[0].callID == "call_1")
        #expect(cancelled[0].isError == true)
        #expect(cancelled[0].content == [ChatMessage].cancelledToolResultContent)
    }

    @Test("stop mid-execution keeps real results and cancels only the missing ones")
    func finalizeKeepsExecutedResults() {
        var messages = [
            Fixtures.message(role: .user, content: "hi"),
            assistantWithCalls(["call_1", "call_2"]),
            toolMessage("call_1")
        ]
        messages.finalizeStoppedTurn()
        // The executed call's real result stays; only call_2 is cancelled.
        #expect(messages.count == 4)
        #expect(messages[2].toolResults?.first?.content == "ok")
        #expect(messages[2].toolResults?.first?.isCancelled == false)
        let cancelled = cancelledResults(messages)
        #expect(cancelled.count == 1)
        #expect(cancelled[0].callID == "call_2")
    }

    @Test("stop clears the diff preview of a call that never ran")
    func finalizeClearsDiffOfUnexecutedCall() {
        var messages = [
            Fixtures.message(role: .user, content: "hi"),
            assistantWithCalls(["call_1"])
        ]
        messages[1].toolCalls?[0].diff = "@@ diff preview @@"
        messages.finalizeStoppedTurn()
        #expect(messages[1].toolCalls?[0].diff == nil)
    }

    @Test("stop while tool-call arguments are still streaming drops the truncated call")
    func finalizeDropsTruncatedCalls() {
        var messages = [
            Fixtures.message(role: .user, content: "hi"),
            Fixtures.message(
                role: .assistant,
                content: "",
                toolCalls: [ToolCall(id: "", name: "", arguments: "{\"path\":")]
            )
        ]
        messages.finalizeStoppedTurn()
        // The call never became executable and nothing else streamed, so the
        // message is now an empty placeholder and is removed too.
        #expect(messages.count == 1)
        #expect(messages.last?.role == .user)
    }

    @Test("stop drops truncated calls but keeps the message's streamed content")
    func finalizeDropsTruncatedCallsKeepsContent() {
        var messages = [
            Fixtures.message(role: .user, content: "hi"),
            Fixtures.message(
                role: .assistant,
                content: "Let me check that file.",
                toolCalls: [ToolCall(id: "", name: "", arguments: "{\"path\":")]
            )
        ]
        messages.finalizeStoppedTurn()
        #expect(messages.count == 2)
        #expect(messages[1].content == "Let me check that file.")
        #expect(messages[1].toolCalls == nil)
    }

    @Test("stop after a complete tool turn followed by an empty placeholder keeps the turn")
    func finalizeKeepsCompleteTurnRemovesPlaceholder() {
        var messages = [
            Fixtures.message(role: .user, content: "hi"),
            assistantWithCalls(["call_1"]),
            toolMessage("call_1"),
            Fixtures.message(role: .assistant, content: "")
        ]
        messages.finalizeStoppedTurn()
        #expect(messages.count == 3)
        #expect(messages.last?.role == .tool)
        #expect(cancelledResults(messages).isEmpty)
    }

    @Test("stop finalizes only the last incomplete loop, keeping earlier completed loops")
    func finalizeKeepsEarlierCompleteLoops() {
        var messages = [
            Fixtures.message(role: .user, content: "hi"),
            assistantWithCalls(["call_1"]),
            toolMessage("call_1"),
            Fixtures.message(role: .assistant, content: "intermediate answer"),
            assistantWithCalls(["call_2"]),
            toolMessage("call_2"),
            Fixtures.message(role: .assistant, content: "done")
        ]
        messages.finalizeStoppedTurn()
        // Everything is complete — nothing changes.
        #expect(messages.count == 7)
        #expect(cancelledResults(messages).isEmpty)

        var stopped = [
            Fixtures.message(role: .user, content: "hi"),
            assistantWithCalls(["call_1"]),
            toolMessage("call_1"),
            Fixtures.message(role: .assistant, content: "intermediate answer"),
            assistantWithCalls(["call_2"])
        ]
        stopped.finalizeStoppedTurn()
        // Earlier loops are untouched; only call_2 gets a cancelled result.
        #expect(stopped.count == 6)
        #expect(stopped[3].content == "intermediate answer")
        let cancelled = cancelledResults(stopped)
        #expect(cancelled.count == 1)
        #expect(cancelled[0].callID == "call_2")
    }

    @Test("stop on a chat with no assistant messages is a no-op")
    func finalizeNoAssistantNoOp() {
        var messages = [Fixtures.message(role: .user, content: "hi")]
        messages.finalizeStoppedTurn()
        #expect(messages.count == 1)
    }

    @Test("ToolResult round-trips isCancelled through JSON")
    func toolResultRoundTripsCancelled() throws {
        let original = ToolResult(callID: "call_1", content: "cancelled", isError: true, isCancelled: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(decoded == original)
        #expect(decoded.isCancelled == true)
    }

    @Test("ToolResult decodes legacy JSON without isCancelled as false")
    func toolResultDecodesLegacyCancelled() throws {
        let json = #"{"callID":"call_1","content":"4","isError":false}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(ToolResult.self, from: json)
        #expect(r.isCancelled == false)
    }
}

} // extension AllAppTests
