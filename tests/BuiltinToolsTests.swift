import AppKit
import Foundation
import Testing

@testable import iCanHazAI

/// In-process tests for the built-in tool groups (Utils, Filesystem, Code,
/// Shell), ported from the former subprocess-based MCP integration tests.
/// These run entirely in-process via [`BuiltinTools`](src/Tools/BuiltinTools.swift)
/// — no subprocess spawning, no MCP stdio transport.
///
/// Nested under `AllAppTests` so its `.serialized` trait keeps these sequential
/// with the rest of the app suites.
extension AllAppTests {

    // MARK: - Test helpers

    /// A temp directory + helpers, mirroring the former `TempDir` from
    /// `MCPTestHarness.swift`.
    private final class TestDir {
        let path: String
        init() throws {
            let base = NSTemporaryDirectory()
            let name = "ichai-builtin-tests-\(UUID().uuidString)"
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

    /// Calls a builtin tool and returns `(text, isError)`.
    private func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (
        text: String, isError: Bool
    ) {
        let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
        let result = await BuiltinTools.call(
            name: name, arguments: arguments, callID: "test", group: group, workdir: workdir, chatFilename: "test.json")
        return (result.content, result.isError)
    }

    // MARK: - Utils

    @Suite("Builtin tools: Utils")
    struct BuiltinUtilsTests {
        @Test("calc evaluates a simple expression")
        func calcSimple() async throws {
            let (text, isError) = await Self.call("calc", BuiltinTools.utilsGroup, ["expression": "2+2*3"])
            #expect(!isError)
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "8")
        }

        @Test("calc supports sqrt via the bc math library")
        func calcSqrt() async throws {
            let (text, isError) = await Self.call("calc", BuiltinTools.utilsGroup, ["expression": "sqrt(16)"])
            #expect(!isError)
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("4"))
        }

        @Test("calc errors on missing expression")
        func calcMissing() async throws {
            let (text, isError) = await Self.call("calc", BuiltinTools.utilsGroup, [:])
            #expect(isError)
            #expect(text.contains("expression"))
        }

        @Test("datetime returns a YYYY-MM-DD HH:mm:ss string")
        func datetimeFormat() async throws {
            let (text, isError) = await Self.call("datetime", BuiltinTools.utilsGroup, [:])
            #expect(!isError)
            let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#
            #expect(text.range(of: pattern, options: .regularExpression) != nil)
        }

        @Test("uuid returns a valid UUID")
        func uuidValid() async throws {
            let (text, isError) = await Self.call("uuid", BuiltinTools.utilsGroup, [:])
            #expect(!isError)
            #expect(UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
        }

        @Test("hash computes sha256 by default")
        func hashDefault() async throws {
            let (text, isError) = await Self.call("hash", BuiltinTools.utilsGroup, ["input": "abc"])
            #expect(!isError)
            #expect(
                text.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }

        @Test("hash supports sha1")
        func hashSha1() async throws {
            let (text, isError) = await Self.call(
                "hash", BuiltinTools.utilsGroup, ["input": "abc", "algorithm": "sha1"])
            #expect(!isError)
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        }

        @Test("hash rejects unknown algorithm")
        func hashUnknown() async throws {
            let (text, isError) = await Self.call(
                "hash", BuiltinTools.utilsGroup, ["input": "abc", "algorithm": "rot13"])
            #expect(isError)
            #expect(text.contains("algorithm"))
        }

        @Test("base64 round-trips arbitrary text")
        func b64RoundTrip() async throws {
            let original = "Héllo, 世界! 🚀"
            let (encoded, _) = await Self.call("base64_encode", BuiltinTools.utilsGroup, ["input": original])
            let (decoded, isError) = await Self.call(
                "base64_decode", BuiltinTools.utilsGroup,
                ["input": encoded.trimmingCharacters(in: .whitespacesAndNewlines)])
            #expect(!isError)
            #expect(decoded == original)
        }

        @Test("sleep returns after the requested duration")
        func sleepShort() async throws {
            let start = Date()
            let (text, isError) = await Self.call("sleep", BuiltinTools.utilsGroup, ["seconds": 0.1])
            let elapsed = Date().timeIntervalSince(start)
            #expect(!isError)
            #expect(text.contains("Slept"))
            #expect(elapsed >= 0.1)
        }

        @Test("rand returns a number within the default range")
        func randDefault() async throws {
            let (text, isError) = await Self.call("rand", BuiltinTools.utilsGroup, [:])
            #expect(!isError)
            let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(n != nil)
            #expect(n! >= 0 && n! <= 100)
        }

        @Test("rand respects a custom range")
        func randRange() async throws {
            let (text, isError) = await Self.call("rand", BuiltinTools.utilsGroup, ["min": 1000, "max": 1001])
            #expect(!isError)
            let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(n == 1000 || n == 1001)
        }

        @Test("rand errors when min > max")
        func randInverted() async throws {
            let (text, isError) = await Self.call("rand", BuiltinTools.utilsGroup, ["min": 50, "max": 40])
            #expect(isError)
            #expect(text.contains("min"))
        }

        @Test("rand single-value range returns that value")
        func randSingleValue() async throws {
            let (text, isError) = await Self.call("rand", BuiltinTools.utilsGroup, ["min": 7, "max": 7])
            #expect(!isError)
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "7")
        }

        @Test("unknown tool errors")
        func unknownTool() async throws {
            let (text, err) = await Self.call("does_not_exist", BuiltinTools.utilsGroup, [:])
            #expect(err)
            #expect(text.contains("Unknown tool"))
        }

