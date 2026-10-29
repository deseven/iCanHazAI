import Foundation
import Testing

@testable import iCanHazAI

// `replace_text` through the real engine: the preflight answers a call that cannot succeed before the user is
// asked anything, an approved call is applied and recorded as the new version of the file, and the `#TAG`s
// that only `edit_file` can use are left out of the file tools' results and descriptions when the role has no
// `edit_file`. Every scenario runs the file tools for real in a temp directory; only the model's answers are
// scripted.
extension AllSmokeTests {
    @Suite("replace_text")
    struct SmokeReplaceTextTests {

        private static let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"

        /// A working directory holding `notes.txt`; removed when the test is over.
        private final class Workspace {
            let path: String
            var file: String { (path as NSString).appendingPathComponent("notes.txt") }

            init() throws {
                path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                    "ichai-smoke-replace-\(UUID().uuidString)")
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                try SmokeReplaceTextTests.content.write(toFile: file, atomically: true, encoding: .utf8)
            }

            deinit { try? FileManager.default.removeItem(atPath: path) }

            func text() throws -> String { try String(contentsOfFile: file, encoding: .utf8) }
        }

        private static func json(_ object: [String: Any]) -> String {
            (try? String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8)) ?? "{}"
        }

        private static func readArgs(throughLine: Int) -> String {
            json(["path": "notes.txt", "ranges": "1-\(throughLine)"])
        }

        private static func replaceArgs(_ old: String, _ new: String) -> String {
            json(["path": "notes.txt", "old_text": old, "new_text": new])
        }

        private static func toolResults(_ messages: [ChatMessage]) -> [ToolResult] {
            messages.flatMap { $0.toolResults ?? [] }
        }

        /// The description of every tool a request advertised, by name.
        private static func advertised(_ request: MockRequest) -> [String: String] {
            var found: [String: String] = [:]
            for tool in request.json["tools"] as? [[String: Any]] ?? [] {
                guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String
                else { continue }
                found[name] = function["description"] as? String ?? ""
            }
            return found
        }

        // MARK: - Approval

        @Test("a replacement is approved, applied and recorded as the new version, with a tag for edit_file")
        func replaceSeenText() async throws {
            let space = try Workspace()
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileEditApproval, workingDirectory: space.path)
                try await fx.mock.enqueue(
                    .deepseek, .toolCall(name: "read_file", arguments: Self.readArgs(throughLine: 5), id: "call_read"))
                try await fx.mock.enqueue(
                    .deepseek,
                    .toolCall(name: "replace_text", arguments: Self.replaceArgs("line2", "TWO"), id: "call_replace"))
                try await fx.mock.enqueue(.deepseek, .text("Done"))
                await fx.send(chat, "go")

                let callID = try await fx.waitForApproval(chat)
                #expect(callID == "call_replace")
                #expect(try space.text() == Self.content, "nothing is written before the user agrees")
                // The approval prompt carries the diff of what would change.
                let pending = await fx.messages(chat).last(where: { $0.role == .assistant })?.toolCalls?.first
                #expect(pending?.diff?.contains("-line2") == true)
                #expect(pending?.diff?.contains("+TWO") == true)

                await fx.engine.resolveToolCallApproval(callID: callID, approval: .allow)
                let record = try await fx.waitUntilIdle(chat)

                let edited = Self.content.replacingOccurrences(of: "line2\n", with: "TWO\n")
                #expect(try space.text() == edited)
                let results = Self.toolResults(try #require(record.chat).activeMessages)
                #expect(results.map(\.callID) == ["call_read", "call_replace"])
                #expect(results[0].content.hasPrefix("[notes.txt#\(HashlineFormat.computeFileHash(Self.content))]\n"))

                let result = results[1]
                #expect(!result.isError, "\(result.content)")
                #expect(
                    result.content.hasPrefix(
                        "Updated: notes.txt [notes.txt#\(HashlineFormat.computeFileHash(edited))] (+1 -1)\n"))
                let event = try #require(result.fileViews?.first)
                #expect(event.kind == .set)
                #expect(event.contentID == HashlineFormat.computeContentID(edited))
                #expect(event.lines == LineSet(range: 1...5))

                // The events are stored with the chat, and the provider never sees them.
                let stored = Self.toolResults(try fx.persisted(chat).activeMessages)
                #expect(stored.map(\.fileViews) == results.map(\.fileViews))
                let requests = try await fx.mock.chatRequests(.deepseek)
                let followUp = try #require(requests.last)
                #expect(
                    followUp.transcript.last?.hasPrefix("tool[call_replace] Updated: notes.txt [notes.txt#") == true)
                let body = try JSONSerialization.data(withJSONObject: try #require(followUp.body))
                #expect(!String(decoding: body, as: UTF8.self).contains("file_views"))

                // The role has edit_file, so the file tools advertise their tags.
                let tools = Self.advertised(try #require(requests.first))
                #expect(Set(tools.keys) == ["read_file", "edit_file", "replace_text"])
                #expect(tools["read_file"]?.contains("#TAG") == true)
            }
        }

        @Test("a text that cannot be replaced is answered during the preflight, no approval asked")
        func notFoundIsAnsweredAtOnce() async throws {
            let space = try Workspace()
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileEditApproval, workingDirectory: space.path)
                try await fx.mock.enqueue(
                    .deepseek,
                    .toolCall(name: "replace_text", arguments: Self.replaceArgs("nope", "x"), id: "call_missing"),
                    .toolCall(name: "replace_text", arguments: Self.replaceArgs("line", "x"), id: "call_ambiguous"))
                try await fx.mock.enqueue(.deepseek, .text("Giving up"))
                await fx.send(chat, "go")
                // Both calls end in the preflight: the loop never stops at an approval.
                let record = try await fx.waitUntilIdle(chat)

                let results = Self.toolResults(try #require(record.chat).activeMessages)
                #expect(results.map(\.callID) == ["call_missing", "call_ambiguous"])
                for result in results { #expect(result.isError) }
                #expect(results[0].content.contains("old_text was not found in notes.txt"))
                #expect(
                    results[1].content.contains("matches 10 times in notes.txt (lines 1, 2, 3, 4, 5, 6, 7, 8, 9, 10)"))
                #expect(try space.text() == Self.content)
            }
        }

        // MARK: - No edit_file, no tags

        @Test("without edit_file the tags are out of the file tools' results and descriptions")
        func noTagsWithoutEditFile() async throws {
            let space = try Workspace()
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(tools: .fileReplaceApproval, workingDirectory: space.path)
                try await fx.mock.enqueue(
                    .deepseek, .toolCall(name: "read_file", arguments: Self.readArgs(throughLine: 5), id: "call_read"))
                try await fx.mock.enqueue(
                    .deepseek,
                    .toolCall(name: "replace_text", arguments: Self.replaceArgs("line2", "TWO"), id: "call_replace"))
                try await fx.mock.enqueue(.deepseek, .text("Done"))
                await fx.send(chat, "go")

                let callID = try await fx.waitForApproval(chat)
                #expect(callID == "call_replace")
                await fx.engine.resolveToolCallApproval(callID: callID, approval: .allow)
                let record = try await fx.waitUntilIdle(chat)

                let edited = Self.content.replacingOccurrences(of: "line2\n", with: "TWO\n")
                #expect(try space.text() == edited)
                let results = Self.toolResults(try #require(record.chat).activeMessages)
                #expect(results.map(\.callID) == ["call_read", "call_replace"])
                #expect(results[0].content.hasPrefix("(lines 1-5 of 10)\n1:line1\n"))
                #expect(!results[0].content.contains("#"))
                #expect(results[1].content.hasPrefix("Updated: notes.txt (+1 -1)\n"))
                #expect(!results[1].content.contains("#"))
                // What the model has seen is still tracked.
                #expect(results[1].fileViews?.first?.lines == LineSet(range: 1...5))

                // Nothing the model was told mentions tags or the tool it does not have.
                let requests = try await fx.mock.chatRequests(.deepseek)
                for request in requests {
                    let tools = Self.advertised(request)
                    #expect(Set(tools.keys) == ["read_file", "replace_text"])
                    let body = String(
                        decoding: try JSONSerialization.data(withJSONObject: try #require(request.body)), as: UTF8.self)
                    #expect(!body.contains("TAG"), "a tag leaked into the request")
                    #expect(!body.contains("edit_file"), "edit_file is mentioned but unavailable")
                }
            }
        }
    }
}
