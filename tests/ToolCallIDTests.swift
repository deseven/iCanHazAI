import Testing
import Foundation
@testable import iCanHazAI

/// Regression tests for the tool-call ID collision bug: providers only
/// guarantee per-response tool call ID uniqueness (Kimi-style `name:index`
/// IDs repeat every turn), and the engine used to correlate results by
/// `callID` across the whole chat — so a repeated ID made a later turn's
/// result overwrite an earlier turn's persisted result message in place,
/// silently dropping it from the chat JSON.
extension AllAppTests {
    @Suite("Tool call ID uniqueness")
    struct ToolCallIDTests {

        // MARK: - [ToolCall].ensuringUniqueCallIDs

        @Test("chat-wide unique provider IDs are preserved")
        func uniqueIDsPreserved() {
            let calls = [
                ToolCall(id: "chatcmpl-tool-aaa", name: "ls", arguments: "{}"),
                ToolCall(id: "chatcmpl-tool-bbb", name: "read_file", arguments: "{}"),
            ]
            let result = calls.ensuringUniqueCallIDs(existingIDs: ["chatcmpl-tool-zzz"])
            #expect(result.map(\.id) == ["chatcmpl-tool-aaa", "chatcmpl-tool-bbb"])
        }

        @Test("ID colliding with a previous turn is rewritten")
        func collisionWithHistoryRewritten() {
            // Kimi-style IDs: every turn restarts at `name:0`.
            let calls = [
                ToolCall(id: "ls:0", name: "ls", arguments: "{}"),
                ToolCall(id: "find_text:1", name: "find_text", arguments: "{}"),
            ]
            let result = calls.ensuringUniqueCallIDs(existingIDs: ["ls:0", "find_text:1"])
            #expect(result.count == 2)
            for call in result {
                #expect(!call.id.isEmpty)
                #expect(call.id != "ls:0")
                #expect(call.id != "find_text:1")
            }
            // Names/arguments untouched — only the ID changes.
            #expect(result.map(\.name) == ["ls", "find_text"])
        }

        @Test("only the colliding IDs are rewritten")
        func onlyCollisionsRewritten() {
            let calls = [
                ToolCall(id: "ls:0", name: "ls", arguments: "{}"),
                ToolCall(id: "read_file:1", name: "read_file", arguments: "{}"),
            ]
            let result = calls.ensuringUniqueCallIDs(existingIDs: ["ls:0"])
            #expect(result[0].id != "ls:0")
            #expect(result[1].id == "read_file:1")
        }

        @Test("duplicate IDs within the same batch are disambiguated")
        func withinBatchDuplicates() {
            let calls = [
                ToolCall(id: "x:0", name: "a", arguments: "{}"),
                ToolCall(id: "x:0", name: "b", arguments: "{}"),
            ]
            let result = calls.ensuringUniqueCallIDs(existingIDs: [])
            #expect(result[0].id != result[1].id)
            #expect(Set(result.map(\.id)).count == 2)
        }

        @Test("empty IDs get a generated ID")
        func emptyIDsGenerated() {
            let calls = [
                ToolCall(id: "", name: "ls", arguments: "{}"),
                ToolCall(id: "", name: "ls", arguments: "{}"),
            ]
            let result = calls.ensuringUniqueCallIDs(existingIDs: [])
            #expect(result.allSatisfy { !$0.id.isEmpty })
            #expect(result[0].id != result[1].id)
        }

        @Test("generated IDs never collide with existing ones")
        func generatedIDsAvoidExisting() {
            // Extinguish any chance of a generated `call_XXXXXXXX` colliding
            // by repeatedly uniquing batches against a growing history.
            var existing: Set<String> = []
            for _ in 0..<50 {
                let batch = [ToolCall(id: "ls:0", name: "ls", arguments: "{}")]
                let result = batch.ensuringUniqueCallIDs(existingIDs: existing)
                #expect(result.count == 1)
                #expect(!existing.contains(result[0].id))
                existing.insert(result[0].id)
            }
        }

        // MARK: - Chat.activeToolResultMessageID

        @Test("finds a result message in the current turn")
        func findsCurrentTurnResult() {
            let resultMsg = ChatMessage(role: .tool, content: "", toolResults: [ToolResult(callID: "ls:0", content: "partial", isError: false, isStreaming: true)])
            let chat = Fixtures.chat(messages: [
                ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "ls:0", name: "ls", arguments: "{}")]),
                resultMsg,
            ])
            #expect(chat.activeToolResultMessageID(callID: "ls:0") == resultMsg.id)
        }

        @Test("a previous turn's result with the same callID is not touched")
        func previousTurnResultIgnored() {
            // The data-loss scenario: turn 2 reuses turn 1's provider-issued
            // ID. Looking up the ID must not find turn 1's persisted result.
            let chat = Fixtures.chat(messages: [
                ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "ls:0", name: "ls", arguments: "{}")]),
                ChatMessage(role: .tool, content: "", toolResults: [ToolResult(callID: "ls:0", content: "turn 1 result", isError: false)]),
                ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "ls:0", name: "ls", arguments: "{}")]),
            ])
            #expect(chat.activeToolResultMessageID(callID: "ls:0") == nil)
        }

        @Test("when both turns carry the ID, the current turn's message wins")
        func currentTurnWins() {
            let turn2 = ChatMessage(role: .tool, content: "", toolResults: [ToolResult(callID: "ls:0", content: "turn 2", isError: false, isStreaming: true)])
            let chat = Fixtures.chat(messages: [
                ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "ls:0", name: "ls", arguments: "{}")]),
                ChatMessage(role: .tool, content: "", toolResults: [ToolResult(callID: "ls:0", content: "turn 1", isError: false)]),
                ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "ls:0", name: "ls", arguments: "{}")]),
                turn2,
            ])
            #expect(chat.activeToolResultMessageID(callID: "ls:0") == turn2.id)
        }

        @Test("no assistant message means the whole history is one turn")
        func noAssistantMessage() {
            let resultMsg = ChatMessage(role: .tool, content: "", toolResults: [ToolResult(callID: "ls:0", content: "x", isError: false)])
            let chat = Fixtures.chat(messages: [resultMsg])
            #expect(chat.activeToolResultMessageID(callID: "ls:0") == resultMsg.id)
            #expect(chat.activeToolResultMessageID(callID: "nope:0") == nil)
        }
    }
}
