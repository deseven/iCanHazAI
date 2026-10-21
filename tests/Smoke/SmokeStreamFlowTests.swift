import Foundation
import Testing

@testable import iCanHazAI

// The normal request lifecycle through the engine: history, failures and retries, the tool loop and approval.
extension AllSmokeTests {
    @Suite("Stream flow")
    struct SmokeStreamFlowTests {

        // MARK: - History

        @Test("a second turn sends the whole history")
        func secondTurn() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                try await fx.mock.enqueue(.deepseek, .text("First answer"))
                await fx.send(chat, "one")
                try await fx.waitUntilIdle(chat)
                try await fx.mock.enqueue(.deepseek, .text("Second answer"))
                await fx.send(chat, "two")
                try await fx.waitUntilIdle(chat)

                let requests = try await fx.mock.chatRequests(.deepseek)
                #expect(requests.count == 2)
                #expect(requests[0].transcript == [SmokeFixture.systemLine, "user: one"])
                #expect(
                    requests[1].transcript == [
                        SmokeFixture.systemLine, "user: one", "assistant: First answer", "user: two",
                    ])
                #expect(
                    try fx.persisted(chat).activeMessages.map(\.content) == [
                        "one", "First answer", "two", "Second answer",
                    ])
            }
        }

        // MARK: - Failures

        @Test("a normal stop with no content is reported as an empty response")
        func emptyResponse() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                try await fx.mock.enqueue(.deepseek, .finish("stop"))
                await fx.send(chat, "hello")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError?.contains("empty response") == true)
                #expect(record.chat?.activeMessages.last?.error != nil)
            }
        }

        @Test("running out of tokens before any output is reported as a token limit")
        func tokenLimit() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                try await fx.mock.enqueue(.deepseek, .finish("max_tokens"))
                await fx.send(chat, "hello")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError?.contains("token limit") == true)
            }
        }

        @Test("a connection reset mid-answer keeps what arrived, reports the error and is not retried")
        func droppedConnection() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                // The delay lets the app read the text before the connection is cut.
                try await fx.mock.enqueue(.deepseek, .text("part of the answer"), .delay(ms: 150), .drop)
                await fx.send(chat, "hello")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError != nil)
                #expect(record.chat?.activeMessages.last?.content == "part of the answer")
                #expect(try await fx.mock.chatRequests(.deepseek).count == 1)
            }
        }

        @Test("a stream closed cleanly mid-answer ends the turn with what arrived")
        func truncatedStream() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                try await fx.mock.enqueue(.deepseek, .text("part of the answer"), .delay(ms: 150), .close)
                await fx.send(chat, "hello")
                let record = try await fx.waitUntilIdle(chat)

                // URLSession reports a body cut short at a chunk boundary as a normal end, so the app can't
                // tell it from a finished answer; what matters is that the turn ends cleanly.
                #expect(record.chat?.activeMessages.last?.content == "part of the answer")
                #expect(!record.isStreaming)
                #expect(try await fx.mock.chatRequests(.deepseek).count == 1)
            }
        }

        @Test("a server error before any output is retried once")
        func retryBeforeOutput() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                try await fx.mock.enqueue(.deepseek, .httpError(500, message: "boom"))
                try await fx.mock.enqueue(.deepseek, .text("recovered"))
                await fx.send(chat, "hello")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                #expect(record.chat?.activeMessages.last?.content == "recovered")
                #expect(try await fx.mock.chatRequests(.deepseek).count == 2)
            }
        }

        @Test("sending after an error drops the errored placeholder")
        func sendAfterError() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                try await fx.mock.enqueue(.deepseek, .httpError(429, message: "slow down"))
                await fx.send(chat, "one")
                try await fx.waitUntilIdle(chat)
                try await fx.mock.enqueue(.deepseek, .text("fine"))
                await fx.send(chat, "two")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .user, .assistant])
                #expect(messages.map(\.content) == ["one", "two", "fine"])
                #expect(
                    try await fx.mock.chatRequests(.deepseek).last?.transcript == [
                        SmokeFixture.systemLine, "user: one", "user: two",
                    ])
            }
        }

        // MARK: - Tool loop

        @Test("a chain of tool calls ends in an answer", arguments: [SmokeProvider.deepseek, .anthropic])
        func toolChain(_ sp: SmokeProvider) async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(sp, tools: .calcAutoAllow)
                try await fx.mock.enqueue(
                    sp.channel, .toolCall(name: "calc", arguments: Calc.call("1+1"), id: "call_1"))
                try await fx.mock.enqueue(
                    sp.channel, .toolCall(name: "calc", arguments: Calc.call("2+2"), id: "call_2"))
                try await fx.mock.enqueue(sp.channel, .text("Done"))
                await fx.send(chat, "go")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant, .tool, .assistant])
                #expect(messages[2].toolResults?.first?.trimmed == "2")
                #expect(messages[4].toolResults?.first?.trimmed == "4")
                #expect(messages[5].content == "Done")
                // The mock checks every follow-up for provider-valid tool pairing, so three accepted
                // requests also prove the history shape.
                #expect(try await fx.mock.chatRequests(sp.channel).count == 3)
            }
        }

        @Test(
            "several tool calls in one response run in order and are answered together",
            arguments: [SmokeProvider.deepseek, .anthropic])
        func parallelCalls(_ sp: SmokeProvider) async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(sp, tools: .calcAutoAllow)
                try await fx.mock.enqueue(
                    sp.channel, .toolCall(name: "calc", arguments: Calc.call("1+1"), id: "call_a"),
                    .toolCall(name: "calc", arguments: Calc.call("3*3"), id: "call_b"))
                try await fx.mock.enqueue(sp.channel, .text("Both done"))
                await fx.send(chat, "go")
                let record = try await fx.waitUntilIdle(chat)

                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant, .tool, .tool, .assistant])
                #expect(messages[1].toolCalls?.map(\.id) == ["call_a", "call_b"])
                #expect(messages[2].toolResults?.first?.callID == "call_a")
                #expect(messages[2].toolResults?.first?.trimmed == "2")
                #expect(messages[3].toolResults?.first?.callID == "call_b")
                #expect(messages[3].toolResults?.first?.trimmed == "9")
                #expect(try await fx.mock.chatRequests(sp.channel).count == 2)
            }
        }

        @Test("an unknown tool yields an error result for the model, not a broken loop")
        func unknownTool() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .calcAutoAllow)
                try await fx.mock.enqueue(.deepseek, .toolCall(name: "no_such_tool", id: "call_x"))
                try await fx.mock.enqueue(.deepseek, .text("Recovered"))
                await fx.send(chat, "go")
                let record = try await fx.waitUntilIdle(chat)

                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant])
                let result = try #require(messages[2].toolResults?.first)
                #expect(result.isError)
                #expect(result.content.contains("No tool found"))
                #expect(messages[3].content == "Recovered")
                let sent = try await fx.mock.chatRequests(.deepseek)
                let followUp = try #require(sent.last)
                #expect(followUp.transcript.last?.hasPrefix("tool[call_x] No tool found") == true)
            }
        }

        @Test("arguments that aren't valid JSON yield an error result for the model")
        func badArguments() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .calcAutoAllow)
                try await fx.mock.enqueue(.deepseek, .toolCall(name: "calc", arguments: "{not json", id: "call_bad"))
                try await fx.mock.enqueue(.deepseek, .text("Recovered"))
                await fx.send(chat, "go")
                let record = try await fx.waitUntilIdle(chat)

                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant])
                #expect(messages[2].toolResults?.first?.isError == true)
                #expect(messages[3].content == "Recovered")
            }
        }

        // MARK: - Approval

        private func approvalChat(_ fx: SmokeFixture, call: String = "2+2") async throws -> (
            chat: String, callID: String
        ) {
            let chat = try await fx.start(tools: .calcApproval)
            try await fx.mock.enqueue(.deepseek, .toolCall(name: "calc", arguments: Calc.call(call), id: "call_ask"))
            await fx.send(chat, "go")
            let callID = try await fx.waitForApproval(chat)
            #expect(callID == "call_ask")
            return (chat, callID)
        }

        @Test("a tool call waits for approval, and allowing it runs the tool")
        func allowOnce() async throws {
            try await SmokeFixture.run { fx in
                let (chat, callID) = try await approvalChat(fx)
                // Nothing ran while the question was open.
                let open = try #require(await fx.record(chat)?.chat)
                #expect(open.activeMessages.map(\.role) == [.user, .assistant])
                #expect(try await fx.mock.chatRequests(.deepseek).count == 1)

                try await fx.mock.enqueue(.deepseek, .text("It is 4"))
                await fx.engine.resolveToolCallApproval(callID: callID, approval: .allow)
                let record = try await fx.waitUntilIdle(chat)

                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant])
                #expect(messages[2].toolResults?.first?.trimmed == "4")
                #expect(try fx.persisted(chat).autoAllow == nil)
            }
        }

        @Test("denying a tool call tells the model why and the loop continues")
        func deny() async throws {
            try await SmokeFixture.run { fx in
                let (chat, callID) = try await approvalChat(fx)
                try await fx.mock.enqueue(.deepseek, .text("Understood"))
                await fx.engine.resolveToolCallApproval(callID: callID, approval: .deny(reason: "not now"))
                let record = try await fx.waitUntilIdle(chat)

                let messages = try #require(record.chat).activeMessages
                let result = try #require(messages[2].toolResults?.first)
                #expect(result.isDenied)
                #expect(result.isError)
                #expect(result.content.contains("not now"))
                #expect(messages.last?.content == "Understood")
                let sent = try await fx.mock.chatRequests(.deepseek)
                let followUp = try #require(sent.last)
                #expect(followUp.transcript.last?.contains("not now") == true)
            }
        }

        @Test("allowing for the chat is remembered, so the next call doesn't ask")
        func allowForChat() async throws {
            try await SmokeFixture.run { fx in
                let (chat, callID) = try await approvalChat(fx)
                try await fx.mock.enqueue(.deepseek, .text("First done"))
                await fx.engine.allowToolCallForChat(callID: callID)
                try await fx.waitUntilIdle(chat)
                #expect(try fx.persisted(chat).autoAllow == ["calc"])

                // The same tool again: if it asked, this would sit at the approval and time out.
                try await fx.mock.enqueue(
                    .deepseek, .toolCall(name: "calc", arguments: Calc.call("5*5"), id: "call_again"))
                try await fx.mock.enqueue(.deepseek, .text("Second done"))
                await fx.send(chat, "again")
                let record = try await fx.waitUntilIdle(chat)

                let messages = try #require(record.chat).activeMessages
                #expect(messages.last?.content == "Second done")
                #expect(messages.flatMap { $0.toolResults ?? [] }.map(\.trimmed) == ["4", "25"])
            }
        }
    }
}
