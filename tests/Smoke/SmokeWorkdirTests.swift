import Foundation
import Testing

@testable import iCanHazAI

// Changing the working directory mid-chat: the next request tells the model, the change survives a restart,
// and it is refused while a stream is running.
extension AllSmokeTests {
    @Suite("Working directory changes")
    struct SmokeWorkdirTests {

        private static let dirA = "/tmp/ichai-smoke-a"
        private static let dirB = "/tmp/ichai-smoke-b"

        private static func note(_ text: String) -> String { "\n\n[SYSTEM NOTE]\n\(text)" }

        @Test("the request after a change carries a note on the user message, and only that one")
        func noteOnNextRequest() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileEditApproval, workingDirectory: Self.dirA)
                try await fx.mock.enqueue(.deepseek, .text("One"))
                await fx.send(chat, "first")
                try await fx.waitUntilIdle(chat)

                await fx.engine.setWorkingDirectory(filename: chat, path: Self.dirB)
                try await fx.mock.enqueue(.deepseek, .text("Two"))
                await fx.send(chat, "second")
                try await fx.waitUntilIdle(chat)

                try await fx.mock.enqueue(.deepseek, .text("Three"))
                await fx.send(chat, "third")
                let record = try await fx.waitUntilIdle(chat)

                let changedText = "The user changed the working directory from `\(Self.dirA)` to `\(Self.dirB)`."
                let changed = Self.note(changedText)
                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(sent.count == 3)
                // No note on the first request, and none once the model has been told.
                #expect(sent[0].transcript.last == "user: first")
                #expect(sent[1].transcript.last == "user: second" + changed)
                #expect(
                    sent[2].transcript.suffix(3) == ["user: second" + changed, "assistant: Two", "user: third"])

                // The note is stored apart from the text the user sees.
                let users = try #require(record.chat).activeMessages.filter { $0.role == .user }
                #expect(users.map(\.content) == ["first", "second", "third"])
                #expect(users.map(\.systemNote) == [nil, changedText, nil])
            }
        }

        @Test("the last directory the model was told about is persisted, so a change survives a restart")
        func lastDirectoryPersists() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileEditApproval, workingDirectory: Self.dirA)
                try await fx.mock.enqueue(.deepseek, .text("One"))
                await fx.send(chat, "first")
                try await fx.waitUntilIdle(chat)
                #expect(try fx.persisted(chat).lastWorkingDirectory == Self.dirA)

                // Changed while "the app is closed": only the saved chat knows what the model was told.
                await fx.engine.setWorkingDirectory(filename: chat, path: Self.dirB)
                let saved = try fx.persisted(chat)
                #expect(saved.workingDirectory == Self.dirB)
                #expect(saved.lastWorkingDirectory == Self.dirA)
            }
        }

        @Test("a directory picked before the first message produces no note, only later changes do")
        func firstPickIsSilent() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileEditApproval)
                await fx.engine.setWorkingDirectory(filename: chat, path: Self.dirA)
                await fx.engine.setWorkingDirectory(filename: chat, path: Self.dirB)
                try await fx.mock.enqueue(.deepseek, .text("One"))
                await fx.send(chat, "first")
                try await fx.waitUntilIdle(chat)

                try await fx.mock.enqueue(.deepseek, .text("Two"))
                await fx.send(chat, "second")
                try await fx.waitUntilIdle(chat)

                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(sent[0].transcript.last == "user: first")
                #expect(sent[1].transcript.last == "user: second")
                #expect(try fx.persisted(chat).lastWorkingDirectory == Self.dirB)
            }
        }

        @Test("picking a directory after the first message is announced as a pick")
        func pickAnnounced() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileEditApproval)
                try await fx.mock.enqueue(.deepseek, .text("One"))
                await fx.send(chat, "first")
                try await fx.waitUntilIdle(chat)

                await fx.engine.setWorkingDirectory(filename: chat, path: Self.dirB)
                try await fx.mock.enqueue(.deepseek, .text("Two"))
                await fx.send(chat, "second")
                try await fx.waitUntilIdle(chat)

                let sent = try await fx.mock.chatRequests(.deepseek)
                #expect(
                    sent[1].transcript.last == "user: second"
                        + Self.note("The user picked the working directory `\(Self.dirB)`."))
            }
        }

        @Test("the directory can't be changed while the chat streams")
        func refusedWhileStreaming() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileEditApproval, workingDirectory: Self.dirA)
                try await fx.mock.enqueue(.deepseek, [.text("Partial answer"), .gate("g"), .text(" finished")])
                await fx.send(chat, "go")
                try await fx.mock.waitForChatRequest(.deepseek, index: 0, atGate: "g")

                await fx.engine.setWorkingDirectory(filename: chat, path: Self.dirB)
                #expect(await fx.record(chat)?.chat?.workingDirectory == Self.dirA)

                try await fx.mock.release("g")
                let record = try await fx.waitUntilIdle(chat)
                #expect(record.chat?.workingDirectory == Self.dirA)

                await fx.engine.setWorkingDirectory(filename: chat, path: Self.dirB)
                #expect(await fx.record(chat)?.chat?.workingDirectory == Self.dirB)
            }
        }
    }
}
