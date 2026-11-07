import AppKit
import Foundation
import Testing

@testable import iCanHazAI

// What a send looks like before the first token: the user message is in the chat at once, the placeholder
// below it says what the engine is doing, and anything sent meanwhile goes straight into the queue. The
// slow part of an attachment (OCR) is held with `AttachmentManager.enrichmentGate`, the request with the
// mock's gates, so every state is observed while it lasts.
extension AllSmokeTests {
    @Suite("Send flow")
    struct SmokeSendFlowTests {

        /// A gate that holds whoever waits on it until it is opened.
        private actor HoldGate {
            private var isOpen = false
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                if isOpen { return }
                await withCheckedContinuation { waiters.append($0) }
            }

            func open() {
                isOpen = true
                for waiter in waiters { waiter.resume() }
                waiters = []
            }
        }

        private static let ocrStatus = "Performing OCR on the image…"

        private static func pendingImage() throws -> PendingAttachment {
            let rep = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            return PendingAttachment(data: png, kind: .image, originalName: "shot.png")
        }

        /// The text of a request message, whether its content is a string or a list of parts.
        private static func text(of message: [String: Any]) -> String {
            if let string = message["content"] as? String { return string }
            let parts = message["content"] as? [[String: Any]] ?? []
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }

        private static func lastAssistant(_ record: ChatRecord) -> ChatMessage? {
            record.chat?.activeMessages.last { $0.role == .assistant }
        }

        /// A chat on the mock's text-only model, so an image goes out as its OCR text.
        private static func startTextOnly(_ fx: SmokeFixture) async throws -> String {
            try await fx.addProvider(.deepseek)
            try await fx.installRole(tools: .attachments)
            return await fx.newChat(.deepseek, model: "deepseek-v4-pro")
        }

        /// Holds attachment processing until the returned gate is opened; cleared again by `release`.
        private static func holdEnrichment() -> HoldGate {
            let gate = HoldGate()
            AttachmentManager.enrichmentGate = { await gate.wait() }
            return gate
        }

        private static func release(_ gate: HoldGate) async {
            AttachmentManager.enrichmentGate = nil
            await gate.open()
        }

        @Test(
            "the message shows up at once with an OCR status, later messages queue, and the request waits for the text")
        func messageFirstOcrAfterwards() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await Self.startTextOnly(fx)
                let gate = Self.holdEnrichment()
                try await fx.mock.enqueue(.deepseek, .text("Seen"))
                try await fx.mock.enqueue(.deepseek, .text("Noted"))

                await fx.engine.sendMessage(
                    filename: chat, text: "look", pendingAttachments: [try Self.pendingImage()])
                let record = try await fx.wait(for: chat, "the message and its OCR status") { record in
                    Self.lastAssistant(record)?.pendingStatus == Self.ocrStatus
                }

