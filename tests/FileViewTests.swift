import Foundation
import Testing

@testable import iCanHazAI

/// The file-view data model (`LineSet`, `FileKey`, `FileViewState`) and the
/// events the file tools record on their results.
///
/// Nested under `AllAppTests` so its `.serialized` trait keeps these sequential
/// with the rest of the app suites.
extension AllAppTests {

    // MARK: - Test helpers

    private final class ViewTestDir {
        let path: String
        init() throws {
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "ichai-fileview-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            self.path = dir
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        func sub(_ relative: String) -> String {
            (path as NSString).appendingPathComponent(relative)
        }
        @discardableResult
        func write(_ relative: String, content: String) throws -> String {
            try write(relative, data: Data(content.utf8))
        }
        @discardableResult
        func write(_ relative: String, data: Data) throws -> String {
            let url = sub(relative)
            try FileManager.default.createDirectory(
                atPath: (url as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: url))
            return url
        }
    }

    private static func runTool(
        _ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none
    ) async -> ToolResult {
        let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
        return await BuiltinTools.call(
            name: name, arguments: arguments, callID: "test", group: group, workdir: workdir,
            chatFilename: "test.json")
    }

    /// The state the model would have after these results, in order.
    private static func fold(_ results: [ToolResult]) -> FileViewState {
        FileViewState.fold(results.map { Fixtures.message(role: .tool, content: "", toolResults: [$0]) })
    }

    private static func key(_ path: String) -> FileKey { .local(resolved: path) }

    private static func contentID(_ text: String) -> String { HashlineFormat.computeContentID(text) }

    private static func lines(_ range: ClosedRange<Int>) -> LineSet { LineSet(range: range) }

    /// The `seen` / `set` event a tool should record for `path` holding `content`.
    private static func seenEvent(_ path: String, _ content: String, _ lines: LineSet) -> FileViewEvent {
        .seen(key(path), contentID: contentID(content), lines: lines)
    }

    private static func setEvent(_ path: String, _ content: String, _ lines: LineSet) -> FileViewEvent {
        .set(key(path), contentID: contentID(content), lines: lines)
    }

    // MARK: - LineSet

    @Suite("LineSet")
    struct LineSetTests {
        @Test("adjacent and overlapping ranges merge")
        func merges() {
            #expect(LineSet(range: 1...3).union(LineSet(range: 4...6)).ranges == [1...6])
            #expect(LineSet(range: 1...5).union(LineSet(range: 3...9)).ranges == [1...9])
            #expect(LineSet(range: 1...2).union(LineSet(range: 4...5)).ranges == [1...2, 4...5])
            #expect(LineSet(range: 1...3).union(LineSet()).ranges == [1...3])
            #expect(LineSet([5, 3, 4, 4, 1]).ranges == [1...1, 3...5])
        }

        @Test("numbers below 1 are not lines")
        func dropsNonPositive() {
            #expect(LineSet([-2, 0, 1]).ranges == [1...1])
            #expect(LineSet(range: -3...2).ranges == [1...2])
            #expect(LineSet(range: -3...0).isEmpty)
        }

