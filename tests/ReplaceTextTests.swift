import Foundation
import Testing

@testable import iCanHazAI

/// In-process tests for the `replace_text` tool (Edit group): exact find and
/// replace, validation, the file views it records (so `edit_file` can follow
/// without a read), the approval preflight, and the `#TAG`-free results and
/// descriptions for a model without `edit_file`. Shares its temp directory and
/// conversation helpers with `EditFileTests.swift`.
extension AllAppTests {

    // MARK: - Test helpers

    private static func replaceCall(
        _ args: [String: Any], workdir: Workdir = .none, context: ToolContext = ToolContext()
    ) async -> ToolResult {
        let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
        return await BuiltinTools.call(
            name: "replace_text", arguments: arguments, callID: "test", group: BuiltinTools.editGroup,
            workdir: workdir, chatFilename: "test.json", context: context)
    }

    private static func replaceArgs(_ path: String, _ old: String, _ new: String, all: Bool? = nil) -> [String: Any] {
        var args: [String: Any] = ["path": path, "old_text": old, "new_text": new]
        if let all { args["replace_all"] = all }
        return args
    }

    private static func numberedLines(_ count: Int) -> String {
        (1...count).map { "line\($0)" }.joined(separator: "\n") + "\n"
    }

    // MARK: - replace_text: replacing

    @Suite("replace_text: replacing")
    struct ReplaceTextReplacingTests {

        @Test("a unique match is replaced and the result has the edit_file shape")
        func uniqueMatch() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\ntwo\nthree\n")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "two", "TWO"))
            #expect(!result.isError, "\(result.content)")
            #expect(try tmp.read("a.txt") == "one\nTWO\nthree\n")
            let tag = HashlineFormat.computeFileHash("one\nTWO\nthree\n")
            #expect(result.content == "Updated: \(file) [\(file)#\(tag)] (+1 -1)\n 1:one\n-:two\n+2:TWO\n 3:three")
        }

