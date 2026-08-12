import Foundation
import Testing

@testable import iCanHazAI

/// Tests for the hashline core: format, tokenizer, parser, applier, and
/// the high-level [`HashlineEdit`](src/Tools/Hashline/HashlineEdit.swift) entry point.
extension AllAppTests {

    // MARK: - Hash computation

    @Suite struct HashlineHashTests {

        @Test func identicalContentProducesSameTag() {
            let text = "func main() {\n    print(\"hello\")\n}\n"
            let tag1 = HashlineFormat.computeFileHash(text)
            let tag2 = HashlineFormat.computeFileHash(text)
            #expect(tag1 == tag2)
        }

        @Test func differentContentProducesDifferentTag() {
            let text1 = "func main() {\n    print(\"hello\")\n}\n"
            let text2 = "func main() {\n    print(\"world\")\n}\n"
            let tag1 = HashlineFormat.computeFileHash(text1)
            let tag2 = HashlineFormat.computeFileHash(text2)
            #expect(tag1 != tag2)
        }

        @Test func trailingWhitespaceNormalized() {
            let text1 = "line1\nline2\n"
            let text2 = "line1   \nline2\t\n"
            let tag1 = HashlineFormat.computeFileHash(text1)
            let tag2 = HashlineFormat.computeFileHash(text2)
            #expect(tag1 == tag2)
        }

        @Test func crlfNormalized() {
            let text1 = "line1\nline2\n"
            let text2 = "line1\r\nline2\r\n"
            let tag1 = HashlineFormat.computeFileHash(text1)
            let tag2 = HashlineFormat.computeFileHash(text2)
            #expect(tag1 == tag2)
        }

        @Test func tagIs4HexChars() {
            let tag = HashlineFormat.computeFileHash("hello\n")
            #expect(tag.count == 4)
            #expect(tag.allSatisfy { $0.isHexDigit })
        }

        @Test func formatHeader() {
            let header = HashlineFormat.formatHashlineHeader(path: "src/app.swift", fileHash: "A1B2")
            #expect(header == "[src/app.swift#A1B2]")
        }

        @Test func formatNumberedLine() {
            let line = HashlineFormat.formatNumberedLine(lineNumber: 5, content: "print(\"hi\")")
            #expect(line == "5:print(\"hi\")")
        }

        @Test func splitAddressableFileLines() {
            let lines = HashlineFormat.splitAddressableFileLines("a\nb\nc\n")
            #expect(lines == ["a", "b", "c"])
        }

        @Test func splitAddressableFileLinesNoTrailingNewline() {
            let lines = HashlineFormat.splitAddressableFileLines("a\nb\nc")
            #expect(lines == ["a", "b", "c"])
        }

        @Test func splitAddressableFileLinesEmpty() {
            let lines = HashlineFormat.splitAddressableFileLines("")
            #expect(lines == [""])
        }
    }

    // MARK: - Tokenizer

    @Suite struct HashlineTokenizerTests {

        @Test func blankLine() {
            let token = HashlineTokenizer.tokenize("", lineNum: 1)
            #expect(token == .blank(lineNum: 1))
        }

        @Test func envelopeBegin() {
            let token = HashlineTokenizer.tokenize("*** Begin Patch", lineNum: 1)
            #expect(token == .envelopeBegin(lineNum: 1))
        }

        @Test func envelopeEnd() {
            let token = HashlineTokenizer.tokenize("*** End Patch", lineNum: 1)
            #expect(token == .envelopeEnd(lineNum: 1))
        }

        @Test func headerWithHash() {
            let token = HashlineTokenizer.tokenize("[src/app.swift#A1B2]", lineNum: 1)
            #expect(token == .header(lineNum: 1, path: "src/app.swift", fileHash: "A1B2"))
        }

        @Test func headerWithoutHash() {
            let token = HashlineTokenizer.tokenize("[src/app.swift]", lineNum: 1)
            #expect(token == .header(lineNum: 1, path: "src/app.swift", fileHash: nil))
        }

