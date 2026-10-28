import Foundation
import Testing

@testable import iCanHazAI

// `edit_file` through the real engine: the seen-lines guard folds what the active branch of the chat showed
// (`FileViewState.fold` over `activeMessages`) in the preflight, before the user is asked anything, and again
// right before the write. Every scenario below runs the file tools for real in a temp directory; only the
// model's answers are scripted.
extension AllSmokeTests {
    @Suite("edit_file seen-lines guard")
    struct SmokeEditFileTests {

        private static let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
        private static let tag = HashlineFormat.computeFileHash(content)

        /// A working directory holding `notes.txt`; removed when the test is over.
        private final class Workspace {
            let path: String
            var file: String { (path as NSString).appendingPathComponent("notes.txt") }

            init() throws {
                path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                    "ichai-smoke-edit-\(UUID().uuidString)")
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                try SmokeEditFileTests.content.write(toFile: file, atomically: true, encoding: .utf8)
            }

            deinit { try? FileManager.default.removeItem(atPath: path) }

            func text() throws -> String { try String(contentsOfFile: file, encoding: .utf8) }
        }

        private static func json(_ object: [String: Any]) -> String {
            (try? String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8)) ?? "{}"
        }

        private static func readArgs(throughLine: Int? = nil) -> String {
            var args: [String: Any] = ["path": "notes.txt"]
            if let throughLine { args["ranges"] = "1-\(throughLine)" }
            return json(args)
        }

        private static func editArgs(_ ops: String) -> String {
            json(["input": "*** Begin Patch\n[notes.txt#\(tag)]\n\(ops)*** End Patch"])
        }

        private static func toolResults(_ messages: [ChatMessage]) -> [ToolResult] {
            messages.flatMap { $0.toolResults ?? [] }
        }

        // MARK: - What a read shows can be edited

        @Test("an edit of a line the partial read showed is approved, applied and recorded as the new version")
        func editSeenLine() async throws {
            let space = try Workspace()
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileEditApproval, workingDirectory: space.path)
                try await fx.mock.enqueue(
                    .deepseek, .toolCall(name: "read_file", arguments: Self.readArgs(throughLine: 5), id: "call_read"))
                try await fx.mock.enqueue(
                    .deepseek,
                    .toolCall(name: "edit_file", arguments: Self.editArgs("PUT 2.=2:\n+TWO\n"), id: "call_edit"))
                try await fx.mock.enqueue(.deepseek, .text("Done"))
                await fx.send(chat, "go")

                let callID = try await fx.waitForApproval(chat)
                #expect(callID == "call_edit")
                #expect(try space.text() == Self.content, "nothing is written before the user agrees")

                await fx.engine.resolveToolCallApproval(callID: callID, approval: .allow)
                let record = try await fx.waitUntilIdle(chat)

                let edited = Self.content.replacingOccurrences(of: "line2\n", with: "TWO\n")
                #expect(try space.text() == edited)
                let results = Self.toolResults(try #require(record.chat).activeMessages)
                #expect(results.map(\.callID) == ["call_read", "call_edit"])
                #expect(results[0].fileViews?.map(\.kind) == [.seen])
                #expect(results[0].fileViews?.first?.lines == LineSet(range: 1...5))

                let result = results[1]
                #expect(!result.isError, "\(result.content)")
                #expect(
                    result.content.hasPrefix("Updated: notes.txt [notes.txt#\(HashlineFormat.computeFileHash(edited))]")
                )
                // Lines 1-5 stay seen at the same numbers (the rewritten line is the author's own).
                let event = try #require(result.fileViews?.first)
                #expect(event.kind == .set)
                #expect(event.contentID == HashlineFormat.computeContentID(edited))
                #expect(event.lines == LineSet(range: 1...5))

                // The events are stored with the chat, and the provider never sees them.
                let stored = Self.toolResults(try fx.persisted(chat).activeMessages)
                #expect(stored.map(\.fileViews) == results.map(\.fileViews))
                let requests = try await fx.mock.chatRequests(.deepseek)
                let followUp = try #require(requests.last)
                #expect(followUp.transcript.last?.hasPrefix("tool[call_edit] Updated: notes.txt [notes.txt#") == true)
                let body = try JSONSerialization.data(withJSONObject: try #require(followUp.body))
                #expect(!String(decoding: body, as: UTF8.self).contains("file_views"))
            }
        }

        // MARK: - What it did not show is revealed, once

        @Test(
            "an edit of lines no read showed is answered with them, no approval asked; the same edit then goes through")
        func revealThenRetry() async throws {
            let space = try Workspace()
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileEditApproval, workingDirectory: space.path)
                let edit = Self.editArgs("PUT 7.=7:\n+SEVEN\n")
                try await fx.mock.enqueue(
                    .deepseek, .toolCall(name: "read_file", arguments: Self.readArgs(throughLine: 3), id: "call_read"))
                try await fx.mock.enqueue(.deepseek, .toolCall(name: "edit_file", arguments: edit, id: "call_first"))
                try await fx.mock.enqueue(.deepseek, .toolCall(name: "edit_file", arguments: edit, id: "call_retry"))
                try await fx.mock.enqueue(.deepseek, .text("Done"))
                await fx.send(chat, "go")

                // Only the retry reaches the user: the first attempt was answered during the preflight.
                let callID = try await fx.waitForApproval(chat)
                #expect(callID == "call_retry")
                #expect(try space.text() == Self.content)

                let sofar = Self.toolResults(await fx.messages(chat))
                let rejected = try #require(sofar.first { $0.callID == "call_first" })
                #expect(rejected.isError)
                #expect(rejected.content.contains("7:line7"))
                #expect(rejected.content.contains("now marked as seen"))
                #expect(rejected.fileViews?.map(\.kind) == [.seen])
                #expect(rejected.fileViews?.first?.lines == LineSet([7]))

                await fx.engine.resolveToolCallApproval(callID: callID, approval: .allow)
                let record = try await fx.waitUntilIdle(chat)

                #expect(try space.text() == Self.content.replacingOccurrences(of: "line7\n", with: "SEVEN\n"))
                let finalChat = try #require(record.chat)
                let retried = try #require(Self.toolResults(finalChat.activeMessages).last)
                #expect(retried.callID == "call_retry")
                #expect(!retried.isError, "\(retried.content)")
            }
        }

        // MARK: - What was never displayed stays closed

        @Test("an edit of a file that was never read is rejected without its content, and so is the retry")
        func blindEdit() async throws {
            let space = try Workspace()
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileEditApproval, workingDirectory: space.path)
                let edit = Self.editArgs("PUT 3.=3:\n+THREE\n")
                try await fx.mock.enqueue(.deepseek, .toolCall(name: "edit_file", arguments: edit, id: "call_blind_1"))
                try await fx.mock.enqueue(.deepseek, .toolCall(name: "edit_file", arguments: edit, id: "call_blind_2"))
                try await fx.mock.enqueue(.deepseek, .text("Giving up"))
                await fx.send(chat, "go")
                // Both attempts end in the preflight: the loop never stops at an approval.
                let record = try await fx.waitUntilIdle(chat)

                let results = Self.toolResults(try #require(record.chat).activeMessages)
                #expect(results.map(\.callID) == ["call_blind_1", "call_blind_2"])
                for result in results {
                    #expect(result.isError)
                    #expect(result.content.contains("never displayed in this conversation"))
                    for line in Self.content.components(separatedBy: "\n") where !line.isEmpty {
                        #expect(!result.content.contains(line), "the file content leaked: \(result.content)")
                    }
                    #expect(result.fileViews?.isEmpty ?? true)
                }
                #expect(try space.text() == Self.content)
            }
        }

        @Test("an edit sent together with the read that would show its lines is rejected: the preflight runs first")
        func editBatchedWithTheRead() async throws {
            let space = try Workspace()
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileEditApproval, workingDirectory: space.path)
                try await fx.mock.enqueue(
                    .deepseek,
                    .toolCall(name: "read_file", arguments: Self.readArgs(throughLine: 3), id: "call_read"),
                    .toolCall(name: "edit_file", arguments: Self.editArgs("PUT 2.=2:\n+TWO\n"), id: "call_edit"))
                try await fx.mock.enqueue(.deepseek, .text("Noted"))
                await fx.send(chat, "go")
                let record = try await fx.waitUntilIdle(chat)

                let results = Self.toolResults(try #require(record.chat).activeMessages)
                #expect(results.map(\.callID) == ["call_read", "call_edit"])
                #expect(!results[0].isError)
                #expect(results[1].isError)
                #expect(results[1].content.contains("never displayed in this conversation"))
                #expect(try space.text() == Self.content)
            }
        }

        // MARK: - Only the active branch counts

        @Test("a read on a regenerated, abandoned branch does not count: the edit on the new one is rejected")
        func regenerateDropsTheRead() async throws {
            let space = try Workspace()
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileEditApproval, workingDirectory: space.path)
                try await fx.mock.enqueue(
                    .deepseek, .toolCall(name: "read_file", arguments: Self.readArgs(), id: "call_read"))
                try await fx.mock.enqueue(.deepseek, .text("Read it"))
                await fx.send(chat, "go")
                try await fx.waitUntilIdle(chat)

                let before = await fx.messages(chat)
                let reading = try #require(before.first { $0.role == .assistant })
                #expect(reading.toolCalls?.first?.id == "call_read")

                // The regenerated turn skips the read and edits at once.
                try await fx.mock.enqueue(
                    .deepseek,
                    .toolCall(name: "edit_file", arguments: Self.editArgs("PUT 2.=2:\n+TWO\n"), id: "call_edit"))
                try await fx.mock.enqueue(.deepseek, .text("Rejected"))
                await fx.engine.regenerate(filename: chat, assistantMessageID: reading.id)
                let record = try await fx.waitUntilIdle(chat)

                let stored = try #require(record.chat)
                let active = stored.activeMessages
                #expect(active.map(\.role) == [.user, .assistant, .tool, .assistant])
                let result = try #require(active[2].toolResults?.first)
                #expect(result.callID == "call_edit")
                #expect(result.isError)
                #expect(result.content.contains("never displayed in this conversation"))
                #expect(stored.message(id: reading.id) != nil, "the old branch is still stored")
                #expect(try space.text() == Self.content)
            }
        }
    }
}
