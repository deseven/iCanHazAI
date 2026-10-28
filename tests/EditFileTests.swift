import AppKit
import Foundation
import Testing

@testable import iCanHazAI

/// In-process tests for the `edit_file` tool (Edit group): hashline patch
/// parsing, #TAG validation, line edits, REM/MV file ops, and the approval
/// preflight/diff. See `BuiltinToolsTests.swift` for the shared helper pattern.
///
/// Nested under `AllAppTests` so its `.serialized` trait keeps these sequential
/// with the rest of the app suites.
extension AllAppTests {

    // MARK: - Test helpers

    /// A temp directory + helpers for edit_file tests.
    private final class EditTestDir {
        let path: String
        init() throws {
            let base = NSTemporaryDirectory()
            let name = "ichai-edit-tests-\(UUID().uuidString)"
            let dir = (base as NSString).appendingPathComponent(name)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            self.path = dir
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        func sub(_ relative: String) -> String {
            (path as NSString).appendingPathComponent(relative)
        }
        @discardableResult
        func write(_ relative: String, content: String) throws -> String {
            let url = sub(relative)
            let dir = (url as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: URL(fileURLWithPath: url))
            return url
        }
        func read(_ relative: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: sub(relative)), encoding: .utf8)
        }
        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: sub(relative))
        }
    }

    /// Calls the local `edit_file` builtin with a hashline patch and returns
    /// `(text, isError)`. Unless `views` says otherwise, the model is taken to
    /// have read every file the patch names in full, so the seen-lines guard
    /// stays out of the way of tests about everything else.
    private static func editCall(
        _ input: String, workdir: Workdir = .none, views: FileViewState? = nil
    ) async -> (text: String, isError: Bool) {
        let arguments =
            (try? String(data: JSONSerialization.data(withJSONObject: ["input": input]), encoding: .utf8))
            ?? "{}"
        let result = await BuiltinTools.call(
            name: "edit_file", arguments: arguments, callID: "test", group: BuiltinTools.editGroup,
            workdir: workdir, chatFilename: "test.json",
            context: ToolContext(views: views ?? fullyViewed(input, workdir: workdir)))
        return (result.content, result.isError)
    }

    /// The state after reading, in full, every existing text file the patch
    /// names.
    private static func fullyViewed(_ input: String, workdir: Workdir) -> FileViewState {
        var state = FileViewState()
        guard let patch = try? HashlineEdit.parse(input) else { return state }
        for section in patch.sections {
            guard let resolved = try? workdir.resolve(section.path),
                let data = FileManager.default.contents(atPath: resolved),
                let file = TextFile.decode(data)
            else { continue }
            let count = file.text.isEmpty ? 0 : HashlineFormat.splitAddressableFileLines(file.text).count
            state.apply(
                .seen(
                    .local(resolved: resolved), contentID: HashlineFormat.computeContentID(file.text),
                    lines: count == 0 ? LineSet() : LineSet(range: 1...count)))
        }
        return state
    }

    /// A conversation as the file tools see it: every call runs through
    /// `BuiltinTools.call` with the views folded from the results so far, and
    /// its result joins the history like it would join the chat.
    private final class ToolHistory {
        private(set) var results: [ToolResult] = []
        let workdir: Workdir

        init(workdir: Workdir = .none) {
            self.workdir = workdir
        }

        var views: FileViewState {
            FileViewState.fold(results.map { Fixtures.message(role: .tool, content: "", toolResults: [$0]) })
        }

        @discardableResult
        func run(_ name: String, _ group: String, _ args: [String: Any]) async -> ToolResult {
            let result = await BuiltinTools.call(
                name: name, arguments: AllAppTests.argsJSON(args), callID: "call-\(results.count)", group: group,
                workdir: workdir, chatFilename: "test.json", context: ToolContext(views: views))
            results.append(result)
            return result
        }

        /// Adds events as if an earlier tool call had recorded them.
        func inject(_ events: [FileViewEvent]) {
            results.append(
                ToolResult(callID: "call-\(results.count)", content: "", isError: false, fileViews: events))
        }

        @discardableResult
        func read(_ path: String, offset: Int? = nil, limit: Int? = nil) async -> ToolResult {
            var args: [String: Any] = ["path": path]
            if let offset { args["offset"] = offset }
            if let limit { args["limit"] = limit }
            return await run("read_file", BuiltinTools.filesystemGroup, args)
        }

        @discardableResult
        func write(_ path: String, _ content: String) async -> ToolResult {
            await run("write_file", BuiltinTools.filesystemGroup, ["path": path, "content": content])
        }

        @discardableResult
        func edit(_ input: String) async -> ToolResult {
            await run("edit_file", BuiltinTools.editGroup, ["input": input])
        }

        /// `edit_file` for a patch built from one section.
        @discardableResult
        func edit(_ path: String, _ body: String, tag: String) async -> ToolResult {
            await edit(AllAppTests.patch(path, body, tag: tag))
        }
    }

    /// Builds a hashline patch input for one section.
    private static func patch(_ path: String, _ body: String, tag: String) -> String {
        "*** Begin Patch\n[\(path)#\(tag)]\n\(body)*** End Patch"
    }

    private static func argsJSON(_ dict: [String: Any]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8)) ?? "{}"
    }

    // MARK: - edit_file: line edits

    @Suite("edit_file: line edits")
    struct EditFileLineEditsTests {
        @Test("single-line replace")
        func singleLineReplace() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\ntwo\nthree\n")
            let tag = HashlineFormat.computeFileHash("one\ntwo\nthree\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=2:\n+TWO\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "one\nTWO\nthree\n")
            // Result reports the updated path and the new tag.
            let newTag = HashlineFormat.computeFileHash("one\nTWO\nthree\n")
            #expect(text.contains("Updated: \(file) [\(file)#\(newTag)]"))
        }

        @Test("multi-line replace expands the body")
        func multiLineReplace() async throws {
            let tmp = try EditTestDir()
            let content = "a\nb\nc\nd\ne\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=4:\n+X\n+Y\n+Z\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\nX\nY\nZ\ne\n")
        }

        @Test("insert before a line")
        func insertBefore() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT <2:\n+inserted\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\ninserted\nb\nc\n")
        }

        @Test("insert after a line")
        func insertAfter() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT >2:\n+inserted\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\nb\ninserted\nc\n")
        }

        @Test("insert at head")
        func insertAtHead() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT <1:\n+head\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "head\na\nb\n")
        }

        @Test("insert at tail")
        func insertAtTail() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT >$:\n+tail\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            // The tail lands before the final newline, which is kept.
            #expect(try tmp.read("a.txt") == "a\nb\ntail\n")
        }

        @Test("insert at tail of files without a final newline, empty files and lone newlines")
        func insertAtTailShapes() async throws {
            let cases: [(content: String, expected: String)] = [
                ("a\nb", "a\nb\ntail"),
                ("", "tail"),
                ("\n", "\ntail\n"),
            ]
            for (i, c) in cases.enumerated() {
                let tmp = try EditTestDir()
                let file = try tmp.write("t\(i).txt", content: c.content)
                let tag = HashlineFormat.computeFileHash(c.content)
                let (text, err) = await AllAppTests.editCall(patch(file, "PUT >$:\n+tail\n", tag: tag))
                #expect(!err, "edit_file failed for \(c.content.debugDescription): \(text)")
                #expect(try tmp.read("t\(i).txt") == c.expected, "\(c.content.debugDescription)")
            }
        }

        @Test("inserts anchored on the line after the last one are EOF inserts")
        func insertAnchoredOnPhantomLine() async throws {
            for op in ["PUT >3:", "PUT <3:"] {
                let tmp = try EditTestDir()
                let file = try tmp.write("a.txt", content: "a\nb\n")
                let tag = HashlineFormat.computeFileHash("a\nb\n")
                let (text, err) = await AllAppTests.editCall(patch(file, "\(op)\n+x\n", tag: tag))
                #expect(!err, "\(op) failed: \(text)")
                #expect(try tmp.read("a.txt") == "a\nb\nx\n", "\(op)")
            }
        }

        @Test("a range ending on the line after the last one keeps the final newline")
        func rangeEndingOnPhantomLine() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=3:\n+X\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\nX\n")
        }

        @Test("cut a range")
        func cutRange() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\nd\ne\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\nd\ne\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "CUT 2.=4\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\ne\n")
        }

        @Test("editing a CRLF file keeps CRLF endings")
        func crlfFileKeepsLineEndings() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\r\nb\r\nc\r\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=2:\n+B1\n+B2\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\r\nB1\r\nB2\r\nc\r\n")
        }

        @Test("editing a file keeps its BOM")
        func bomFileKeepsBOM() async throws {
            let tmp = try EditTestDir()
            let path = tmp.sub("bom.txt")
            try Data([0xEF, 0xBB, 0xBF] + Array("a\nb\n".utf8)).write(to: URL(fileURLWithPath: path))
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            let (text, err) = await AllAppTests.editCall(patch(path, "PUT 1.=1:\n+A\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(
                try Data(contentsOf: URL(fileURLWithPath: path)) == Data([0xEF, 0xBB, 0xBF] + Array("A\nb\n".utf8)))
        }

        @Test("a CRLF patch is accepted")
        func crlfPatch() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            let crlf = patch(file, "PUT 2.=2:\n+B\n", tag: tag).replacingOccurrences(of: "\n", with: "\r\n")
            let (text, err) = await AllAppTests.editCall(crlf)
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\nB\n")
        }
    }

    // MARK: - edit_file: diff preview

    @Suite("edit_file: diff preview")
    struct EditFileDiffPreviewTests {

        @Test("single-line replace produces a preview")
        func singleLineReplace() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\ntwo\nthree\n")
            let tag = HashlineFormat.computeFileHash("one\ntwo\nthree\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=2:\n+TWO\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            // Deleted and added lines with correct line numbers, plus context.
            #expect(text.contains("-2:two"))
            #expect(text.contains("+2:TWO"))
            #expect(text.contains(" 1:one"))
            #expect(text.contains(" 3:three"))
        }

        @Test("context lines carry post-edit numbers after an insert")
        func contextPostEditNumbers() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\n")
            // Insert a line before line 3 — line 3 shifts to line 4 in the
            // post-edit file, and the preview must show the new number.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT <3:\n+inserted\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(text.contains("+3:inserted"))
            #expect(text.contains(" 4:c"))
        }

        @Test("multi-section patch keeps each preview under its own header")
        func multiSectionAttribution() async throws {
            let tmp = try EditTestDir()
            let file1 = try tmp.write("one.txt", content: "a\nb\n")
            let file2 = try tmp.write("two.txt", content: "x\ny\n")
            let tag1 = HashlineFormat.computeFileHash("a\nb\n")
            let tag2 = HashlineFormat.computeFileHash("x\ny\n")
            let input = """
                *** Begin Patch
                [\(file1)#\(tag1)]
                PUT 1.=1:
                +A
                [\(file2)#\(tag2)]
                PUT 2.=2:
                +Y
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(!err, "edit_file failed: \(text)")
            // Each preview follows its own Updated: header (attribution).
            let updated1 = text.range(of: "Updated: \(file1)")
            let preview1 = text.range(of: "-1:a")
            let updated2 = text.range(of: "Updated: \(file2)")
            let preview2 = text.range(of: "-2:y")
            #expect(updated1 != nil && preview1 != nil && preview1!.lowerBound > updated1!.lowerBound)
            #expect(updated2 != nil && preview2 != nil && preview2!.lowerBound > updated2!.lowerBound)
            #expect(updated2!.lowerBound > preview1!.lowerBound)
        }

        @Test("multi-line replace shows all deletions and additions")
        func multiLineReplace() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\nd\ne\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\nd\ne\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=4:\n+X\n+Y\n+Z\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(text.contains("-2:b"))
            #expect(text.contains("-3:c"))
            #expect(text.contains("-4:d"))
            #expect(text.contains("+2:X"))
            #expect(text.contains("+3:Y"))
            #expect(text.contains("+4:Z"))
        }

        @Test("insert produces additions only")
        func insertOnlyAdditions() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT >2:\n+inserted\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(text.contains("+3:inserted"))
            // No '-' lines for a pure insert.
            let hasDelete = text.components(separatedBy: "\n").contains { $0.hasPrefix("-") }
            #expect(!hasDelete)
        }

        @Test("CUT produces deletions only")
        func cutOnlyDeletions() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\nd\ne\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\nd\ne\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "CUT 2.=4\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(text.contains("-2:b"))
            #expect(text.contains("-4:d"))
            // No '+' lines for a pure cut.
            let hasAdd = text.components(separatedBy: "\n").contains { $0.hasPrefix("+") }
            #expect(!hasAdd)
        }

        @Test("non-contiguous hunks are separated by a blank row")
        func nonContiguousHunks() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n")
            let tag = HashlineFormat.computeFileHash((1...10).map { "line\($0)" }.joined(separator: "\n") + "\n")
            let input = """
                *** Begin Patch
                [\(file)#\(tag)]
                PUT 2.=2:
                +TWO
                PUT 9.=9:
                +NINE
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(!err, "edit_file failed: \(text)")
            #expect(text.contains("-2:line2"))
            #expect(text.contains("-9:line9"))
            #expect(text.contains("\n\n"))
        }

        @Test("large edit is truncated with a marker")
        func largeEditTruncated() async throws {
            let tmp = try EditTestDir()
            let content = (1...400).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            // Replace all 400 lines with 400 new ones.
            let body = (1...400).map { "+NEW\($0)" }.joined(separator: "\n") + "\n"
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 1.=400:\n\(body)", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(text.contains("(diff preview truncated)"))
            // Under the line and byte caps.
            let preview = text.components(separatedBy: "\n").filter { !$0.hasPrefix("Updated:") }
            #expect(preview.count <= HashlineDiffPreview.maxLines + 1)
            #expect(text.utf8.count < HashlineDiffPreview.maxBytes * 2)
        }

        @Test("UTF-8 truncation never splits a character")
        func utf8TruncationSafe() async throws {
            let tmp = try EditTestDir()
            // Enough multi-byte lines to exceed the 8 KiB byte cap. A naive
            // byte-cap would split a 3-byte sequence at the cut, yielding
            // U+FFFD.
            let oldLine = String(repeating: "é", count: 800)  // 2 bytes each
            let newLine = String(repeating: "界", count: 800)  // 3 bytes each
            let oldContent = (1...10).map { "\(oldLine)\($0)" }.joined(separator: "\n") + "\n"
            let newContent = (1...10).map { "\(newLine)\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: oldContent)
            let tag = HashlineFormat.computeFileHash(oldContent)
            let body = newContent.components(separatedBy: "\n").map { "+\($0)" }.joined(separator: "\n") + "\n"
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 1.=10:\n\(body)", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(text.contains("(diff preview truncated)"))
            // No U+FFFD replacement character anywhere in the preview.
            #expect(!text.contains("\u{FFFD}"))
        }

        @Test("the preview reports the post-edit lines it printed, not the removed ones")
        func shownLines() throws {
            let old = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let new = old.replacingOccurrences(of: "line5\n", with: "X\nY\n")
            let preview = try #require(HashlineDiffPreview.generate(old: old, new: new))
            #expect(preview.text.contains("-5:line5"))
            // Context 3-4, added 5-6, context 7-8; the `-5:` row has no post-edit line.
            #expect(preview.shownLines == LineSet(range: 3...8))
        }

        @Test("rows cut by the truncation caps are not reported as shown")
        func shownLinesAfterTruncation() throws {
            let new = (1...400).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let preview = try #require(HashlineDiffPreview.generate(old: "line1\n", new: new))
            #expect(preview.text.hasSuffix("... (diff preview truncated)"))
            #expect(preview.shownLines == LineSet(range: 1...HashlineDiffPreview.maxLines))
            #expect(!preview.text.contains("\n201:") && !preview.text.contains("+201:"))
        }

        @Test("REM has no preview")
        func remHasNoPreview() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "REM\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(text.contains("Deleted: \(file)"))
            #expect(!text.contains("-1:"))
            #expect(!text.contains("+1:"))
        }

        @Test("no-op is an error without a preview")
        func noopHasNoPreview() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 1.=1:\n+a\n", tag: tag))
            #expect(err)
            #expect(text.contains("Edits to \(file) resulted in no changes."))
            #expect(!text.contains("-1:"))
            #expect(!text.contains("+1:"))
        }
    }

    // MARK: - edit_file: file operations

    @Suite("edit_file: file ops")
    struct EditFileFileOpsTests {
        @Test("REM deletes the file after hash validation")
        func rem() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "REM\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(!tmp.exists("a.txt"))
            #expect(text.contains("Deleted: \(file)"))
        }

        @Test("REM with a stale tag is rejected")
        func remStaleTag() async throws {
            let tmp = try EditTestDir()
            _ = try tmp.write("a.txt", content: "a\nb\n")
            let (text, err) = await AllAppTests.editCall(patch(tmp.sub("a.txt"), "REM\n", tag: "FFFF"))
            #expect(err)
            #expect(text.contains("has changed since you last read it"))
            #expect(tmp.exists("a.txt"))
        }

        @Test("MV moves the file after edits")
        func mv() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\ntwo\n")
            let tag = HashlineFormat.computeFileHash("one\ntwo\n")
            let input = """
                *** Begin Patch
                [\(file)#\(tag)]
                PUT 1.=1:
                +ONE
                MV \(tmp.sub("renamed.txt"))
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(!err, "edit_file failed: \(text)")
            #expect(!tmp.exists("a.txt"))
            #expect(try tmp.read("renamed.txt") == "ONE\ntwo\n")
            // The new tag covers the moved content.
            let newTag = HashlineFormat.computeFileHash("ONE\ntwo\n")
            #expect(text.contains("Updated: \(file) [\(tmp.sub("renamed.txt"))#\(newTag)]"))
        }

        @Test("MV validates the source hash before moving")
        func mvStaleTag() async throws {
            let tmp = try EditTestDir()
            _ = try tmp.write("a.txt", content: "a\nb\n")
            let input = """
                *** Begin Patch
                [\(tmp.sub("a.txt"))#FFFF]
                MV \(tmp.sub("renamed.txt"))
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(err)
            #expect(text.contains("has changed since you last read it"))
            #expect(tmp.exists("a.txt"))
            #expect(!tmp.exists("renamed.txt"))
        }

        @Test("MV to an existing destination is rejected (no silent overwrite)")
        func mvExistingDest() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "source content\n")
            _ = try tmp.write("dest.txt", content: "destination content\n")
            let tag = HashlineFormat.computeFileHash("source content\n")
            let input = """
                *** Begin Patch
                [\(file)#\(tag)]
                MV \(tmp.sub("dest.txt"))
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(err)
            #expect(text.contains("MV destination already exists"))
            #expect(try tmp.read("a.txt") == "source content\n")
            #expect(try tmp.read("dest.txt") == "destination content\n")
        }

        @Test("MV onto the source itself is rejected")
        func mvSelf() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            let input = """
                *** Begin Patch
                [\(file)#\(tag)]
                MV \(file)
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(err)
            #expect(text.contains("MV destination is the same"))
            #expect(tmp.exists("a.txt"))
        }
    }

    // MARK: - edit_file: validation

    @Suite("edit_file: validation")
    struct EditFileValidationTests {
        @Test("hash mismatch returns a re-read instruction")
        func hashMismatch() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 1.=1:\n+X\n", tag: "0000"))
            #expect(err)
            #expect(text.contains("has changed since you last read it"))
            #expect(text.contains("Re-read the file and retry"))
        }

        @Test("missing tag is rejected")
        func missingTag() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let input = "*** Begin Patch\n[\(file)]\nPUT 1.=1:\n+X\n*** End Patch"
            let (text, err) = await AllAppTests.editCall(input)
            #expect(err)
            #expect(text.contains("missing a `#TAG`"))
        }

        @Test("multi-section patch edits two files")
        func multiSection() async throws {
            let tmp = try EditTestDir()
            let file1 = try tmp.write("one.txt", content: "a\nb\n")
            let file2 = try tmp.write("two.txt", content: "x\ny\n")
            let tag1 = HashlineFormat.computeFileHash("a\nb\n")
            let tag2 = HashlineFormat.computeFileHash("x\ny\n")
            let input = """
                *** Begin Patch
                [\(file1)#\(tag1)]
                PUT 1.=1:
                +A
                [\(file2)#\(tag2)]
                PUT 1.=1:
                +X
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("one.txt") == "A\nb\n")
            #expect(try tmp.read("two.txt") == "X\ny\n")
            #expect(text.contains("Updated: \(file1)"))
            #expect(text.contains("Updated: \(file2)"))
        }

        @Test("out-of-bounds anchor is rejected")
        func outOfBounds() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 999.=999:\n+X\n", tag: tag))
            #expect(err)
            #expect(text.contains("out of bounds"))
        }

        @Test("out-of-bounds error reports the line count the model sees, without the phantom line")
        func outOfBoundsLineCount() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 5.=5:\n+X\n", tag: tag))
            #expect(err)
            #expect(text.contains("file has 3 lines"))
        }

        @Test("missing file is rejected")
        func missingFile() async throws {
            let tmp = try EditTestDir()
            let (text, err) = await AllAppTests.editCall(patch(tmp.sub("nope.txt"), "PUT 1.=1:\n+X\n", tag: "0000"))
            #expect(err)
            #expect(text.contains("not found"))
        }

        @Test("a directory target is rejected")
        func directoryTarget() async throws {
            let tmp = try EditTestDir()
            _ = try tmp.write("dir.txt", content: "x")
            let dir = tmp.sub("adir")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let (text, err) = await AllAppTests.editCall(patch(dir, "PUT 1.=1:\n+X\n", tag: "0000"))
            #expect(err)
            #expect(text.contains("is a directory"))
        }

        @Test("empty PUT body becomes an auto-cut with a warning")
        func emptyPutAutoCut() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=2:\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\nc\n")
            #expect(text.contains("Empty `PUT` bodies are deprecated"))
        }

        @Test("bare body rows are auto-piped with a warning surfaced in output")
        func bareBodyWarning() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "alpha\nbravo\ncharlie\n")
            let tag = HashlineFormat.computeFileHash("alpha\nbravo\ncharlie\n")
            // Row without '+': accepted as literal (matching the reference),
            // but the warning must reach the model.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=2:\nbravo (modified)\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "alpha\nbravo (modified)\ncharlie\n")
            #expect(text.contains("Warnings:"))
            #expect(text.contains("Auto-prefixed bare body row(s)"))
        }

        @Test("duplicate sections for the same file apply atomically")
        func duplicateSameFileSections() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "alpha\nbravo\ncharlie\n")
            let tag = HashlineFormat.computeFileHash("alpha\nbravo\ncharlie\n")
            // Two sections targeting the same file with the same tag must
            // apply as one batch (first section's write shifts the tag out
            // from under the second's stale-tag check).
            let input = """
                *** Begin Patch
                [\(file)#\(tag)]
                PUT 1.=1:
                +ALPHA
                [\(file)#\(tag)]
                PUT 2.=2:
                +BRAVO
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "ALPHA\nBRAVO\ncharlie\n")
        }

        @Test("conflicting tags on duplicate same-file sections are rejected up front")
        func duplicateSameFileConflictingTags() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "alpha\nbravo\ncharlie\n")
            let tag = HashlineFormat.computeFileHash("alpha\nbravo\ncharlie\n")
            let input = """
                *** Begin Patch
                [\(file)#\(tag)]
                PUT 1.=1:
                +ALPHA
                [\(file)#0000]
                PUT 2.=2:
                +BRAVO
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(err)
            #expect(text.contains("Conflicting hashline snapshot tags"))
            // Nothing was written — the merge rejects before any apply.
            #expect(try tmp.read("a.txt") == "alpha\nbravo\ncharlie\n")
        }

        @Test("apply_patch contamination is rejected")
        func applyPatchContamination() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            let input = """
                *** Begin Patch
                [\(file)#\(tag)]
                *** Update File:\(file)
                @@ -1,2 +1,2 @@
                +a
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(err)
            #expect(text.contains("apply_patch sentinel"))
        }

        @Test("a noop body is an error")
        func noop() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            // Body identical to the targeted line.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 1.=1:\n+a\n", tag: tag))
            #expect(err)
            #expect(text.contains("resulted in no changes"))
            #expect(try tmp.read("a.txt") == "a\nb\n")
        }

        @Test("non-text files are rejected")
        func nonTextFile() async throws {
            let tmp = try EditTestDir()
            // A tiny PNG magic-byte file.
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            let file = tmp.sub("img.png")
            try png.write(to: URL(fileURLWithPath: file))
            let tag = HashlineFormat.computeFileHash("x")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 1.=1:\n+X\n", tag: tag))
            #expect(err)
            #expect(text.contains("not a text file"))
        }
    }

    // MARK: - edit_file: preflight

    @Suite("edit_file: preflight")
    struct EditFilePreflightTests {
        private func argsJSON(_ input: String) -> String {
            AllAppTests.argsJSON(["input": input])
        }

        private func preflight(
            _ input: String, workdir: Workdir, views: FileViewState? = nil
        ) async throws -> HashlinePatcher.Preflight {
            try await HashlinePatcher.preflight(
                arguments: argsJSON(input), workdir: workdir,
                views: views ?? AllAppTests.fullyViewed(input, workdir: workdir))
        }

        @Test("preflight ok produces a unified diff")
        func preflightOk() async throws {
            let tmp = try EditTestDir()
            _ = try tmp.write("a.txt", content: "one\ntwo\nthree\n")
            let tag = HashlineFormat.computeFileHash("one\ntwo\nthree\n")
            let input = "*** Begin Patch\n[\(tmp.sub("a.txt"))#\(tag)]\nPUT 2.=2:\n+TWO\n*** End Patch"
            let result = try await preflight(input, workdir: Workdir(root: tmp.path, isolated: false))
            guard case .ok(let diff) = result else {
                Issue.record("expected .ok, got \(result)")
                return
            }
            let d = try #require(diff)
            #expect(d.contains("-two"))
            #expect(d.contains("+TWO"))
            // Preflight never writes.
            #expect(try tmp.read("a.txt") == "one\ntwo\nthree\n")
        }

        @Test("preflight relays parse errors")
        func preflightParseError() async throws {
            let result = try await preflight(
                "not a patch", workdir: Workdir(root: NSTemporaryDirectory(), isolated: false))
            guard case .error(let message, _) = result else {
                Issue.record("expected .error, got \(result)")
                return
            }
            #expect(!message.isEmpty)
        }

        @Test("preflight relays hash mismatches")
        func preflightHashMismatch() async throws {
            let tmp = try EditTestDir()
            _ = try tmp.write("a.txt", content: "one\ntwo\n")
            let input = "*** Begin Patch\n[\(tmp.sub("a.txt"))#0000]\nPUT 1.=1:\n+X\n*** End Patch"
            let result = try await preflight(input, workdir: Workdir(root: tmp.path, isolated: false))
            guard case .error(let message, _) = result else {
                Issue.record("expected .error, got \(result)")
                return
            }
            #expect(message.contains("has changed since you last read it"))
        }

        @Test("preflight keeps parser warnings out of the diff")
        func preflightWarnings() async throws {
            let tmp = try EditTestDir()
            _ = try tmp.write("a.txt", content: "one\ntwo\n")
            let tag = HashlineFormat.computeFileHash("one\ntwo\n")
            let input = "*** Begin Patch\n[\(tmp.sub("a.txt"))#\(tag)]\nPUT 1.=1:\nX\n*** End Patch"
            let result = try await preflight(input, workdir: Workdir(root: tmp.path, isolated: false))
            guard case .ok(let diff) = result else {
                Issue.record("expected .ok, got \(result)")
                return
            }
            // The warning is surfaced in the tool result only; the approval
            // diff must not duplicate it.
            let d = try #require(diff)
            #expect(!d.contains("WARNING:"))
            #expect(!d.contains("Auto-prefixed bare body row(s)"))
            // Preflight still never writes.
            #expect(try tmp.read("a.txt") == "one\ntwo\n")
        }

        @Test("preflight handles invalid arguments JSON")
        func preflightInvalidArgs() async throws {
            let result = try await HashlinePatcher.preflight(
                arguments: "not json", workdir: .none, views: FileViewState())
            guard case .error(let message, _) = result else {
                Issue.record("expected .error, got \(result)")
                return
            }
            #expect(message.contains("Invalid arguments"))
        }

        @Test("preflight enforces the seen-lines guard and carries the reveal events")
        func preflightGuard() async throws {
            let tmp = try EditTestDir()
            let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let wd = Workdir(root: tmp.path, isolated: false)
            let history = ToolHistory(workdir: wd)
            await history.read(file, offset: 1, limit: 3)
            let input = patch(file, "PUT 8.=8:\n+X\n", tag: HashlineFormat.computeFileHash(content))

            let first = try await preflight(input, workdir: wd, views: history.views)
            guard case .error(let message, let events) = first else {
                Issue.record("expected .error, got \(first)")
                return
            }
            #expect(message.contains("8:line8"))
            #expect(events.count == 1)
            #expect(events.first?.kind == .seen)

            // The events make the same patch pass.
            var views = history.views
            for event in events { views.apply(event) }
            guard case .ok = try await preflight(input, workdir: wd, views: views) else {
                Issue.record("the retry must pass once the revealed lines are folded in")
                return
            }
            #expect(try tmp.read("a.txt") == content)
        }

        @Test("a preflight without any view cannot be skipped by a later execution")
        func executionRechecksTheGuard() async throws {
            let tmp = try EditTestDir()
            let content = "a\nb\nc\n"
            let file = try tmp.write("a.txt", content: content)
            let input = patch(file, "PUT 2.=2:\n+B\n", tag: HashlineFormat.computeFileHash(content))
            // Straight to execution with no views, as if the preflight had
            // been skipped.
            let (text, err) = await AllAppTests.editCall(input, views: FileViewState())
            #expect(err)
            #expect(text.contains("never displayed"))
            #expect(try tmp.read("a.txt") == content)
        }

        @Test("an MV destination that exists is caught in the preflight")
        func preflightMoveDestinationExists() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "source\n")
            _ = try tmp.write("b.txt", content: "other\n")
            let tag = HashlineFormat.computeFileHash("source\n")
            let input = "*** Begin Patch\n[\(file)#\(tag)]\nMV \(tmp.sub("b.txt"))\n*** End Patch"
            let result = try await preflight(input, workdir: .none)
            guard case .error(let message, _) = result else {
                Issue.record("expected .error, got \(result)")
                return
            }
            #expect(message.contains("MV destination already exists"))
        }

        @Test("a noop is an error in the preflight too")
        func preflightNoop() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let input = patch(file, "PUT 1.=1:\n+a\n", tag: HashlineFormat.computeFileHash("a\nb\n"))
            let result = try await preflight(input, workdir: .none)
            guard case .error(let message, _) = result else {
                Issue.record("expected .error, got \(result)")
                return
            }
            #expect(message.contains("resulted in no changes"))
        }
    }

    // MARK: - edit_file: workdir

    @Suite("edit_file: workdir")
    struct EditFileWorkdirTests {
        @Test("relative paths resolve against the workdir")
        func relative() async throws {
            let tmp = try EditTestDir()
            try tmp.write("proj/a.txt", content: "one\ntwo\n")
            let tag = HashlineFormat.computeFileHash("one\ntwo\n")
            let wd = Workdir(root: tmp.sub("proj"), isolated: false)
            let input = "*** Begin Patch\n[a.txt#\(tag)]\nPUT 1.=1:\n+ONE\n*** End Patch"
            let (text, err) = await AllAppTests.editCall(input, workdir: wd)
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("proj/a.txt") == "ONE\ntwo\n")
        }

        @Test("isolated absolute paths are jail-relative")
        func isolatedAbsolute() async throws {
            let tmp = try EditTestDir()
            try tmp.write("proj/a.txt", content: "one\ntwo\n")
            let tag = HashlineFormat.computeFileHash("one\ntwo\n")
            let wd = Workdir(root: tmp.sub("proj"), isolated: true)
            let input = "*** Begin Patch\n[/a.txt#\(tag)]\nPUT 1.=1:\n+ONE\n*** End Patch"
            let (text, err) = await AllAppTests.editCall(input, workdir: wd)
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("proj/a.txt") == "ONE\ntwo\n")
        }

        @Test("path escape via .. is rejected when isolated")
        func escapeRejected() async throws {
            let tmp = try EditTestDir()
            try tmp.write("proj/a.txt", content: "one\ntwo\n")
            let tag = HashlineFormat.computeFileHash("one\ntwo\n")
            let wd = Workdir(root: tmp.sub("proj"), isolated: true)
            let input = "*** Begin Patch\n[../../outside.txt#\(tag)]\nPUT 1.=1:\n+X\n*** End Patch"
            let (text, err) = await AllAppTests.editCall(input, workdir: wd)
            #expect(err)
            #expect(text.contains("escapes"))
        }
    }

    // MARK: - edit_file: tool registry

    @Suite("edit_file: registry")
    struct EditFileRegistryTests {
        @Test("edit_file is the only Edit tool and dispatches to the Edit group")
        func registry() {
            let defs = BuiltinTools.tools(for: BuiltinTools.editGroup)
            #expect(defs.count == 1)
            #expect(defs[0].name == "edit_file")
            #expect(BuiltinTools.group(for: "edit_file") == "Edit")
            #expect(BuiltinTools.allToolNames.contains("edit_file"))
        }

        @Test("edit_file tool definition carries the hashline schema")
        func schema() throws {
            let defs = BuiltinTools.tools(for: BuiltinTools.editGroup)
            let def = defs.first { $0.name == "edit_file" }
            let schema = try #require(def?.schema)
            #expect(schema.contains("\"input\""))
            #expect(schema.contains("\"required\":[\"input\"]"))
        }
    }

    // MARK: - edit_file: seen-lines guard

    @Suite("edit_file: seen-lines guard")
    struct EditFileSeenLinesTests {
        private static func lines(_ count: Int) -> String {
            (1...count).map { "line\($0)" }.joined(separator: "\n") + "\n"
        }

        private static func tag(_ text: String) -> String { HashlineFormat.computeFileHash(text) }

        @Test("partial read then editing an unseen line is rejected")
        func partialReadUnseenLine() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            let readOut = await history.read(file, offset: 1, limit: 3)
            #expect(readOut.content.contains("[\(file)#"))
            let rej = await history.edit(file, "PUT 8.=8:\n+X\n", tag: Self.tag(content))
            #expect(rej.isError)
            #expect(rej.content.contains("never displayed"))
            // The insert and delete of a `PUT 8.=8:` replacement both anchor to
            // line 8; the guard reports each anchor line once.
            #expect(rej.content.contains("lines 8 of"))
            #expect(!rej.content.contains("8, 8"))
            #expect(try tmp.read("a.txt") == content)
        }

        @Test("an empty file read then PUT >$ is accepted")
        func emptyFileReadThenAppend() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "")
            let history = ToolHistory()
            let readOut = await history.read(file)
            #expect(readOut.content.hasSuffix("(empty file)"))
            let result = await history.edit(file, "PUT >$:\n+first\n", tag: Self.tag(""))
            #expect(!result.isError, "edit_file failed: \(result.content)")
            #expect(try tmp.read("a.txt") == "first")
        }

        @Test("an empty file has no lines to have seen: its lone line is not an anchor")
        func emptyFileLoneLine() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "")
            let history = ToolHistory()
            await history.read(file)
            let result = await history.edit(file, "PUT 1.=1:\n+first\n", tag: Self.tag(""))
            #expect(!result.isError, "edit_file failed: \(result.content)")
            #expect(try tmp.read("a.txt") == "first")
        }

        @Test("find_text only records the lines it printed in full")
        func findTextRecordsPrintedLines() async throws {
            let tmp = try EditTestDir()
            let long = "needle " + String(repeating: "x", count: 500)
            let file = try tmp.write("a.txt", content: "\(long)\nneedle two\nneedle three\nother\n")
            let history = ToolHistory()
            let result = await history.run(
                "find_text", BuiltinTools.filesystemGroup, ["path": file, "regex": "needle", "max_results": 2])
            #expect(!result.isError, "find_text failed: \(result.content)")
            // Line 1 was column-clipped and line 3 cut by max_results.
            #expect(history.views.view(for: .local(resolved: file))?.lines == LineSet([2]))
        }

        @Test("find_text hits are editable, other lines are not")
        func findTextRecordsSeenLines() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory(workdir: Workdir(root: tmp.path, isolated: false))
            let found = await history.run(
                "find_text", BuiltinTools.filesystemGroup, ["regex": "line5", "path": tmp.path])
            #expect(!found.isError)
            #expect(found.content.contains("[\(file)#"))
            let rej = await history.edit(file, "PUT 8.=8:\n+X\n", tag: Self.tag(content))
            #expect(rej.isError)
            #expect(rej.content.contains("never displayed"))
            let ok = await history.edit(file, "PUT 5.=5:\n+Y\n", tag: Self.tag(content))
            #expect(!ok.isError, "matched-line edit failed: \(ok.content)")
        }

        @Test("full read then editing any line succeeds")
        func fullReadEditsAnyLine() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file)
            let result = await history.edit(file, "PUT 8.=8:\n+X\n", tag: Self.tag(content))
            #expect(!result.isError, "edit_file failed: \(result.content)")
            #expect(
                try tmp.read("a.txt") == (1...7).map { "line\($0)" }.joined(separator: "\n") + "\nX\nline9\nline10\n")
        }

        @Test("partial read then editing a seen line succeeds")
        func partialReadSeenLine() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file, offset: 1, limit: 3)
            let result = await history.edit(file, "PUT 2.=2:\n+X\n", tag: Self.tag(content))
            #expect(!result.isError, "edit_file failed: \(result.content)")
            #expect(try tmp.read("a.txt") == "line1\nX\n" + (3...10).map { "line\($0)" }.joined(separator: "\n") + "\n")
        }

        // MARK: Strictness

        @Test("a file that was never displayed is rejected without revealing content")
        func neverDisplayedFile() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            // A valid tag, but no read ever produced it.
            let input = patch(file, "PUT 8.=8:\n+X\n", tag: Self.tag(content))
            let rej = await history.edit(input)
            #expect(rej.isError)
            #expect(rej.content.contains("never displayed"))
            #expect(!rej.content.contains("line8"))
            #expect(rej.fileViews == nil)
            // Retrying without a read is rejected again, still without content.
            let retry = await history.edit(input)
            #expect(retry.isError)
            #expect(!retry.content.contains("line8"))
            #expect(try tmp.read("a.txt") == content)
        }

        @Test("a view of another version of the file is rejected without revealing content")
        func otherVersionOfTheFile() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let file = try tmp.write("a.txt", content: content)
            var views = FileViewState()
            views.apply(.seen(.local(resolved: file), contentID: "0000000000000000", lines: LineSet(range: 1...10)))
            let (text, err) = await AllAppTests.editCall(
                patch(file, "PUT 8.=8:\n+X\n", tag: Self.tag(content)), views: views)
            #expect(err)
            #expect(text.contains("never displayed"))
            #expect(!text.contains("line8"))
            #expect(try tmp.read("a.txt") == content)
        }

        @Test("a view left by a read on an abandoned branch does not count")
        func abandonedBranch() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            let read = await history.read(file)
            let input = patch(file, "PUT 8.=8:\n+X\n", tag: Self.tag(content))

            let user = Fixtures.message(role: .user, content: "q")
            let call = Fixtures.message(
                role: .assistant, content: "",
                toolCalls: [ToolCall(id: read.callID, name: "read_file", arguments: "{}")])
            let result = Fixtures.message(role: .tool, content: "", toolResults: [read])
            var chat = Fixtures.chat(messages: [user, call, result])
            let forked = chat.forkRegenerating(call.id, adding: Fixtures.message(role: .assistant, content: "again"))
            #expect(forked)

            let (text, err) = await AllAppTests.editCall(input, views: FileViewState.fold(chat.activeMessages))
            #expect(err)
            #expect(text.contains("never displayed"))
            #expect(try tmp.read("a.txt") == content)

            let switched = chat.switchActiveBranch(parentID: user.id, to: call.id)
            #expect(switched)
            let (okText, okErr) = await AllAppTests.editCall(input, views: FileViewState.fold(chat.activeMessages))
            #expect(!okErr, "edit_file failed: \(okText)")
        }

        @Test("views survive a save and reload of the chat")
        func viewsSurviveReload() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file, offset: 1, limit: 3)
            let reloaded = try history.results.map { result -> ToolResult in
                try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(result))
            }
            let views = FileViewState.fold(
                reloaded.map { Fixtures.message(role: .tool, content: "", toolResults: [$0]) })
            let input = patch(file, "PUT 2.=2:\n+X\n", tag: Self.tag(content))
            let (text, err) = await AllAppTests.editCall(input, views: views)
            #expect(!err, "edit_file failed: \(text)")
        }

        // MARK: Reveal on reject

        @Test("up to 20 unseen lines are revealed and count as seen: the same edit goes through")
        func revealThenRetry() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file, offset: 1, limit: 3)
            let input = patch(file, "PUT 8.=8:\n+X\n", tag: Self.tag(content))

            let rej = await history.edit(input)
            #expect(rej.isError)
            #expect(rej.content.contains("8:line8"))
            #expect(rej.content.contains("marked as seen"))
            #expect(rej.fileViews?.count == 1)
            #expect(rej.fileViews?.first?.kind == .seen)
            #expect(try tmp.read("a.txt") == content)

            let retry = await history.edit(input)
            #expect(!retry.isError, "the retry must pass: \(retry.content)")
            #expect(try tmp.read("a.txt").contains("\nX\n"))
        }

        @Test("more than 20 unseen lines: a partial reveal, nothing recorded, the retry is still rejected")
        func largeUnseenRange() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(60)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file, offset: 1, limit: 3)
            // 50 unseen lines (4-53): the message collapses the list into a range.
            let input = patch(file, "PUT 4.=53:\n+X\n", tag: Self.tag(content))

            let rej = await history.edit(input)
            #expect(rej.isError)
            #expect(rej.content.contains("4-53 (50 lines)"))
            #expect(rej.content.contains("never displayed"))
            // Only the first 20 are shown.
            #expect(rej.content.contains("4:line4"))
            #expect(rej.content.contains("23:line23"))
            #expect(!rej.content.contains("24:line24"))
            #expect(rej.content.contains("NOT marked as seen"))
            #expect(rej.fileViews == nil)

            let retry = await history.edit(input)
            #expect(retry.isError)
            #expect(retry.fileViews == nil)
            #expect(try tmp.read("a.txt") == content)
        }

        @Test("a line cut at 300 characters is not a complete reveal")
        func clippedReveal() async throws {
            let tmp = try EditTestDir()
            let long = String(repeating: "x", count: 400)
            let content = "a\nb\n\(long)\nd\n"
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file, offset: 1, limit: 2)
            let input = patch(file, "PUT 3.=3:\n+X\n", tag: Self.tag(content))

            let rej = await history.edit(input)
            #expect(rej.isError)
            #expect(rej.content.contains(String(repeating: "x", count: 300) + "…"))
            #expect(!rej.content.contains(String(repeating: "x", count: 301)))
            #expect(rej.content.contains("NOT marked as seen"))
            #expect(rej.fileViews == nil)

            let retry = await history.edit(input)
            #expect(retry.isError)
            #expect(try tmp.read("a.txt") == content)
        }

        @Test("an anchor beyond the file is a bounds error, not a guard rejection")
        func outOfRangeAnchor() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file, offset: 1, limit: 3)
            let result = await history.edit(file, "PUT 999.=999:\n+X\n", tag: Self.tag(content))
            #expect(result.isError)
            #expect(result.content.contains("out of bounds"))
            #expect(!result.content.contains("never displayed"))
            #expect(result.fileViews == nil)
        }

        @Test("a multi-file patch gets every reveal in one error, and one retry lands both")
        func multiFileReveal() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let fileA = try tmp.write("a.txt", content: content)
            let fileB = try tmp.write("b.txt", content: content)
            let history = ToolHistory()
            await history.read(fileA, offset: 1, limit: 2)
            await history.read(fileB, offset: 1, limit: 2)
            let input = """
                *** Begin Patch
                [\(fileA)#\(Self.tag(content))]
                PUT 5.=5:
                +A
                [\(fileB)#\(Self.tag(content))]
                PUT 7.=7:
                +B
                *** End Patch
                """

            let rej = await history.edit(input)
            #expect(rej.isError)
            #expect(rej.content.contains("5:line5"))
            #expect(rej.content.contains("7:line7"))
            #expect(rej.fileViews?.count == 2)
            #expect(try tmp.read("a.txt") == content)
            #expect(try tmp.read("b.txt") == content)

            let retry = await history.edit(input)
            #expect(!retry.isError, "the retry must pass: \(retry.content)")
            #expect(try tmp.read("a.txt").contains("\nA\n"))
            #expect(try tmp.read("b.txt").contains("\nB\n"))
        }

        // MARK: What an edit teaches the guard

        @Test("lines seen before an edit stay seen at their new numbers")
        func carryOver() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(100)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file)
            // One line becomes four: old line 80 is line 83 afterwards.
            let first = await history.edit(file, "PUT 5.=5:\n+a\n+b\n+c\n+d\n", tag: Self.tag(content))
            #expect(!first.isError, "first edit failed: \(first.content)")
            let edited = try tmp.read("a.txt")
            let second = await history.edit(file, "PUT 83.=83:\n+X\n", tag: Self.tag(edited))
            #expect(!second.isError, "second edit failed: \(second.content)")
            #expect(try tmp.read("a.txt").contains("\nX\nline81\n"))
        }

        @Test("a partial read stays partial after an edit")
        func partialStaysPartial() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(60)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file, offset: 1, limit: 5)
            let first = await history.edit(file, "PUT 5.=5:\n+X\n", tag: Self.tag(content))
            #expect(!first.isError, "seen-line edit failed: \(first.content)")
            let edited = try tmp.read("a.txt")

            // Line 30 was never displayed; neither the read nor the edit's
            // preview showed it.
            let rej = await history.edit(file, "PUT 30.=30:\n+Y\n", tag: Self.tag(edited))
            #expect(rej.isError, "editing line 30 must be rejected: \(rej.content)")
            #expect(rej.content.contains("never displayed"))
            #expect(try tmp.read("a.txt") == edited)
        }

        @Test("removed lines do not leak their old numbers into the post-edit view")
        func removedLinesDoNotLeak() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(200)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file, offset: 1, limit: 60)
            let cut = await history.edit(file, "CUT 50.=60\n", tag: Self.tag(content))
            #expect(!cut.isError, "cut failed: \(cut.content)")
            let edited = try tmp.read("a.txt")
            let newTag = Self.tag(edited)

            // The preview showed post-edit lines 48-51 (old 48, 49, 61, 62), so
            // post-edit 52-60 (old 63-71) were never displayed even though the
            // removed rows carried the numbers 50-60.
            let rej = await history.edit(file, "PUT 55.=55:\n+X\n", tag: newTag)
            #expect(rej.isError)
            #expect(rej.content.contains("never displayed"))
            let ok = await history.edit(file, "PUT 51.=51:\n+X\n", tag: newTag)
            #expect(!ok.isError, "a line of the preview must be editable: \(ok.content)")
        }

        @Test("an edit records a set event: carried-over lines, authored lines, preview rows")
        func editRecordsSetEvent() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file, offset: 1, limit: 3)
            let result = await history.edit(file, "PUT 2.=2:\n+X\n+Y\n", tag: Self.tag(content))
            #expect(!result.isError, "edit failed: \(result.content)")

            let events = try #require(result.fileViews)
            #expect(events.count == 1)
            let event = try #require(events.first)
            #expect(event.kind == .set)
            #expect(event.key == .local(resolved: file))
            #expect(event.contentID == HashlineFormat.computeContentID(try tmp.read("a.txt")))
            // Seen 1-3 → 1, (2 replaced), 3→4; authored 2-3; preview rows 1-5.
            #expect(event.lines == LineSet(range: 1...5))
        }

        @Test("MV: the destination is editable with the new tag, the source view is gone")
        func mvMovesTheView() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(10)
            let file = try tmp.write("a.txt", content: content)
            let dest = tmp.sub("renamed.txt")
            let history = ToolHistory()
            await history.read(file)
            let mv = await history.edit("*** Begin Patch\n[\(file)#\(Self.tag(content))]\nMV \(dest)\n*** End Patch")
            #expect(!mv.isError, "MV failed: \(mv.content)")
            #expect(history.views.view(for: .local(resolved: file)) == nil)
            #expect(history.views.view(for: .local(resolved: dest)) != nil)

            let newTag = Self.tag(try tmp.read("renamed.txt"))
            let result = await history.edit(dest, "PUT 5.=5:\n+Y\n", tag: newTag)
            #expect(!result.isError, "edit after MV failed: \(result.content)")
            #expect(try tmp.read("renamed.txt").contains("\nY\n"))
        }

        @Test("MV replaces whatever the model knew about the destination path")
        func mvReplacesDestinationView() async throws {
            let tmp = try EditTestDir()
            let content = Self.lines(5)
            let file = try tmp.write("src.txt", content: content)
            let dest = tmp.sub("dest.txt")
            let history = ToolHistory()
            // The model once saw another file at the destination, since removed.
            history.inject([.seen(.local(resolved: dest), contentID: "STALE", lines: LineSet(range: 1...9))])
            await history.read(file)
            let mv = await history.edit("*** Begin Patch\n[\(file)#\(Self.tag(content))]\nMV \(dest)\n*** End Patch")
            #expect(!mv.isError, "MV failed: \(mv.content)")
            let view = try #require(history.views.view(for: .local(resolved: dest)))
            #expect(view.contentID == HashlineFormat.computeContentID(content))
            #expect(view.lines == LineSet(range: 1...5))
        }

        @Test("REM drops the view")
        func remDropsTheView() async throws {
            let tmp = try EditTestDir()
            let content = "a\nb\nc\n"
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file)
            let rem = await history.edit(file, "REM\n", tag: Self.tag(content))
            #expect(!rem.isError, "REM failed: \(rem.content)")
            #expect(!tmp.exists("a.txt"))
            #expect(history.views.view(for: .local(resolved: file)) == nil)
        }

        @Test("write_file's tag edits any line without a read")
        func writeThenEdit() async throws {
            let tmp = try EditTestDir()
            let file = tmp.sub("a.txt")
            let content = Self.lines(10)
            let history = ToolHistory()
            let written = await history.write(file, content)
            #expect(!written.isError, "write_file failed: \(written.content)")
            let header = HashlineFormat.formatHashlineHeader(path: file, fileHash: Self.tag(content))
            #expect(written.content.contains(header), "write_file must return the #TAG: \(written.content)")
            let result = await history.edit(file, "PUT 8.=8:\n+X\n", tag: Self.tag(content))
            #expect(!result.isError, "edit after write_file failed: \(result.content)")
            #expect(try tmp.read("a.txt").contains("\nX\n"))
        }

        @Test("a write with pasted line prefixes: the tag and view describe what was written")
        func writeWithStrippedPrefixes() async throws {
            let tmp = try EditTestDir()
            let file = tmp.sub("a.txt")
            let history = ToolHistory()
            let written = await history.write(file, "[\(file)#ABCD]\n1:x\n2:y")
            #expect(!written.isError, "write_file failed: \(written.content)")
            #expect(try tmp.read("a.txt") == "x\ny")
            let result = await history.edit(file, "PUT 1.=1:\n+X\n", tag: Self.tag("x\ny"))
            #expect(!result.isError, "edit after write_file failed: \(result.content)")
            #expect(try tmp.read("a.txt") == "X\ny")
        }
    }

    // MARK: - edit_file: pipeline

    @Suite("edit_file: pipeline")
    struct EditFilePipelineTests {
        @Test("a stale tag in a later section leaves every file untouched")
        func staleTagLeavesEverythingUntouched() async throws {
            let tmp = try EditTestDir()
            let fileA = try tmp.write("a.txt", content: "a\nb\n")
            let fileB = try tmp.write("b.txt", content: "x\ny\n")
            let input = """
                *** Begin Patch
                [\(fileA)#\(HashlineFormat.computeFileHash("a\nb\n"))]
                PUT 1.=1:
                +A
                [\(fileB)#0000]
                PUT 1.=1:
                +X
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(err)
            #expect(text.contains("has changed since you last read it"))
            #expect(try tmp.read("a.txt") == "a\nb\n")
            #expect(try tmp.read("b.txt") == "x\ny\n")
        }

        @Test("a noop section fails the whole patch")
        func noopSectionFailsThePatch() async throws {
            let tmp = try EditTestDir()
            let fileA = try tmp.write("a.txt", content: "a\nb\n")
            let fileB = try tmp.write("b.txt", content: "x\ny\n")
            let input = """
                *** Begin Patch
                [\(fileA)#\(HashlineFormat.computeFileHash("a\nb\n"))]
                PUT 1.=1:
                +A
                [\(fileB)#\(HashlineFormat.computeFileHash("x\ny\n"))]
                PUT 1.=1:
                +x
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(err)
            #expect(text.contains("Edits to \(fileB) resulted in no changes."))
            #expect(try tmp.read("a.txt") == "a\nb\n")
        }

        @Test("two spellings of one file are rejected, not applied one after the other")
        func twoSpellingsOfOneFile() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\n")
            let input = """
                *** Begin Patch
                [\(file)#\(tag)]
                PUT 1.=1:
                +A
                [\(tmp.path)/./a.txt#\(tag)]
                PUT 3.=3:
                +C
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(err)
            #expect(text.contains("resolve to the same file"))
            #expect(try tmp.read("a.txt") == "a\nb\nc\n")
        }

        @Test("a symlink and its target are one file")
        func symlinkAndTarget() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\n")
            let link = tmp.sub("link.txt")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
            let tag = HashlineFormat.computeFileHash("a\nb\nc\n")
            let input = """
                *** Begin Patch
                [\(file)#\(tag)]
                PUT 1.=1:
                +A
                [\(link)#\(tag)]
                PUT 3.=3:
                +C
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(err)
            #expect(text.contains("resolve to the same file"))
            #expect(try tmp.read("a.txt") == "a\nb\nc\n")
        }

        @Test("two sections cannot move to the same destination")
        func sameDestinationTwice() async throws {
            let tmp = try EditTestDir()
            let fileA = try tmp.write("a.txt", content: "a\n")
            let fileB = try tmp.write("b.txt", content: "b\n")
            let dest = tmp.sub("dest.txt")
            let input = """
                *** Begin Patch
                [\(fileA)#\(HashlineFormat.computeFileHash("a\n"))]
                MV \(dest)
                [\(fileB)#\(HashlineFormat.computeFileHash("b\n"))]
                MV \(dest)
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(err)
            #expect(text.contains("used by more than one section"))
            #expect(tmp.exists("a.txt") && tmp.exists("b.txt") && !tmp.exists("dest.txt"))
        }

        @Test("MV into a new directory creates it and keeps the BOM and CRLF endings")
        func moveKeepsEncoding() async throws {
            let tmp = try EditTestDir()
            let path = tmp.sub("a.txt")
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            try Data(bom + Array("a\r\nb\r\n".utf8)).write(to: URL(fileURLWithPath: path))
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            let dest = tmp.sub("moved/dir/b.txt")
            let input = "*** Begin Patch\n[\(path)#\(tag)]\nPUT 1.=1:\n+A\nMV \(dest)\n*** End Patch"
            let (text, err) = await AllAppTests.editCall(input)
            #expect(!err, "edit_file failed: \(text)")
            #expect(!tmp.exists("a.txt"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: dest)) == Data(bom + Array("A\r\nb\r\n".utf8)))
        }

        @Test("a failing write reports which sections landed and keeps their view events")
        func partialCommitIsReported() async throws {
            let tmp = try EditTestDir()
            let fileA = try tmp.write("a.txt", content: "a\nb\n")
            let fileB = try tmp.write("b.txt", content: "x\ny\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fileB)
            let input = """
                *** Begin Patch
                [\(fileA)#\(HashlineFormat.computeFileHash("a\nb\n"))]
                PUT 1.=1:
                +A
                [\(fileB)#\(HashlineFormat.computeFileHash("x\ny\n"))]
                PUT 1.=1:
                +X
                *** End Patch
                """
            let history = ToolHistory()
            history.inject([
                .seen(
                    .local(resolved: fileA), contentID: HashlineFormat.computeContentID("a\nb\n"),
                    lines: LineSet(range: 1...2)),
                .seen(
                    .local(resolved: fileB), contentID: HashlineFormat.computeContentID("x\ny\n"),
                    lines: LineSet(range: 1...2)),
            ])
            let result = await history.edit(input)
            #expect(result.isError)
            #expect(result.content.contains("applied only partly"))
            #expect(result.content.contains("Written: \(fileA)"))
            #expect(result.content.contains("Not written: \(fileB)"))
            #expect(try tmp.read("a.txt") == "A\nb\n")
            #expect(try tmp.read("b.txt") == "x\ny\n")
            // The landed section's new version is known, the failed one's old
            // version still is.
            let state = history.views
            #expect(state.view(for: .local(resolved: fileA))?.contentID == HashlineFormat.computeContentID("A\nb\n"))
            #expect(state.view(for: .local(resolved: fileB))?.contentID == HashlineFormat.computeContentID("x\ny\n"))
        }
    }

    // MARK: - edit_file: boundary repair

    @Suite("edit_file: boundary repair")
    struct EditFileBoundaryRepairTests {
        @Test("two-sided echo: restated boundary lines are dropped with a warning")
        func twoSidedEchoRepaired() async throws {
            let tmp = try EditTestDir()
            let content = "a\nb\nc\nd\ne\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            // Replace lines 2-3; the body restates line 1 (above) and line 4
            // (below) — both are dropped so they are not duplicated.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=3:\n+a\n+X\n+d\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\nX\nd\ne\n")
            #expect(text.contains("Auto-repaired a replacement boundary echo at line 2"))
            #expect(text.contains("dropped 1 leading and 1 trailing payload line(s)"))
        }

        @Test("one-sided leading echo: body restates lines above the range")
        func oneSidedLeadingEcho() async throws {
            let tmp = try EditTestDir()
            let content = "a\nb\nc\nd\ne\nf\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            // Replace lines 3-4; the body restates lines 1-2 just above the range.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 3.=4:\n+a\n+b\n+X\n+Y\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\nb\nX\nY\ne\nf\n")
            #expect(text.contains("dropped 2 leading payload line(s)"))
            #expect(text.contains("just above the range"))
        }

        @Test("one-sided trailing echo: body restates a line below the range")
        func oneSidedTrailingEcho() async throws {
            let tmp = try EditTestDir()
            let content = "a\nb\nc\nd\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            // Replace lines 1-2; the body restates line 3 just below the range.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 1.=2:\n+X\n+Y\n+c\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "X\nY\nc\nd\n")
            #expect(text.contains("dropped 1 trailing payload line(s)"))
            #expect(text.contains("just below the range"))
        }

        @Test("one-sided echo on a single-line range is not repaired")
        func singleLineOneSidedEchoLeftAlone() async throws {
            let tmp = try EditTestDir()
            let content = "a\nb\nc\nd\ne\nf\ng\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            // The body ends with a copy of line 6, but a duplicated neighbouring
            // statement may well be intended, so it is applied as written.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 5.=5:\n+E\n+f\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\nb\nc\nd\nE\nf\nf\ng\n")
            #expect(!text.contains("Auto-repaired"))
        }

        @Test("one-sided echo too short for the widened range is rejected, not repaired")
        func shiftedRangeEchoRejected() async throws {
            let tmp = try EditTestDir()
            let content = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            // Meant lines 6-8, but the range names 5-7: the trailing `l8` echo would
            // be dropped and `l5` silently deleted. Reject instead.
            let (text, err) = await AllAppTests.editCall(
                patch(file, "PUT 5.=7:\n+L6\n+L7\n+l8\n", tag: tag))
            #expect(err)
            #expect(text.contains("`PUT 5.=7:` rejected"))
            #expect(text.contains("too short"))
            #expect(try tmp.read("a.txt") == content)
        }

        @Test("one-sided echo with a payload long enough for the widened range is repaired")
        func widenedRangeEchoRepaired() async throws {
            let tmp = try EditTestDir()
            let content = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            let (text, err) = await AllAppTests.editCall(
                patch(file, "PUT 5.=7:\n+A\n+B\n+C\n+l8\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "l1\nl2\nl3\nl4\nA\nB\nC\nl8\nl9\n")
            #expect(text.contains("dropped 1 trailing payload line(s)"))
        }

        @Test("two-sided echo that shifts the delimiter balance is not repaired")
        func imbalancedTwoSidedEchoLeftAlone() async throws {
            let tmp = try EditTestDir()
            let content = "foo(\nx\ny\nbar\nz\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            // Dropping `foo(` would leave the payload's own `w(` unmatched.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=3:\n+foo(\n+w(\n+bar\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "foo(\nfoo(\nw(\nbar\nbar\nz\n")
            #expect(!text.contains("Auto-repaired"))
        }

        @Test("two-sided echo of balanced delimiters is repaired")
        func balancedTwoSidedEchoRepaired() async throws {
            let tmp = try EditTestDir()
            let content = "f(\nx\ny\n)\nz\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=3:\n+f(\n+w\n+)\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "f(\nw\n)\nz\n")
            #expect(text.contains("dropped 1 leading and 1 trailing payload line(s)"))
        }

        @Test("duplicated trailing closer that explains the imbalance is dropped")
        func duplicateSuffixRepaired() async throws {
            let tmp = try EditTestDir()
            let content = "foo(\n  a,\n  b,\n)\ntail\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            let (text, err) = await AllAppTests.editCall(
                patch(file, "PUT 2.=3:\n+  a2,\n+  b2,\n+)\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "foo(\n  a2,\n  b2,\n)\ntail\n")
            #expect(text.contains("delimiter-balance mismatch"))
            #expect(text.contains("dropped 1 duplicated trailing payload line(s)"))
        }

        @Test("duplicated leading opener that explains the imbalance is dropped")
        func duplicatePrefixRepaired() async throws {
            let tmp = try EditTestDir()
            let content = "x\nfoo(\n  a,\n)\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            let (text, err) = await AllAppTests.editCall(
                patch(file, "PUT 3.=4:\n+foo(\n+  a2,\n+)\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "x\nfoo(\n  a2,\n)\n")
            #expect(text.contains("dropped 1 duplicated leading payload line(s)"))
        }

        @Test("echo repair works on a CRLF file and keeps its endings")
        func crlfEchoRepaired() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\r\nb\r\nc\r\nd\r\ne\r\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\nd\ne\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=3:\n+a\n+X\n+d\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\r\nX\r\nd\r\ne\r\n")
            #expect(text.contains("dropped 1 leading and 1 trailing payload line(s)"))
        }

        @Test("whole-payload echo is left alone as intentional")
        func wholePayloadEchoLeftAlone() async throws {
            let tmp = try EditTestDir()
            let content = "a\nb\nc\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            // Body is entirely a restatement of the boundaries (k+j >= payload):
            // ambiguous, so the edit applies as-is with no repair.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=2:\n+a\n+c\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\na\nc\nc\n")
            #expect(!text.contains("Auto-repaired"))
        }

        @Test("clean replace produces no repair and no warning")
        func noEchoNoRepair() async throws {
            let tmp = try EditTestDir()
            let content = "a\nb\nc\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=2:\n+B\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\nB\nc\n")
            #expect(!text.contains("Auto-repaired"))
        }

        @Test("multi-hunk patch: only the echoed hunk is repaired")
        func multiHunkOnlyEchoedRepaired() async throws {
            let tmp = try EditTestDir()
            let content = "alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\ngolf\nhotel\nindia\njuliet\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            let input = """
                *** Begin Patch
                [\(file)#\(tag)]
                PUT 2.=3:
                +alpha
                +X
                +delta
                PUT 7.=7:
                +GOLF
                *** End Patch
                """
            let (text, err) = await AllAppTests.editCall(input)
            #expect(!err, "edit_file failed: \(text)")
            // Hunk 1 dropped its echoed edges; hunk 2 applied unchanged.
            #expect(
                try tmp.read("a.txt") == "alpha\nX\ndelta\necho\nfoxtrot\nGOLF\nhotel\nindia\njuliet\n")
            // Exactly one warning, attributed to the echoed hunk.
            let occurrences = text.components(separatedBy: "Auto-repaired a replacement boundary echo").count - 1
            #expect(occurrences == 1)
            #expect(text.contains("at line 2"))
        }
    }
}
