import AppKit
import Foundation
import Testing

@testable import iCanHazAI

/// In-process tests for the `edit_file` tool (Code group): hashline patch
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
    /// `(text, isError)`.
    private static func editCall(_ input: String, workdir: Workdir = .none) async -> (text: String, isError: Bool) {
        let arguments =
            (try? String(data: JSONSerialization.data(withJSONObject: ["input": input]), encoding: .utf8))
            ?? "{}"
        let result = await BuiltinTools.call(
            name: "edit_file", arguments: arguments, callID: "test", group: BuiltinTools.codeGroup,
            workdir: workdir, chatFilename: "test.json")
        return (result.content, result.isError)
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
            // Appending at eof keeps the phantom trailing empty line from the
            // final newline, so the tail lands after a blank separator line.
            #expect(try tmp.read("a.txt") == "a\nb\n\ntail")
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

        @Test("noop body produces an informational message")
        func noop() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            // Body identical to the targeted line.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 1.=1:\n+a\n", tag: tag))
            #expect(!err)
            #expect(text.contains("No changes to \(file)."))
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

        @Test("preflight ok produces a unified diff")
        func preflightOk() async throws {
            let tmp = try EditTestDir()
            _ = try tmp.write("a.txt", content: "one\ntwo\nthree\n")
            let tag = HashlineFormat.computeFileHash("one\ntwo\nthree\n")
            let input = "*** Begin Patch\n[\(tmp.sub("a.txt"))#\(tag)]\nPUT 2.=2:\n+TWO\n*** End Patch"
            let wd = Workdir(root: tmp.path, isolated: false)
            let result = DiffBuilder.preflightEditFile(arguments: argsJSON(input), workdir: wd)
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
            let wd = Workdir(root: NSTemporaryDirectory(), isolated: false)
            let result = DiffBuilder.preflightEditFile(arguments: argsJSON("not a patch"), workdir: wd)
            guard case .error(let message) = result else {
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
            let wd = Workdir(root: tmp.path, isolated: false)
            let result = DiffBuilder.preflightEditFile(arguments: argsJSON(input), workdir: wd)
            guard case .error(let message) = result else {
                Issue.record("expected .error, got \(result)")
                return
            }
            #expect(message.contains("has changed since you last read it"))
        }

        @Test("preflight handles invalid arguments JSON")
        func preflightInvalidArgs() {
            let result = DiffBuilder.preflightEditFile(arguments: "not json", workdir: .none)
            guard case .error(let message) = result else {
                Issue.record("expected .error, got \(result)")
                return
            }
            #expect(message.contains("Invalid arguments"))
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
        @Test("edit_file is the only Code tool and dispatches to the Code group")
        func registry() {
            let defs = BuiltinTools.tools(for: BuiltinTools.codeGroup)
            #expect(defs.count == 1)
            #expect(defs[0].name == "edit_file")
            #expect(BuiltinTools.group(for: "edit_file") == "Code")
            #expect(BuiltinTools.allToolNames.contains("edit_file"))
        }

        @Test("edit_file tool definition carries the hashline schema")
        func schema() throws {
            let defs = BuiltinTools.tools(for: BuiltinTools.codeGroup)
            let def = defs.first { $0.name == "edit_file" }
            let schema = try #require(def?.schema)
            #expect(schema.contains("\"input\""))
            #expect(schema.contains("\"required\":[\"input\"]"))
        }
    }
}