        @Test("contains and count")
        func contains() {
            let set = LineSet([1, 2, 3, 7, 10, 11])
            for line in [1, 2, 3, 7, 10, 11] { #expect(set.contains(line)) }
            for line in [-1, 0, 4, 5, 6, 8, 9, 12, 100] { #expect(!set.contains(line)) }
            #expect(set.count == 6)
            #expect(!LineSet().contains(1))
            #expect(LineSet().count == 0)
        }

        @Test("compact encoding round-trips")
        func encoding() {
            let set = LineSet(range: 1...200).union(LineSet([350])).union(LineSet(range: 360...362))
            #expect(set.encoded == "1-200,350,360-362")
            #expect(LineSet(encoded: "1-200,350,360-362") == set)
            #expect(LineSet().encoded == "")
            #expect(LineSet(encoded: "") == LineSet())
            #expect(LineSet(encoded: "5,1-2,2-3")?.ranges == [1...3, 5...5])
        }

        @Test("garbage does not decode")
        func garbage() {
            for text in ["a", "1-", "-3", "3-1", "0", "1,,2", "1-2-3", "1.5", "1, 2", "٣", "1-0", "+4"] {
                #expect(LineSet(encoded: text) == nil, "\(text)")
            }
        }

        @Test("an event with a bad line set fails to decode")
        func jsonRoundTrip() throws {
            let event = FileViewEvent.seen(FileKey(raw: "/a"), contentID: "ABCD", lines: LineSet(range: 1...3))
            let data = try JSONEncoder().encode(event)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["kind"] as? String == "seen")
            #expect(object["key"] as? String == "/a")
            #expect(object["lines"] as? String == "1-3")
            #expect(object["to"] == nil)
            #expect(try JSONDecoder().decode(FileViewEvent.self, from: data) == event)

            let bad = #"{"kind":"seen","key":"/a","contentID":"X","lines":"3-1"}"#
            #expect(throws: (any Error).self) { try JSONDecoder().decode(FileViewEvent.self, from: Data(bad.utf8)) }
        }

        @Test("remapping follows the origins of an edit")
        func remapped() {
            // Lines 2 and 3 were seen; the edit inserted a line after line 1,
            // replaced line 4 and kept the rest.
            let origins: [Int?] = [1, nil, 2, 3, nil, 5]
            #expect(LineSet([2, 3]).remapped(throughOrigins: origins) == LineSet([3, 4]))
            // A deleted line has no successor.
            #expect(LineSet([2]).remapped(throughOrigins: [1, 3]).isEmpty)
            #expect(LineSet(range: 1...3).remapped(throughOrigins: [nil]).isEmpty)
        }
    }

    // MARK: - FileKey

    @Suite("FileKey")
    struct FileKeyTests {
        @Test("the key of a missing path is the key once it exists")
        func stableForMissingPaths() throws {
            let tmp = try ViewTestDir()
            let path = tmp.sub("new/deep/a.txt")
            let before = FileKey.local(resolved: path)
            try tmp.write("new/deep/a.txt", content: "x")
            #expect(FileKey.local(resolved: path) == before)
        }

        @Test("the spelling of the temp directory does not matter")
        func canonicalSpelling() throws {
            let tmp = try ViewTestDir()
            let canonical = BuiltinTools.canonicalPath(tmp.path)
            #expect(FileKey.local(resolved: tmp.sub("a.txt")).raw == canonical + "/a.txt")
            #expect(FileKey.local(resolved: tmp.sub("a.txt")) == FileKey.local(resolved: canonical + "/a.txt"))
        }

        @Test("symlinked directories resolve, the last component does not")
        func symlinks() throws {
            let tmp = try ViewTestDir()
            try tmp.write("real/a.txt", content: "x")
            try FileManager.default.createSymbolicLink(
                atPath: tmp.sub("link"), withDestinationPath: tmp.sub("real"))
            #expect(FileKey.local(resolved: tmp.sub("link/a.txt")) == FileKey.local(resolved: tmp.sub("real/a.txt")))
            #expect(FileKey.local(resolved: tmp.sub("link")).raw.hasSuffix("/link"))
        }

        @Test("dots are normalized and the root is a key")
        func normalization() throws {
            let tmp = try ViewTestDir()
            #expect(FileKey.local(resolved: tmp.sub("x/../a.txt")) == FileKey.local(resolved: tmp.sub("a.txt")))
            #expect(FileKey.local(resolved: "/").raw == "/")
        }

        @Test("SSH keys carry the host and never touch the local filesystem")
        func sshKeys() {
            #expect(FileKey.ssh(host: "h", resolved: "/a/b/../c").raw == "ssh://h/a/c")
            #expect(FileKey.ssh(host: "h", resolved: "~/x").raw == "ssh://h/./~/x")
            #expect(FileKey.ssh(host: "h", resolved: "/a") != FileKey.ssh(host: "g", resolved: "/a"))
            #expect(FileKey.ssh(host: "h", resolved: "/a") != FileKey.local(resolved: "/a"))
        }