        @Test func opBlockReplaceRange() {
            let token = HashlineTokenizer.tokenize("PUT 5.=9:", lineNum: 1)
            if case .opBlock(let ln, let target, let hadColon) = token {
                #expect(ln == 1)
                #expect(hadColon == true)
                if case .replace(let range) = target {
                    #expect(range.start.line == 5)
                    #expect(range.end.line == 9)
                } else {
                    Issue.record("expected .replace")
                }
            } else {
                Issue.record("expected .opBlock")
            }
        }

        @Test func opBlockInsertBefore() {
            let token = HashlineTokenizer.tokenize("PUT <3:", lineNum: 1)
            if case .opBlock(_, let target, let hadColon) = token {
                #expect(hadColon == true)
                if case .insertBefore(let anchor) = target {
                    #expect(anchor.line == 3)
                } else {
                    Issue.record("expected .insertBefore")
                }
            } else {
                Issue.record("expected .opBlock")
            }
        }

        @Test func opBlockInsertAfter() {
            let token = HashlineTokenizer.tokenize("PUT >7:", lineNum: 1)
            if case .opBlock(_, let target, let hadColon) = token {
                #expect(hadColon == true)
                if case .insertAfter(let anchor) = target {
                    #expect(anchor.line == 7)
                } else {
                    Issue.record("expected .insertAfter")
                }
            } else {
                Issue.record("expected .opBlock")
            }
        }

        @Test func opBlockInsertAtBof() {
            let token = HashlineTokenizer.tokenize("PUT <1:", lineNum: 1)
            if case .opBlock(_, let target, _) = token {
                if case .bof = target {
                    // ok
                } else {
                    Issue.record("expected .bof")
                }
            } else {
                Issue.record("expected .opBlock")
            }
        }

        @Test func opBlockInsertAtEof() {
            let token = HashlineTokenizer.tokenize("PUT >$:", lineNum: 1)
            if case .opBlock(_, let target, _) = token {
                if case .eof = target {
                    // ok
                } else {
                    Issue.record("expected .eof")
                }
            } else {
                Issue.record("expected .opBlock")
            }
        }

        @Test func opBlockCut() {
            let token = HashlineTokenizer.tokenize("CUT 3.=5", lineNum: 1)
            if case .opBlock(_, let target, _) = token {
                if case .cut(let range) = target {
                    #expect(range.start.line == 3)
                    #expect(range.end.line == 5)
                } else {
                    Issue.record("expected .cut")
                }
            } else {
                Issue.record("expected .opBlock")
            }
        }

        @Test func opBlockRem() {
            let token = HashlineTokenizer.tokenize("REM", lineNum: 1)
            if case .opBlock(_, let target, _) = token {
                if case .rem = target {
                    // ok
                } else {
                    Issue.record("expected .rem")
                }
            } else {
                Issue.record("expected .opBlock")
            }
        }

        @Test func opBlockMove() {
            let token = HashlineTokenizer.tokenize("MV dest/path.swift", lineNum: 1)
            if case .opBlock(_, let target, _) = token {
                if case .move(let dest) = target {
                    #expect(dest == "dest/path.swift")
                } else {
                    Issue.record("expected .move")
                }
            } else {
                Issue.record("expected .opBlock")
            }
        }

        @Test func payloadLiteral() {
            let token = HashlineTokenizer.tokenize("+hello world", lineNum: 1)
            #expect(token == .payloadLiteral(lineNum: 1, text: "hello world"))
        }

        @Test func payloadLiteralBlank() {
            let token = HashlineTokenizer.tokenize("+", lineNum: 1)
            #expect(token == .payloadLiteral(lineNum: 1, text: ""))
        }

        @Test func rawLine() {
            let token = HashlineTokenizer.tokenize("some random text", lineNum: 1)
            #expect(token == .raw(lineNum: 1, text: "some random text"))
        }

        @Test func tokenizeAllMultiLine() {
            let tokenizer = HashlineTokenizer()
            let tokens = tokenizer.tokenizeAll("[src/app.swift#A1B2]\nPUT 2.=2:\n+hello\n*** End Patch")
            #expect(tokens.count == 4)
            #expect(tokens[0] == .header(lineNum: 1, path: "src/app.swift", fileHash: "A1B2"))
            #expect(tokens[3] == .envelopeEnd(lineNum: 4))
        }
    }

