import Foundation
import Testing

@testable import iCanHazAI

// When a finished stream raises the unread marker (which also drives the dock badge): never for the chat in
// front of a focused window, never after a stop, always otherwise.
extension AllSmokeTests {
    @Suite("Unread marker")
    struct SmokeUnreadTests {

        @Test("an answer in the selected chat of a focused window is already read")
        func focusedSelected() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                try await fx.mock.enqueue(.deepseek, .text("Answer"))
                await fx.send(chat, "go")
                let record = try await fx.waitUntilIdle(chat)

                #expect(!record.hasUnreadActivity)
            }
        }

        @Test("an answer in another chat of a focused window is unread until the chat is opened")
        func focusedNotSelected() async throws {
            try await SmokeFixture.run { fx in
                let first = try await fx.start()
                try await fx.mock.enqueue(.deepseek, .text("One"))
                await fx.send(first, "go")
                try await fx.waitUntilIdle(first)
                // Opening a second chat moves the selection (the first one has content, so it is kept).
                _ = await fx.newChat(.deepseek)

                try await fx.mock.enqueue(.deepseek, .text("Two"))
                await fx.send(first, "again")
                let record = try await fx.waitUntilIdle(first)
                #expect(record.hasUnreadActivity)

                await fx.engine.selectChat(filename: first)
                await fx.engine.markViewed(filename: first)
                #expect(await fx.record(first)?.hasUnreadActivity == false)
            }
        }

        @Test("an answer in the selected chat is unread while the window is not focused")
        func unfocusedSelected() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                await fx.engine.setWindowFocused(false)
                try await fx.mock.enqueue(.deepseek, .text("Answer"))
                await fx.send(chat, "go")
                let record = try await fx.waitUntilIdle(chat)
                #expect(record.hasUnreadActivity)

                await fx.engine.setWindowFocused(true)
                await fx.engine.markViewed(filename: chat)
                #expect(await fx.record(chat)?.hasUnreadActivity == false)
            }
        }

        @Test("a failed turn is unread like an answer")
        func failureIsUnread() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                await fx.engine.setWindowFocused(false)
                try await fx.mock.enqueue(.deepseek, .finish("stop"))
                await fx.send(chat, "go")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError != nil)
                #expect(record.hasUnreadActivity)
            }
        }

        @Test("a stop never raises the unread marker")
        func stopIsNotUnread() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start()
                await fx.engine.setWindowFocused(false)
                try await fx.mock.enqueue(.deepseek, .text("Partial answer"), .gate("g"), .text(" finished"))
                await fx.send(chat, "go")
                try await fx.mock.waitForChatRequest(.deepseek, index: 0, atGate: "g")
                try await fx.waitForAnswer(chat, "Partial answer")

                await fx.engine.stopStreaming(filename: chat)
                let record = try await fx.waitUntilIdle(chat)
                #expect(!record.hasUnreadActivity)
            }
        }
    }
}
