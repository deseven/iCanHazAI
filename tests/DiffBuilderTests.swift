import Foundation
import Testing

@testable import iCanHazAI

/// Tests for [`DiffBuilder`](src/Tools/DiffBuilder.swift), which builds unified
/// diffs for `write_file` tool calls.
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
            let d = DiffBuilder.unifiedDiff(
                old: "one\ntwo\nthree\n", new: "one\nTWO\nthree\n", oldPath: "f", newPath: "f")
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
            let d = DiffBuilder.unifiedDiff(
                old: "keep\nchange\nkeep2\n", new: "keep\nCHANGED\nkeep2\n", oldPath: "f", newPath: "f")
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
}