        @Test("a fragment of a line is replaced, the whole changed line is shown")
        func fragmentOfLine() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.swift", content: "let a = 1\nlet x = old\nlet b = 2\n")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "x = old", "x = new"))
            #expect(!result.isError, "\(result.content)")
            #expect(try tmp.read("a.swift") == "let a = 1\nlet x = new\nlet b = 2\n")
            #expect(result.content.hasSuffix("\n 1:let a = 1\n-:let x = old\n+2:let x = new\n 3:let b = 2"))
        }

        @Test("a relative path resolves against the working directory and is reported as given")
        func relativePath() async throws {
            let tmp = try EditTestDir()
            try tmp.write("src/a.txt", content: "one\ntwo\n")
            let result = await AllAppTests.replaceCall(
                AllAppTests.replaceArgs("src/a.txt", "one", "ONE"), workdir: Workdir(root: tmp.path, isolated: false))
            #expect(!result.isError, "\(result.content)")
            #expect(try tmp.read("src/a.txt") == "ONE\ntwo\n")
            let tag = HashlineFormat.computeFileHash("ONE\ntwo\n")
            #expect(result.content.hasPrefix("Updated: src/a.txt [src/a.txt#\(tag)] (+1 -1)\n"))
        }

        @Test("a multi-line old_text and new_text are replaced as a block")
        func multiLine() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\nd\n")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "b\nc", "X\nY\nZ"))
            #expect(!result.isError, "\(result.content)")
            #expect(try tmp.read("a.txt") == "a\nX\nY\nZ\nd\n")
            #expect(result.content.hasSuffix("\n 1:a\n-:b\n-:c\n+2:X\n+3:Y\n+4:Z\n 5:d"))
            #expect(result.content.contains("(+3 -2)"))
        }

        @Test("an empty new_text deletes old_text")
        func deletion() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "keep\ndrop me\nkeep too\n")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "drop me\n", ""))
            #expect(!result.isError, "\(result.content)")
            #expect(try tmp.read("a.txt") == "keep\nkeep too\n")
            #expect(result.content.contains("(-1)"))
            #expect(result.content.hasSuffix("\n 1:keep\n-:drop me\n 2:keep too"))
        }

        @Test("text can be inserted by matching a neighbour and repeating it")
        func insertion() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\nc\n")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "b", "b\ninserted"))
            #expect(!result.isError, "\(result.content)")
            #expect(try tmp.read("a.txt") == "a\nb\ninserted\nc\n")
            #expect(result.content.contains("(+1)"))
        }

        @Test("a match at the very end of a file without a final newline")
        func matchAtEnd() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "b", "B"))
            #expect(!result.isError, "\(result.content)")
            #expect(try tmp.read("a.txt") == "a\nB")
        }

        @Test("matching is exact: case, indentation and line breaks count")
        func exactMatch() async throws {
            let tmp = try EditTestDir()
            let content = "Two\n  b\nc\n"
            let file = try tmp.write("a.txt", content: content)
            for old in ["two", "TWO", "Two\n b", "Two b", "Two\n\n  b"] {
                let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, old, "x"))
                #expect(result.isError, "\(old.debugDescription) should not match")
                #expect(result.content.contains("was not found"))
            }
            #expect(try tmp.read("a.txt") == content)
        }

        @Test("canonically equivalent Unicode is not the same text")
        func unicodeIsExact() async throws {
            let tmp = try EditTestDir()
            let precomposed = "caf\u{00E9}\n"
            let file = try tmp.write("a.txt", content: precomposed)
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "cafe\u{0301}", "coffee"))
            #expect(result.isError)
            #expect(result.content.contains("was not found"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data(precomposed.utf8))
        }

        @Test("multi-byte text is replaced on character boundaries")
        func multiByte() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "héllo wörld 日本語\n")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "wörld 日本", "world 本"))
            #expect(!result.isError, "\(result.content)")
            #expect(try tmp.read("a.txt") == "héllo world 本語\n")
        }

        // MARK: Ambiguity and replace_all

        @Test("several matches without replace_all fail and list their lines")
        func multipleMatches() async throws {
            let tmp = try EditTestDir()
            let content = "x\ny\nx\nz\nx\n"
            let file = try tmp.write("a.txt", content: content)
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "x", "X"))
            #expect(result.isError)
            #expect(result.content.contains("old_text matches 3 times in \(file) (lines 1, 3, 5)"))
            #expect(result.content.contains("replace_all"))
            #expect(try tmp.read("a.txt") == content)
        }

        @Test("only the first ten match lines are listed")
        func matchListIsCapped() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: String(repeating: "x\n", count: 12))
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "x", "X"))
            #expect(result.isError)
            #expect(result.content.contains("matches 12 times"))
            #expect(result.content.contains("(lines 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 and 2 more)"))
        }

        @Test("matches on one line list that line once each, multi-line matches their first line")
        func matchLines() async throws {
            let tmp = try EditTestDir()
            let sameLine = try tmp.write("a.txt", content: "foo foo\nbar\n")
            let first = await AllAppTests.replaceCall(AllAppTests.replaceArgs(sameLine, "foo", "baz"))
            #expect(first.content.contains("matches 2 times"))
            #expect(first.content.contains("(lines 1, 1)"))

            let blocks = try tmp.write("b.txt", content: "a\nb\nc\nb\nc\n")
            let second = await AllAppTests.replaceCall(AllAppTests.replaceArgs(blocks, "b\nc", "X"))
            #expect(second.content.contains("(lines 2, 4)"))
        }

        @Test("replace_all replaces every occurrence")
        func replaceAll() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "x\ny\nx\nz\nx\n")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "x", "X", all: true))
            #expect(!result.isError, "\(result.content)")
            #expect(try tmp.read("a.txt") == "X\ny\nX\nz\nX\n")
            #expect(result.content.contains("(+3 -3)"))
        }

        @Test("replace_all with a single match, false or null is the same as the default")
        func replaceAllFlags() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\ntwo\n")
            let single = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "one", "1", all: true))
            #expect(!single.isError, "\(single.content)")
            var args = AllAppTests.replaceArgs(file, "two", "2")
            args["replace_all"] = NSNull()
            let null = await AllAppTests.replaceCall(args)
            #expect(!null.isError, "\(null.content)")
            #expect(try tmp.read("a.txt") == "1\n2\n")

            let dup = try tmp.write("b.txt", content: "x x\n")
            let off = await AllAppTests.replaceCall(AllAppTests.replaceArgs(dup, "x", "y", all: false))
            #expect(off.isError)
            #expect(try tmp.read("b.txt") == "x x\n")
        }

        @Test("matches do not overlap")
        func nonOverlapping() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "aaaa\naaa\n")
            let ambiguous = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "aa", "b"))
            #expect(ambiguous.content.contains("matches 3 times"))
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "aa", "b", all: true))
            #expect(!result.isError, "\(result.content)")
            #expect(try tmp.read("a.txt") == "bb\nba\n")
        }

        @Test("replace_all may change the number of lines")
        func replaceAllAcrossLines() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a,b\nc,d\n")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, ",", "\n", all: true))
            #expect(!result.isError, "\(result.content)")
            #expect(try tmp.read("a.txt") == "a\nb\nc\nd\n")
        }

        @Test("a text that is not in the file is an error that leaves it alone")
        func notFound() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\ntwo\n")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "three", "3"))
            #expect(result.isError)
            #expect(result.content.hasPrefix("Error: old_text was not found in \(file)."))
            #expect(result.content.contains("'N:'"))
            #expect(result.fileViews == nil)
            #expect(try tmp.read("a.txt") == "one\ntwo\n")
        }

        // MARK: Line endings and BOM

        @Test("a CRLF file keeps its line endings; old_text and new_text may use LF")
        func crlfFile() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\r\nb\r\nc\r\n")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "a\nb", "A\nB\nB2"))
            #expect(!result.isError, "\(result.content)")
            #expect(try tmp.read("a.txt") == "A\r\nB\r\nB2\r\nc\r\n")
            // The tag is the hash of the LF text, like the one edit_file prints.
            let tag = HashlineFormat.computeFileHash("A\nB\nB2\nc\n")
            #expect(result.content.hasPrefix("Updated: \(file) [\(file)#\(tag)]"))
        }

        @Test("a CRLF old_text matches an LF file and a CRLF one")
        func crlfOldText() async throws {
            let tmp = try EditTestDir()
            let lf = try tmp.write("lf.txt", content: "a\nb\nc\n")
            let first = await AllAppTests.replaceCall(AllAppTests.replaceArgs(lf, "a\r\nb", "A\r\nB"))
            #expect(!first.isError, "\(first.content)")
            #expect(try tmp.read("lf.txt") == "A\nB\nc\n")

            let crlf = try tmp.write("crlf.txt", content: "a\r\nb\r\nc\r\n")
            let second = await AllAppTests.replaceCall(AllAppTests.replaceArgs(crlf, "b\r\nc", "X"))
            #expect(!second.isError, "\(second.content)")
            #expect(try tmp.read("crlf.txt") == "a\r\nX\r\n")
        }

        @Test("a BOM is kept")
        func bomFile() async throws {
            let tmp = try EditTestDir()
            let path = tmp.sub("bom.txt")
            try Data([0xEF, 0xBB, 0xBF] + Array("a\nb\n".utf8)).write(to: URL(fileURLWithPath: path))
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(path, "a", "A"))
            #expect(!result.isError, "\(result.content)")
            #expect(
                try Data(contentsOf: URL(fileURLWithPath: path)) == Data([0xEF, 0xBB, 0xBF] + Array("A\nb\n".utf8)))
        }

        @Test("a CRLF file with a BOM round-trips both")
        func crlfAndBOM() async throws {
            let tmp = try EditTestDir()
            let path = tmp.sub("both.txt")
            let original = Data([0xEF, 0xBB, 0xBF] + Array("a\r\nb\r\n".utf8))
            try original.write(to: URL(fileURLWithPath: path))
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(path, "b", "B"))
            #expect(!result.isError, "\(result.content)")
            #expect(
                try Data(contentsOf: URL(fileURLWithPath: path)) == Data([0xEF, 0xBB, 0xBF] + Array("a\r\nB\r\n".utf8)))
        }
    }

    // MARK: - replace_text: validation

    @Suite("replace_text: validation")
    struct ReplaceTextValidationTests {

        @Test("an empty old_text is rejected")
        func emptyOldText() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\n")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "", "x"))
            #expect(result.isError)
            #expect(result.content.contains("'old_text': must not be empty"))
            #expect(try tmp.read("a.txt") == "one\n")
        }

        @Test("a new_text identical to old_text is rejected, line endings aside")
        func noop() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            for (old, new) in [("a", "a"), ("a\nb", "a\nb"), ("a\nb", "a\r\nb")] {
                let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, old, new))
                #expect(result.isError)
                #expect(result.content.contains("identical to old_text"))
            }
            #expect(try tmp.read("a.txt") == "a\nb\n")
        }

        @Test("missing or mistyped arguments are rejected")
        func badArguments() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\n")
            for key in ["path", "old_text", "new_text"] {
                var args = AllAppTests.replaceArgs(file, "one", "1")
                args[key] = nil
                let result = await AllAppTests.replaceCall(args)
                #expect(result.isError)
                #expect(result.content.contains("missing required argument '\(key)'"))
            }
            var args = AllAppTests.replaceArgs(file, "one", "1")
            args["replace_all"] = "yes"
            let result = await AllAppTests.replaceCall(args)
            #expect(result.isError)
            #expect(result.content.contains("'replace_all': expected a boolean"))
            #expect(try tmp.read("a.txt") == "one\n")
        }

        @Test("a file that does not exist is an error pointing to write_file")
        func missingFile() async throws {
            let tmp = try EditTestDir()
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(tmp.sub("nope.txt"), "a", "b"))
            #expect(result.isError)
            #expect(result.content.contains("File not found"))
            #expect(result.content.contains("write_file"))
            #expect(!tmp.exists("nope.txt"))
        }

        @Test("a directory is an error")
        func directory() async throws {
            let tmp = try EditTestDir()
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(tmp.path, "a", "b"))
            #expect(result.isError)
            #expect(result.content.contains("is a directory"))
        }

        @Test("a non-text file is an error and stays as it is")
        func nonText() async throws {
            let tmp = try EditTestDir()
            let path = tmp.sub("blob.bin")
            let bytes = Data([0x61, 0xFF, 0xFE, 0x00, 0x62])
            try bytes.write(to: URL(fileURLWithPath: path))
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(path, "a", "b"))
            #expect(result.isError)
            #expect(result.content.contains("not a text file"))
            #expect(result.content.contains("replace_text"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        }

        @Test("an isolated working directory confines the path")
        func isolation() async throws {
            let tmp = try EditTestDir()
            try tmp.write("proj/a.txt", content: "one\ntwo\n")
            try tmp.write("outside.txt", content: "one\n")
            let wd = Workdir(root: tmp.sub("proj"), isolated: true)

            let inside = await AllAppTests.replaceCall(AllAppTests.replaceArgs("a.txt", "one", "1"), workdir: wd)
            #expect(!inside.isError, "\(inside.content)")
            #expect(try tmp.read("proj/a.txt") == "1\ntwo\n")

            let escape = await AllAppTests.replaceCall(
                AllAppTests.replaceArgs("../outside.txt", "one", "1"), workdir: wd)
            #expect(escape.isError)
            #expect(escape.content.contains("escapes"))
            #expect(try tmp.read("outside.txt") == "one\n")
        }
    }

    // MARK: - replace_text: file views

    @Suite("replace_text: file views")
    struct ReplaceTextFileViewTests {
        private static func views(_ file: String, content: String, seen: [Int]) -> FileViewState {
            var views = FileViewState()
            views.apply(
                .seen(.local(resolved: file), contentID: HashlineFormat.computeContentID(content), lines: LineSet(seen))
            )
            return views
        }

        private func event(_ result: ToolResult) throws -> FileViewEvent {
            let events = try #require(result.fileViews)
            #expect(events.count == 1)
            return try #require(events.first)
        }

        @Test("the new version is recorded with the seen lines carried over, the written ones and the preview's")
        func recordsTheNewVersion() async throws {
            let tmp = try EditTestDir()
            let content = AllAppTests.numberedLines(40)
            let file = try tmp.write("a.txt", content: content)
            let views = Self.views(file, content: content, seen: Array(1...5) + Array(30...40))

            let result = await AllAppTests.replaceCall(
                AllAppTests.replaceArgs(file, "line20", "TWENTY"), context: ToolContext(views: views))
            #expect(!result.isError, "\(result.content)")

            let new = content.replacingOccurrences(of: "line20\n", with: "TWENTY\n")
            let set = try event(result)
            #expect(set.kind == .set)
            #expect(set.key == .local(resolved: file))
            #expect(set.contentID == HashlineFormat.computeContentID(new))
            #expect(set.lines == LineSet(Array(1...5) + Array(18...22) + Array(30...40)))
        }

        @Test("seen lines move with the lines around an edit that changes their number")
        func seenLinesShift() async throws {
            let tmp = try EditTestDir()
            let content = AllAppTests.numberedLines(40)
            let file = try tmp.write("a.txt", content: content)
            let views = Self.views(file, content: content, seen: Array(1...5) + Array(30...40))

            let result = await AllAppTests.replaceCall(
                AllAppTests.replaceArgs(file, "line20", "a\nb\nc"), context: ToolContext(views: views))
            #expect(!result.isError, "\(result.content)")

            // line30-line40 are lines 32-42 now; 20-22 are the new ones, 18-24 are in the preview.
            #expect(try event(result).lines == LineSet(Array(1...5) + Array(18...24) + Array(32...42)))
        }

        @Test("a view of another version of the file carries nothing over")
        func otherVersion() async throws {
            let tmp = try EditTestDir()
            let content = AllAppTests.numberedLines(40)
            let file = try tmp.write("a.txt", content: content)
            var views = FileViewState()
            views.apply(.seen(.local(resolved: file), contentID: "0000000000000000", lines: LineSet(range: 1...40)))

            let result = await AllAppTests.replaceCall(
                AllAppTests.replaceArgs(file, "line20", "TWENTY"), context: ToolContext(views: views))
            #expect(!result.isError, "\(result.content)")
            #expect(try event(result).lines == LineSet(range: 18...22))
        }

        @Test("a file that was never displayed can be edited, and only what the result shows is then known")
        func neverDisplayed() async throws {
            let tmp = try EditTestDir()
            let content = AllAppTests.numberedLines(40)
            let file = try tmp.write("a.txt", content: content)
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "line20", "TWENTY"))
            #expect(!result.isError, "\(result.content)")
            #expect(try event(result).lines == LineSet(range: 18...22))
        }

        @Test("a deletion records the lines around it that the preview shows")
        func deletionView() async throws {
            let tmp = try EditTestDir()
            let content = AllAppTests.numberedLines(10)
            let file = try tmp.write("a.txt", content: content)
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "line5\n", ""))
            #expect(!result.isError, "\(result.content)")
            #expect(try event(result).lines == LineSet(range: 3...6))
        }

        @Test("emptying a file leaves no lines known")
        func emptied() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "only\n")
            let result = await AllAppTests.replaceCall(AllAppTests.replaceArgs(file, "only\n", ""))
            #expect(!result.isError, "\(result.content)")
            let set = try event(result)
            #expect(set.contentID == HashlineFormat.computeContentID(""))
            #expect(set.lines == LineSet())
        }

        @Test("edit_file works right after replace_text with its new tag, without a read")
        func editFileFollows() async throws {
            let tmp = try EditTestDir()
            let content = AllAppTests.numberedLines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file)

            let replaced = await history.run(
                "replace_text", BuiltinTools.editGroup,
                ["path": file, "old_text": "line2\n", "new_text": "TWO\nTWO-B\n"])
            #expect(!replaced.isError, "\(replaced.content)")
            let after = content.replacingOccurrences(of: "line2\n", with: "TWO\nTWO-B\n")
            let tag = HashlineFormat.computeFileHash(after)
            #expect(replaced.content.hasPrefix("Updated: \(file) [\(file)#\(tag)]"))

            // The line numbers shifted: line3 is now line 4.
            let edited = await history.edit(file, "PUT 4.=4:\n+THREE\n", tag: tag)
            #expect(!edited.isError, "edit_file failed: \(edited.content)")
            #expect(
                try tmp.read("a.txt")
                    == after.replacingOccurrences(of: "line3\n", with: "THREE\n"))
        }

        @Test("after a partial read, edit_file reaches the replaced lines and what was seen, nothing else")
        func guardContinuity() async throws {
            let tmp = try EditTestDir()
            let content = AllAppTests.numberedLines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file, ranges: "1-3")

            let replaced = await history.run(
                "replace_text", BuiltinTools.editGroup, ["path": file, "old_text": "line8", "new_text": "EIGHT"])
            #expect(!replaced.isError, "\(replaced.content)")
            let after = content.replacingOccurrences(of: "line8", with: "EIGHT")
            let tag = HashlineFormat.computeFileHash(after)

            // Line 5 was neither read nor shown by the result.
            let blind = await history.edit(file, "PUT 5.=5:\n+FIVE\n", tag: tag)
            #expect(blind.isError)
            #expect(blind.content.contains("never displayed"))
            #expect(try tmp.read("a.txt") == after)

            for line in [2, 8, 9] {
                let current = try tmp.read("a.txt")
                let ok = await history.edit(
                    file, "PUT \(line).=\(line):\n+X\n", tag: HashlineFormat.computeFileHash(current))
                #expect(!ok.isError, "line \(line): \(ok.content)")
            }
        }

        @Test("replace_text works right after edit_file, without a read")
        func replaceTextFollows() async throws {
            let tmp = try EditTestDir()
            let content = AllAppTests.numberedLines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file)

            let edited = await history.edit(file, "PUT 2.=2:\n+TWO\n", tag: HashlineFormat.computeFileHash(content))
            #expect(!edited.isError, "edit_file failed: \(edited.content)")

            let replaced = await history.run(
                "replace_text", BuiltinTools.editGroup, ["path": file, "old_text": "line3", "new_text": "THREE"])
            #expect(!replaced.isError, "\(replaced.content)")
            let after = content.replacingOccurrences(of: "line2\n", with: "TWO\n")
                .replacingOccurrences(of: "line3\n", with: "THREE\n")
            #expect(try tmp.read("a.txt") == after)

            // And edit_file once more with the tag replace_text printed.
            let again = await history.edit(
                file, "PUT 1.=1:\n+ONE\n", tag: HashlineFormat.computeFileHash(after))
            #expect(!again.isError, "edit_file failed: \(again.content)")
        }

        @Test("the events survive a save and reload of the chat")
        func eventsSurviveReload() async throws {
            let tmp = try EditTestDir()
            let content = AllAppTests.numberedLines(10)
            let file = try tmp.write("a.txt", content: content)
            let history = ToolHistory()
            await history.read(file)
            await history.run(
                "replace_text", BuiltinTools.editGroup, ["path": file, "old_text": "line4", "new_text": "FOUR"])
            let reloaded = try history.results.map { result -> ToolResult in
                try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(result))
            }
            let views = FileViewState.fold(
                reloaded.map { Fixtures.message(role: .tool, content: "", toolResults: [$0]) })
            let after = content.replacingOccurrences(of: "line4", with: "FOUR")
            #expect(views.view(for: .local(resolved: file))?.contentID == HashlineFormat.computeContentID(after))
        }
    }

    // MARK: - replace_text: preflight

    @Suite("replace_text: preflight")
    struct ReplaceTextPreflightTests {
        private func preflight(
            _ args: [String: Any], workdir: Workdir, views: FileViewState = FileViewState()
        ) async throws -> HashlinePatcher.Preflight {
            let arguments = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8) ?? "{}"
            return try await ReplaceText.preflight(arguments: arguments, workdir: workdir, views: views)
        }

        private func errorMessage(_ result: HashlinePatcher.Preflight) -> String? {
            guard case .error(let message, let fileViews) = result else { return nil }
            #expect(fileViews.isEmpty)
            return message
        }

        @Test("a valid call produces a unified diff and writes nothing")
        func ok() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\ntwo\nthree\n")
            let result = try await preflight(
                AllAppTests.replaceArgs(file, "two", "TWO"), workdir: Workdir(root: tmp.path, isolated: false))
            guard case .ok(let diff) = result else {
                Issue.record("expected .ok, got \(result)")
                return
            }
            let d = try #require(diff)
            #expect(d.contains("--- \(file)"))
            #expect(d.contains("-two"))
            #expect(d.contains("+TWO"))
            #expect(try tmp.read("a.txt") == "one\ntwo\nthree\n")
        }

        @Test("relays a text that is not found")
        func notFound() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\n")
            let result = try await preflight(
                AllAppTests.replaceArgs(file, "two", "2"), workdir: Workdir(root: tmp.path, isolated: false))
            #expect(errorMessage(result)?.contains("old_text was not found in \(file)") == true)
            #expect(try tmp.read("a.txt") == "one\n")
        }

        @Test("relays an ambiguous match with its lines")
        func ambiguous() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "x\nx\n")
            let result = try await preflight(
                AllAppTests.replaceArgs(file, "x", "y"), workdir: Workdir(root: tmp.path, isolated: false))
            #expect(errorMessage(result)?.contains("matches 2 times in \(file) (lines 1, 2)") == true)
        }

        @Test("replace_all passes where a single match would not")
        func replaceAllPasses() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "x\nx\n")
            let result = try await preflight(
                AllAppTests.replaceArgs(file, "x", "y", all: true), workdir: Workdir(root: tmp.path, isolated: false))
            guard case .ok(let diff) = result else {
                Issue.record("expected .ok, got \(result)")
                return
            }
            #expect(try #require(diff).contains("+y"))
        }

        @Test("relays missing files, non-text files and bad arguments")
        func failures() async throws {
            let tmp = try EditTestDir()
            let wd = Workdir(root: tmp.path, isolated: false)
            let missing = try await preflight(AllAppTests.replaceArgs("nope.txt", "a", "b"), workdir: wd)
            #expect(errorMessage(missing)?.contains("File not found") == true)

            try Data([0xFF, 0xFE, 0x00]).write(to: URL(fileURLWithPath: tmp.sub("blob.bin")))
            let binary = try await preflight(AllAppTests.replaceArgs("blob.bin", "a", "b"), workdir: wd)
            #expect(errorMessage(binary)?.contains("not a text file") == true)

            let empty = try await preflight(AllAppTests.replaceArgs("a.txt", "", "b"), workdir: wd)
            #expect(errorMessage(empty)?.contains("must not be empty") == true)

            let same = try await preflight(AllAppTests.replaceArgs("a.txt", "b", "b"), workdir: wd)
            #expect(errorMessage(same)?.contains("identical to old_text") == true)

            var incomplete = AllAppTests.replaceArgs("a.txt", "a", "b")
            incomplete["new_text"] = nil
            let partial = try await preflight(incomplete, workdir: wd)
            #expect(errorMessage(partial)?.contains("missing required argument 'new_text'") == true)
        }

        @Test("invalid arguments JSON is an error, not a crash")
        func invalidJSON() async throws {
            let garbage = try await ReplaceText.preflight(arguments: "not json", workdir: .none, views: FileViewState())
            #expect(errorMessage(garbage)?.contains("Invalid arguments") == true)
            let empty = try await ReplaceText.preflight(arguments: "", workdir: .none, views: FileViewState())
            #expect(errorMessage(empty)?.contains("missing required argument 'path'") == true)
        }
    }

    // MARK: - replace_text: registry

    @Suite("replace_text: registry")
    struct ReplaceTextRegistryTests {
        @Test("the definition requires path, old_text and new_text and offers replace_all")
        func schema() throws {
            let def = try #require(BuiltinTools.tools(for: BuiltinTools.editGroup).first { $0.name == "replace_text" })
            let schema = try #require(
                try JSONSerialization.jsonObject(with: Data(def.schema.utf8)) as? [String: Any])
            #expect(schema["required"] as? [String] == ["path", "old_text", "new_text"])
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(Set(properties.keys) == ["path", "old_text", "new_text", "replace_all"])
            let replaceAll = try #require(properties["replace_all"] as? [String: Any])
            #expect(replaceAll["type"] as? String == "boolean")
        }

        @Test("edit_file points to replace_text and the other way round")
        func pointers() throws {
            let defs = BuiltinTools.tools(for: BuiltinTools.editGroup)
            let edit = try #require(defs.first { $0.name == "edit_file" })
            let replace = try #require(defs.first { $0.name == "replace_text" })
            #expect(edit.description.contains("replace_text"))
            #expect(replace.description.contains("edit_file"))
        }
    }

    // MARK: - File tags only for a model with edit_file

    @Suite("file tags: only with edit_file")
    struct FileTagsTests {
        private let untagged = ToolContext(fileTags: false)

        private func call(
            _ name: String, _ group: String, _ args: [String: Any], context: ToolContext
        ) async -> ToolResult {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            return await BuiltinTools.call(
                name: name, arguments: arguments, callID: "test", group: group, workdir: .none,
                chatFilename: "test.json", context: context)
        }

        @Test("replace_text leaves the [path#TAG] out of its result but still records the file view")
        func replaceTextResult() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\ntwo\nthree\n")
            let result = await call(
                "replace_text", BuiltinTools.editGroup, ["path": file, "old_text": "two", "new_text": "TWO"],
                context: untagged)
            #expect(!result.isError, "\(result.content)")
            #expect(result.content == "Updated: \(file) (+1 -1)\n 1:one\n-:two\n+2:TWO\n 3:three")
            let event = try #require(result.fileViews?.first)
            #expect(event.kind == .set)
            #expect(event.contentID == HashlineFormat.computeContentID("one\nTWO\nthree\n"))
        }

        @Test("read_file prints no header, so no tag, and keeps its line numbers and notices")
        func readFileResult() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\ntwo\nthree\n")
            let whole = await call("read_file", BuiltinTools.filesystemGroup, ["path": file], context: untagged)
            #expect(whole.content == "1:one\n2:two\n3:three")
            #expect(whole.fileViews?.first?.lines == LineSet(range: 1...3))

            let part = await call(
                "read_file", BuiltinTools.filesystemGroup, ["path": file, "ranges": "2-3"], context: untagged)
            #expect(part.content == "(lines 2-3 of 3)\n2:two\n3:three")

            let empty = try tmp.write("empty.txt", content: "")
            let none = await call("read_file", BuiltinTools.filesystemGroup, ["path": empty], context: untagged)
            #expect(none.content == "(empty file)")

            // Documents had no header to begin with and images no text rows: only the default changes.
            let tagged = await call(
                "read_file", BuiltinTools.filesystemGroup, ["path": file], context: ToolContext())
            let tag = HashlineFormat.computeFileHash("one\ntwo\nthree\n")
            #expect(tagged.content == "[\(file)#\(tag)]\n1:one\n2:two\n3:three")
        }

        @Test("find_text keeps a bare [path] label per file, without the tag")
        func findTextResult() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\nneedle\nthree\n")
            let other = try tmp.write("b.txt", content: "needle too\n")
            let result = await call(
                "find_text", BuiltinTools.filesystemGroup, ["path": tmp.path, "regex": "needle"], context: untagged)
            #expect(!result.isError, "\(result.content)")
            #expect(!result.content.contains("#"))
            #expect(result.content.contains("[\(file)]\n2:needle"))
            #expect(result.content.contains("[\(other)]\n1:needle too"))

            let tagged = await call(
                "find_text", BuiltinTools.filesystemGroup, ["path": tmp.path, "regex": "needle"], context: ToolContext()
            )
            #expect(tagged.content.contains("[\(file)#\(HashlineFormat.computeFileHash("one\nneedle\nthree\n"))]"))
        }

        @Test("write_file reports the bytes written and no tag")
        func writeFileResult() async throws {
            let tmp = try EditTestDir()
            let path = tmp.sub("new.txt")
            let result = await call(
                "write_file", BuiltinTools.filesystemGroup, ["path": path, "content": "line1\nline2\n"],
                context: untagged)
            #expect(result.content == "Wrote 12 bytes to \(path)")
            #expect(try tmp.read("new.txt") == "line1\nline2\n")
            #expect(result.fileViews?.first?.lines == LineSet(range: 1...2))

            let pasted = await call(
                "write_file", BuiltinTools.filesystemGroup,
                ["path": path, "content": "1:line1\n2:line2\n"], context: untagged)
            #expect(pasted.content == "Wrote 12 bytes to \(path)\n\(HashlineFormat.strippedPastedPrefixesNote)")

            let tagged = await call(
                "write_file", BuiltinTools.filesystemGroup, ["path": path, "content": "line1\nline2\n"],
                context: ToolContext())
            let tag = HashlineFormat.computeFileHash("line1\nline2\n")
            #expect(tagged.content == "Wrote 12 bytes to \(path)\n[\(path)#\(tag)]")
        }

        @Test("edit_file results always carry the tag")
        func editFileResult() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "one\ntwo\n")
            let history = ToolHistory()
            await history.read(file)
            let result = await history.edit(
                file, "PUT 1.=1:\n+ONE\n", tag: HashlineFormat.computeFileHash("one\ntwo\n"))
            #expect(result.content.hasPrefix("Updated: \(file) [\(file)#"))
        }

        @Test("the tools that mention tags have a description without them; the others have one description")
        func descriptions() throws {
            let defs =
                BuiltinTools.tools(for: BuiltinTools.filesystemGroup) + BuiltinTools.tools(for: BuiltinTools.editGroup)
            func def(_ name: String) throws -> BuiltinToolDef { try #require(defs.first { $0.name == name }) }

            for name in ["read_file", "write_file", "find_text", "replace_text"] {
                let tool = try def(name)
                let plain = tool.description(fileTags: false)
                #expect(plain != tool.description, "\(name) has no variant")
                #expect(!plain.contains("TAG"), "\(name): \(plain)")
                #expect(!plain.contains("edit_file"), "\(name): \(plain)")
                #expect(tool.description(fileTags: true) == tool.description)
            }
            #expect(try def("read_file").description.contains("#TAG"))
            #expect(try def("write_file").description.contains("#TAG"))
            #expect(try def("find_text").description.contains("#TAG"))

            for name in ["ls", "find_file", "edit_file"] {
                let tool = try def(name)
                #expect(tool.description(fileTags: false) == tool.description)
            }
        }
    }

    // MARK: - File tags in the advertised tools

    @Suite("file tags: advertised tools")
    struct FileTagsAdvertisedTests {
        private struct SnapshotHarness {
            let engine: ChatEngine
            let temp: TempEnv
        }

        private static func role(edit: String?) -> String {
            var toml = "prompt = \"P\"\n\n[filesystem]\ntools = [\"read_file\", \"write_file\", \"find_text\"]\n"
            if let edit { toml += "\n[edit]\n\(edit)" }
            return toml
        }

        private static let roles: [(name: String, toml: String, tagged: Bool)] = [
            ("EditAll", Self.role(edit: ""), true),
            ("EditFileOnly", Self.role(edit: "tools = [\"edit_file\"]\n"), true),
            ("ReplaceOnly", Self.role(edit: "tools = [\"replace_text\"]\n"), false),
            ("NoEdit", Self.role(edit: nil), false),
        ]

        private func harness() async throws -> SnapshotHarness {
            let temp = try TempEnv()
            let registry = ProviderRegistry(store: InMemorySecretStore())
            try await registry.load()
            let catalog = ModelCatalog(
                registry: registry, store: ModelCatalogStore(),
                fetcher: StubFetcher { _ in .status(500) },
                metadata: StubMetadataSource(result: .failure(TestFailure())))
            let engine = ChatEngine(store: temp.store, env: temp.env, registry: registry, catalog: catalog)
            try "Hello".write(
                to: temp.env.promptsURL.appendingPathComponent("P.md"), atomically: true, encoding: .utf8)
            for role in Self.roles {
                try role.toml.write(
                    to: temp.env.rolesURL.appendingPathComponent("\(role.name).toml"), atomically: true,
                    encoding: .utf8)
            }
            await engine.applyConfigChange(.prompts)
            await engine.applyConfigChange(.roles)
            return SnapshotHarness(engine: engine, temp: temp)
        }

        @Test("descriptions mention #TAG only when the role has edit_file")
        func descriptionsFollowTheRole() async throws {
            let h = try await harness()
            for role in Self.roles {
                let filename = "\(role.name).json"
                try h.temp.writeChatDirect(
                    Fixtures.chat(messages: [Fixtures.message()], role: role.name), filename: filename)
                await h.engine.loadFromCache()
                await h.engine.ensureChatLoaded(filename: filename)

                let entries = await h.engine.toolSnapshot(filename: filename).builtin
                for entry in entries where entry.name != "edit_file" {
                    #expect(
                        entry.description.contains("TAG") == role.tagged,
                        "\(role.name): \(entry.name): \(entry.description)")
                    #expect(
                        entry.description.contains("edit_file") == role.tagged,
                        "\(role.name): \(entry.name): \(entry.description)")
                }
                let names = Set(entries.map(\.name))
                #expect(names.contains("read_file"))
                #expect(names.contains("replace_text") == (role.name == "EditAll" || role.name == "ReplaceOnly"))
            }
        }
    }
}
