import Testing
import Foundation
@testable import iCanHazAI

/// Tests for [`ToolSummary`](src/Tools/ToolSummary.swift) — the one-line tool
/// call/result summaries persisted in the chat data and consumed by every
/// surface (chat renderer, CLI).
extension AllAppTests {

    @Suite("Tool summary")
    struct ToolSummaryTests {

        private func json(_ obj: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: obj)
            return String(data: data, encoding: .utf8)!
        }

        // MARK: - Call summaries: internal tools

        @Test("read_file: path is the bare primary value, offset/limit secondary")
        func readFile() {
            #expect(ToolSummary.callEntries(name: "read_file", arguments: json(["path": "src/main.swift"]))
                    == [ToolSummary.Entry(key: nil, value: "src/main.swift")])
            #expect(ToolSummary.callEntries(name: "read_file", arguments: json(["path": "a.txt", "offset": 10, "limit": 50]))
                    == [ToolSummary.Entry(key: nil, value: "a.txt"),
                        ToolSummary.Entry(key: "offset", value: "10"),
                        ToolSummary.Entry(key: "limit", value: "50")])
        }

        @Test("shell: command is primary, cwd/timeout secondary; newlines collapse to ⏎")
        func shell() {
            #expect(ToolSummary.callEntries(name: "shell", arguments: json(["command": "ls -la", "cwd": "/tmp", "timeout": 30]))
                    == [ToolSummary.Entry(key: nil, value: "ls -la"),
                        ToolSummary.Entry(key: "cwd", value: "/tmp"),
                        ToolSummary.Entry(key: "timeout", value: "30")])
            #expect(ToolSummary.callEntries(name: "shell", arguments: json(["command": "cd /tmp\nls -la"]))
                    == [ToolSummary.Entry(key: nil, value: "cd /tmp⏎ls -la")])
        }

        @Test("mv renders src → dst; git joins args; apply_patch lists affected paths")
        func customKnown() {
            #expect(ToolSummary.callEntries(name: "mv", arguments: json(["src": "a.txt", "dst": "b.txt"]))
                    == [ToolSummary.Entry(key: nil, value: "a.txt → b.txt")])
            #expect(ToolSummary.callEntries(name: "git", arguments: json(["args": ["status", "--short"]]))
                    == [ToolSummary.Entry(key: nil, value: "status --short")])

            let patch = """
                *** Begin Patch
                *** Add File: hello.txt
                +hi
                *** Update File: src/app.py
                @@
                 ctx
                *** Delete File: obsolete.txt
                *** End Patch
                """
            #expect(ToolSummary.callEntries(name: "apply_patch", arguments: json(["patch": patch]))
                    == [ToolSummary.Entry(key: nil, value: "hello.txt, src/app.py, obsolete.txt")])

            let move = """
                *** Begin Patch
                *** Update File: src/app.py
                *** Move to: src/main.py
                @@
                 ctx
                *** End Patch
                """
            #expect(ToolSummary.callEntries(name: "apply_patch", arguments: json(["patch": move]))
                    == [ToolSummary.Entry(key: nil, value: "src/app.py → src/main.py")])
        }

        @Test("no-arg tools produce an empty summary")
        func noArgTools() {
            #expect(ToolSummary.callEntries(name: "datetime", arguments: "{}") == [])
            #expect(ToolSummary.callEntries(name: "list_roles", arguments: "{}") == [])
        }

        @Test("configurator tools: id/name is primary")
        func configurator() {
            #expect(ToolSummary.callEntries(name: "delete_role", arguments: json(["name": "Old"]))
                    == [ToolSummary.Entry(key: nil, value: "Old")])
            #expect(ToolSummary.callEntries(name: "check_connection", arguments: json(["id": "openai/gpt-4o"]))
                    == [ToolSummary.Entry(key: nil, value: "openai/gpt-4o")])
        }

        // MARK: - Call summaries: unknown tools

        @Test("unknown tool: required args first (alphabetical), then optional")
        func unknownRequiredFirst() {
            let args = json(["zebra": 1, "apple": 2, "mango": 3, "kiwi": 4])
            #expect(ToolSummary.callEntries(name: "mcp__srv__tool", arguments: args, requiredArgs: ["zebra", "apple"]).map(\.key)
                    == ["apple", "zebra", "kiwi", "mango"])
        }

        @Test("unknown tool: required args not present in the call are ignored")
        func unknownMissingRequired() {
            let args = json(["beta": 1, "alpha": 2])
            #expect(ToolSummary.callEntries(name: "some_tool", arguments: args, requiredArgs: ["alpha", "missing"]).map(\.key)
                    == ["alpha", "beta"])
        }

        @Test("unknown tool: without requiredArgs the JSON key order is preserved")
        func unknownKeyOrder() {
            #expect(ToolSummary.callEntries(name: "some_tool", arguments: #"{"zebra":1,"apple":2,"mango":3}"#).map(\.key)
                    == ["zebra", "apple", "mango"])
        }

        @Test("unknown tool: entries render as key: value; scalar arrays join inline")
        func unknownValues() {
            #expect(ToolSummary.callEntries(name: "some_tool", arguments: json(["query": "cats"]))
                    == [ToolSummary.Entry(key: "query", value: "cats")])
            #expect(ToolSummary.callEntries(name: "some_tool", arguments: json(["ids": [1, 2, 3]]))
                    == [ToolSummary.Entry(key: "ids", value: "1 2 3")])
            #expect(ToolSummary.callEntries(name: "some_tool", arguments: json(["flag": true]))
                    == [ToolSummary.Entry(key: "flag", value: "true")])
        }

        @Test("malformed arguments fall back to the raw single-line string; empty is empty")
        func malformedArgs() {
            #expect(ToolSummary.callEntries(name: "some_tool", arguments: "{broken json")
                    == [ToolSummary.Entry(key: nil, value: "{broken json")])
            #expect(ToolSummary.callEntries(name: "some_tool", arguments: "") == [])
            #expect(ToolSummary.callEntries(name: "some_tool", arguments: "{}") == [])
        }

        @Test("callLine joins entries with · and key: prefixes")
        func callLine() {
            #expect(ToolSummary.callLine(name: "read_file", arguments: json(["path": "a.txt", "offset": 10]))
                    == "a.txt · offset: 10")
            #expect(ToolSummary.callLine(name: "mv", arguments: json(["src": "a", "dst": "b"])) == "a → b")
            #expect(ToolSummary.callLine(name: "pwd", arguments: "{}") == "")
        }

        // MARK: - Result summaries

        @Test("done: first non-empty line; error: first line of the error text")
        func doneAndError() {
            let done = ToolSummary.resultStatus(name: "some_tool", result: ToolResult(callID: "c", content: "\n\n  first line  \nsecond", isError: false))
            #expect(done == ToolSummary.Status(kind: .done, label: "done", description: "first line"))

            let error = ToolSummary.resultStatus(name: "some_tool", result: ToolResult(callID: "c", content: "file not found: a.txt\ndetails", isError: true))
            #expect(error == ToolSummary.Status(kind: .error, label: "error", description: "file not found: a.txt"))
        }

        @Test("streaming results have no final summary")
        func streaming() {
            #expect(ToolSummary.resultStatus(name: "some_tool", result: ToolResult(callID: "c", content: "partial", isError: false, isStreaming: true)) == nil)
        }

        @Test("read_file counts the numbered output lines, ignoring truncation markers")
        func readFileResult() {
            let r = ToolSummary.resultStatus(name: "read_file", result: ToolResult(callID: "c", content: " 1 | first\n 2 | second\n10 | tenth", isError: false))
            #expect(r?.description == "Read 3 lines.")
            let truncated = ToolSummary.resultStatus(name: "read_file", result: ToolResult(callID: "c", content: "1 | only\n... (truncated at 2000 lines)", isError: false))
            #expect(truncated?.description == "Read 1 line.")
            let image = ToolSummary.resultStatus(name: "read_file", result: ToolResult(callID: "c", content: "[image: image/png]", isError: false))
            #expect(image?.description == "[image: image/png]")
        }

        @Test("ls/find_file/find_text count their result lines")
        func counting() {
            #expect(ToolSummary.resultStatus(name: "ls", result: ToolResult(callID: "c", content: "src/\nPackage.swift\nREADME.md", isError: false))?.description == "Listed 3 items.")
            #expect(ToolSummary.resultStatus(name: "ls", result: ToolResult(callID: "c", content: "", isError: false))?.description == "Listed 0 items.")
            #expect(ToolSummary.resultStatus(name: "find_file", result: ToolResult(callID: "c", content: "a.txt\nb.txt\n... (truncated at 200 results)", isError: false))?.description == "Found 2 items.")
            #expect(ToolSummary.resultStatus(name: "find_text", result: ToolResult(callID: "c", content: "src/a.swift:10:match one", isError: false))?.description == "Found 1 item.")
        }

        @Test("shell/git surface the exit-code line")
        func exitCode() {
            #expect(ToolSummary.resultStatus(name: "shell", result: ToolResult(callID: "c", content: "total 8\n-rw-r--r--  a.txt\n[exit code: 0]", isError: false))?.description == "[exit code: 0]")
            #expect(ToolSummary.resultStatus(name: "git", result: ToolResult(callID: "c", content: "error: pathspec 'x' did not match\n[exit code: 1]", isError: false))?.description == "[exit code: 1]")
        }

        @Test("apply_patch summarizes the per-file operation lines")
        func applyPatchResult() {
            let content = "Added: a.txt\nUpdated: b.swift (2 hunks)\nUpdated: c.swift → d.swift (1 hunks)\nDeleted: e.txt"
            #expect(ToolSummary.resultStatus(name: "apply_patch", result: ToolResult(callID: "c", content: content, isError: false))?.description
                    == "Patched 4 files (1 added, 2 updated, 1 deleted).")
            #expect(ToolSummary.resultStatus(name: "apply_patch", result: ToolResult(callID: "c", content: "Updated: src/app.py (3 hunks)", isError: false))?.description
                    == "Patched 1 file (1 updated).")
        }

        @Test("configurator list/check tools count bullets; readers count lines")
        func configuratorResults() {
            #expect(ToolSummary.resultStatus(name: "list_roles", result: ToolResult(callID: "c", content: "- Assistant\n- Developer", isError: false))?.description == "Listed 2 items.")
            #expect(ToolSummary.resultStatus(name: "list_connections", result: ToolResult(callID: "c", content: "(none)", isError: false))?.description == "Listed 0 items.")
            #expect(ToolSummary.resultStatus(name: "check_mcp_stdio", result: ToolResult(callID: "c", content: "- search — web search\n- fetch", isError: false))?.description == "Found 2 tools.")
            #expect(ToolSummary.resultStatus(name: "read_role", result: ToolResult(callID: "c", content: "[role]\nname = \"Dev\"\n", isError: false))?.description == "Read 2 lines.")
            #expect(ToolSummary.resultStatus(name: "read_log", result: ToolResult(callID: "c", content: "(application log is empty)", isError: false))?.description == "(application log is empty)")
        }

        @Test("denied strips the boilerplate prefix; cancelled has no description")
        func deniedAndCancelled() {
            let denied = ToolSummary.resultStatus(name: "some_tool", result: ToolResult(
                callID: "c", content: "User denied this tool call with the following reason: too risky",
                isError: true, isDenied: true))
            #expect(denied == ToolSummary.Status(kind: .denied, label: "denied", description: "too risky"))

            let generic = ToolSummary.resultStatus(name: "some_tool", result: ToolResult(
                callID: "c", content: "User denied this tool call", isError: true, isDenied: true))
            #expect(generic == ToolSummary.Status(kind: .denied, label: "denied", description: ""))

            let cancelled = ToolSummary.resultStatus(name: "some_tool", result: ToolResult(
                callID: "c", content: "Tool call was cancelled by the user before it was executed.",
                isError: true, isCancelled: true))
            #expect(cancelled == ToolSummary.Status(kind: .cancelled, label: "cancelled", description: ""))
        }

        // MARK: - Persistence

        @Test("tool call/result summaries survive a Codable round-trip")
        func codableRoundTrip() throws {
            let call = ToolCall(id: "c1", name: "read_file", arguments: #"{"path":"a.txt"}"#,
                                requiredArgs: ["path"], summary: "a.txt")
            let decodedCall = try JSONDecoder().decode(ToolCall.self, from: JSONEncoder().encode(call))
            #expect(decodedCall == call)

            let result = ToolResult(callID: "c1", content: "1 | x", isError: false,
                                    summary: ToolSummary.Status(kind: .done, label: "done", description: "Read 1 line."))
            let data = try JSONEncoder().encode(result)
            // The persisted key is tool_call_result_summary.
            let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(obj["tool_call_result_summary"] != nil)
            let decodedResult = try JSONDecoder().decode(ToolResult.self, from: data)
            #expect(decodedResult == result)

            // Chat data without the fields decodes with nil summaries.
            let legacy = Data(#"{"callID":"c2","content":"x","isError":false}"#.utf8)
            let decodedLegacy = try JSONDecoder().decode(ToolResult.self, from: legacy)
            #expect(decodedLegacy.summary == nil)
        }
    }
}
