import Testing
import Foundation
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
    private func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (text: String, isError: Bool) {
        let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
        let result = await BuiltinTools.call(name: name, arguments: arguments, callID: "test", group: group, workdir: workdir)
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
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) ==
                    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }

        @Test("hash supports sha1")
        func hashSha1() async throws {
            let (text, isError) = await Self.call("hash", BuiltinTools.utilsGroup, ["input": "abc", "algorithm": "sha1"])
            #expect(!isError)
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) ==
                    "a9993e364706816aba3e25717850c26c9cd0d89d")
        }

        @Test("hash rejects unknown algorithm")
        func hashUnknown() async throws {
            let (text, isError) = await Self.call("hash", BuiltinTools.utilsGroup, ["input": "abc", "algorithm": "rot13"])
            #expect(isError)
            #expect(text.contains("algorithm"))
        }

        @Test("base64 round-trips arbitrary text")
        func b64RoundTrip() async throws {
            let original = "Héllo, 世界! 🚀"
            let (encoded, _) = await Self.call("base64_encode", BuiltinTools.utilsGroup, ["input": original])
            let (decoded, isError) = await Self.call("base64_decode", BuiltinTools.utilsGroup, ["input": encoded.trimmingCharacters(in: .whitespacesAndNewlines)])
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

        @Test("unknown tool errors")
        func unknownTool() async throws {
            let (text, err) = await Self.call("does_not_exist", BuiltinTools.utilsGroup, [:])
            #expect(err)
            #expect(text.contains("Unknown tool"))
        }

        // Static wrapper so nested struct can call the helper.
        static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (text: String, isError: Bool) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(name: name, arguments: arguments, callID: "test", group: group, workdir: workdir)
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
            let (w, wErr) = await Self.call("write_file", BuiltinTools.filesystemGroup, ["path": path, "content": "line1\nline2\n"])
            #expect(!wErr)
            #expect(w.contains("Wrote"))
            let (r, rErr) = await Self.call("read_file", BuiltinTools.filesystemGroup, ["path": path])
            #expect(!rErr)
            #expect(r.contains("line1"))
            #expect(r.contains("line2"))
        }

        @Test("read_file supports offset and limit")
        func readOffsetLimit() async throws {
            let tmp = try TestDir()
            try tmp.write("offset.txt", content: "a\nb\nc\nd\ne\n")
            let (r, rErr) = await Self.call("read_file", BuiltinTools.filesystemGroup, ["path": tmp.sub("offset.txt"), "offset": 2, "limit": 2])
            #expect(!rErr)
            #expect(r.contains("b"))
            #expect(r.contains("c"))
            #expect(!r.contains("d"))
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
            let (text, err) = await Self.call("ls", BuiltinTools.filesystemGroup, ["path": tmp.path, "recursive": true])
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
            let (text, err) = await Self.call("ls", BuiltinTools.filesystemGroup, ["path": tmp.path, "recursive": true])
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
            let (_, err) = await Self.call("mv", BuiltinTools.filesystemGroup, ["src": tmp.sub("src.txt"), "dst": tmp.sub("dst.txt")])
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
            let (text, err) = await Self.call("find_file", BuiltinTools.filesystemGroup, ["path": tmp.sub("find"), "pattern": "*.swift"])
            #expect(!err)
            #expect(text.contains("me.swift"))
            #expect(!text.contains("me.txt"))
        }

        @Test("find_text searches file contents")
        func findText() async throws {
            let tmp = try TestDir()
            try tmp.write("search/a.txt", content: "needle in haystack")
            try tmp.write("search/b.txt", content: "nothing here")
            let (text, err) = await Self.call("find_text", BuiltinTools.filesystemGroup, ["path": tmp.sub("search"), "regex": "needle"])
            #expect(!err)
            #expect(text.contains("a.txt"))
            #expect(!text.contains("b.txt"))
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
            let (_, err) = await Self.call("write_file", BuiltinTools.filesystemGroup, ["path": "/isolated.txt", "content": "x"], workdir: wd)
            #expect(!err)
            #expect(tmp.exists("isolated.txt"))
        }

        @Test("path escape via .. is rejected when isolated")
        func escapeRejected() async throws {
            let tmp = try TestDir()
            let wd = Workdir(root: tmp.path, isolated: true)
            let (text, err) = await Self.call("write_file", BuiltinTools.filesystemGroup, ["path": "../../escaped.txt", "content": "z"], workdir: wd)
            #expect(err)
            #expect(text.contains("escapes"))
        }

        @Test("relative path resolves against workdir")
        func relativePath() async throws {
            let tmp = try TestDir()
            let wd = Workdir(root: tmp.path, isolated: false)
            let (_, err) = await Self.call("write_file", BuiltinTools.filesystemGroup, ["path": "rel.txt", "content": "hi"], workdir: wd)
            #expect(!err)
            #expect(tmp.exists("rel.txt"))
        }

        static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (text: String, isError: Bool) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(name: name, arguments: arguments, callID: "test", group: group, workdir: workdir)
            return (result.content, result.isError)
        }
    }

    // MARK: - Code

    @Suite("Builtin tools: Code")
    struct BuiltinCodeTests {
        @Test("apply_patch adds a new file")
        func patchAddFile() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("new.swift")
            let patch = """
            *** Begin Patch
            *** Add File: \(path)
            +let x = 42
            +print(x)
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(!err)
            #expect(text.contains("Added"))
            let content = try String(contentsOfFile: path, encoding: .utf8)
            #expect(content.contains("let x = 42"))
        }

        @Test("apply_patch deletes a file")
        func patchDeleteFile() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("kill.txt")
            try tmp.write("kill.txt", content: "bye")
            let patch = """
            *** Begin Patch
            *** Delete File: \(path)
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(!err)
            #expect(text.contains("Deleted"))
            #expect(!FileManager.default.fileExists(atPath: path))
        }

        @Test("apply_patch updates an existing file")
        func patchUpdateFile() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("edit.txt")
            try tmp.write("edit.txt", content: "line one\nline two\nline three\n")
            let patch = """
            *** Begin Patch
            *** Update File: \(path)
            @@
             line one
            -line two
            +line TWO
             line three
            *** End Patch
            """
            let (text, _) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(text.contains("Updated"), "patch failed: \(text)")
            let content = try String(contentsOfFile: path, encoding: .utf8)
            #expect(content.contains("line TWO"))
            #expect(!content.contains("line two\n"))
        }

        @Test("git runs a command")
        func gitStatus() async throws {
            let (text, err) = await Self.call("git", BuiltinTools.codeGroup, ["args": ["--version"]])
            #expect(!err)
            #expect(text.contains("git version"))
        }

        @Test("git errors on missing args")
        func gitMissing() async throws {
            let (text, err) = await Self.call("git", BuiltinTools.codeGroup, [:])
            #expect(err)
            #expect(text.contains("args"))
        }

        @Test("git errors on empty args")
        func gitEmpty() async throws {
            let (text, err) = await Self.call("git", BuiltinTools.codeGroup, ["args": []])
            #expect(err)
            #expect(text.contains("empty"))
        }

        @Test("apply_patch uses relative paths against workdir")
        func patchRelative() async throws {
            let tmp = try TestDir()
            let wd = Workdir(root: tmp.path, isolated: false)
            let patch = """
            *** Begin Patch
            *** Add File: rel.txt
            +hello workdir
            *** End Patch
            """
            let (_, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch], workdir: wd)
            #expect(!err)
            #expect(tmp.exists("rel.txt"))
            #expect(try tmp.read("rel.txt").contains("hello workdir"))
        }

        @Test("path escape via .. is rejected when isolated")
        func escapeRejected() async throws {
            let tmp = try TestDir()
            let wd = Workdir(root: tmp.path, isolated: true)
            let patch = """
            *** Begin Patch
            *** Add File: ../../escaped.txt
            +bad
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch], workdir: wd)
            #expect(err)
            #expect(text.contains("escapes"))
        }

        @Test("apply_patch End of File as hunk opener appends at EOF")
        func patchEndOfFileOpener() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("append.txt")
            try tmp.write("append.txt", content: "first\nlast line\n")
            let patch = """
            *** Begin Patch
            *** Update File: \(path)
            *** End of File
             last line
            +appended line
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(!err, "patch failed: \(text)")
            #expect(try tmp.read("append.txt") == "first\nlast line\nappended line\n")
        }

        @Test("apply_patch End of File as separator anchors the following hunk at EOF")
        func patchEndOfFileSeparator() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("sep.txt")
            try tmp.write("sep.txt", content: "one\ntwo\nthree\nfour\n")
            let patch = """
            *** Begin Patch
            *** Update File: \(path)
            @@
             one
            -two
            +TWO
            *** End of File
             four
            +five
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(!err, "patch failed: \(text)")
            #expect(try tmp.read("sep.txt") == "one\nTWO\nthree\nfour\nfive\n")
        }

        @Test("apply_patch trailing End of File still anchors its own hunk at EOF")
        func patchEndOfFileStrictAnchor() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("dup.txt")
            try tmp.write("dup.txt", content: "x\nmid\nx\n")
            let patch = """
            *** Begin Patch
            *** Update File: \(path)
            -x
            +CHANGED
            *** End of File
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(!err, "patch failed: \(text)")
            // The EOF anchor must hit the LAST "x", not the first.
            #expect(try tmp.read("dup.txt") == "x\nmid\nCHANGED\n")
        }

        @Test("apply_patch parse error reports the format problem and line")
        func patchParseErrorMessage() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("err.txt")
            try tmp.write("err.txt", content: "a\nb\n")
            let patch = """
            *** Begin Patch
            *** Update File: \(path)
            @@
             a
            +b2
            stray line without prefix
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(err)
            #expect(text.contains("Invalid apply_patch format"), "unexpected message: \(text)")
            #expect(text.contains("Line 6"), "expected a line number: \(text)")
            #expect(text.contains("@@"), "expected a hint about the @@ marker: \(text)")
        }

        @Test("apply_patch multi-op: update+move, add, delete in one call")
        func patchMultiOp() async throws {
            let tmp = try TestDir()
            try tmp.write("base.txt", content: "alpha\n")
            try tmp.write("doomed.txt", content: "bye\n")
            let patch = """
            *** Begin Patch
            *** Update File: \(tmp.sub("base.txt"))
            *** Move to: \(tmp.sub("renamed.txt"))
             alpha
            +beta
            *** Add File: \(tmp.sub("fresh.txt"))
            +created
            *** Delete File: \(tmp.sub("doomed.txt"))
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(!err, "patch failed: \(text)")
            #expect(!tmp.exists("base.txt"))
            #expect(try tmp.read("renamed.txt") == "alpha\nbeta\n")
            #expect(try tmp.read("fresh.txt") == "created\n")
            #expect(!tmp.exists("doomed.txt"))
        }

        @Test("apply_patch add then update the same file in one call")
        func patchAddThenUpdateSameFile() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("two-step.txt")
            let patch = """
            *** Begin Patch
            *** Add File: \(path)
            +first
            *** Update File: \(path)
             first
            +second
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(!err, "patch failed: \(text)")
            #expect(try tmp.read("two-step.txt") == "first\nsecond\n")
        }

        @Test("apply_patch failure leaves earlier operations unapplied")
        func patchAtomicOnFailure() async throws {
            let tmp = try TestDir()
            let patch = """
            *** Begin Patch
            *** Add File: \(tmp.sub("partial.txt"))
            +should not exist
            *** Delete File: \(tmp.sub("missing.txt"))
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(err)
            #expect(text.contains("missing.txt"), "unexpected message: \(text)")
            #expect(!tmp.exists("partial.txt"), "failed patch must not write anything")
        }

        @Test("apply_patch stacked @@ markers produce a targeted error")
        func patchStackedContextMarkers() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("stacked.txt")
            try tmp.write("stacked.txt", content: "class A:\n    def f():\n        pass\n")
            let patch = """
            *** Begin Patch
            *** Update File: \(path)
            @@ class A:
            @@     def f():
            -        pass
            +        return 1
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(err)
            #expect(text.contains("stacked @@"), "unexpected message: \(text)")
        }

        @Test("apply_patch anchor repeated in body gets a diagnostic error")
        func patchRepeatedAnchorDiagnostic() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("anchor.txt")
            try tmp.write("anchor.txt", content: "one\ntwo\nthree\nfour\n")
            // The @@ anchor "two" is repeated as the first body context line —
            // the body can never match after the anchor.
            let patch = """
            *** Begin Patch
            *** Update File: \(path)
            @@ two
             two
            -three
            +THREE
             four
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(err)
            #expect(text.contains("line 2"), "expected the matched line number: \(text)")
            #expect(text.contains("repeated"), "expected the anchor-repeat hint: \(text)")
        }

        @Test("apply_patch overlapping hunks get a top-to-bottom diagnostic")
        func patchOverlappingHunksDiagnostic() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("overlap.txt")
            try tmp.write("overlap.txt", content: "one\ntwo\nthree\nfour\nfive\n")
            // Hunk 1's trailing context ("three") is hunk 2's @@ anchor — the
            // sequential matcher has already consumed past it.
            let patch = """
            *** Begin Patch
            *** Update File: \(path)
            @@
             one
            -two
            +TWO
             three
            @@ three
            -four
            +FOUR
             five
            *** End Patch
            """
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(err)
            #expect(text.contains("top-to-bottom"), "expected the ordering hint: \(text)")
        }

        @Test("apply_patch tolerates trailing whitespace on structural lines")
        func patchTrailingWhitespaceMarkers() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("ws.txt")
            try tmp.write("ws.txt", content: "a\nb\n")
            // "@@ " with a trailing space is a bare @@ (codex parity).
            let patch = "*** Begin Patch\n*** Update File: \(path)\n@@ \n a\n-b\n+b2\n*** End Patch\n"
            let (text, err) = await Self.call("apply_patch", BuiltinTools.codeGroup, ["patch": patch])
            #expect(!err, "patch failed: \(text)")
            #expect(try tmp.read("ws.txt") == "a\nb2\n")
        }

        static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (text: String, isError: Bool) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(name: name, arguments: arguments, callID: "test", group: group, workdir: workdir)
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

        @Test("applescript returns a result")
        func applescript() async throws {
            let (text, err) = await Self.call("applescript", BuiltinTools.shellGroup, ["script": "return 1 + 1"])
            #expect(!err)
            #expect(text.contains("2"))
        }

        @Test("applescript errors on bad script")
        func applescriptBad() async throws {
            let (text, err) = await Self.call("applescript", BuiltinTools.shellGroup, ["script": "this is not applescript"])
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

        static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir = .none) async -> (text: String, isError: Bool) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(name: name, arguments: arguments, callID: "test", group: group, workdir: workdir)
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
            // Filesystem
            #expect(defs.contains { $0.name == "ls" && $0.serverName == "Filesystem" })
            #expect(defs.contains { $0.name == "read_file" && $0.serverName == "Filesystem" })
            #expect(defs.contains { $0.name == "write_file" && $0.serverName == "Filesystem" })
            #expect(defs.contains { $0.name == "pwd" && $0.serverName == "Filesystem" })
            // Code
            #expect(defs.contains { $0.name == "apply_patch" && $0.serverName == "Code" })
            #expect(defs.contains { $0.name == "git" && $0.serverName == "Code" })
            // Shell
            #expect(defs.contains { $0.name == "shell" && $0.serverName == "Shell" })
            #expect(defs.contains { $0.name == "applescript" && $0.serverName == "Shell" })
        }

        @Test("group(for:) resolves tool names to their group")
        func groupResolution() {
            #expect(BuiltinTools.group(for: "calc") == "Utils")
            #expect(BuiltinTools.group(for: "ls") == "Filesystem")
            #expect(BuiltinTools.group(for: "apply_patch") == "Code")
            #expect(BuiltinTools.group(for: "shell") == "Shell")
            #expect(BuiltinTools.group(for: "nonexistent") == nil)
        }

        @Test("shell_background and shell_read_output are not present")
        func noBackgroundTools() {
            #expect(!BuiltinTools.allToolNames.contains("shell_background"))
            #expect(!BuiltinTools.allToolNames.contains("shell_read_output"))
        }
    }
}