        @Test("a directory covers its subtree and nothing else")
        func covers() {
            let dir = FileKey(raw: "/a/b")
            #expect(dir.covers(FileKey(raw: "/a/b")))
            #expect(dir.covers(FileKey(raw: "/a/b/c/d.txt")))
            #expect(!dir.covers(FileKey(raw: "/a/bc")))
            #expect(!dir.covers(FileKey(raw: "/a")))
            #expect(FileKey(raw: "/a/b/c").rebased(from: dir, to: FileKey(raw: "/x")) == FileKey(raw: "/x/c"))
        }

        @Test("a key encodes as a plain string")
        func codable() throws {
            let data = try JSONEncoder().encode([FileKey(raw: "/a b")])
            #expect(try JSONDecoder().decode([String].self, from: data) == ["/a b"])
            #expect(try JSONDecoder().decode([FileKey].self, from: data) == [FileKey(raw: "/a b")])
        }
    }

    // MARK: - Fold

    @Suite("FileViewState")
    struct FileViewStateTests {
        private let a = FileKey(raw: "/p/a.txt")

        @Test("seen events for the same content union their lines")
        func seenUnions() {
            var state = FileViewState()
            state.apply(.seen(a, contentID: "A", lines: LineSet(range: 1...5)))
            state.apply(.seen(a, contentID: "A", lines: LineSet(range: 10...12)))
            #expect(state.view(for: a) == FileView(contentID: "A", lines: LineSet([1, 2, 3, 4, 5, 10, 11, 12])))
        }

        @Test("a seen event for other content replaces the view")
        func seenReplaces() {
            var state = FileViewState()
            state.apply(.seen(a, contentID: "A", lines: LineSet(range: 1...5)))
            state.apply(.seen(a, contentID: "B", lines: LineSet(range: 7...8)))
            #expect(state.view(for: a) == FileView(contentID: "B", lines: LineSet(range: 7...8)))
        }

        @Test("a set event replaces the view")
        func setReplaces() {
            var state = FileViewState()
            state.apply(.seen(a, contentID: "A", lines: LineSet(range: 1...5)))
            state.apply(.set(a, contentID: "A", lines: LineSet(range: 2...3)))
            #expect(state.view(for: a) == FileView(contentID: "A", lines: LineSet(range: 2...3)))
        }

        @Test("seen and set without a content id are ignored")
        func missingContentID() {
            var state = FileViewState()
            state.apply(FileViewEvent(kind: .seen, key: a, to: nil, contentID: nil, lines: LineSet(range: 1...2)))
            state.apply(FileViewEvent(kind: .set, key: a, to: nil, contentID: nil, lines: LineSet(range: 1...2)))
            #expect(state.view(for: a) == nil)
        }

        @Test("dropping a directory drops its subtree only")
        func dropDirectory() {
            var state = FileViewState()
            for raw in ["/p/d/a", "/p/d/sub/b", "/p/dd/c", "/p/d"] {
                state.apply(.set(FileKey(raw: raw), contentID: "X", lines: LineSet()))
            }
            state.apply(.drop(FileKey(raw: "/p/d")))
            #expect(state.view(for: FileKey(raw: "/p/d/a")) == nil)
            #expect(state.view(for: FileKey(raw: "/p/d/sub/b")) == nil)
            #expect(state.view(for: FileKey(raw: "/p/d")) == nil)
            #expect(state.view(for: FileKey(raw: "/p/dd/c")) != nil)
        }