        // Static wrapper so nested struct can call the helper.
        static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (
            text: String, isError: Bool
        ) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(
                name: name, arguments: arguments, callID: "test", group: group, workdir: workdir,
                chatFilename: "test.json")
            return (result.content, result.isError)
        }
    }

    // MARK: - Filesystem

    @Suite("Builtin tools: Filesystem")
    struct BuiltinFilesystemTests {
        @Test("pwd returns the home directory by default")
        func pwdDefault() async throws {
            let (text, err) = await Self.call("pwd", BuiltinTools.filesystemGroup, [:])
            #expect(!err)
            #expect(text == NSHomeDirectory())
        }

        @Test("write_file then read_file round-trips")
        func writeReadRoundTrip() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("hello.txt")
            let (w, wErr) = await Self.call(
                "write_file", BuiltinTools.filesystemGroup, ["path": path, "content": "line1\nline2\n"])
            #expect(!wErr)
            #expect(w.contains("Wrote"))
            let (r, rErr) = await Self.call("read_file", BuiltinTools.filesystemGroup, ["path": path])
            #expect(!rErr)
            #expect(r.contains("line1"))
            #expect(r.contains("line2"))
        }

        @Test("write_file strips pasted read_file headers and line-number prefixes")
        func writeStripsPastedPrefixes() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("pasted.txt")
            // Pasting read_file output verbatim (header + N: prefixes) must
            // write only the real content.
            let pasted = "\(HashlineFormat.formatHashlineHeader(path: path, fileHash: "A1B2"))\n1:line1\n2:line2\n"
            let (w, wErr) = await Self.call(
                "write_file", BuiltinTools.filesystemGroup, ["path": path, "content": pasted])
            #expect(!wErr)
            #expect(!w.contains("#A1B2"), "result must not carry a tag: \(w)")
            let (r, rErr) = await Self.call("read_file", BuiltinTools.filesystemGroup, ["path": path])
            #expect(!rErr)
            #expect(r.contains("\n1:line1"))
            #expect(r.contains("\n2:line2"))
            #expect(!r.contains("1:1:"), "line-number prefix must have been stripped")
            // Genuine content without prefixes is untouched.
            let plain = "no prefix here\nand: neither: this\n"
            let (w2, w2Err) = await Self.call(
                "write_file", BuiltinTools.filesystemGroup, ["path": path, "content": plain])
            #expect(!w2Err)
            let (r2, r2Err) = await Self.call("read_file", BuiltinTools.filesystemGroup, ["path": path])
            #expect(!r2Err)
            #expect(r2.contains("no prefix here"))
            #expect(r2.contains("and: neither: this"))
        }

        @Test("read_file supports offset and limit")
        func readOffsetLimit() async throws {
            let tmp = try TestDir()
            try tmp.write("offset.txt", content: "a\nb\nc\nd\ne\n")
            let (r, rErr) = await Self.call(
                "read_file", BuiltinTools.filesystemGroup, ["path": tmp.sub("offset.txt"), "offset": 2, "limit": 2])
            #expect(!rErr)
            #expect(r.contains("2:b"))
            #expect(r.contains("3:c"))
            #expect(!r.contains("4:d"))
            // The header hash comes from the full file, so a partial read can
            // still anchor an edit anywhere in the file.
            let expectedTag = HashlineFormat.computeFileHash("a\nb\nc\nd\ne\n")
            #expect(
                r.hasPrefix(
                    "\(HashlineFormat.formatHashlineHeader(path: tmp.sub("offset.txt"), fileHash: expectedTag))\n"))
        }

        @Test("read_file emits a hashline header and unpadded 'N:' lines")
        func readLineNumberGutter() async throws {
            let tmp = try TestDir()
            let content = (1...12).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let path = tmp.sub("nums.txt")
            try tmp.write("nums.txt", content: content)
            let (r, err) = await Self.call("read_file", BuiltinTools.filesystemGroup, ["path": path])
            #expect(!err)
            // Header carries the path and a hash of the full file content.
            let expectedTag = HashlineFormat.computeFileHash(content)
            #expect(r.hasPrefix("\(HashlineFormat.formatHashlineHeader(path: path, fileHash: expectedTag))\n"))
            #expect(r.contains("\n1:line1"))
            #expect(r.contains("\n12:line12"))
            #expect(!r.contains("|"), "gutter must not use pipes: \(r)")
            #expect(!r.contains("\t"), "gutter must not use tabs: \(r)")
        }

        @Test("read_file shows the trailing empty line so line counts match edit_file")
        func readTrailingEmptyLine() async throws {
            let tmp = try TestDir()
            try tmp.write("trail.txt", content: "a\nb\n")
            let (r, err) = await Self.call("read_file", BuiltinTools.filesystemGroup, ["path": tmp.sub("trail.txt")])
            #expect(!err, "read_file failed: \(r)")
            // "a\nb\n" splits to ["a", "b", ""] — 3 lines. The trailing
            // empty line (line 3) is shown so edit_file's bounds check
            // ("file has 3 lines") matches what the model saw.
            #expect(r.contains("\n1:a"))
            #expect(r.contains("\n2:b"))
            #expect(r.contains("\n3:"))
            #expect(!r.contains("\n4:"))
        }

        @Test("read_file handles large files with multi-byte UTF-8")
        func readMultiByteLargeFile() async throws {
            let tmp = try TestDir()
            let content = String(repeating: "# ─── section ───\n", count: 800)
            try tmp.write("multi.txt", content: content)
            let (text, err) = await Self.call("read_file", BuiltinTools.filesystemGroup, ["path": tmp.sub("multi.txt")])
            #expect(!err, "read_file failed: \(text)")
            #expect(text.contains("section"))
        }

        @Test("ls lists a directory")
        func lsLists() async throws {
            let tmp = try TestDir()
            try tmp.write("alpha.txt", content: "1")
            try tmp.write("beta.txt", content: "2")
            let (text, err) = await Self.call("ls", BuiltinTools.filesystemGroup, ["path": tmp.path])
            #expect(!err)
            #expect(text.contains("alpha.txt"))
            #expect(text.contains("beta.txt"))
        }

        @Test("ls recursive is capped at depth 1")
        func lsRecursiveDepthCapped() async throws {
            let tmp = try TestDir()
            // node_modules/                     (L1 dir)
            // node_modules/react/               (L2 dir — top-level dep)
            // node_modules/react/index.js       (L3 file — inside dep, skipped)
            // node_modules/react/dom/           (L3 dir — deeper, skipped)
            // node_modules/react/dom/node.js    (L4 file — deeper, skipped)
            // node_modules/express/             (L2 dir — top-level dep)
            // node_modules/express/main.js      (L3 file — inside dep, skipped)
            // src/                              (L1 dir)
            // src/app.ts                        (L2 file — direct child of L1 dir, shown)
            try tmp.write("node_modules/react/index.js", content: "")
            try tmp.write("node_modules/react/dom/node.js", content: "")
            try tmp.write("node_modules/express/main.js", content: "")
            try tmp.write("src/app.ts", content: "")
            let (text, err) = await Self.call(
                "ls", BuiltinTools.filesystemGroup, ["path": tmp.path, "recursive": true])
            #expect(!err)
            // Depth 1: direct children of the listed root.
            #expect(text.contains("node_modules/"))
            #expect(text.contains("src/"))
            // Depth 1: one level into subdirectories (top-level dep folders).
            #expect(text.contains("node_modules/react/"))
            #expect(text.contains("node_modules/express/"))
            // Depth 1: files directly inside a direct-child directory are shown.
            #expect(text.contains("src/app.ts"))
            // Anything deeper than depth 1 must be absent: contents of the
            // top-level dep folders are not descended into.
            #expect(!text.contains("node_modules/react/index.js"))
            #expect(!text.contains("node_modules/express/main.js"))
            #expect(!text.contains("node_modules/react/dom/"))
            #expect(!text.contains("node_modules/react/dom/node.js"))
        }

        @Test("ls recursive is capped at 1000 entries")
        func lsRecursiveEntryCapped() async throws {
            let tmp = try TestDir()
            for i in 0..<1200 {
                try tmp.write("f\(i).txt", content: "")
            }
            let (text, err) = await Self.call(
                "ls", BuiltinTools.filesystemGroup, ["path": tmp.path, "recursive": true])
            #expect(!err)
            let count = text.split(separator: "\n", omittingEmptySubsequences: true).count
            #expect(count == 1000)
        }

        @Test("mkdir creates a directory")
        func mkdirCreates() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("newdir")
            let (_, err) = await Self.call("mkdir", BuiltinTools.filesystemGroup, ["path": path])
            #expect(!err)
            #expect(tmp.exists("newdir"))
        }

        @Test("mv moves a file")
        func mvMoves() async throws {
            let tmp = try TestDir()
            try tmp.write("src.txt", content: "data")
            let (_, err) = await Self.call(
                "mv", BuiltinTools.filesystemGroup, ["src": tmp.sub("src.txt"), "dst": tmp.sub("dst.txt")])
            #expect(!err)
            #expect(!tmp.exists("src.txt"))
            #expect(tmp.exists("dst.txt"))
        }

        @Test("rm deletes a file")
        func rmDeletes() async throws {
            let tmp = try TestDir()
            try tmp.write("kill.txt", content: "x")
            let (_, err) = await Self.call("rm", BuiltinTools.filesystemGroup, ["path": tmp.sub("kill.txt")])
            #expect(!err)
            #expect(!tmp.exists("kill.txt"))
        }

        @Test("rm non-recursive directory errors")
        func rmDirNonRecursive() async throws {
            let tmp = try TestDir()
            try tmp.write("nonempty/a.txt", content: "x")
            let (text, err) = await Self.call("rm", BuiltinTools.filesystemGroup, ["path": tmp.sub("nonempty")])
            #expect(err)
            #expect(text.contains("recursive"))
        }

        @Test("stat returns metadata")
        func statReturns() async throws {
            let tmp = try TestDir()
            try tmp.write("stat.txt", content: "hello")
            let (text, err) = await Self.call("stat", BuiltinTools.filesystemGroup, ["path": tmp.sub("stat.txt")])
            #expect(!err)
            #expect(text.contains("\"type\":\"file\""))
            #expect(text.contains("\"size\":\"5\""))
        }

        @Test("find_file matches by glob")
        func findFileGlob() async throws {
            let tmp = try TestDir()
            try tmp.write("find/me.swift", content: "x")
            try tmp.write("find/me.txt", content: "y")
            let (text, err) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup, ["path": tmp.sub("find"), "pattern": "*.swift"])
            #expect(!err)
            #expect(text.contains("me.swift"))
            #expect(!text.contains("me.txt"))
        }

        @Test("find_text searches file contents")
        func findText() async throws {
            let tmp = try TestDir()
            try tmp.write("search/a.txt", content: "needle in haystack")
            try tmp.write("search/b.txt", content: "nothing here")
            let (text, err) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup, ["path": tmp.sub("search"), "regex": "needle"])
            #expect(!err)
            #expect(text.contains("a.txt"))
            #expect(!text.contains("b.txt"))
        }

        @Test("find_text supports full regex syntax")
        func findTextRealRegex() async throws {
            let tmp = try TestDir()
            try tmp.write("s/a.txt", content: "error code 42\nwarning\nerror code 7\n")
            // \d class and alternation would be literal/broken under BRE grep.
            let (text, err) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup, ["path": tmp.sub("s"), "regex": #"error code \d+"#])
            #expect(!err)
            #expect(text.contains("\n1:error code 42"))
            #expect(text.contains("\n3:error code 7"))
            #expect(!text.contains("2:"))
            let (alt, altErr) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup,
                ["path": tmp.sub("s"), "regex": #"^(warning|error) .*[0-9]{1,2}$"#])
            #expect(!altErr)
            #expect(alt.contains("error code 42"))
            #expect(!alt.contains("warning"))
        }

        @Test("find_text errors on an invalid regex instead of returning nothing")
        func findTextInvalidRegex() async throws {
            let tmp = try TestDir()
            try tmp.write("s/a.txt", content: "x\n")
            let (text, err) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup, ["path": tmp.sub("s"), "regex": "(unclosed"])
            #expect(err)
            #expect(text.contains("regex"))
        }

        @Test("find_text case_insensitive matches regardless of case")
        func findTextCaseInsensitive() async throws {
            let tmp = try TestDir()
            try tmp.write("s/a.txt", content: "Hello World\n")
            let (sensitive, _) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup, ["path": tmp.sub("s"), "regex": "hello"])
            #expect(!sensitive.contains("Hello"))
            let (insensitive, err) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup,
                ["path": tmp.sub("s"), "regex": "hello", "case_insensitive": true])
            #expect(!err)
            #expect(insensitive.contains("Hello World"))
        }

        @Test("find_text caps results with a truncation notice")
        func findTextMaxResults() async throws {
            let tmp = try TestDir()
            let content = (1...10).map { "hit \($0)" }.joined(separator: "\n") + "\n"
            try tmp.write("s/a.txt", content: content)
            let (text, err) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup, ["path": tmp.sub("s"), "regex": "hit", "max_results": 3])
            #expect(!err)
            let hits = text.split(separator: "\n").filter { $0.contains("hit") }
            #expect(hits.count == 3)
            #expect(text.contains("truncated at 3 results"))
        }

        @Test("find_text truncates very long lines")
        func findTextLineTruncation() async throws {
            let tmp = try TestDir()
            let longLine = "start " + String(repeating: "x", count: 500)
            try tmp.write("s/a.txt", content: longLine + "\n")
            let (text, err) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup, ["path": tmp.sub("s"), "regex": "start"])
            #expect(!err)
            #expect(text.contains("…"))
            #expect(!text.contains(String(repeating: "x", count: 301)))
        }

        @Test("find_text context lines use grep-style separators")
        func findTextContext() async throws {
            let tmp = try TestDir()
            try tmp.write("s/a.txt", content: "a\nb\nmatch\nc\nd\n")
            let (text, err) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup, ["path": tmp.sub("s"), "regex": "match", "context": 1])
            #expect(!err)
            #expect(text.contains("\n3:match"))
            #expect(text.contains("\n2-b"))
            #expect(text.contains("\n4-c"))
            #expect(!text.contains("1-a"))
            #expect(!text.contains("5-d"))
        }

        @Test("find_text skips hidden and binary files by default")
        func findTextHiddenAndBinary() async throws {
            let tmp = try TestDir()
            try tmp.write("s/.hidden.txt", content: "needle\n")
            try tmp.write("s/bin.dat", content: "needle\0binary")
            let (text, err) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup, ["path": tmp.sub("s"), "regex": "needle"])
            #expect(!err)
            #expect(text.isEmpty)
            let (withHidden, hiddenErr) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup,
                ["path": tmp.sub("s"), "regex": "needle", "include_hidden": true])
            #expect(!hiddenErr)
            #expect(withHidden.contains(".hidden.txt"))
            // Binary files are never searched, even with include_hidden.
            #expect(!withHidden.contains("bin.dat"))
        }

        @Test("find_text searches large files with multi-byte UTF-8")
        func findTextMultiByteLargeFile() async throws {
            let tmp = try TestDir()
            let content = String(repeating: "# ─── section ───\n", count: 800)
            try tmp.write("s/multi.txt", content: content)
            let (text, err) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup, ["path": tmp.sub("s"), "regex": "section"])
            #expect(!err)
            #expect(text.contains("multi.txt"))
        }

        @Test("find_text file_pattern filters by glob")
        func findTextFilePattern() async throws {
            let tmp = try TestDir()
            try tmp.write("s/a.swift", content: "needle\n")
            try tmp.write("s/a.txt", content: "needle\n")
            let (text, err) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup,
                ["path": tmp.sub("s"), "regex": "needle", "file_pattern": "*.swift"])
            #expect(!err)
            #expect(text.contains("a.swift"))
            #expect(!text.contains("a.txt"))
        }

        @Test("find_file exclude_paths prunes directories and files")
        func findFileExcludePaths() async throws {
            let tmp = try TestDir()
            try tmp.write("f/src/a.swift", content: "")
            try tmp.write("f/build/b.swift", content: "")
            try tmp.write("f/notes.txt", content: "")
            let (dirExcl, dirErr) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup,
                ["path": tmp.sub("f"), "pattern": "*", "exclude_paths": [tmp.sub("f/build")]])
            #expect(!dirErr)
            #expect(dirExcl.contains("src/a.swift"))
            #expect(dirExcl.contains("notes.txt"))
            #expect(!dirExcl.contains("build"))
            // A trailing slash still excludes the whole directory.
            let (trailing, trailingErr) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup,
                ["path": tmp.sub("f"), "pattern": "*", "exclude_paths": [tmp.sub("f/build") + "/"]])
            #expect(!trailingErr)
            #expect(!trailing.contains("build"))
            // An excluded file disappears; siblings stay.
            let (fileExcl, fileErr) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup,
                ["path": tmp.sub("f"), "pattern": "*", "exclude_paths": [tmp.sub("f/notes.txt")]])
            #expect(!fileErr)
            #expect(!fileExcl.contains("notes.txt"))
            #expect(fileExcl.contains("src/a.swift"))
        }

        @Test("find_text exclude_paths prunes directories and files")
        func findTextExcludePaths() async throws {
            let tmp = try TestDir()
            try tmp.write("s/keep/a.txt", content: "needle\n")
            try tmp.write("s/skip/b.txt", content: "needle\n")
            try tmp.write("s/loose.txt", content: "needle\n")
            let (dirExcl, dirErr) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup,
                ["path": tmp.sub("s"), "regex": "needle", "exclude_paths": [tmp.sub("s/skip")]])
            #expect(!dirErr)
            #expect(dirExcl.contains("keep/a.txt"))
            #expect(dirExcl.contains("loose.txt"))
            #expect(!dirExcl.contains("skip"))
            let (fileExcl, fileErr) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup,
                ["path": tmp.sub("s"), "regex": "needle", "exclude_paths": [tmp.sub("s/loose.txt")]])
            #expect(!fileErr)
            #expect(!fileExcl.contains("loose.txt"))
            #expect(fileExcl.contains("keep/a.txt"))
        }

        @Test("find_text exclude_paths can exclude the single-file search root")
        func findTextExcludeSearchRootFile() async throws {
            let tmp = try TestDir()
            let file = try tmp.write("s/a.txt", content: "needle\n")
            let (text, err) = await Self.call(
                "find_text", BuiltinTools.filesystemGroup, ["path": file, "regex": "needle", "exclude_paths": [file]])
            #expect(!err)
            #expect(text.isEmpty)
        }

        @Test("find_file exclude_paths resolves relative entries against the working directory")
        func findFileExcludeRelative() async throws {
            let tmp = try TestDir()
            try tmp.write("proj/src/a.swift", content: "")
            try tmp.write("proj/build/b.swift", content: "")
            let wd = Workdir(root: tmp.sub("proj"), isolated: false)
            let (text, err) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup, ["pattern": "*.swift", "exclude_paths": ["build"]],
                workdir: wd)
            #expect(!err)
            #expect(text == "src/a.swift")
        }

        @Test("find_file exclude_paths honors the jail when isolated")
        func findFileExcludeIsolated() async throws {
            let tmp = try TestDir()
            try tmp.write("src/a.swift", content: "")
            try tmp.write("build/b.swift", content: "")
            let wd = Workdir(root: tmp.path, isolated: true)
            let (text, err) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup, ["pattern": "*.swift", "exclude_paths": ["/build"]],
                workdir: wd)
            #expect(!err)
            #expect(text == "src/a.swift")
            // Escaping the jail is rejected like any other path.
            let (escape, escapeErr) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup, ["pattern": "*", "exclude_paths": ["../.."]], workdir: wd)
            #expect(escapeErr)
            #expect(escape.contains("escapes"))
        }

        @Test("find_file supports ? wildcards and character classes")
        func findFileGlobSyntax() async throws {
            let tmp = try TestDir()
            try tmp.write("f/test_1.py", content: "")
            try tmp.write("f/test_12.py", content: "")
            try tmp.write("f/main.py", content: "")
            let (q, qErr) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup, ["path": tmp.sub("f"), "pattern": "test_?.py"])
            #expect(!qErr)
            #expect(q.contains("test_1.py"))
            #expect(!q.contains("test_12.py"))
            #expect(!q.contains("main.py"))
            let (cls, clsErr) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup, ["path": tmp.sub("f"), "pattern": "test_[0-9].py"])
            #expect(!clsErr)
            #expect(cls.contains("test_1.py"))
            #expect(!cls.contains("main.py"))
        }

        @Test("find_file supports ** and path-aware patterns")
        func findFilePathGlobs() async throws {
            let tmp = try TestDir()
            try tmp.write("f/src/deep/test_a.py", content: "")
            try tmp.write("f/src/top.py", content: "")
            try tmp.write("f/test_root.py", content: "")
            // ** matches any number of directories, including zero.
            let (star, starErr) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup, ["path": tmp.sub("f"), "pattern": "**/test_*.py"])
            #expect(!starErr)
            #expect(star.contains("src/deep/test_a.py"))
            #expect(star.contains("test_root.py"))
            #expect(!star.contains("top.py"))
            // A path pattern with a plain * stays within one component.
            let (rel, relErr) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup, ["path": tmp.sub("f"), "pattern": "src/*.py"])
            #expect(!relErr)
            #expect(rel.contains("src/top.py"))
            #expect(!rel.contains("deep"))
        }

        @Test("find_file case_insensitive and include_hidden")
        func findFileCaseAndHidden() async throws {
            let tmp = try TestDir()
            try tmp.write("f/Main.PY", content: "")
            try tmp.write("f/.hidden/secret.py", content: "")
            let (sensitive, _) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup, ["path": tmp.sub("f"), "pattern": "*.py"])
            #expect(!sensitive.contains("Main.PY"))
            #expect(!sensitive.contains("secret.py"))
            let (insensitive, err) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup,
                ["path": tmp.sub("f"), "pattern": "*.py", "case_insensitive": true])
            #expect(!err)
            #expect(insensitive.contains("Main.PY"))
            let (withHidden, hiddenErr) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup,
                ["path": tmp.sub("f"), "pattern": "*.py", "include_hidden": true])
            #expect(!hiddenErr)
            #expect(withHidden.contains(".hidden/secret.py"))
        }

        @Test("find_file results are sorted")
        func findFileSorted() async throws {
            let tmp = try TestDir()
            try tmp.write("f/b.txt", content: "")
            try tmp.write("f/a.txt", content: "")
            try tmp.write("f/c.txt", content: "")
            let (text, err) = await Self.call(
                "find_file", BuiltinTools.filesystemGroup, ["path": tmp.sub("f"), "pattern": "*.txt"])
            #expect(!err)
            #expect(text == "a.txt\nb.txt\nc.txt")
        }

        @Test("ls hidden handling is consistent across modes")
        func lsHiddenConsistency() async throws {
            let tmp = try TestDir()
            try tmp.write(".env", content: "")
            try tmp.write("plain.txt", content: "")
            try tmp.write(".config/settings.ini", content: "")
            // Both modes hide dotfiles by default.
            let (flat, flatErr) = await Self.call("ls", BuiltinTools.filesystemGroup, ["path": tmp.path])
            #expect(!flatErr)
            #expect(flat == "plain.txt")
            let (rec, recErr) = await Self.call(
                "ls", BuiltinTools.filesystemGroup, ["path": tmp.path, "recursive": true])
            #expect(!recErr)
            #expect(rec == "plain.txt")
            // Both modes show them with include_hidden.
            let (flatH, _) = await Self.call(
                "ls", BuiltinTools.filesystemGroup, ["path": tmp.path, "include_hidden": true])
            #expect(flatH.contains(".env"))
            #expect(flatH.contains(".config/"))
            #expect(!flatH.contains("settings.ini"))
            let (recH, _) = await Self.call(
                "ls", BuiltinTools.filesystemGroup, ["path": tmp.path, "recursive": true, "include_hidden": true])
            #expect(recH.contains(".env"))
            #expect(recH.contains(".config/settings.ini"))
        }

        // Workdir isolation tests
        @Test("pwd returns / when isolated")
        func pwdIsolated() async throws {
            let tmp = try TestDir()
            let wd = Workdir(root: tmp.path, isolated: true)
            let (text, err) = await Self.call("pwd", BuiltinTools.filesystemGroup, [:], workdir: wd)
            #expect(!err)
            #expect(text == "/")
        }

        @Test("absolute path treated as relative to root when isolated")
        func absoluteTreatedAsRelative() async throws {
            let tmp = try TestDir()
            let wd = Workdir(root: tmp.path, isolated: true)
            let (_, err) = await Self.call(
                "write_file", BuiltinTools.filesystemGroup, ["path": "/isolated.txt", "content": "x"], workdir: wd)
            #expect(!err)
            #expect(tmp.exists("isolated.txt"))
        }

        @Test("path escape via .. is rejected when isolated")
        func escapeRejected() async throws {
            let tmp = try TestDir()
            let wd = Workdir(root: tmp.path, isolated: true)
            let (text, err) = await Self.call(
                "write_file", BuiltinTools.filesystemGroup, ["path": "../../escaped.txt", "content": "z"], workdir: wd)
            #expect(err)
            #expect(text.contains("escapes"))
        }

        @Test("relative path resolves against workdir")
        func relativePath() async throws {
            let tmp = try TestDir()
            let wd = Workdir(root: tmp.path, isolated: false)
            let (_, err) = await Self.call(
                "write_file", BuiltinTools.filesystemGroup, ["path": "rel.txt", "content": "hi"], workdir: wd)
            #expect(!err)
            #expect(tmp.exists("rel.txt"))
        }

        static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (
            text: String, isError: Bool
        ) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(
                name: name, arguments: arguments, callID: "test", group: group, workdir: workdir,
                chatFilename: "test.json")
            return (result.content, result.isError)
        }
    }

    // MARK: - Directory isolation

    @Suite("Builtin tools: directory isolation")
    struct BuiltinIsolationTests {
        private static let fs = BuiltinTools.filesystemGroup
        private static let code = BuiltinTools.codeGroup

        /// TestDir paths carry this marker; any appearance in isolated tool
        /// output means the host layout leaked.
        private static let hostMarker = "ichai-builtin-tests"

        @Test("find_text shows jail-relative paths and never the host root")
        func findTextJailPaths() async throws {
            let tmp = try TestDir()
            try tmp.write("sub/note.txt", content: "before\nhello isolated world\nafter\n")
            try tmp.write("top.txt", content: "hello from the top\n")
            let wd = Workdir(root: tmp.path, isolated: true)

            // Default search root (the jail "/").
            let (text, err) = await Self.call("find_text", Self.fs, ["regex": "hello"], workdir: wd)
            #expect(!err)
            #expect(text.contains("[/sub/note.txt#"))
            #expect(text.contains("\n2:hello isolated world"))
            #expect(text.contains("[/top.txt#"))
            #expect(text.contains("\n1:hello from the top"))
            #expect(!text.contains(Self.hostMarker))

            // Explicit subdirectory as the search root: display paths stay
            // jail-absolute so they can be fed back into read_file as-is.
            let (sub, subErr) = await Self.call("find_text", Self.fs, ["regex": "hello", "path": "/sub"], workdir: wd)
            #expect(!subErr)
            #expect(sub.contains("[/sub/note.txt#"))
            #expect(sub.contains("\n2:hello isolated world"))
            #expect(!sub.contains(Self.hostMarker))

            // A single file as the search root.
            let (file, fileErr) = await Self.call(
                "find_text", Self.fs, ["regex": "hello", "path": "/sub/note.txt"], workdir: wd)
            #expect(!fileErr)
            #expect(file.contains("[/sub/note.txt#"))
            #expect(file.contains("\n2:hello isolated world"))
            #expect(!file.contains(Self.hostMarker))

            // Context lines get the same jail spelling.
            let (ctx, ctxErr) = await Self.call("find_text", Self.fs, ["regex": "hello", "context": 1], workdir: wd)
            #expect(!ctxErr)
            #expect(ctx.contains("\n1-before"))
            #expect(ctx.contains("\n3-after"))
            #expect(!ctx.contains(Self.hostMarker))
        }

        @Test("find_text rejects search roots outside the jail")
        func findTextEscapeRejected() async throws {
            let tmp = try TestDir()
            let wd = Workdir(root: tmp.path, isolated: true)
            for path in ["/../..", "../../outside", "/sub/../../.."] {
                let (text, err) = await Self.call("find_text", Self.fs, ["regex": "x", "path": path], workdir: wd)
                #expect(err)
                #expect(text.contains("escapes the workdir"))
            }
        }

        @Test("find_text shows real paths when not isolated")
        func findTextNonIsolated() async throws {
            let tmp = try TestDir()
            try tmp.write("sub/note.txt", content: "hello plain world\n")
            let wd = Workdir(root: tmp.path, isolated: false)
            let (text, err) = await Self.call("find_text", Self.fs, ["regex": "hello"], workdir: wd)
            #expect(!err)
            // Real (host) path shows in the header, unpadded line prefix below.
            #expect(text.contains("sub/note.txt#"))
            #expect(text.contains("\n1:hello plain world"))
            // The whole point of isolation: without it the real path shows.
            #expect(text.contains(Self.hostMarker))
        }

        @Test("find_file output stays relative to the search root when isolated")
        func findFileIsolated() async throws {
            let tmp = try TestDir()
            try tmp.write("sub/note.txt", content: "")
            try tmp.write("top.txt", content: "")
            let wd = Workdir(root: tmp.path, isolated: true)
            let (text, err) = await Self.call("find_file", Self.fs, ["pattern": "*.txt"], workdir: wd)
            #expect(!err)
            #expect(text == "sub/note.txt\ntop.txt")
            #expect(!text.contains(Self.hostMarker))
        }

        @Test("no filesystem tool output leaks the host root when isolated")
        func noFilesystemToolLeaksHostRoot() async throws {
            let tmp = try TestDir()
            try tmp.write("sub/note.txt", content: "sweep content\n")
            let wd = Workdir(root: tmp.path, isolated: true)
            let fs = Self.fs

            var outputs: [(label: String, text: String)] = []
            func collect(_ label: String, _ result: (text: String, isError: Bool)) {
                outputs.append((label, result.text))
            }

            collect("write_file", await Self.call("write_file", fs, ["path": "/a.txt", "content": "x"], workdir: wd))
            collect("ls flat", await Self.call("ls", fs, ["path": "/"], workdir: wd))
            collect("ls recursive", await Self.call("ls", fs, ["path": "/", "recursive": true], workdir: wd))
            collect("read_file", await Self.call("read_file", fs, ["path": "/a.txt"], workdir: wd))
            collect("read_file missing", await Self.call("read_file", fs, ["path": "/missing.txt"], workdir: wd))
            collect("find_file", await Self.call("find_file", fs, ["pattern": "*.txt"], workdir: wd))
            collect("find_text", await Self.call("find_text", fs, ["regex": "sweep"], workdir: wd))
            collect("mkdir", await Self.call("mkdir", fs, ["path": "/newdir"], workdir: wd))
            collect("mv", await Self.call("mv", fs, ["src": "/a.txt", "dst": "/newdir/b.txt"], workdir: wd))
            collect("mv missing", await Self.call("mv", fs, ["src": "/missing.txt", "dst": "/x.txt"], workdir: wd))
            collect("rm missing", await Self.call("rm", fs, ["path": "/missing.txt"], workdir: wd))
            collect("rm non-empty dir", await Self.call("rm", fs, ["path": "/newdir"], workdir: wd))
            collect("stat", await Self.call("stat", fs, ["path": "/newdir/b.txt"], workdir: wd))
            collect("stat missing", await Self.call("stat", fs, ["path": "/missing.txt"], workdir: wd))
            collect("pwd", await Self.call("pwd", fs, [:], workdir: wd))

            // Path-form marker: a full-path leak always contains "/" + the
            // tmp dir name. (Cocoa's mv error names the destination's parent
            // folder by bare name only — not a layout leak.)
            for (label, text) in outputs {
                #expect(!text.contains("/" + Self.hostMarker), "\(label) leaked the host root: \(text)")
            }
        }

        static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (
            text: String, isError: Bool
        ) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(
                name: name, arguments: arguments, callID: "test", group: group, workdir: workdir,
                chatFilename: "test.json")
            return (result.content, result.isError)
        }
    }

    // MARK: - Shell

    @Suite("Builtin tools: Shell")
    struct BuiltinShellTests {
        @Test("shell runs a command and returns stdout")
        func shellEcho() async throws {
            let (text, err) = await Self.call("shell", BuiltinTools.shellGroup, ["command": "echo hello-shell"])
            #expect(!err)
            #expect(text.contains("hello-shell"))
            #expect(text.contains("[exit code: 0]"))
        }

        @Test("shell returns non-zero exit code")
        func shellNonZero() async throws {
            let (text, err) = await Self.call("shell", BuiltinTools.shellGroup, ["command": "exit 3"])
            #expect(!err)
            #expect(text.contains("[exit code: 3]"))
        }

        @Test("shell errors on missing command")
        func shellMissing() async throws {
            let (text, err) = await Self.call("shell", BuiltinTools.shellGroup, [:])
            #expect(err)
            #expect(text.contains("command"))
        }

        @Test("shell respects a cwd argument")
        func shellCwd() async throws {
            let tmp = try TestDir()
            let (text, err) = await Self.call("shell", BuiltinTools.shellGroup, ["command": "pwd", "cwd": tmp.path])
            #expect(!err)
            #expect(text.contains(tmp.path))
        }

        @Test("shell timeout kills a long command")
        func shellTimeout() async throws {
            let (text, err) = await Self.call("shell", BuiltinTools.shellGroup, ["command": "sleep 30", "timeout": 1])
            #expect(!err)
            #expect(text.contains("timed out"))
        }

        @Test("shell merges stderr into stdout in write order")
        func shellStderrMerged() async throws {
            // Interleave stdout and stderr; the merged stream must preserve
            // the order the lines were written, not bucket stdout-then-stderr.
            let cmd = "echo out1; echo err1 >&2; echo out2; echo err2 >&2"
            let (text, err) = await Self.call("shell", BuiltinTools.shellGroup, ["command": cmd])
            #expect(!err)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            #expect(lines.contains("out1"))
            #expect(lines.contains("err1"))
            #expect(lines.contains("out2"))
            #expect(lines.contains("err2"))
            let o1 = lines.firstIndex(of: "out1")!
            let e1 = lines.firstIndex(of: "err1")!
            let o2 = lines.firstIndex(of: "out2")!
            let e2 = lines.firstIndex(of: "err2")!
            #expect(o1 < e1 && e1 < o2 && o2 < e2, "expected out1<err1<out2<err2, got: \(lines)")
        }

        @Test("shell returns stderr on a zero-exit command")
        func shellStderrOnSuccess() async throws {
            // stderr must be surfaced even when the command exits 0 (the old
            // behavior dropped stderr entirely on exit code 0).
            let (text, err) = await Self.call(
                "shell", BuiltinTools.shellGroup, ["command": "echo to-stderr >&2; exit 0"])
            #expect(!err)
            #expect(text.contains("to-stderr"))
            #expect(text.contains("[exit code: 0]"))
        }

        @Test("shell strips ANSI color codes from output")
        func shellStripsAnsi() async throws {
            // A colored echo (red) must come back as plain text with the escape
            // sequences removed, not as raw \x1B[...m bytes.
            let cmd = "printf '\\033[31mred\\033[0m plain'"
            let (text, err) = await Self.call("shell", BuiltinTools.shellGroup, ["command": cmd])
            #expect(!err)
            #expect(!text.contains("\u{1B}"), "ANSI escape leaked into output: \(text.debugDescription)")
            #expect(text.contains("red"))
            #expect(text.contains("plain"))
        }

        @Test("applescript returns a result")
        func applescript() async throws {
            let (text, err) = await Self.call("applescript", BuiltinTools.shellGroup, ["script": "return 1 + 1"])
            #expect(!err)
            #expect(text.contains("2"))
        }

        @Test("applescript errors on bad script")
        func applescriptBad() async throws {
            let (text, err) = await Self.call(
                "applescript", BuiltinTools.shellGroup, ["script": "this is not applescript"])
            #expect(!err)
            #expect(text.contains("AppleScript error"))
        }

        @Test("shell defaults to the workdir as cwd")
        func shellDefaultCwd() async throws {
            let tmp = try TestDir()
            let wd = Workdir(root: tmp.path, isolated: false)
            let (text, err) = await Self.call("shell", BuiltinTools.shellGroup, ["command": "pwd"], workdir: wd)
            #expect(!err)
            #expect(text.contains(tmp.path))
        }

        @Test("shell handles large output without deadlock")
        func shellLargeOutput() async throws {
            // Output exceeds the 64 KB pipe buffer; the old read-after-exit
            // pattern deadlocked here. 70000 lines * ~2 bytes = ~140 KB.
            let (text, err) = await Self.call(
                "shell", BuiltinTools.shellGroup, ["command": "yes x | head -70000", "timeout": 15])
            #expect(!err)
            #expect(text.contains("[exit code: 0]"))
            // Truncation marker should be present since output > 10000 chars
            #expect(text.contains("[truncated to 10000 chars]"))
        }

        @Test("shell truncates output to 10000 chars with head and tail")
        func shellTruncation() async throws {
            // Generate a predictable long output: 20000 lines of "line NNNNN"
            // so we can verify head and tail content survives truncation.
            let cmd = "for i in $(seq 1 20000); do echo \"line $i\"; done"
            let (text, err) = await Self.call("shell", BuiltinTools.shellGroup, ["command": cmd, "timeout": 15])
            #expect(!err)
            #expect(text.contains("[truncated to 10000 chars]"))
            // Head: first lines survive
            #expect(text.contains("line 1\n"))
            // Tail: last line survives
            #expect(text.contains("line 20000"))
            // Exit code line is present after truncation
            #expect(text.contains("[exit code: 0]"))
        }

        @Test("shell does not truncate output under 10000 chars")
        func shellNoTruncation() async throws {
            let (text, err) = await Self.call("shell", BuiltinTools.shellGroup, ["command": "echo hello"])
            #expect(!err)
            #expect(!text.contains("[truncated to"))
        }

        // MARK: - chmod preservation

        /// Reads the POSIX permission bits of a path as an octal string (e.g.
        /// "755"), for asserting the executable bit survives a write.
        private func modeString(_ path: String) throws -> String {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? 0
            return String(mode & 0o7777, radix: 8)
        }

        static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (
            text: String, isError: Bool
        ) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(
                name: name, arguments: arguments, callID: "test", group: group, workdir: workdir,
                chatFilename: "test.json")
            return (result.content, result.isError)
        }
    }

    // MARK: - Shell chmod preservation

    @Suite("Builtin tools: Shell chmod preservation")
    struct BuiltinShellChmodTests {
        private static let fs = BuiltinTools.filesystemGroup

        private func modeString(_ path: String) throws -> String {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? 0
            return String(mode & 0o7777, radix: 8)
        }

        @Test("write_file preserves the executable bit on an existing file")
        func writePreservesExecBit() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("script.sh")
            try Data("#!/bin/sh\necho hi\n".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            #expect(try modeString(path) == "755")

            let (_, err) = await Self.call("write_file", Self.fs, ["path": path, "content": "#!/bin/sh\necho bye\n"])
            #expect(!err)
            // The atomic write swaps the inode; the executable bit must survive.
            #expect(try modeString(path) == "755", "executable bit was lost on write_file")
        }

        @Test("write_file preserves a custom mode on an existing file")
        func writePreservesCustomMode() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("cfg.conf")
            try Data("old\n".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
            #expect(try modeString(path) == "640")

            let (_, err) = await Self.call("write_file", Self.fs, ["path": path, "content": "new\n"])
            #expect(!err)
            #expect(try modeString(path) == "640", "custom mode was lost on write_file")
        }

        static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (
            text: String, isError: Bool
        ) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(
                name: name, arguments: arguments, callID: "test", group: group, workdir: workdir,
                chatFilename: "test.json")
            return (result.content, result.isError)
        }
    }

    // MARK: - Tilde paths

    @Suite("Builtin tools: tilde paths")
    struct BuiltinTildeTests {
        @Test("local resolution expands ~ to the user home")
        func localResolve() throws {
            let home = NSHomeDirectory()
            #expect(try Workdir.none.resolve("~") == home)
            #expect(try Workdir.none.resolve("~/x") == home + "/x")

            // A tilde wins over the workdir root, like in a real shell.
            let tmp = try TestDir()
            let wd = Workdir(root: tmp.path, isolated: false)
            #expect(try wd.resolve("~/x") == home + "/x")
        }

        @Test("local resolution rejects an unknown ~user instead of misplacing the path")
        func localUnknownUser() {
            #expect(throws: BuiltinToolError.self) { try Workdir.none.resolve("~ichai-no-such-user-xyz/x") }
        }

        @Test("isolated tilde maps to the virtual home (the root)")
        func isolatedResolve() throws {
            let tmp = try TestDir()
            let wd = Workdir(root: tmp.path, isolated: true)
            let root = try #require(wd.root)
            #expect(try wd.resolve("~") == root)
            #expect(try wd.resolve("~/x") == root + "/x")
            #expect(throws: BuiltinToolError.self) { try wd.resolve("~root/x") }
        }

        @Test("ls accepts a tilde path")
        func lsTilde() async {
            let (_, err) = await Self.call("ls", BuiltinTools.filesystemGroup, ["path": "~"])
            #expect(!err)
        }

        @Test("shell cwd accepts a tilde path")
        func shellTildeCwd() async {
            let (text, err) = await Self.call("shell", BuiltinTools.shellGroup, ["command": "pwd", "cwd": "~"])
            #expect(!err)
            #expect(text.contains(NSHomeDirectory()))
        }

        static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (
            text: String, isError: Bool
        ) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(
                name: name, arguments: arguments, callID: "test", group: group, workdir: workdir,
                chatFilename: "test.json")
            return (result.content, result.isError)
        }
    }

    // MARK: - Tool registry

    @Suite("Builtin tools: registry")
    struct BuiltinToolsRegistryTests {
        @Test("tool definitions cover all groups")
        func registry() {
            let defs = BuiltinTools.toolDefinitions(for: BuiltinTools.allGroups)
            #expect(!defs.isEmpty)
            // Utils
            #expect(defs.contains { $0.name == "calc" && $0.serverName == "Utils" })
            #expect(defs.contains { $0.name == "datetime" && $0.serverName == "Utils" })
            #expect(defs.contains { $0.name == "uuid" && $0.serverName == "Utils" })
            #expect(defs.contains { $0.name == "hash" && $0.serverName == "Utils" })
            #expect(defs.contains { $0.name == "base64_encode" && $0.serverName == "Utils" })
            #expect(defs.contains { $0.name == "base64_decode" && $0.serverName == "Utils" })
            #expect(defs.contains { $0.name == "sleep" && $0.serverName == "Utils" })
            #expect(defs.contains { $0.name == "rand" && $0.serverName == "Utils" })
            // Filesystem
            #expect(defs.contains { $0.name == "ls" && $0.serverName == "Filesystem" })
            #expect(defs.contains { $0.name == "read_file" && $0.serverName == "Filesystem" })
            #expect(defs.contains { $0.name == "write_file" && $0.serverName == "Filesystem" })
            #expect(defs.contains { $0.name == "pwd" && $0.serverName == "Filesystem" })
            // Code
            #expect(!defs.contains { $0.name == "apply_patch" })
            // Shell
            #expect(defs.contains { $0.name == "shell" && $0.serverName == "Shell" })
            #expect(defs.contains { $0.name == "applescript" && $0.serverName == "Shell" })
        }

        @Test("group(for:) resolves tool names to their group")
        func groupResolution() {
            #expect(BuiltinTools.group(for: "calc") == "Utils")
            #expect(BuiltinTools.group(for: "ls") == "Filesystem")
            #expect(BuiltinTools.group(for: "shell") == "Shell")
            #expect(BuiltinTools.group(for: "nonexistent") == nil)
        }

        @Test("shell_background and shell_read_output are not present")
        func noBackgroundTools() {
            #expect(!BuiltinTools.allToolNames.contains("shell_background"))
            #expect(!BuiltinTools.allToolNames.contains("shell_read_output"))
        }
    }

    // MARK: - Document-aware read_file

    @Suite("Builtin tools: document-aware read_file")
    struct BuiltinDocumentReadFileTests {
        private static let fs = BuiltinTools.filesystemGroup

        /// Generates document fixtures on disk for read_file tests. MainActor
        /// because it builds AppKit views/images to synthesize PDF/PNG fixtures.
        @MainActor
        private final class DocFixtures {
            let dir: String

            let rtfPath: String
            let docxPath: String
            let pdfPath: String
            let pngPath: String
            let binaryPath: String

            init() throws {
                let base = NSTemporaryDirectory()
                let name = "ichai-readfile-doc-\(UUID().uuidString)"
                let d = (base as NSString).appendingPathComponent(name)
                try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
                self.dir = d

                // RTF via AppKit.
                let attr = NSAttributedString(string: "Hello RTF\nSecond line of RTF text.")
                let rtfData = try attr.data(
                    from: NSRange(location: 0, length: attr.length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                )
                self.rtfPath = (d as NSString).appendingPathComponent("doc.rtf")
                try rtfData.write(to: URL(fileURLWithPath: rtfPath))

                // DOCX via textutil (from the RTF).
                let rtfURL = URL(fileURLWithPath: rtfPath)
                let docxData = try Self.textutil(["-convert", "docx", "-stdout", rtfURL.path])
                self.docxPath = (d as NSString).appendingPathComponent("doc.docx")
                try docxData.write(to: URL(fileURLWithPath: docxPath))

                // PDF with a text layer via NSTextView.dataWithPDF(inside:).
                let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
                tv.string = "Page one text content.\nAnother paragraph on page one."
                let pdfData = tv.dataWithPDF(inside: tv.bounds)
                self.pdfPath = (d as NSString).appendingPathComponent("doc.pdf")
                try pdfData.write(to: URL(fileURLWithPath: pdfPath))

                // PNG with rendered text (for image OCR).
                let pngData = try Self.makePNG(text: "IMAGE OCR TEXT")
                self.pngPath = (d as NSString).appendingPathComponent("shot.png")
                try pngData.write(to: URL(fileURLWithPath: pngPath))

                // Arbitrary binary (zip magic bytes) — must be rejected.
                let binData = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00])
                self.binaryPath = (d as NSString).appendingPathComponent("archive.zip")
                try binData.write(to: URL(fileURLWithPath: binaryPath))
            }

            deinit { try? FileManager.default.removeItem(atPath: dir) }

            private static func textutil(_ args: [String]) throws -> Data {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    throw NSError(
                        domain: "DocFixtures", code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "textutil failed"])
                }
                return pipe.fileHandleForReading.readDataToEndOfFile()
            }

            private static func makePNG(text: String) throws -> Data {
                let size = NSSize(width: 400, height: 100)
                let image = NSImage(size: size)
                image.lockFocus()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 32),
                    .foregroundColor: NSColor.black,
                ]
                (text as NSString).draw(at: NSPoint(x: 20, y: 30), withAttributes: attrs)
                image.unlockFocus()
                guard let tiff = image.tiffRepresentation,
                    let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:])
                else {
                    throw NSError(
                        domain: "DocFixtures", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "PNG render failed"])
                }
                return png
            }
        }

        @Test("read_file extracts RTF as plain text without hashline headers")
        @MainActor
        func readRTF() async throws {
            let f = try DocFixtures()
            let (text, err) = await Self.call("read_file", Self.fs, ["path": f.rtfPath])
            #expect(!err, "read_file failed: \(text)")
            #expect(text.contains("Hello RTF"))
            #expect(text.contains("Second line of RTF text."))
            // Documents are not editable: no hashline header, no line numbers.
            #expect(!text.contains("["))
            #expect(!text.contains("\n1:Hello"))
        }

        @Test("read_file extracts DOCX as plain text without hashline headers")
        @MainActor
        func readDOCX() async throws {
            let f = try DocFixtures()
            let (text, err) = await Self.call("read_file", Self.fs, ["path": f.docxPath])
            #expect(!err, "read_file failed: \(text)")
            #expect(text.contains("Hello RTF"))
            #expect(!text.contains("1:"))
            #expect(!text.contains("["))
        }

        @Test("read_file extracts PDF with page markers")
        @MainActor
        func readPDF() async throws {
            let f = try DocFixtures()
            let (text, err) = await Self.call("read_file", Self.fs, ["path": f.pdfPath])
            #expect(!err, "read_file failed: \(text)")
            #expect(text.contains("Page one text content."))
            // PDF page markers survive into the line-numbered output.
            #expect(text.contains("--- Page 1 ---"))
        }

        @Test("read_file offset/limit slices extracted document text")
        @MainActor
        func readDocOffsetLimit() async throws {
            let f = try DocFixtures()
            // The RTF has two lines: "Hello RTF" and "Second line of RTF text."
            let (text, err) = await Self.call("read_file", Self.fs, ["path": f.rtfPath, "offset": 2, "limit": 1])
            #expect(!err, "read_file failed: \(text)")
            #expect(text.contains("Second line of RTF text."))
            #expect(!text.contains("Hello RTF"))
        }

        @Test("read_file on an image produces a processed image and fallback text")
        @MainActor
        func readImageProducesImageAndFallback() async throws {
            let f = try DocFixtures()
            let arguments =
                try String(data: JSONSerialization.data(withJSONObject: ["path": f.pngPath]), encoding: .utf8) ?? "{}"
            let result = await BuiltinTools.call(
                name: "read_file", arguments: arguments, callID: "test", group: Self.fs, workdir: .none,
                chatFilename: "test.json")
            #expect(!result.isError, "read_file failed: \(result.content)")
            // The result carries a processed image (no disk file written).
            #expect(result.image != nil)
            #expect(result.image?.mimeType.hasPrefix("image/") == true)
            // The content is the classification+OCR fallback text.
            #expect(result.content.contains("lacking the capabilities to digest images"))
            // Vision recognizes the rendered text when available. In the
            // `swift test` runner Vision can return empty (no GUI session),
            // so the "no readable text" fallback is acceptable there; when
            // Vision produces output it must contain the words.
            if !result.content.contains("no readable text") {
                #expect(
                    result.content.contains("IMAGE") || result.content.contains("OCR")
                        || result.content.contains("TEXT"))
            }
        }

        @Test("read_file rejects unsupported binary formats")
        @MainActor
        func readBinaryRejected() async throws {
            let f = try DocFixtures()
            let (text, err) = await Self.call("read_file", Self.fs, ["path": f.binaryPath])
            #expect(!err)
            #expect(text.contains("not a supported format"))
        }

        static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (
            text: String, isError: Bool
        ) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(
                name: name, arguments: arguments, callID: "test", group: group, workdir: workdir,
                chatFilename: "test.json")
            return (result.content, result.isError)
        }
    }
}
