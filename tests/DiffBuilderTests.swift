import Testing
import Foundation
@testable import iCanHazAI

/// Tests for [`DiffBuilder`](src/DiffBuilder.swift), which builds unified diffs
/// for `write_file` and `apply_patch` tool calls.
///
/// Nested under `AllAppTests` so its `.serialized` trait keeps these sequential
/// with the rest of the app suites.
extension AllAppTests {

    // MARK: - Test helpers

    /// A temp directory + helpers, mirroring the `TestDir` in
    /// `BuiltinToolsTests.swift`.
    private final class TestDir {
        let path: String
        init() throws {
            let base = NSTemporaryDirectory()
            let name = "ichai-diff-tests-\(UUID().uuidString)"
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
    }

    private static func argsJSON(_ dict: [String: Any]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8)) ?? "{}"
    }

    // MARK: - unifiedDiff (direct)

    @Suite("DiffBuilder: unifiedDiff")
    struct DiffBuilderUnifiedTests {
        @Test("identical content produces an empty diff")
        func identicalEmpty() async throws {
            let d = DiffBuilder.unifiedDiff(old: "a\nb\nc\n", new: "a\nb\nc\n", oldPath: "f", newPath: "f")
            #expect(d.isEmpty)
        }

        @Test("pure insertion marks added lines with +")
        func pureInsertion() async throws {
            let d = DiffBuilder.unifiedDiff(old: "a\n", new: "a\nb\n", oldPath: "f", newPath: "f")
            #expect(!d.isEmpty)
            #expect(d.contains("+b"))
            #expect(!d.contains("-b"))
        }

        @Test("pure deletion marks removed lines with -")
        func pureDeletion() async throws {
            let d = DiffBuilder.unifiedDiff(old: "a\nb\n", new: "a\n", oldPath: "f", newPath: "f")
            #expect(!d.isEmpty)
            #expect(d.contains("-b"))
            #expect(!d.contains("+b"))
        }

        @Test("modification shows both - and + lines")
        func modification() async throws {
            let d = DiffBuilder.unifiedDiff(old: "one\ntwo\nthree\n", new: "one\nTWO\nthree\n", oldPath: "f", newPath: "f")
            #expect(!d.isEmpty)
            #expect(d.contains("-two"))
            #expect(d.contains("+TWO"))
        }

        @Test("new file uses /dev/null for old path")
        func newFile() async throws {
            let d = DiffBuilder.unifiedDiff(old: "", new: "hello\n", oldPath: nil, newPath: "new.txt")
            #expect(!d.isEmpty)
            #expect(d.contains("--- /dev/null"))
            #expect(d.contains("+++ new.txt"))
            #expect(d.contains("+hello"))
        }

        @Test("deleted file uses /dev/null for new path")
        func deletedFile() async throws {
            let d = DiffBuilder.unifiedDiff(old: "bye\n", new: "", oldPath: "old.txt", newPath: nil)
            #expect(!d.isEmpty)
            #expect(d.contains("--- old.txt"))
            #expect(d.contains("+++ /dev/null"))
            #expect(d.contains("-bye"))
        }

        @Test("hunk header has the @@ format with line counts")
        func hunkHeader() async throws {
            let d = DiffBuilder.unifiedDiff(old: "a\nb\nc\n", new: "a\nB\nc\n", oldPath: "f", newPath: "f")
            #expect(d.contains("@@"))
            // The header has the form `@@ -<oldStart>,<oldCount> +<newStart>,<newCount> @@`.
            // With a 3-line file and context=3, the hunk covers the whole file
            // (start clamped to line 1), so we just verify the format.
            #expect(d.range(of: #"@@\s+-\d+,\d+\s+\+\d+,\d+\s+@@"#, options: .regularExpression) != nil)
        }

        @Test("context lines are prefixed with a space")
        func contextPrefix() async throws {
            let d = DiffBuilder.unifiedDiff(old: "keep\nchange\nkeep2\n", new: "keep\nCHANGED\nkeep2\n", oldPath: "f", newPath: "f")
            #expect(d.contains(" keep"))
            #expect(d.contains(" keep2"))
        }

        @Test("changes far apart produce separate hunks")
        func separateHunks() async throws {
            let old = (0..<20).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let new = old.replacingOccurrences(of: "line1", with: "LINE1")
                         .replacingOccurrences(of: "line18", with: "LINE18")
            let d = DiffBuilder.unifiedDiff(old: old, new: new, oldPath: "f", newPath: "f")
            let hunkCount = d.components(separatedBy: "@@").count - 1
            #expect(hunkCount >= 2, "expected >= 2 hunks, got \(hunkCount)\n\(d)")
        }
    }

    // MARK: - diffForWriteFile

    @Suite("DiffBuilder: write_file")
    struct DiffBuilderWriteFileTests {
        @Test("diff against an existing file shows the change")
        func existingFile() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("f.txt")
            try tmp.write("f.txt", content: "old\n")
            let args = Self.argsJSON(["path": path, "content": "new\n"])
            let d = DiffBuilder.diffForWriteFile(arguments: args, workdir: .none)
            #expect(d != nil)
            #expect(d!.contains("-old"))
            #expect(d!.contains("+new"))
        }

        @Test("new file diff shows all lines as additions")
        func newFile() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("brand_new.txt")
            let args = Self.argsJSON(["path": path, "content": "a\nb\n"])
            let d = DiffBuilder.diffForWriteFile(arguments: args, workdir: .none)
            #expect(d != nil)
            #expect(d!.contains("+a"))
            #expect(d!.contains("+b"))
            #expect(!d!.contains("-a"))
        }

        @Test("identical content returns an empty (but non-nil) diff")
        func identical() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("same.txt")
            try tmp.write("same.txt", content: "same\n")
            let args = Self.argsJSON(["path": path, "content": "same\n"])
            let d = DiffBuilder.diffForWriteFile(arguments: args, workdir: .none)
            #expect(d != nil)
            #expect(d!.isEmpty)
        }

        @Test("invalid JSON returns nil")
        func invalidJSON() async throws {
            let d = DiffBuilder.diffForWriteFile(arguments: "not json", workdir: .none)
            #expect(d == nil)
        }

        @Test("missing path returns nil")
        func missingPath() async throws {
            let args = Self.argsJSON(["content": "hi"])
            let d = DiffBuilder.diffForWriteFile(arguments: args, workdir: .none)
            #expect(d == nil)
        }

        @Test("missing content returns nil")
        func missingContent() async throws {
            let tmp = try TestDir()
            let args = Self.argsJSON(["path": tmp.sub("x.txt")])
            let d = DiffBuilder.diffForWriteFile(arguments: args, workdir: .none)
            #expect(d == nil)
        }

        static func argsJSON(_ dict: [String: Any]) -> String {
            (try? String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8)) ?? "{}"
        }
    }

    // MARK: - diffForApplyPatch

    @Suite("DiffBuilder: apply_patch")
    struct DiffBuilderApplyPatchTests {
        @Test("add file produces a diff with additions only")
        func addFile() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("added.txt")
            let patch = """
            *** Begin Patch
            *** Add File: \(path)
            +hello
            +world
            *** End Patch
            """
            let args = Self.argsJSON(["patch": patch])
            let d = DiffBuilder.diffForApplyPatch(arguments: args, workdir: .none)
            #expect(d != nil)
            #expect(d!.contains("+hello"))
            #expect(d!.contains("+world"))
            #expect(!d!.contains("-hello"))
        }

        @Test("delete file produces a diff with deletions only")
        func deleteFile() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("kill.txt")
            try tmp.write("kill.txt", content: "bye\nnow\n")
            let patch = """
            *** Begin Patch
            *** Delete File: \(path)
            *** End Patch
            """
            let args = Self.argsJSON(["patch": patch])
            let d = DiffBuilder.diffForApplyPatch(arguments: args, workdir: .none)
            #expect(d != nil)
            #expect(d!.contains("-bye"))
            #expect(d!.contains("-now"))
            #expect(!d!.contains("+bye"))
        }

        @Test("update file produces a diff with both - and + lines")
        func updateFile() async throws {
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
            let args = Self.argsJSON(["patch": patch])
            let d = DiffBuilder.diffForApplyPatch(arguments: args, workdir: .none)
            #expect(d != nil, "expected a diff for a valid update patch")
            #expect(d!.contains("-line two"))
            #expect(d!.contains("+line TWO"))
        }

        @Test("invalid patch returns nil")
        func invalidPatch() async throws {
            let args = Self.argsJSON(["patch": "this is not a patch"])
            let d = DiffBuilder.diffForApplyPatch(arguments: args, workdir: .none)
            #expect(d == nil)
        }

        @Test("missing patch argument returns nil")
        func missingPatch() async throws {
            let args = Self.argsJSON([:])
            let d = DiffBuilder.diffForApplyPatch(arguments: args, workdir: .none)
            #expect(d == nil)
        }

        @Test("multi-file patch joins sections")
        func multiFile() async throws {
            let tmp = try TestDir()
            let pathA = tmp.sub("a.txt")
            let pathB = tmp.sub("b.txt")
            try tmp.write("a.txt", content: "a1\n")
            try tmp.write("b.txt", content: "b1\n")
            let patch = """
            *** Begin Patch
            *** Update File: \(pathA)
            @@
            -a1
            +a2
            *** Update File: \(pathB)
            @@
            -b1
            +b2
            *** End Patch
            """
            let args = Self.argsJSON(["patch": patch])
            let d = DiffBuilder.diffForApplyPatch(arguments: args, workdir: .none)
            #expect(d != nil)
            #expect(d!.contains("-a1"))
            #expect(d!.contains("+a2"))
            #expect(d!.contains("-b1"))
            #expect(d!.contains("+b2"))
        }

        @Test("preflight returns the real parse error for an unparseable patch")
        func preflightParseError() async throws {
            let args = Self.argsJSON(["patch": "this is not a patch"])
            guard case .error(let message) = DiffBuilder.preflightApplyPatch(arguments: args, workdir: .none) else {
                Issue.record("expected preflight to fail")
                return
            }
            #expect(message.contains("Invalid apply_patch format"), "unexpected message: \(message)")
            #expect(message.contains("*** Begin Patch"), "expected the reason in the message: \(message)")
        }

        @Test("preflight reports context mismatches with the tool's own error")
        func preflightApplyError() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("mismatch.txt")
            try tmp.write("mismatch.txt", content: "actual\n")
            let patch = """
            *** Begin Patch
            *** Update File: \(path)
            @@
            -expected
            +changed
            *** End Patch
            """
            let args = Self.argsJSON(["patch": patch])
            guard case .error(let message) = DiffBuilder.preflightApplyPatch(arguments: args, workdir: .none) else {
                Issue.record("expected preflight to fail")
                return
            }
            #expect(message.contains("Failed to apply patch"), "unexpected message: \(message)")
            #expect(message.contains("expected"), "expected the missing lines in the message: \(message)")
        }

        @Test("preflight dry-run makes no changes on disk")
        func preflightNoWrites() async throws {
            let tmp = try TestDir()
            let path = tmp.sub("keep.txt")
            try tmp.write("keep.txt", content: "before\n")
            let patch = """
            *** Begin Patch
            *** Update File: \(path)
            @@
            -before
            +after
            *** End Patch
            """
            let args = Self.argsJSON(["patch": patch])
            guard case .ok(let diff) = DiffBuilder.preflightApplyPatch(arguments: args, workdir: .none) else {
                Issue.record("expected preflight to succeed")
                return
            }
            #expect(diff != nil)
            #expect(diff!.contains("+after"))
            #expect(try tmp.read("keep.txt") == "before\n", "dry-run must not write")
        }

        static func argsJSON(_ dict: [String: Any]) -> String {
            (try? String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8)) ?? "{}"
        }
    }
}