        @Test("moving a directory relocates its subtree and clears the destination")
        func moveDirectory() {
            var state = FileViewState()
            state.apply(.set(FileKey(raw: "/p/d/a"), contentID: "A", lines: LineSet(range: 1...2)))
            state.apply(.set(FileKey(raw: "/p/d/sub/b"), contentID: "B", lines: LineSet(range: 1...3)))
            state.apply(.set(FileKey(raw: "/p/e/stale"), contentID: "S", lines: LineSet(range: 1...1)))
            state.apply(.move(from: FileKey(raw: "/p/d"), to: FileKey(raw: "/p/e")))
            #expect(state.view(for: FileKey(raw: "/p/e/a")) == FileView(contentID: "A", lines: LineSet(range: 1...2)))
            #expect(
                state.view(for: FileKey(raw: "/p/e/sub/b")) == FileView(contentID: "B", lines: LineSet(range: 1...3)))
            #expect(state.view(for: FileKey(raw: "/p/e/stale")) == nil)
            #expect(state.view(for: FileKey(raw: "/p/d/a")) == nil)
            #expect(state.files.count == 2)
        }

        @Test("moving a file replaces the view at the destination")
        func moveFile() {
            let b = FileKey(raw: "/p/b.txt")
            var state = FileViewState()
            state.apply(.set(a, contentID: "A", lines: LineSet(range: 1...2)))
            state.apply(.set(b, contentID: "B", lines: LineSet(range: 1...9)))
            state.apply(.move(from: a, to: b))
            #expect(state.view(for: a) == nil)
            #expect(state.view(for: b) == FileView(contentID: "A", lines: LineSet(range: 1...2)))
        }

        @Test("moving onto itself changes nothing")
        func moveToSelf() {
            var state = FileViewState()
            state.apply(.set(a, contentID: "A", lines: LineSet(range: 1...2)))
            state.apply(.move(from: a, to: a))
            #expect(state.view(for: a) == FileView(contentID: "A", lines: LineSet(range: 1...2)))
        }

        @Test("the fold replays every result in order, errors included")
        func foldOrder() {
            let read = ToolResult(
                callID: "1", content: "", isError: false,
                fileViews: [.seen(a, contentID: "A", lines: LineSet(range: 1...3))])
            let revealed = ToolResult(
                callID: "2", content: "rejected", isError: true,
                fileViews: [.seen(a, contentID: "A", lines: LineSet(range: 8...8))])
            let plain = ToolResult(callID: "3", content: "no events", isError: false)
            let state = AllAppTests.fold([read, plain, revealed])
            #expect(state.view(for: a) == FileView(contentID: "A", lines: LineSet([1, 2, 3, 8])))

            let deleted = ToolResult(callID: "4", content: "", isError: false, fileViews: [.drop(a)])
            #expect(AllAppTests.fold([read, deleted, plain]).view(for: a) == nil)
            #expect(AllAppTests.fold([deleted, read]).view(for: a) != nil)
        }

        @Test("events on an abandoned branch are ignored")
        func forkedBranches() {
            let read = ToolResult(
                callID: "c", content: "", isError: false,
                fileViews: [.seen(a, contentID: "A", lines: LineSet(range: 1...3))])
            let user = Fixtures.message(role: .user, content: "q")
            let call = Fixtures.message(
                role: .assistant, content: "", toolCalls: [ToolCall(id: "c", name: "read_file", arguments: "{}")])
            let result = Fixtures.message(role: .tool, content: "", toolResults: [read])
            let regenerated = Fixtures.message(role: .assistant, content: "again")

            var chat = Fixtures.chat(messages: [user, call, result])
            #expect(FileViewState.fold(chat.activeMessages).view(for: a) != nil)
            let forked = chat.forkRegenerating(call.id, adding: regenerated)
            #expect(forked)
            #expect(FileViewState.fold(chat.activeMessages).view(for: a) == nil)
            let switched = chat.switchActiveBranch(parentID: user.id, to: call.id)
            #expect(switched)
            #expect(FileViewState.fold(chat.activeMessages).view(for: a) != nil)
        }
    }

    // MARK: - Persistence

