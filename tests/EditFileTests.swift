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

        @Test("no-op has no preview")
        func noopHasNoPreview() async throws {
            let tmp = try EditTestDir()
            let file = try tmp.write("a.txt", content: "a\nb\n")
            let tag = HashlineFormat.computeFileHash("a\nb\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 1.=1:\n+a\n", tag: tag))
            #expect(!err)
            #expect(text.contains("No changes to \(file)."))
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

        @Test("out-of-bounds error reports the real line count including trailing empty line")
        func outOfBoundsLineCount() async throws {
            let tmp = try EditTestDir()
            // "a\nb\nc\n" splits to ["a","b","c",""] — 4 lines. read_file
            // shows all 4 (including the empty line 4), so edit_file's
            // bounds error must also report 4, not 3.
            let file = try tmp.write("a.txt", content: "a\nb\nc\n")
            let tag = HashlineFormat.computeFileHash("a\nb\nc\n")
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 5.=5:\n+X\n", tag: tag))
            #expect(err)
            #expect(text.contains("file has 4 lines"))
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

        @Test("preflight surfaces parser warnings")
        func preflightWarnings() async throws {
            let tmp = try EditTestDir()
            _ = try tmp.write("a.txt", content: "one\ntwo\n")
            let tag = HashlineFormat.computeFileHash("one\ntwo\n")
            let input = "*** Begin Patch\n[\(tmp.sub("a.txt"))#\(tag)]\nPUT 1.=1:\nX\n*** End Patch"
            let wd = Workdir(root: tmp.path, isolated: false)
            let result = DiffBuilder.preflightEditFile(arguments: argsJSON(input), workdir: wd)
            guard case .ok(let diff) = result else {
                Issue.record("expected .ok, got \(result)")
                return
            }
            let d = try #require(diff)
            #expect(d.contains("WARNING: Auto-prefixed bare body row(s)"))
            // Preflight still never writes.
            #expect(try tmp.read("a.txt") == "one\ntwo\n")
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

    // MARK: - edit_file: seen-lines guard

    @Suite("edit_file: seen-lines guard")
    struct EditFileSeenLinesTests {
        /// Runs `read_file` (with a store) over the given line window, returns
        /// the content.
        private static func read(
            _ relative: String, tmp: EditTestDir, store: SnapshotStore, offset: Int? = nil, limit: Int? = nil
        ) async -> String {
            let file = tmp.sub(relative)
            var args: [String: Any] = ["path": file]
            if let offset { args["offset"] = offset }
            if let limit { args["limit"] = limit }
            let result = await BuiltinTools.call(
                name: "read_file", arguments: AllAppTests.argsJSON(args), callID: "test",
                group: BuiltinTools.filesystemGroup, workdir: .none, chatFilename: "test.json", snapshotStore: store)
            return result.content
        }

        /// A helper to run edit_file with a store.
        private static func editWithStore(
            _ input: String, workdir: Workdir = .none, store: SnapshotStore
        ) async -> (text: String, isError: Bool) {
            let arguments = AllAppTests.argsJSON(["input": input])
            let result = await BuiltinTools.call(
                name: "edit_file", arguments: arguments, callID: "test", group: BuiltinTools.codeGroup,
                workdir: workdir, chatFilename: "test.json", snapshotStore: store)
            return (result.content, result.isError)
        }

        @Test("partial read then editing an unseen line is rejected")
        func partialReadUnseenLine() async throws {
            let tmp = try EditTestDir()
            // 10 lines; read only lines 1-3.
            let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let store = SnapshotStore()
            let readOut = await Self.read("a.txt", tmp: tmp, store: store, offset: 1, limit: 3)
            #expect(readOut.contains("[\(file)#"))
            // Edit line 8 (never displayed).
            let tag = HashlineFormat.computeFileHash(content)
            let (text, err) = await Self.editWithStore(patch(file, "PUT 8.=8:\n+X\n", tag: tag), store: store)
            #expect(err)
            #expect(text.contains("8"))
            #expect(text.contains("never displayed"))
            #expect(try tmp.read("a.txt") == content)
        }

        @Test("full read then editing any line succeeds")
        func fullReadEditsAnyLine() async throws {
            let tmp = try EditTestDir()
            let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let store = SnapshotStore()
            _ = await Self.read("a.txt", tmp: tmp, store: store)
            let tag = HashlineFormat.computeFileHash(content)
            let (text, err) = await Self.editWithStore(patch(file, "PUT 8.=8:\n+X\n", tag: tag), store: store)
            #expect(!err, "edit_file failed: \(text)")
            #expect(
                try tmp.read("a.txt") == (1...7).map { "line\($0)" }.joined(separator: "\n") + "\nX\nline9\nline10\n")
        }

        @Test("partial read then editing a seen line succeeds")
        func partialReadSeenLine() async throws {
            let tmp = try EditTestDir()
            let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let store = SnapshotStore()
            _ = await Self.read("a.txt", tmp: tmp, store: store, offset: 1, limit: 3)
            let tag = HashlineFormat.computeFileHash(content)
            let (text, err) = await Self.editWithStore(patch(file, "PUT 2.=2:\n+X\n", tag: tag), store: store)
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "line1\nX\n" + (3...10).map { "line\($0)" }.joined(separator: "\n") + "\n")
        }

        @Test("reveal-and-retry: rejection inlines content, retry succeeds")
        func revealAndRetry() async throws {
            let tmp = try EditTestDir()
            let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let store = SnapshotStore()
            _ = await Self.read("a.txt", tmp: tmp, store: store, offset: 1, limit: 3)
            let tag = HashlineFormat.computeFileHash(content)
            let (rej, err) = await Self.editWithStore(patch(file, "PUT 8.=8:\n+X\n", tag: tag), store: store)
            #expect(err)
            #expect(rej.contains("Actual file content at those lines"))
            #expect(rej.contains("8:line8"))
            // The rejection inlined line 8 and merged it into seenLines, so a
            // straight retry of the same edit succeeds without a re-read.
            let (retry, retryErr) = await Self.editWithStore(patch(file, "PUT 8.=8:\n+X\n", tag: tag), store: store)
            #expect(!retryErr, "retry failed: \(retry)")
            #expect(
                try tmp.read("a.txt") == (1...7).map { "line\($0)" }.joined(separator: "\n") + "\nX\nline9\nline10\n")
        }

        @Test("truncated reveal does not merge into seenLines")
        func truncatedRevealNoMerge() async throws {
            let tmp = try EditTestDir()
            // 60 lines; read lines 1-3. Edit 50 unseen lines (4-53) — the
            // reveal exceeds the 40-line cap, so nothing is merged.
            let content = (1...60).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let store = SnapshotStore()
            _ = await Self.read("a.txt", tmp: tmp, store: store, offset: 1, limit: 3)
            let tag = HashlineFormat.computeFileHash(content)
            let (rej, err) = await Self.editWithStore(patch(file, "PUT 4.=53:\n+X\n", tag: tag), store: store)
            #expect(err)
            #expect(rej.contains("exceeds the inline preview cap"))
            // Retry is still rejected — the truncated reveal did not merge.
            let (retry, retryErr) = await Self.editWithStore(patch(file, "PUT 4.=53:\n+X\n", tag: tag), store: store)
            #expect(retryErr)
            #expect(retry.contains("exceeds the inline preview cap"))
            #expect(try tmp.read("a.txt") == content)
        }

        @Test("no snapshot means the guard is skipped")
        func noSnapshotSkipsGuard() async throws {
            let tmp = try EditTestDir()
            let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            // No store passed → no seen-lines check, edit applies as before.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 8.=8:\n+X\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(
                try tmp.read("a.txt") == (1...7).map { "line\($0)" }.joined(separator: "\n") + "\nX\nline9\nline10\n")
        }

        @Test("MV relocates the snapshot so the destination is editable")
        func mvRelocatesSnapshot() async throws {
            let tmp = try EditTestDir()
            let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let store = SnapshotStore()
            _ = await Self.read("a.txt", tmp: tmp, store: store)
            let tag = HashlineFormat.computeFileHash(content)
            let dest = tmp.sub("renamed.txt")
            let mvInput = """
                *** Begin Patch
                [\(file)#\(tag)]
                MV \(dest)
                *** End Patch
                """
            let (mvText, mvErr) = await Self.editWithStore(mvInput, store: store)
            #expect(!mvErr, "MV failed: \(mvText)")
            // Editing the destination with the new tag succeeds (history was
            // relocated; the whole file is seen).
            let newContent = try tmp.read("renamed.txt")
            let newTag = HashlineFormat.computeFileHash(newContent)
            let (text, err) = await Self.editWithStore(patch(dest, "PUT 5.=5:\n+Y\n", tag: newTag), store: store)
            #expect(!err, "edit after MV failed: \(text)")
            #expect(try tmp.read("renamed.txt").contains("\nY\n"))
        }

        @Test("REM invalidates the snapshot")
        func remInvalidates() async throws {
            let tmp = try EditTestDir()
            let content = "a\nb\nc\n"
            let file = try tmp.write("a.txt", content: content)
            let store = SnapshotStore()
            _ = await Self.read("a.txt", tmp: tmp, store: store)
            let tag = HashlineFormat.computeFileHash(content)
            let (remText, remErr) = await Self.editWithStore(patch(file, "REM\n", tag: tag), store: store)
            #expect(!remErr, "REM failed: \(remText)")
            #expect(!tmp.exists("a.txt"))
            #expect(store.head(path: BuiltinTools.canonicalPath(file)) == nil)
        }

        @Test("find_text records seen lines: matched editable, unmatched rejected")
        func findTextRecordsSeenLines() async throws {
            let tmp = try EditTestDir()
            let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let store = SnapshotStore()
            let args = AllAppTests.argsJSON(["regex": "line5", "path": tmp.path])
            let result = await BuiltinTools.call(
                name: "find_text", arguments: args, callID: "test", group: BuiltinTools.filesystemGroup,
                workdir: Workdir(root: tmp.path, isolated: false), chatFilename: "test.json", snapshotStore: store)
            #expect(!result.isError)
            #expect(result.content.contains("[\(file)#"))
            let tag = HashlineFormat.computeFileHash(content)
            // Editing a non-matched line is rejected (never displayed).
            let (rej, rejErr) = await Self.editWithStore(
                patch(file, "PUT 8.=8:\n+X\n", tag: tag), workdir: Workdir(root: tmp.path, isolated: false),
                store: store)
            #expect(rejErr)
            #expect(rej.contains("8"))
            #expect(rej.contains("never displayed"))
            // Editing a matched line succeeds.
            let (okText, okErr) = await Self.editWithStore(
                patch(file, "PUT 5.=5:\n+Y\n", tag: tag), workdir: Workdir(root: tmp.path, isolated: false),
                store: store)
            #expect(!okErr, "matched-line edit failed: \(okText)")
        }

        @Test("rebuild from history restores the seen-lines guard")
        func rebuildFromHistory() async throws {
            let tmp = try EditTestDir()
            let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            // Build a chat history: assistant issued a read_file, then a
            // tool-role message carries its result.
            let tag = HashlineFormat.computeFileHash(content)
            let readOutput = """
                [\(file)#\(tag)]
                1:line1
                2:line2
                3:line3
                """
            let calls = [ToolCall(id: "call_1", name: "read_file", arguments: "{}")]
            let results = [ToolResult(callID: "call_1", content: readOutput, isError: false)]
            let messages: [ChatMessage] = [
                ChatMessage(role: .assistant, content: "", toolCalls: calls),
                ChatMessage(role: .tool, content: "", toolResults: results),
            ]
            let store = BuiltinTools.rebuildSnapshots(
                from: messages, workdir: Workdir(root: tmp.path, isolated: false))
            // Editing line 2 (seen) succeeds; line 8 (unseen) is rejected.
            let (okText, okErr) = await Self.editWithStore(
                patch(file, "PUT 2.=2:\n+X\n", tag: tag), workdir: Workdir(root: tmp.path, isolated: false),
                store: store)
            #expect(!okErr, "seen-line edit failed: \(okText)")
            // Rewrite the file back for the second edit.
            _ = try tmp.write("a.txt", content: content)
            let (rej, rejErr) = await Self.editWithStore(
                patch(file, "PUT 8.=8:\n+X\n", tag: tag), workdir: Workdir(root: tmp.path, isolated: false),
                store: store)
            #expect(rejErr)
            #expect(rej.contains("8"))
            #expect(rej.contains("were not displayed"))
        }

        @Test("edit records all lines as seen: later edits without re-read succeed")
        func editRecordsAllLinesSeen() async throws {
            let tmp = try EditTestDir()
            let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let file = try tmp.write("a.txt", content: content)
            let store = SnapshotStore()
            _ = await Self.read("a.txt", tmp: tmp, store: store)
            let tag = HashlineFormat.computeFileHash(content)
            // First edit changes line 2.
            let (e1, e1err) = await Self.editWithStore(patch(file, "PUT 2.=2:\n+X\n", tag: tag), store: store)
            #expect(!e1err, "first edit failed: \(e1)")
            let newContent = try tmp.read("a.txt")
            let newTag = HashlineFormat.computeFileHash(newContent)
            // Second edit touches a different line without re-reading; the
            // first edit recorded all lines as seen.
            let (e2, e2err) = await Self.editWithStore(patch(file, "PUT 8.=8:\n+Y\n", tag: newTag), store: store)
            #expect(!e2err, "second edit failed: \(e2)")
            #expect(try tmp.read("a.txt").contains("\nY\n"))
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
            // Replace line 3; the body restates lines 1-2 just above the range.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 3.=3:\n+a\n+b\n+X\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\nb\nX\nd\ne\nf\n")
            #expect(text.contains("dropped 2 leading payload line(s)"))
            #expect(text.contains("just above the range"))
        }

        @Test("one-sided trailing echo: body restates a line below the range")
        func oneSidedTrailingEcho() async throws {
            let tmp = try EditTestDir()
            let content = "a\nb\nc\nd\n"
            let file = try tmp.write("a.txt", content: content)
            let tag = HashlineFormat.computeFileHash(content)
            // Replace line 2; the body restates line 3 just below the range.
            let (text, err) = await AllAppTests.editCall(patch(file, "PUT 2.=2:\n+X\n+c\n", tag: tag))
            #expect(!err, "edit_file failed: \(text)")
            #expect(try tmp.read("a.txt") == "a\nX\nc\nd\n")
            #expect(text.contains("dropped 1 trailing payload line(s)"))
            #expect(text.contains("just below the range"))
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
