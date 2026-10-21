import Foundation
import Testing

@testable import iCanHazAI

// Stop, the stop-then-send race (`awaitStreamUnwind`) and the message queue. The mock's gates park a response
// mid-stream, so each scenario is deterministic: nothing here waits for time to pass.
extension AllSmokeTests {
    @Suite("Stop and queue")
    struct SmokeStopQueueTests {

        /// Long enough to be published at once: the app buffers shorter text (under 10 characters) until the
        /// next chunk arrives, so a stream parked right after it would not show it yet.
        private static let partial = "Partial answer"
        private static let full = "Partial answer finished"

        /// Starts a stream whose answer reads `partial` and is then parked on gate `g`. Returns once the app
        /// has that text, so a stop here has a known partial answer.
        private func parkedStream(
            _ fx: SmokeFixture, _ chat: String, extra: [MockStep] = [.text(" finished")]
        ) async throws -> MockRequest {
            try await fx.mock.enqueue(.deepseek, [.text(Self.partial), .gate("g")] + extra)
            await fx.send(chat, "go")
            let request = try await fx.mock.waitForChatRequest(.deepseek, index: 0, atGate: "g")
            try await fx.waitForAnswer(chat, Self.partial)
            return request
        }

        // MARK: - Stop

        @Test("stopping mid-stream keeps the partial answer, saves it and aborts the HTTP call")
        func stopMidStream() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                let request = try await parkedStream(fx, chat)

                await fx.engine.stopStreaming(filename: chat)
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                #expect(record.chat?.activeMessages.map(\.content) == ["go", Self.partial])
                #expect(try fx.persisted(chat).activeMessages.map(\.content) == ["go", Self.partial])
                try await fx.mock.waitForDisconnect(seq: request.seq)