    @Suite("ToolResult file views")
    struct ToolResultFileViewsTests {
        @Test("events round-trip through the chat JSON under file_views")
        func roundTrip() throws {
            let a = FileKey(raw: "/p/a.txt")
            let events: [FileViewEvent] = [
                .seen(a, contentID: "0123456789ABCDEF", lines: LineSet(range: 1...9)),
                .move(from: a, to: FileKey(raw: "/p/b.txt")),
                .drop(a),
            ]
            let result = ToolResult(callID: "c", content: "x", isError: false, fileViews: events)
            let data = try JSONEncoder().encode(ChatMessage(role: .tool, content: "", toolResults: [result]))
            #expect(String(decoding: data, as: UTF8.self).contains("\"file_views\""))
            let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
            #expect(decoded.toolResults?.first?.fileViews == events)
        }

        @Test("a result without events has no file_views key")
        func absent() throws {
            let result = ToolResult(callID: "c", content: "x", isError: false)
            let data = try JSONEncoder().encode(result)
            #expect(!String(decoding: data, as: UTF8.self).contains("file_views"))
            #expect(try JSONDecoder().decode(ToolResult.self, from: data).fileViews == nil)
        }

        @Test("invalid events decode to nil without losing the result")
        func invalid() throws {
            func result(withViews views: String) -> String {
                #"{"callID":"c","content":"x","isError":true,"file_views":\#(views)}"#
            }
            let badLines = result(withViews: #"[{"kind":"seen","key":"/a","contentID":"A","lines":"nope"}]"#)
            let unknownKind = result(withViews: #"[{"kind":"bogus","key":"/a"}]"#)
            for json in [badLines, unknownKind] {
                let decoded = try JSONDecoder().decode(ToolResult.self, from: Data(json.utf8))
                #expect(decoded.fileViews == nil)
                #expect(decoded.content == "x")
                #expect(decoded.isError)
            }
        }

        @Test("provider request bodies never carry file view events")
        @MainActor
        func notSentToProviders() throws {
            let events = [
                FileViewEvent.seen(FileKey(raw: "/secret/path.txt"), contentID: "0123456789ABCDEF", lines: LineSet())
            ]
            let messages = [
                ChatMessage(role: .user, content: "go"),
                ChatMessage(
                    role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "read_file", arguments: "{}")]),
                ChatMessage(
                    role: .tool, content: "",
                    toolResults: [ToolResult(callID: "c1", content: "1:visible", isError: false, fileViews: events)]),
            ]
            let capabilities = ModelCapabilities.safeDefaults
            let ollama = ResolvedModel(
                provider: .custom("Local"), customType: .ollama, modelID: "qwen3:8b", apiKey: "",
                baseUrl: "http://ollama.test:11434", capabilities: capabilities)
            let openai = ResolvedModel(provider: .openai, modelID: "m", apiKey: "k", capabilities: capabilities)
            let anthropic = ResolvedModel(provider: .anthropic, modelID: "m", apiKey: "k", capabilities: capabilities)
            let bodies: [[String: Any]] = [
                OpenAIProvider().buildRequestBody(
                    model: openai, messages: messages, chatFilename: "chat", tools: nil, stream: false),
                AnthropicProvider().buildRequestBody(
                    model: anthropic, messages: messages, chatFilename: "chat", tools: nil, stream: false),
                OllamaProvider().buildRequestBody(
                    model: ollama, messages: messages, chatFilename: "chat", tools: nil, stream: false),
            ]
            for body in bodies {
                let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
                #expect(json.contains("1:visible"))
                #expect(!json.contains("file_views"))
                #expect(!json.contains("0123456789ABCDEF"))
                #expect(!json.contains("path.txt"))
            }
        }
    }

    // MARK: - Recording

    @Suite("File view recording")
    struct FileViewRecordingTests {
        private static let fs = BuiltinTools.filesystemGroup

        // MARK: read_file

        @Test("read_file records the displayed lines")
        func readFull() async throws {
            let tmp = try ViewTestDir()
            let content = "a\nb\nc\n"
            let file = try tmp.write("a.txt", content: content)
            let result = await AllAppTests.runTool("read_file", Self.fs, ["path": file])
            #expect(result.fileViews == [AllAppTests.seenEvent(file, content, AllAppTests.lines(1...3))])
        }

