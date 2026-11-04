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

        /// A shell command that ignores SIGTERM (so does what it `exec`s) and reports the pid of its inner
        /// process, so a test can tell when it runs and whether it got killed.
        private static func stubbornShellCall(pidFile: String) -> String {
            let command = "trap '' TERM; sh -c 'echo $$ > \(pidFile); exec sleep 600'"
            let data = try! JSONSerialization.data(withJSONObject: ["command": command])
            return String(decoding: data, as: UTF8.self)
        }

        private static func waitForPid(at path: String, timeout: Duration = .seconds(10)) async throws -> pid_t {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while clock.now < deadline {
                if let text = try? String(contentsOfFile: path, encoding: .utf8),
                    let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
                {
                    return pid
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw SmokeTimeout(description: "the shell command never started")
        }

        private static func waitForDeath(_ pid: pid_t, timeout: Duration = .seconds(10)) async throws -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while clock.now < deadline {
                if kill(pid, 0) != 0, errno == ESRCH { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }

        @Test("stopping a shell command that ignores the stop unwinds at once, saves the turn and kills it later")
        func stopDuringStubbornShell() async throws {
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "ichai-smoke-stop-\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let pidFile = (dir as NSString).appendingPathComponent("child.pid")

            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .shellAutoAllow, workingDirectory: dir)
                try await fx.mock.enqueue(
                    .deepseek,
                    .toolCall(name: "shell", arguments: Self.stubbornShellCall(pidFile: pidFile), id: "call_sh"))
                await fx.send(chat, "go")
                let child = try await Self.waitForPid(at: pidFile)

                // The process group only gets SIGKILL after a 2s grace, so an unwind that waited for the
                // command could not make this deadline.
                await fx.engine.stopStreaming(filename: chat)
                let record = try await fx.waitUntilIdle(chat, timeout: 1.5)

                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant, .tool])
                #expect(messages[2].toolResults?.first?.callID == "call_sh")
                #expect(messages[2].toolResults?.first?.isError == true)
                #expect(try fx.persisted(chat).activeMessages.map(\.role) == [.user, .assistant, .tool])

                // The chat takes the next message right away.
                try await fx.mock.enqueue(.deepseek, .text("ok"))
                await fx.send(chat, "next")
                let after = try await fx.waitUntilIdle(chat)
                #expect(after.lastError == nil)
                #expect(after.chat?.activeMessages.last?.content == "ok")

                #expect(try await Self.waitForDeath(child), "the stopped command was left running")
            }
        }

        @Test("switching chats right after stopping a stuck tool loses nothing from the turn, queued messages included")
        func stopThenSwitchAway() async throws {
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "ichai-smoke-stop-\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let pidFile = (dir as NSString).appendingPathComponent("child.pid")

            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .shellAutoAllow, workingDirectory: dir)
                let other = await fx.engine.createNewChat(role: "SmokePlain", model: SmokeProvider.deepseek.modelString)
                try await fx.mock.enqueue(
                    .deepseek, .text("Working"), .gate("g"),
                    .toolCall(name: "shell", arguments: #"{"command":"echo hi"}"#, id: "call_1"))
                try await fx.mock.enqueue(
                    .deepseek,
                    .toolCall(name: "shell", arguments: Self.stubbornShellCall(pidFile: pidFile), id: "call_2"))
                await fx.send(chat, "go")
                try await fx.mock.waitForChatRequest(.deepseek, index: 0, atGate: "g")
                await fx.engine.queueMessage(filename: chat, text: "steer", pendingAttachments: [])
                try await fx.waitForQueue(chat, count: 1)
                try await fx.mock.release("g")
                let child = try await Self.waitForPid(at: pidFile)

                await fx.engine.stopStreaming(filename: chat)
                await fx.engine.selectChat(filename: other)
                await fx.engine.selectChat(filename: chat)

                func shape(_ messages: [ChatMessage]) -> [String] {
                    messages.map { message in
                        if let result = message.toolResults?.first {
                            return "tool[\(result.callID)]\(result.isCancelled ? " cancelled" : "")"
                        }
                        let calls = message.toolCalls?.map(\.id).joined(separator: ",")
                        return "\(message.role.rawValue): \(message.content)" + (calls.map { " [\($0)]" } ?? "")
                    }
                }
                let expected = [
                    "user: go", "assistant: Working [call_1]", "tool[call_1]", "user: steer", "assistant:  [call_2]",
                    "tool[call_2] cancelled",
                ]
                #expect(shape(await fx.messages(chat)) == expected)
                #expect(shape(try fx.persisted(chat).activeMessages) == expected)

                try await fx.waitUntilIdle(chat)
                #expect(try await Self.waitForDeath(child), "the stopped command was left running")
            }
        }

        @Test("allowing a tool for the chat saves no approval prompt to disk")
        func allowForChatSavesNoPrompt() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .calcApproval)
                try await fx.mock.enqueue(
                    .deepseek, .toolCall(name: "calc", arguments: Calc.call("2+2"), id: "call_ask"))
                try await fx.mock.enqueue(.deepseek, [.text(Self.partial), .gate("g"), .text(" finished")])
                await fx.send(chat, "go")
                let callID = try await fx.waitForApproval(chat)

                await fx.engine.allowToolCallForChat(callID: callID)
                // Mid-stream: the save that remembered the allowance is the latest one on disk.
                try await fx.mock.waitForChatRequest(.deepseek, index: 1, atGate: "g")
                let saved = try fx.persisted(chat)
                #expect(saved.autoAllow == ["calc"])
                let calls = saved.activeMessages.compactMap(\.toolCalls).joined()
                #expect(!calls.isEmpty)
                #expect(!calls.contains { $0.pendingApproval })

                try await fx.mock.release("g")
                try await fx.waitUntilIdle(chat)
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