                // The chat is usable afterwards, and the follow-up carries the partial answer.
                try await fx.mock.enqueue(.deepseek, .text("Back"))
                await fx.send(chat, "again")
                try await fx.waitUntilIdle(chat)
                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(
                    sent.last?.transcript == [
                        SmokeFixture.systemLine, "user: go", "assistant: \(Self.partial)", "user: again",
                    ])
            }
        }

        @Test("stopping while a tool call awaits approval cancels it and leaves a valid history")
        func stopDuringApproval() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .calcApproval)
                try await fx.mock.enqueue(
                    .deepseek, .toolCall(name: "calc", arguments: Calc.call("2+2"), id: "call_ask"))
                await fx.send(chat, "go")
                _ = try await fx.waitForApproval(chat)

                await fx.engine.stopStreaming(filename: chat)
                let record = try await fx.waitUntilIdle(chat)

                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant, .tool])
                let result = try #require(messages[2].toolResults?.first)
                #expect(result.isCancelled)
                #expect(result.callID == "call_ask")

                // The mock rejects a dangling tool call, so an accepted request proves the history is valid.
                try await fx.mock.enqueue(.deepseek, .text("ok"))
                await fx.send(chat, "next")
                let after = try await fx.waitUntilIdle(chat)
                #expect(after.lastError == nil)
                #expect(after.chat?.activeMessages.last?.content == "ok")
            }
        }

        @Test("stopping while a tool runs adds no result after the stop")
        func stopDuringTool() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .utilsAutoAllow)
                try await fx.mock.enqueue(
                    .deepseek, .toolCall(name: "sleep", arguments: #"{"seconds":30}"#, id: "call_sleep"))
                await fx.send(chat, "go")
                // Running: the call is on the assistant message and no result exists yet.
                try await fx.wait(for: chat, "the sleep tool call to be issued") { record in
                    record.chat?.activeMessages.last?.toolCalls?.first?.id == "call_sleep"
                }

                await fx.engine.stopStreaming(filename: chat)
                let record = try await fx.waitUntilIdle(chat, timeout: 10)

                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant, .tool])
                let result = try #require(messages[2].toolResults?.first)
                #expect(result.callID == "call_sleep")
                #expect(result.isError)
                #expect(try await fx.mock.chatRequests(.deepseek).count == 1)
            }
        }

        @Test("stop-after-iteration finishes the tool turn, sends no follow-up and carries the results forward")
        func stopAfterIteration() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .calcAutoAllow)
                try await fx.mock.enqueue(
                    .deepseek, .text("Calling"), .gate("g"),
                    .toolCall(name: "calc", arguments: Calc.call("2+2"), id: "call_1"))
                await fx.send(chat, "go")
                try await fx.mock.waitForChatRequest(.deepseek, index: 0, atGate: "g")

                await fx.engine.stopStreamingAfterIteration(filename: chat)
                try await fx.wait(for: chat, "the stop-after-iteration flag") { $0.stopAfterIteration }
                try await fx.mock.release("g")
                let record = try await fx.waitUntilIdle(chat)

                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant, .tool])
                #expect(messages[2].toolResults?.first?.trimmed == "4")
                #expect(record.lastError == nil)
                #expect(try await fx.mock.chatRequests(.deepseek).count == 1)

                try await fx.mock.enqueue(.deepseek, .text("Carried on"))
                await fx.send(chat, "go on")
                try await fx.waitUntilIdle(chat)
                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(
                    sent.last?.transcript == [
                        SmokeFixture.systemLine, "user: go", "assistant[calls call_1] Calling", "tool[call_1] 4",
                        "user: go on",
                    ])
            }
        }

        @Test("a hard stop clears a pending stop-after-iteration")
        func hardStopClearsStopAfterIteration() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                _ = try await parkedStream(fx, chat)

                await fx.engine.stopStreamingAfterIteration(filename: chat)
                try await fx.wait(for: chat, "the stop-after-iteration flag") { $0.stopAfterIteration }
                await fx.engine.stopStreaming(filename: chat)
                let record = try await fx.waitUntilIdle(chat)

                #expect(!record.stopAfterIteration)
            }
        }

        // MARK: - Stop, then send

        @Test("sending right after a stop waits for the old stream to unwind, then runs cleanly")
        func stopThenSend() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                let first = try await parkedStream(fx, chat)
                try await fx.mock.enqueue(.deepseek, .text("Second answer"))

                await fx.engine.stopStreaming(filename: chat)
                await fx.send(chat, "two")  // no waiting in between: this is the race
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                #expect(record.queuedMessages.isEmpty)
                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant, .user, .assistant])
                #expect(messages.map(\.content) == ["go", Self.partial, "two", "Second answer"])
                #expect(
                    try fx.persisted(chat).activeMessages.map(\.content) == [
                        "go", Self.partial, "two", "Second answer",
                    ])

                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(sent.count == 2)
                #expect(
                    sent[1].transcript == [
                        SmokeFixture.systemLine, "user: go", "assistant: \(Self.partial)", "user: two",
                    ])
                try await fx.mock.waitForDisconnect(seq: first.seq)
            }
        }

        @Test("retrying right after a stop waits for the unwind and re-sends the last user message")
        func stopThenRetry() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                _ = try await parkedStream(fx, chat)
                try await fx.mock.enqueue(.deepseek, .text("Retried"))

                await fx.engine.stopStreaming(filename: chat)
                await fx.engine.retryLastMessage(filename: chat)
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                #expect(record.chat?.activeMessages.map(\.content) == ["go", "Retried"])
                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(sent.last?.transcript == [SmokeFixture.systemLine, "user: go"])
            }
        }

        @Test("sending while a stream is live queues the message instead of starting a second stream")
        func sendDuringLiveStream() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                _ = try await parkedStream(fx, chat)

                await fx.send(chat, "queued by send")
                try await fx.waitForQueue(chat, count: 1)
                #expect(try await fx.mock.chatRequests(.deepseek).count == 1)

                try await fx.mock.enqueue(.deepseek, .text("Second"))
                try await fx.mock.release("g")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.queuedMessages.isEmpty)
                #expect(record.chat?.activeMessages.map(\.content) == ["go", Self.full, "queued by send", "Second"])
            }
        }

        // MARK: - Queue

        @Test("a message queued during a tool turn goes out after the tool results")
        func queueAtToolBoundary() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .calcAutoAllow)
                try await fx.mock.enqueue(
                    .deepseek, .text("Working"), .gate("g"),
                    .toolCall(name: "calc", arguments: Calc.call("2+2"), id: "call_q"))
                try await fx.mock.enqueue(.deepseek, .text("Done"))
                await fx.send(chat, "go")
                try await fx.mock.waitForChatRequest(.deepseek, index: 0, atGate: "g")

                await fx.engine.queueMessage(filename: chat, text: "also this", pendingAttachments: [])
                try await fx.waitForQueue(chat, count: 1)
                try await fx.mock.release("g")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.queuedMessages.isEmpty)
                #expect(record.chat?.activeMessages.map(\.role) == [.user, .assistant, .tool, .user, .assistant])
                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(
                    sent.last?.transcript == [
                        SmokeFixture.systemLine, "user: go", "assistant[calls call_q] Working", "tool[call_q] 4",
                        "user: also this",
                    ])
            }
        }

        @Test("a message queued during the final answer goes out in a request that contains that answer")
        func queueAtAnswerBoundary() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                _ = try await parkedStream(fx, chat)
                try await fx.mock.enqueue(.deepseek, .text("Second"))

                await fx.engine.queueMessage(filename: chat, text: "next question", pendingAttachments: [])
                try await fx.waitForQueue(chat, count: 1)
                try await fx.mock.release("g")
                try await fx.waitUntilIdle(chat)

                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(
                    sent.last?.transcript == [
                        SmokeFixture.systemLine, "user: go", "assistant: \(Self.full)", "user: next question",
                    ])
            }
        }

        @Test("several queued messages are combined into one user message")
        func queueCombines() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                _ = try await parkedStream(fx, chat)
                try await fx.mock.enqueue(.deepseek, .text("Second"))

                await fx.engine.queueMessage(filename: chat, text: "first extra", pendingAttachments: [])
                await fx.engine.queueMessage(filename: chat, text: "second extra", pendingAttachments: [])
                try await fx.waitForQueue(chat, count: 2)
                try await fx.mock.release("g")
                try await fx.waitUntilIdle(chat)

                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(sent.last?.transcript.last == "user: first extra\n\nsecond extra")
            }
        }

        @Test("queueing while idle sends right away")
        func queueWhileIdle() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                try await fx.mock.enqueue(.deepseek, .text("Hi"))

                await fx.engine.queueMessage(filename: chat, text: "direct", pendingAttachments: [])
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.chat?.activeMessages.map(\.content) == ["direct", "Hi"])
            }
        }

        @Test("discarding the queue sends nothing")
        func clearQueue() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                _ = try await parkedStream(fx, chat)

                await fx.engine.queueMessage(filename: chat, text: "never sent", pendingAttachments: [])
                try await fx.waitForQueue(chat, count: 1)
                await fx.engine.clearQueuedMessages(filename: chat)
                try await fx.waitForQueue(chat, count: 0)
                try await fx.mock.release("g")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.chat?.activeMessages.map(\.content) == ["go", Self.full])
                #expect(try await fx.mock.chatRequests(.deepseek).count == 1)
            }
        }

        @Test("a hard stop leaves the queue alone, and the next send folds it in")
        func stopKeepsQueue() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                _ = try await parkedStream(fx, chat)

                await fx.engine.queueMessage(filename: chat, text: "later", pendingAttachments: [])
                try await fx.waitForQueue(chat, count: 1)
                await fx.engine.stopStreaming(filename: chat)
                let stopped = try await fx.waitUntilIdle(chat)

                #expect(stopped.queuedMessages.map(\.text) == ["later"])
                #expect(try await fx.mock.chatRequests(.deepseek).count == 1)

                try await fx.mock.enqueue(.deepseek, .text("Folded"))
                await fx.send(chat, "now")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.queuedMessages.isEmpty)
                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(
                    sent.last?.transcript == [
                        SmokeFixture.systemLine, "user: go", "assistant: \(Self.partial)", "user: later\n\nnow",
                    ])
            }
        }

        // MARK: - Send immediately

        @Test("send-now stops the stream and sends the queue with the typed message as one")
        func sendQueuedNow() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                let first = try await parkedStream(fx, chat)
                try await fx.mock.enqueue(.deepseek, .text("Final"))

                await fx.engine.queueMessage(filename: chat, text: "queued", pendingAttachments: [])
                try await fx.waitForQueue(chat, count: 1)
                await fx.engine.sendQueuedMessagesNow(filename: chat, extra: QueuedMessage(text: "typed"))
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                #expect(record.queuedMessages.isEmpty)
                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(sent.count == 2)
                #expect(
                    sent[1].transcript == [
                        SmokeFixture.systemLine, "user: go", "assistant: \(Self.partial)", "user: queued\n\ntyped",
                    ])
                try await fx.mock.waitForDisconnect(seq: first.seq)
            }
        }

        @Test("send-now with nothing typed sends the queue")
        func sendQueuedNowWithoutText() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                _ = try await parkedStream(fx, chat)
                try await fx.mock.enqueue(.deepseek, .text("Final"))

                await fx.engine.queueMessage(filename: chat, text: "only queued", pendingAttachments: [])
                try await fx.waitForQueue(chat, count: 1)
                await fx.engine.sendQueuedMessagesNow(filename: chat)
                try await fx.waitUntilIdle(chat)

                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(sent.last?.transcript.last == "user: only queued")
            }
        }
    }
}