        @Test("read_file records only the requested window")
        func readPartial() async throws {
            let tmp = try ViewTestDir()
            let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let result = await AllAppTests.runTool("read_file", Self.fs, ["path": file, "ranges": "3-4"])
            #expect(result.fileViews == [AllAppTests.seenEvent(file, content, AllAppTests.lines(3...4))])
        }

        @Test("read_file records the lines left after the 2000-line cap")
        func readCapped() async throws {
            let tmp = try ViewTestDir()
            let content = (1...2500).map { "l\($0)" }.joined(separator: "\n")
            let file = try tmp.write("big.txt", content: content)
            let result = await AllAppTests.runTool("read_file", Self.fs, ["path": file])
            #expect(result.content.contains("truncated at 2000 lines"))
            #expect(result.fileViews?.first?.lines == AllAppTests.lines(1...2000))
        }

        @Test("reading an empty file or past the end records the version with no lines")
        func readNoLines() async throws {
            let tmp = try ViewTestDir()
            let empty = try tmp.write("empty.txt", content: "")
            let short = try tmp.write("short.txt", content: "a\nb\n")
            let emptyResult = await AllAppTests.runTool("read_file", Self.fs, ["path": empty])
            #expect(emptyResult.fileViews == [AllAppTests.seenEvent(empty, "", LineSet())])
            let pastEnd = await AllAppTests.runTool("read_file", Self.fs, ["path": short, "ranges": "5-"])
            #expect(pastEnd.fileViews == [AllAppTests.seenEvent(short, "a\nb\n", LineSet())])
        }

        @Test("the content id is that of the normalized text of a CRLF file with a BOM")
        func readCRLFWithBOM() async throws {
            let tmp = try ViewTestDir()
            let file = try tmp.write("crlf.txt", data: Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\r\n".utf8))
            let result = await AllAppTests.runTool("read_file", Self.fs, ["path": file])
            #expect(result.fileViews?.first?.contentID == AllAppTests.contentID("a\nb\n"))
            #expect(result.fileViews?.first?.lines == AllAppTests.lines(1...2))
        }

        @Test("read_file records nothing for errors and non-text files")
        func readNothing() async throws {
            let tmp = try ViewTestDir()
            let missing = await AllAppTests.runTool("read_file", Self.fs, ["path": tmp.sub("missing.txt")])
            #expect(missing.isError)
            #expect(missing.fileViews == nil)

            let binary = try tmp.write("x.bin", data: Data([0, 1, 2, 3, 0, 0, 0, 0, 255, 254]))
            let result = await AllAppTests.runTool("read_file", Self.fs, ["path": binary])
            #expect(result.fileViews == nil)
        }

        @Test("reads of the same content union, a changed file replaces")
        func readsFold() async throws {
            let tmp = try ViewTestDir()
            let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let first = await AllAppTests.runTool("read_file", Self.fs, ["path": file, "ranges": "1-2"])
            let second = await AllAppTests.runTool("read_file", Self.fs, ["path": file, "ranges": "4-5"])
            let key = AllAppTests.key(file)
            #expect(
                AllAppTests.fold([first, second]).view(for: key)
                    == FileView(contentID: AllAppTests.contentID(content), lines: LineSet([1, 2, 4, 5])))

            let changed = "other\n" + content
            try tmp.write("a.txt", content: changed)
            let third = await AllAppTests.runTool("read_file", Self.fs, ["path": file, "ranges": "1-1"])
            #expect(
                AllAppTests.fold([first, second, third]).view(for: key)
                    == FileView(contentID: AllAppTests.contentID(changed), lines: LineSet([1])))
        }

        // MARK: find_text

        @Test("find_text records only the lines it printed")
        func findTextMaxResults() async throws {
            let tmp = try ViewTestDir()
            let content = "needle one\nother\nneedle two\nneedle three\n"
            let file = try tmp.write("a.txt", content: content)
            let result = await AllAppTests.runTool(
                "find_text", Self.fs, ["path": tmp.path, "regex": "needle", "max_results": 1])
            #expect(result.fileViews == [AllAppTests.seenEvent(file, content, LineSet([1]))])
        }