                #expect(record.isStreaming)
                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant])
                #expect(messages[0].content == "look")
                #expect(messages[0].attachments?.count == 1)
                #expect(messages[0].attachments?.first?.text == nil, "no text before the OCR ran")
                #expect(try await fx.mock.chatRequests(.deepseek).isEmpty)

                // Sent while the OCR runs: queued at once, not held up by it.
                await fx.engine.sendMessage(filename: chat, text: "and this", pendingAttachments: [])
                try await fx.waitForQueue(chat, count: 1)

                await Self.release(gate)
                let done = try await fx.waitUntilIdle(chat)

                #expect(done.lastError == nil)
                #expect(done.queuedMessages.isEmpty)
                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(sent.count == 2)
                let first = try #require(sent.first?.messages.last { $0["role"] as? String == "user" })
                #expect(Self.text(of: first).hasPrefix("look"))
                #expect(Self.text(of: first).contains("You are lacking the capabilities to digest images"))
                #expect(sent[1].transcript.suffix(2) == ["assistant: Seen", "user: and this"])

                let stored = try #require(done.chat).activeMessages
                #expect(stored.map(\.role) == [.user, .assistant, .user, .assistant])
                #expect(stored[0].attachments?.first?.text?.contains("lacking the capabilities") == true)
                #expect(
                    try fx.persisted(chat).activeMessages[0].attachments?.first?.text?
                        .contains("lacking the capabilities") == true)
            }
        }

        @Test("stopping during the OCR unwinds at once, keeps the message and leaves the chat usable")
        func stopDuringOcr() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await Self.startTextOnly(fx)
                let gate = Self.holdEnrichment()

                await fx.engine.sendMessage(
                    filename: chat, text: "look", pendingAttachments: [try Self.pendingImage()])
                try await fx.wait(for: chat, "the OCR status") {
                    Self.lastAssistant($0)?.pendingStatus == Self.ocrStatus
                }

                // The recognition itself can't be interrupted; the stop must not wait for it.
                await fx.engine.stopStreaming(filename: chat)
                let record = try await fx.waitUntilIdle(chat, timeout: 2)

                #expect(record.lastError == nil)
                #expect(record.chat?.activeMessages.map(\.role) == [.user])
                #expect(try fx.persisted(chat).activeMessages.map(\.role) == [.user])
                #expect(try await fx.mock.chatRequests(.deepseek).isEmpty)

                // Late recognition results are dropped, and the next message goes out normally.
                await Self.release(gate)
                try await fx.mock.enqueue(.deepseek, .text("Fine"))
                await fx.send(chat, "again")
                let after = try await fx.waitUntilIdle(chat)
                #expect(after.lastError == nil)
                #expect(after.chat?.activeMessages.last?.content == "Fine")
                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(sent.count == 1)
                #expect(sent[0].transcript.suffix(2).last == "user: again")
            }
        }

        @Test("a queued message with an image is shown at once at the answer boundary and its OCR is reported")
        func queuedMessageWithImage() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await Self.startTextOnly(fx)
                try await fx.mock.enqueue(.deepseek, [.text("Partial answer"), .gate("g"), .text(" finished")])
                try await fx.mock.enqueue(.deepseek, .text("Second"))
                await fx.send(chat, "go")
                try await fx.mock.waitForChatRequest(.deepseek, index: 0, atGate: "g")
                try await fx.waitForAnswer(chat, "Partial answer")

                let gate = Self.holdEnrichment()
                await fx.engine.queueMessage(
                    filename: chat, text: "see this", pendingAttachments: [try Self.pendingImage()])
                try await fx.waitForQueue(chat, count: 1)
                try await fx.mock.release("g")

                let record = try await fx.wait(for: chat, "the queued message and its OCR status") { record in
                    Self.lastAssistant(record)?.pendingStatus == Self.ocrStatus
                }
                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant, .user, .assistant])
                #expect(messages[2].content == "see this")
                #expect(messages[2].attachments?.first?.text == nil)
                #expect(record.queuedMessages.isEmpty)
                #expect(try await fx.mock.chatRequests(.deepseek).count == 1)

                await Self.release(gate)
                let done = try await fx.waitUntilIdle(chat)
                #expect(done.lastError == nil)
                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(sent.count == 2)
                let last = try #require(sent[1].messages.last { $0["role"] as? String == "user" })
                #expect(Self.text(of: last).contains("see this"))
                #expect(Self.text(of: last).contains("You are lacking the capabilities to digest images"))
            }
        }

        @Test("while the request is out the placeholder says so, and a reopened chat shows the same status")
        func requestStatus() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                let other = await fx.engine.createNewChat(role: "SmokePlain", model: SmokeProvider.deepseek.modelString)

                // Parked before the response opens: the request is still being sent.
                try await fx.mock.enqueue(.deepseek, [.gate("g1"), .open, .gate("g2"), .text("Hi there")])
                await fx.send(chat, "go")
                try await fx.mock.waitForChatRequest(.deepseek, index: 0, atGate: "g1")
                try await fx.wait(for: chat, "the connecting status") {
                    Self.lastAssistant($0)?.pendingStatus == RequestPhase.connecting.statusText
                }

                // Headers are in, no output yet.
                try await fx.mock.release("g1")
                try await fx.mock.waitForChatRequest(.deepseek, index: 0, atGate: "g2")
                try await fx.wait(for: chat, "the awaiting status") {
                    Self.lastAssistant($0)?.pendingStatus == RequestPhase.awaitingResponse.statusText
                }

                // Leave the chat and come back: the status is still on the placeholder, and the renderer gets it.
                await fx.engine.selectChat(filename: other)
                await fx.engine.selectChat(filename: chat)
                let record = try #require(await fx.record(chat))
                #expect(record.isStreaming)
                let rows = ChatRenderQueue.projectActiveMessages(try #require(record.chat))
                #expect(rows.last?.pendingStatus == RequestPhase.awaitingResponse.statusText)
                #expect(rows.last?.isPending(streaming: true) == true)

                try await fx.mock.release("g2")
                let done = try await fx.waitUntilIdle(chat)
                #expect(done.chat?.activeMessages.last?.content == "Hi there")
                // Runtime state only: nothing of it reaches the disk.
                let json = try Data(contentsOf: fx.temp.chatURL(chat))
                #expect(!String(decoding: json, as: UTF8.self).contains("pendingStatus"))
            }
        }

        @Test("a failed attempt is reported on the placeholder while the retry waits")
        func retryStatus() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                try await fx.mock.enqueue(.deepseek, .httpError(503, message: "Overloaded"))
                try await fx.mock.enqueue(.deepseek, .text("Second try"))
                await fx.send(chat, "go")

                // The retry starts after a pause of a second; the status stays for that long.
                try await fx.wait(for: chat, "the retry status") {
                    Self.lastAssistant($0)?.pendingStatus == RequestPhase.retrying(attempt: 1, of: 1).statusText
                }
                let done = try await fx.waitUntilIdle(chat)
                #expect(done.lastError == nil)
                #expect(done.chat?.activeMessages.last?.content == "Second try")
                #expect(try await fx.mock.chatRequests(.deepseek).count == 2)
            }
        }

        @Test("a send during the preparation of another one queues without starting a second stream")
        func sendWhilePreparing() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await Self.startTextOnly(fx)
                let gate = Self.holdEnrichment()
                try await fx.mock.enqueue(.deepseek, .text("One"))
                try await fx.mock.enqueue(.deepseek, .text("Two"))

                await fx.engine.sendMessage(
                    filename: chat, text: "first", pendingAttachments: [try Self.pendingImage()])
                // Both race the same preparation; neither may start a stream of its own.
                async let a: Void = fx.send(chat, "second")
                async let b: Void = fx.send(chat, "third")
                _ = await (a, b)
                try await fx.waitForQueue(chat, count: 2)

                await Self.release(gate)
                let done = try await fx.waitUntilIdle(chat)
                #expect(done.lastError == nil)
                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(sent.count == 2)
                #expect(sent[1].transcript.suffix(2).last == "user: second\n\nthird")
            }
        }
    }
}