    // MARK: - Parser

    @Suite struct HashlineParserTests {

        @Test func singleReplaceLine() throws {
            let diff = "PUT 2.=2:\n+hello"
            let result = try HashlineParser.parsePatch(diff)
            // One insert (replacement) + one delete
            #expect(result.edits.count == 2)
            #expect(result.fileOp == nil)
        }

        @Test func multiLineReplace() throws {
            let diff = "PUT 5.=10:\n+line5\n+line6\n+line7"
            let result = try HashlineParser.parsePatch(diff)
            // 3 inserts + 6 deletes (lines 5-10)
            #expect(result.edits.count == 9)
        }

        @Test func insertBefore() throws {
            let diff = "PUT <3:\n+new line"
            let result = try HashlineParser.parsePatch(diff)
            #expect(result.edits.count == 1)
            if case .insert(let cursor, let text, _, _, _) = result.edits[0] {
                if case .beforeAnchor(let anchor) = cursor {
                    #expect(anchor.line == 3)
                } else {
                    Issue.record("expected beforeAnchor")
                }
                #expect(text == "new line")
            } else {
                Issue.record("expected insert")
            }
        }

        @Test func insertAfter() throws {
            let diff = "PUT >7:\n+after line"
            let result = try HashlineParser.parsePatch(diff)
            #expect(result.edits.count == 1)
            if case .insert(let cursor, _, _, _, _) = result.edits[0] {
                if case .afterAnchor(let anchor) = cursor {
                    #expect(anchor.line == 7)
                } else {
                    Issue.record("expected afterAnchor")
                }
            } else {
                Issue.record("expected insert")
            }
        }

        @Test func insertAtBof() throws {
            let diff = "PUT <1:\n+at start"
            let result = try HashlineParser.parsePatch(diff)
            #expect(result.edits.count == 1)
            if case .insert(let cursor, _, _, _, _) = result.edits[0] {
                if case .bof = cursor {
                    // ok
                } else {
                    Issue.record("expected bof")
                }
            } else {
                Issue.record("expected insert")
            }
        }

        @Test func insertAtEof() throws {
            let diff = "PUT >$:\n+at end"
            let result = try HashlineParser.parsePatch(diff)
            #expect(result.edits.count == 1)
            if case .insert(let cursor, _, _, _, _) = result.edits[0] {
                if case .eof = cursor {
                    // ok
                } else {
                    Issue.record("expected eof")
                }
            } else {
                Issue.record("expected insert")
            }
        }

        @Test func cutRange() throws {
            let diff = "CUT 3.=5"
            let result = try HashlineParser.parsePatch(diff)
            // 3 deletes (lines 3, 4, 5)
            #expect(result.edits.count == 3)
            for edit in result.edits {
                if case .delete(let anchor, _, _) = edit {
                    #expect(anchor.line >= 3 && anchor.line <= 5)
                } else {
                    Issue.record("expected delete")
                }
            }
        }

        @Test func remFileOp() throws {
            let diff = "REM"
            let result = try HashlineParser.parsePatch(diff)
            #expect(result.edits.isEmpty)
            #expect(result.fileOp == .rem)
        }

        @Test func moveFileOp() throws {
            let diff = "MV new/path.swift"
            let result = try HashlineParser.parsePatch(diff)
            #expect(result.edits.isEmpty)
            #expect(result.fileOp == .move("new/path.swift"))
        }

        @Test func applyPatchContaminationDetected() {
            let diff = "*** Update File:src/app.swift\nPUT 2.=2:\n+hello"
            #expect(throws: HashlineParseError.self) {
                _ = try HashlineParser.parsePatch(diff)
            }
        }