        @Test("find_text does not record a line it cut")
        func findTextClipped() async throws {
            let tmp = try ViewTestDir()
            let content = "needle " + String(repeating: "x", count: 400) + "\nneedle two\n"
            let file = try tmp.write("a.txt", content: content)
            let result = await AllAppTests.runTool("find_text", Self.fs, ["path": tmp.path, "regex": "needle"])
            #expect(result.content.contains("…"))
            #expect(result.fileViews == [AllAppTests.seenEvent(file, content, LineSet([2]))])
        }

        @Test("find_text records context lines too")
        func findTextContext() async throws {
            let tmp = try ViewTestDir()
            let content = "a\nneedle\nb\nc\nd\n"
            let file = try tmp.write("a.txt", content: content)
            let result = await AllAppTests.runTool(
                "find_text", Self.fs, ["path": tmp.path, "regex": "needle", "context": 1])
            #expect(result.fileViews == [AllAppTests.seenEvent(file, content, AllAppTests.lines(1...3))])
        }

        @Test("find_text records one event per matching file")
        func findTextFiles() async throws {
            let tmp = try ViewTestDir()
            let a = try tmp.write("a.txt", content: "x\nneedle\n")
            let b = try tmp.write("sub/b.txt", content: "needle\n")
            try tmp.write("c.txt", content: "nothing here\n")
            let result = await AllAppTests.runTool("find_text", Self.fs, ["path": tmp.path, "regex": "needle"])
            #expect(
                result.fileViews == [
                    AllAppTests.seenEvent(a, "x\nneedle\n", LineSet([2])),
                    AllAppTests.seenEvent(b, "needle\n", LineSet([1])),
                ])
        }

        @Test("find_text with no match records nothing")
        func findTextNoMatch() async throws {
            let tmp = try ViewTestDir()
            try tmp.write("a.txt", content: "x\n")
            let result = await AllAppTests.runTool("find_text", Self.fs, ["path": tmp.path, "regex": "needle"])
            #expect(result.fileViews == nil)
        }

        // MARK: write_file

        @Test("write_file records every written line")
        func writeAll() async throws {
            let tmp = try ViewTestDir()
            let file = tmp.sub("sub/a.txt")
            let content = "a\nb\nc\n"
            let result = await AllAppTests.runTool("write_file", Self.fs, ["path": file, "content": content])
            #expect(result.fileViews == [AllAppTests.setEvent(file, content, AllAppTests.lines(1...3))])
        }

        @Test("write_file of empty content records no lines")
        func writeEmpty() async throws {
            let tmp = try ViewTestDir()
            let file = tmp.sub("a.txt")
            let result = await AllAppTests.runTool("write_file", Self.fs, ["path": file, "content": ""])
            #expect(result.fileViews == [AllAppTests.setEvent(file, "", LineSet())])
        }

        @Test("write_file records the content that was written, after prefix stripping")
        func writeStripped() async throws {
            let tmp = try ViewTestDir()
            let file = tmp.sub("a.txt")
            let result = await AllAppTests.runTool(
                "write_file", Self.fs, ["path": file, "content": "[f#ABCD]\n1:x\n2:y"])
            #expect(result.fileViews == [AllAppTests.setEvent(file, "x\ny", AllAppTests.lines(1...2))])
        }

        @Test("a write replaces what a read recorded")
        func writeAfterRead() async throws {
            let tmp = try ViewTestDir()
            let file = try tmp.write("a.txt", content: "old\n")
            let read = await AllAppTests.runTool("read_file", Self.fs, ["path": file])
            let write = await AllAppTests.runTool("write_file", Self.fs, ["path": file, "content": "new1\nnew2\n"])
            #expect(
                AllAppTests.fold([read, write]).view(for: AllAppTests.key(file))
                    == FileView(contentID: AllAppTests.contentID("new1\nnew2\n"), lines: AllAppTests.lines(1...2)))
        }

        // MARK: mv / rm / untracked tools

        @Test("mv records a move of a file")
        func moveFile() async throws {
            let tmp = try ViewTestDir()
            let src = try tmp.write("a.txt", content: "a\nb\n")
            let dst = tmp.sub("moved/b.txt")
            try FileManager.default.createDirectory(atPath: tmp.sub("moved"), withIntermediateDirectories: true)
            let read = await AllAppTests.runTool("read_file", Self.fs, ["path": src])
            let move = await AllAppTests.runTool("mv", Self.fs, ["src": src, "dst": dst])
            #expect(move.fileViews == [.move(from: AllAppTests.key(src), to: AllAppTests.key(dst))])

            let state = AllAppTests.fold([read, move])
            #expect(state.view(for: AllAppTests.key(src)) == nil)
            #expect(
                state.view(for: AllAppTests.key(dst))
                    == FileView(contentID: AllAppTests.contentID("a\nb\n"), lines: AllAppTests.lines(1...2)))
        }

        @Test("mv records a move of a directory and the views below it follow")
        func moveDirectory() async throws {
            let tmp = try ViewTestDir()
            let file = try tmp.write("old/sub/a.txt", content: "a\n")
            let read = await AllAppTests.runTool("read_file", Self.fs, ["path": file])
            let move = await AllAppTests.runTool(
                "mv", Self.fs, ["src": tmp.sub("old"), "dst": tmp.sub("new")])
            let (old, new) = (AllAppTests.key(tmp.sub("old")), AllAppTests.key(tmp.sub("new")))
            #expect(move.fileViews == [.move(from: old, to: new)])

            let state = AllAppTests.fold([read, move])
            #expect(state.view(for: AllAppTests.key(tmp.sub("old/sub/a.txt"))) == nil)
            #expect(state.view(for: AllAppTests.key(tmp.sub("new/sub/a.txt")))?.lines == AllAppTests.lines(1...1))
        }

        @Test("rm records a drop, a recursive rm drops what was read below it")
        func remove() async throws {
            let tmp = try ViewTestDir()
            let file = try tmp.write("a.txt", content: "a\n")
            let nested = try tmp.write("dir/b.txt", content: "b\n")
            let readFile = await AllAppTests.runTool("read_file", Self.fs, ["path": file])
            let readNested = await AllAppTests.runTool("read_file", Self.fs, ["path": nested])

            let removeFile = await AllAppTests.runTool("rm", Self.fs, ["path": file])
            #expect(removeFile.fileViews == [.drop(AllAppTests.key(file))])
            let removeDir = await AllAppTests.runTool("rm", Self.fs, ["path": tmp.sub("dir"), "recursive": true])
            #expect(removeDir.fileViews == [.drop(AllAppTests.key(tmp.sub("dir")))])

            let state = AllAppTests.fold([readFile, readNested, removeFile, removeDir])
            #expect(state.files.isEmpty)
        }

        @Test("failed operations record nothing")
        func failures() async throws {
            let tmp = try ViewTestDir()
            try tmp.write("dir/b.txt", content: "b\n")
            let notEmpty = await AllAppTests.runTool("rm", Self.fs, ["path": tmp.sub("dir")])
            #expect(notEmpty.isError)
            #expect(notEmpty.fileViews == nil)
            let moveMissing = await AllAppTests.runTool(
                "mv", Self.fs, ["src": tmp.sub("missing"), "dst": tmp.sub("x")])
            #expect(moveMissing.isError)
            #expect(moveMissing.fileViews == nil)
        }

        @Test("cp and ls record nothing")
        func untracked() async throws {
            let tmp = try ViewTestDir()
            let file = try tmp.write("a.txt", content: "a\n")
            let copy = await AllAppTests.runTool("cp", Self.fs, ["src": file, "dst": tmp.sub("b.txt")])
            #expect(!copy.isError)
            #expect(copy.fileViews == nil)
            let list = await AllAppTests.runTool("ls", Self.fs, ["path": tmp.path])
            #expect(list.fileViews == nil)
        }
    }
}