        @Test func barePrefixStripping() throws {
            // When all bare rows carry N: prefix, it should be stripped
            let diff = "PUT 2.=3:\n2:hello\n3:world"
            let result = try HashlineParser.parsePatch(diff)
            // 2 inserts (replacement) + 2 deletes
            #expect(result.edits.count == 4)
            if case .insert(_, let text, _, _, _) = result.edits[0] {
                #expect(text == "hello")
            } else {
                Issue.record("expected insert")
            }
            if case .insert(_, let text, _, _, _) = result.edits[1] {
                #expect(text == "world")
            } else {
                Issue.record("expected insert")
            }
        }
    }

    // MARK: - Applier

    @Suite struct HashlineApplierTests {

        @Test func singleLineReplace() throws {
            let original = "line1\nline2\nline3"
            let edits: [Edit] = [
                .insert(
                    cursor: .beforeAnchor(Anchor(line: 2)), text: "replaced", lineNum: 1, index: 0, mode: .replacement),
                .delete(anchor: Anchor(line: 2), lineNum: 1, index: 1),
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "line1\nreplaced\nline3")
            #expect(result.firstChangedLine == 2)
        }

        @Test func multiLineReplace() throws {
            let original = "a\nb\nc\nd\ne"
            let edits: [Edit] = [
                .insert(cursor: .beforeAnchor(Anchor(line: 2)), text: "B1", lineNum: 1, index: 0, mode: .replacement),
                .insert(cursor: .beforeAnchor(Anchor(line: 2)), text: "B2", lineNum: 1, index: 1, mode: .replacement),
                .delete(anchor: Anchor(line: 2), lineNum: 1, index: 2),
                .delete(anchor: Anchor(line: 3), lineNum: 1, index: 3),
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "a\nB1\nB2\nd\ne")
        }

        @Test func insertBefore() throws {
            let original = "a\nb\nc"
            let edits: [Edit] = [
                .insert(cursor: .beforeAnchor(Anchor(line: 2)), text: "new", lineNum: 1, index: 0)
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "a\nnew\nb\nc")
        }

        @Test func insertAfter() throws {
            let original = "a\nb\nc"
            let edits: [Edit] = [
                .insert(cursor: .afterAnchor(Anchor(line: 2)), text: "new", lineNum: 1, index: 0)
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "a\nb\nnew\nc")
        }

        @Test func insertAtBof() throws {
            let original = "a\nb\nc"
            let edits: [Edit] = [
                .insert(cursor: .bof, text: "head", lineNum: 1, index: 0)
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "head\na\nb\nc")
            #expect(result.firstChangedLine == 1)
        }

        @Test func insertAtEof() throws {
            let original = "a\nb\nc"
            let edits: [Edit] = [
                .insert(cursor: .eof, text: "tail", lineNum: 1, index: 0)
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "a\nb\nc\ntail")
        }

        @Test func cutRange() throws {
            let original = "a\nb\nc\nd\ne"
            let edits: [Edit] = [
                .delete(anchor: Anchor(line: 2), lineNum: 1, index: 0),
                .delete(anchor: Anchor(line: 3), lineNum: 1, index: 1),
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "a\nd\ne")
        }

        @Test func outOfBoundsAnchor() {
            let original = "a\nb\nc"
            let edits: [Edit] = [
                .delete(anchor: Anchor(line: 99), lineNum: 1, index: 0)
            ]
            #expect(throws: HashlineParseError.self) {
                _ = try HashlineApplier.applyEdits(original, edits: edits)
            }
        }

        @Test func noopEmptyEdits() throws {
            let original = "a\nb\nc"
            let result = try HashlineApplier.applyEdits(original, edits: [])
            #expect(result.text == original)
            #expect(result.firstChangedLine == nil)
        }

        @Test func bottomUpOrdering() throws {
            // Edits at multiple lines should apply correctly because we go bottom-up
            let original = "1\n2\n3\n4\n5"
            let edits: [Edit] = [
                .insert(cursor: .beforeAnchor(Anchor(line: 2)), text: "before2", lineNum: 1, index: 0),
                .insert(cursor: .beforeAnchor(Anchor(line: 4)), text: "before4", lineNum: 1, index: 1),
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "1\nbefore2\n2\n3\nbefore4\n4\n5")
        }
    }

    // MARK: - HashlineEdit (end-to-end)

    @Suite struct HashlineEditTests {

        @Test func parseAndApplySingleEdit() throws {
            let fileContent = "func main() {\n    print(\"hello\")\n}\n"
            let tag = HashlineFormat.computeFileHash(fileContent)
            let input = """
                *** Begin Patch
                [src/app.swift#\(tag)]
                PUT 2.=2:
                +    print("hello world")
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            #expect(patch.sections.count == 1)
            let section = patch.sections[0]
            #expect(section.path == "src/app.swift")
            #expect(section.fileHash == tag)

            let result = try HashlineEdit.applySection(section, fileContent: fileContent)
            #expect(result.text == "func main() {\n    print(\"hello world\")\n}\n")
        }

        @Test func hashMismatchThrows() throws {
            let fileContent = "line1\nline2\n"
            let input = """
                *** Begin Patch
                [src/app.swift#0000]
                PUT 1.=1:
                +changed
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            let section = patch.sections[0]
            #expect(throws: HashlineEditError.self) {
                _ = try HashlineEdit.applySection(section, fileContent: fileContent)
            }
        }

        @Test func missingTagThrows() throws {
            let fileContent = "line1\nline2\n"
            let input = """
                *** Begin Patch
                [src/app.swift]
                PUT 1.=1:
                +changed
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            let section = patch.sections[0]
            #expect(throws: HashlineEditError.self) {
                _ = try HashlineEdit.applySection(section, fileContent: fileContent)
            }
        }

        @Test func multiSectionPatch() throws {
            let content1 = "a\nb\n"
            let content2 = "x\ny\n"
            let tag1 = HashlineFormat.computeFileHash(content1)
            let tag2 = HashlineFormat.computeFileHash(content2)
            let input = """
                *** Begin Patch
                [file1.swift#\(tag1)]
                PUT 1.=1:
                +A
                [file2.swift#\(tag2)]
                PUT 1.=1:
                +X
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            #expect(patch.sections.count == 2)
            let result1 = try HashlineEdit.applySection(patch.sections[0], fileContent: content1)
            #expect(result1.text == "A\nb\n")
            let result2 = try HashlineEdit.applySection(patch.sections[1], fileContent: content2)
            #expect(result2.text == "X\ny\n")
        }

        @Test func noopDetection() throws {
            let fileContent = "a\nb\n"
            let tag = HashlineFormat.computeFileHash(fileContent)
            // Replace line 1 with "a" — same content
            let input = """
                *** Begin Patch
                [src/app.swift#\(tag)]
                PUT 1.=1:
                +a
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            let section = patch.sections[0]
            #expect(throws: HashlineEditError.self) {
                _ = try HashlineEdit.applySection(section, fileContent: fileContent)
            }
        }

        @Test func insertAtHead() throws {
            let fileContent = "line1\nline2\n"
            let tag = HashlineFormat.computeFileHash(fileContent)
            let input = """
                *** Begin Patch
                [src/app.swift#\(tag)]
                PUT <1:
                +new first line
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            let result = try HashlineEdit.applySection(patch.sections[0], fileContent: fileContent)
            #expect(result.text == "new first line\nline1\nline2\n")
        }

        @Test func insertAtTail() throws {
            let fileContent = "line1\nline2\n"
            let tag = HashlineFormat.computeFileHash(fileContent)
            let input = """
                *** Begin Patch
                [src/app.swift#\(tag)]
                PUT >$:
                +new last line
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            let result = try HashlineEdit.applySection(patch.sections[0], fileContent: fileContent)
            #expect(result.text == "line1\nline2\n\nnew last line")
        }

        @Test func cutRange() throws {
            let fileContent = "a\nb\nc\nd\ne\n"
            let tag = HashlineFormat.computeFileHash(fileContent)
            let input = """
                *** Begin Patch
                [src/app.swift#\(tag)]
                CUT 2.=4
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            let result = try HashlineEdit.applySection(patch.sections[0], fileContent: fileContent)
            #expect(result.text == "a\ne\n")
        }

        @Test func remFileOp() throws {
            let fileContent = "a\nb\n"
            let tag = HashlineFormat.computeFileHash(fileContent)
            let input = """
                *** Begin Patch
                [src/app.swift#\(tag)]
                REM
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            let section = patch.sections[0]
            #expect(section.fileOp == .rem)
        }

        @Test func moveFileOp() throws {
            let fileContent = "a\nb\n"
            let tag = HashlineFormat.computeFileHash(fileContent)
            let input = """
                *** Begin Patch
                [src/app.swift#\(tag)]
                MV src/new.swift
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            let section = patch.sections[0]
            #expect(section.fileOp == .move("src/new.swift"))
        }

        @Test func emptyInputThrows() {
            #expect(throws: HashlineEditError.self) {
                _ = try HashlineEdit.parse("")
            }
        }

        @Test func noHeaderThrows() {
            let input = "PUT 1.=1:\n+hello"
            #expect(throws: HashlineEditError.self) {
                _ = try HashlineEdit.parse(input)
            }
        }

        @Test func stripPastedPrefixes() {
            let content = "[src/app.swift#A1B2]\n1:line1\n2:line2\n3:line3"
            let stripped = HashlineFormat.stripPastedPrefixes(content)
            #expect(stripped == "line1\nline2\nline3")
        }

        @Test func stripPastedPrefixesNoPrefix() {
            let content = "line1\nline2\nline3"
            let stripped = HashlineFormat.stripPastedPrefixes(content)
            #expect(stripped == "line1\nline2\nline3")
        }

        @Test func stripPastedPrefixesMixed() {
            // Not all lines have prefix — should not strip
            let content = "1:line1\nnoPrefix\n3:line3"
            let stripped = HashlineFormat.stripPastedPrefixes(content)
            #expect(stripped == "1:line1\nnoPrefix\n3:line3")
        }
    }

    // MARK: - Edge cases

    @Suite struct HashlineEdgeCaseTests {

        @Test func emptyPutBodyAutoCut() throws {
            let diff = "PUT 3.=5:"
            let result = try HashlineParser.parsePatch(diff)
            #expect(result.edits.count == 3)
            #expect(result.warnings.contains(where: { $0.contains("deletion") }))
        }

        @Test func multipleHunksInOneSection() throws {
            let diff = "PUT 1.=1:\n+new1\nPUT 3.=3:\n+new3"
            let result = try HashlineParser.parsePatch(diff)
            #expect(result.edits.count == 4)
        }

        @Test func cutSingleLine() throws {
            let diff = "CUT 3.=3"
            let result = try HashlineParser.parsePatch(diff)
            #expect(result.edits.count == 1)
            if case .delete(let anchor, _, _) = result.edits[0] {
                #expect(anchor.line == 3)
            }
        }

        @Test func contaminationUnifiedDiffHunkHeader() {
            let diff = "@@ -1,3 +1,3 @@\n+hello"
            #expect(throws: HashlineParseError.self) {
                _ = try HashlineParser.parsePatch(diff)
            }
        }

        @Test func contaminationBareAtAt() {
            let diff = "@@ some text\n+hello"
            #expect(throws: HashlineParseError.self) {
                _ = try HashlineParser.parsePatch(diff)
            }
        }

        @Test func minusRowIgnoredWithWarning() throws {
            let diff = "PUT 1.=2:\n-old line\n+new line"
            let result = try HashlineParser.parsePatch(diff)
            #expect(result.edits.count == 3)
            #expect(result.warnings.contains(where: { $0.contains("diff") }))
        }

        @Test func minusBulletAccepted() throws {
            let diff = "PUT 1.=1:\n+- item\n+- another"
            let result = try HashlineParser.parsePatch(diff)
            #expect(result.edits.count == 3)
        }

        @Test func noEnvelopeMarkers() throws {
            let diff = "PUT 1.=1:\n+hello"
            let result = try HashlineParser.parsePatch(diff)
            #expect(result.edits.count == 2)
        }

        @Test func lowercaseHexTagNormalized() {
            let token = HashlineTokenizer.tokenize("[src/app.swift#a1b2]", lineNum: 1)
            #expect(token == .header(lineNum: 1, path: "src/app.swift", fileHash: "A1B2"))
        }

        @Test func headerWithPathContainingSpaces() {
            let token = HashlineTokenizer.tokenize("[src/my app/app.swift#A1B2]", lineNum: 1)
            #expect(token == .header(lineNum: 1, path: "src/my app/app.swift", fileHash: "A1B2"))
        }

        @Test func replaceExpandingLineCount() throws {
            let original = "a\nb\nc"
            let edits: [Edit] = [
                .insert(cursor: .beforeAnchor(Anchor(line: 2)), text: "x", lineNum: 1, index: 0, mode: .replacement),
                .insert(cursor: .beforeAnchor(Anchor(line: 2)), text: "y", lineNum: 1, index: 1, mode: .replacement),
                .insert(cursor: .beforeAnchor(Anchor(line: 2)), text: "z", lineNum: 1, index: 2, mode: .replacement),
                .delete(anchor: Anchor(line: 2), lineNum: 1, index: 3),
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "a\nx\ny\nz\nc")
        }

        @Test func replaceShrinkingLineCount() throws {
            let original = "a\nb\nc\nd\ne"
            let edits: [Edit] = [
                .insert(cursor: .beforeAnchor(Anchor(line: 2)), text: "B", lineNum: 1, index: 0, mode: .replacement),
                .delete(anchor: Anchor(line: 2), lineNum: 1, index: 1),
                .delete(anchor: Anchor(line: 3), lineNum: 1, index: 2),
                .delete(anchor: Anchor(line: 4), lineNum: 1, index: 3),
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "a\nB\ne")
        }

        @Test func multipleEditsOnSameLine() throws {
            let original = "a\nb\nc"
            let edits: [Edit] = [
                .insert(cursor: .beforeAnchor(Anchor(line: 2)), text: "before", lineNum: 1, index: 0),
                .insert(cursor: .afterAnchor(Anchor(line: 2)), text: "after", lineNum: 1, index: 1),
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "a\nbefore\nb\nafter\nc")
        }

        @Test func emptyFileInsertAtBof() throws {
            let original = ""
            let edits: [Edit] = [
                .insert(cursor: .bof, text: "first line", lineNum: 1, index: 0)
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "first line")
        }

        @Test func emptyFileInsertAtEof() throws {
            let original = ""
            let edits: [Edit] = [
                .insert(cursor: .eof, text: "last line", lineNum: 1, index: 0)
            ]
            let result = try HashlineApplier.applyEdits(original, edits: edits)
            #expect(result.text == "last line")
        }

        @Test func e2eReplaceExpanding() throws {
            let fileContent = "one line\n"
            let tag = HashlineFormat.computeFileHash(fileContent)
            let input = """
                *** Begin Patch
                [src/app.swift#\(tag)]
                PUT 1.=1:
                +line one
                +line two
                +line three
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            let result = try HashlineEdit.applySection(patch.sections[0], fileContent: fileContent)
            #expect(result.text == "line one\nline two\nline three\n")
        }

        @Test func e2eInsertAndCutSameSection() throws {
            let fileContent = "a\nb\nc\nd\ne\n"
            let tag = HashlineFormat.computeFileHash(fileContent)
            let input = """
                *** Begin Patch
                [src/app.swift#\(tag)]
                PUT >1:
                +inserted
                CUT 3.=4
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            let result = try HashlineEdit.applySection(patch.sections[0], fileContent: fileContent)
            #expect(result.text == "a\ninserted\nb\ne\n")
        }

        @Test func e2eNewTagAfterEdit() throws {
            let fileContent = "hello\n"
            let tag = HashlineFormat.computeFileHash(fileContent)
            let input = """
                *** Begin Patch
                [src/app.swift#\(tag)]
                PUT 1.=1:
                +world
                *** End Patch
                """
            let patch = try HashlineEdit.parse(input)
            let result = try HashlineEdit.applySection(patch.sections[0], fileContent: fileContent)
            let newTag = HashlineFormat.computeFileHash(result.text)
            #expect(newTag != tag)
        }

        @Test func e2eWithoutEnvelope() throws {
            let fileContent = "a\nb\n"
            let tag = HashlineFormat.computeFileHash(fileContent)
            let input = """
                [src/app.swift#\(tag)]
                PUT 1.=1:
                +A
                """
            let patch = try HashlineEdit.parse(input)
            let result = try HashlineEdit.applySection(patch.sections[0], fileContent: fileContent)
            #expect(result.text == "A\nb\n")
        }
    }
}
