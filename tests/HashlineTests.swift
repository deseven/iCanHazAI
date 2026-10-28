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

        @Test func splitAddressableFileLinesLoneNewline() {
            #expect(HashlineFormat.splitAddressableFileLines("\n") == [""])
        }

        @Test func splitLinesSplitsCRLF() {
            // "\r\n" is a single Character, so Character-based splitting never
            // sees a line break in it.
            #expect(HashlineFormat.splitLines("a\r\nb\r\n") == ["a\r", "b\r", ""])
            #expect(HashlineFormat.splitLines("") == [""])
        }

        @Test func contentIDIs16HexAndStable() {
            let id = HashlineFormat.computeContentID("hello\nworld\n")
            #expect(id.count == 16)
            #expect(id.allSatisfy { $0.isHexDigit })
            #expect(id == HashlineFormat.computeContentID("hello\nworld\n"))
        }

        @Test func contentIDNormalizesLikeTheTag() {
            #expect(
                HashlineFormat.computeContentID("a  \r\nb\t\n") == HashlineFormat.computeContentID("a\nb\n"))
            #expect(HashlineFormat.computeContentID("a\n") != HashlineFormat.computeContentID("b\n"))
        }
    }

    // MARK: - TextFile

    @Suite struct TextFileTests {

        private let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

        @Test func decodesLF() throws {
            let file = try #require(TextFile.decode(Data("a\nb\n".utf8)))
            #expect(!file.hasBOM)
            #expect(file.lineEnding == .lf)
            #expect(file.text == "a\nb\n")
        }

        @Test func decodesCRLFAndNormalizes() throws {
            let file = try #require(TextFile.decode(Data("a\r\nb\r\n".utf8)))
            #expect(file.lineEnding == .crlf)
            #expect(file.text == "a\nb\n")
        }

        @Test func noLineBreaksIsLF() throws {
            let file = try #require(TextFile.decode(Data("abc".utf8)))
            #expect(file.lineEnding == .lf)
            #expect(file.text == "abc")
        }

        @Test func mixedEndingsMajorityWins() throws {
            let crlfMajority = try #require(TextFile.decode(Data("a\r\nb\r\nc\n".utf8)))
            #expect(crlfMajority.lineEnding == .crlf)
            #expect(crlfMajority.text == "a\nb\nc\n")
            let lfMajority = try #require(TextFile.decode(Data("a\nb\nc\r\n".utf8)))
            #expect(lfMajority.lineEnding == .lf)
            #expect(lfMajority.text == "a\nb\nc\n")
            let tie = try #require(TextFile.decode(Data("a\r\nb\n".utf8)))
            #expect(tie.lineEnding == .lf)
        }

        @Test func detectsBOMOnRawBytes() throws {
            // `String(data:encoding:)` would drop the BOM without a trace.
            let file = try #require(TextFile.decode(Data(bom + Array("x\n".utf8))))
            #expect(file.hasBOM)
            #expect(file.text == "x\n")
        }

        @Test func onlyOneLeadingBOMIsStripped() throws {
            let file = try #require(TextFile.decode(Data(bom + bom + Array("x".utf8))))
            #expect(file.hasBOM)
            #expect(file.text == "\u{FEFF}x")
        }

        @Test func invalidUTF8IsNil() {
            #expect(TextFile.decode(Data([0x61, 0xFF, 0xFE, 0x62])) == nil)
        }

        @Test func emptyData() throws {
            let file = try #require(TextFile.decode(Data()))
            #expect(!file.hasBOM)
            #expect(file.lineEnding == .lf)
            #expect(file.text == "")
            #expect(file.encode("").isEmpty)
        }

        @Test func roundTripsLFCRLFAndBOM() throws {
            let inputs: [Data] = [
                Data("a\nb\n".utf8),
                Data("a\nb".utf8),
                Data("a\r\nb\r\n".utf8),
                Data("a\r\n\r\nb".utf8),
                Data(bom + Array("a\nb\n".utf8)),
                Data(bom + Array("a\r\nb\r\n".utf8)),
                Data("héllo \u{1F680}\r\n世界\r\n".utf8),
            ]
            for data in inputs {
                let file = try #require(TextFile.decode(data))
                #expect(file.encode(file.text) == data, "round trip changed \(Array(data))")
            }
        }

        @Test func encodeRestoresLineEndingForNewText() throws {
            let file = try #require(TextFile.decode(Data(bom + Array("a\r\nb\r\n".utf8))))
            let encoded = file.encode("a\nNEW\nb\n")
            #expect(encoded == Data(bom + Array("a\r\nNEW\r\nb\r\n".utf8)))
        }

        @Test func encodeDoesNotDoubleExistingCR() throws {
            let file = try #require(TextFile.decode(Data("a\r\nb\r\n".utf8)))
            #expect(file.encode("x\r\ny") == Data("x\r\ny".utf8))
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

        @Test func abortIsNotEnvelopeEnd() {
            let token = HashlineTokenizer.tokenize("*** Abort", lineNum: 1)
            #expect(token == .abort(lineNum: 1))
        }

        @Test func hunkHeaderWithTrailingTextIsRaw() {
            #expect(
                HashlineTokenizer.tokenize("PUT 3.=3: foo", lineNum: 1) == .raw(lineNum: 1, text: "PUT 3.=3: foo"))
            #expect(HashlineTokenizer.tokenize("CUT 3.=5 @fn", lineNum: 1) == .raw(lineNum: 1, text: "CUT 3.=5 @fn"))
            #expect(HashlineTokenizer.tokenize("PUT 5*:", lineNum: 1) == .raw(lineNum: 1, text: "PUT 5*:"))
        }

        @Test func hunkHeaderTolerantOfSurroundingWhitespace() {
            let token = HashlineTokenizer.tokenize("  PUT 3.=3:  ", lineNum: 1)
            if case .opBlock(_, .replace(let range), true) = token {
                #expect(range.start.line == 3 && range.end.line == 3)
            } else {
                Issue.record("expected opBlock, got \(token)")
            }
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

        @Test func tokenizeAllCRLF() {
            let tokenizer = HashlineTokenizer()
            let tokens = tokenizer.tokenizeAll("[src/app.swift#A1B2]\r\nPUT 2.=2:\r\n+hello\r\n*** End Patch\r\n")
            #expect(tokens.count == 4)
            #expect(tokens[0] == .header(lineNum: 1, path: "src/app.swift", fileHash: "A1B2"))
            #expect(tokens[2] == .payloadLiteral(lineNum: 3, text: "hello"))
            #expect(tokens[3] == .envelopeEnd(lineNum: 4))
        }

        @Test func feedHandlesCRLFSplitAcrossChunks() {
            let tokenizer = HashlineTokenizer()
            var tokens = tokenizer.feed("PUT 2.=2:\r")
            #expect(tokens.isEmpty)
            tokens += tokenizer.feed("\n+hello\r\n")
            #expect(tokens.count == 2)
            #expect(tokens[1] == .payloadLiteral(lineNum: 2, text: "hello"))
        }

        @Test func splitHashlineLinesNormalizesCRLF() {
            #expect(HashlineTokenizer.splitHashlineLines("a\r\nb\r\n") == ["a", "b"])
            #expect(HashlineTokenizer.splitHashlineLines("a\r\n\r\nb") == ["a", "", "b"])
            #expect(HashlineTokenizer.splitHashlineLines("a\nb\n") == ["a", "b"])
            #expect(HashlineTokenizer.splitHashlineLines("a\n") == ["a"])
            #expect(HashlineTokenizer.splitHashlineLines("\n") == [""])
            #expect(HashlineTokenizer.splitHashlineLines("") == [""])
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

    // MARK: - Applier: phantom line and line origins

    @Suite struct HashlineApplierLinesTests {

        private static func apply(_ text: String, _ diff: String) throws -> ApplyResult {
            try HashlineApplier.applyEdits(text, edits: HashlineParser.parsePatch(diff).edits)
        }

        // MARK: EOF and the phantom line

        @Test func eofInsertLandsBeforeTheFinalNewline() throws {
            let result = try Self.apply("a\nb\n", "PUT >$:\n+tail")
            #expect(result.text == "a\nb\ntail\n")
            #expect(result.firstChangedLine == 3)
        }

        @Test func eofInsertWithoutFinalNewline() throws {
            #expect(try Self.apply("a\nb", "PUT >$:\n+tail").text == "a\nb\ntail")
        }

        @Test func eofInsertOnEmptyFileReplacesThePlaceholder() throws {
            let result = try Self.apply("", "PUT >$:\n+tail")
            #expect(result.text == "tail")
            #expect(result.firstChangedLine == 1)
        }

        @Test func eofInsertOnLoneNewline() throws {
            #expect(try Self.apply("\n", "PUT >$:\n+tail").text == "\ntail\n")
        }

        @Test func insertsAnchoredOnThePhantomLineAreEOFInserts() throws {
            #expect(try Self.apply("a\nb\n", "PUT >3:\n+x").text == "a\nb\nx\n")
            #expect(try Self.apply("a\nb\n", "PUT <3:\n+x").text == "a\nb\nx\n")
        }

        @Test func phantomAnchoredAndExplicitEOFInsertsKeepPatchOrder() throws {
            let result = try Self.apply("x\ny\n", "PUT >$:\n+a\nPUT <3:\n+b")
            #expect(result.text == "x\ny\na\nb\n")
        }

        @Test func insertsAnchoredOnTheEmptyFilesOnlyLineAreEOFInserts() throws {
            #expect(try Self.apply("", "PUT <1:\n+x").text == "x")
            #expect(try Self.apply("", "PUT >1:\n+x").text == "x")
        }

        @Test func rangeEndingOnThePhantomLineKeepsTheFinalNewline() throws {
            #expect(try Self.apply("a\nb\n", "PUT 2.=3:\n+X").text == "a\nX\n")
            #expect(try Self.apply("a\nb\n", "CUT 2.=3").text == "a\n")
        }

        @Test func replacingOnlyThePhantomLineAppendsBeforeTheFinalNewline() throws {
            #expect(try Self.apply("a\nb\n", "PUT 3.=3:\n+X").text == "a\nb\nX\n")
        }

        @Test func replacingTheEmptyFilesOnlyLine() throws {
            #expect(try Self.apply("", "PUT 1.=1:\n+x").text == "x")
        }

        @Test func cuttingEveryLineThenAppendingKeepsTheFinalNewline() throws {
            #expect(try Self.apply("a\n", "CUT 1.=1\nPUT >$:\n+x").text == "x\n")
        }

        @Test func boundsErrorCountsAddressableLines() {
            let cases: [(text: String, diff: String, expected: String)] = [
                ("a\nb\nc\n", "CUT 5.=5", "file has 3 lines"),
                ("a", "CUT 2.=2", "file has 1 line)"),
                ("", "CUT 3.=3", "file has 0 lines"),
            ]
            for c in cases {
                do {
                    _ = try Self.apply(c.text, c.diff)
                    Issue.record("expected a bounds error for \(c.text.debugDescription)")
                } catch {
                    #expect(error.localizedDescription.contains(c.expected), "\(error.localizedDescription)")
                }
            }
        }

        // MARK: Guard anchors

        @Test func anchorLinesExcludeThePhantomLine() throws {
            let section = try HashlineEdit.parse("[f#ABCD]\nCUT 1.=3\n").sections[0]
            #expect(section.anchorLines(in: "a\nb\n") == [1, 2])
            #expect(section.anchorLines(in: "a\nb\nc") == [1, 2, 3])
        }

        // MARK: Origins

        @Test func originsOfAPureInsert() throws {
            let result = try Self.apply("a\nb\nc\n", "PUT >1:\n+x")
            #expect(result.text == "a\nx\nb\nc\n")
            #expect(result.origins == [1, nil, 2, 3])
        }

        @Test func originsOfAPureCut() throws {
            let result = try Self.apply("a\nb\nc\n", "CUT 2.=2")
            #expect(result.text == "a\nc\n")
            #expect(result.origins == [1, 3])
        }

        @Test func originsOfAReplace() throws {
            let result = try Self.apply("a\nb\nc\n", "PUT 2.=2:\n+B1\n+B2")
            #expect(result.text == "a\nB1\nB2\nc\n")
            #expect(result.origins == [1, nil, nil, 3])
        }

        @Test func originsOfBofAndEofInserts() throws {
            let result = try Self.apply("a\nb\n", "PUT <1:\n+h\nPUT >$:\n+t")
            #expect(result.text == "h\na\nb\nt\n")
            #expect(result.origins == [nil, 1, 2, nil])
        }

        @Test func originsOfSeveralHunks() throws {
            let result = try Self.apply("a\nb\nc\nd\ne\nf\n", "PUT 2.=3:\n+X\nCUT 5.=5\nPUT >6:\n+Z")
            #expect(result.text == "a\nX\nd\nf\nZ\n")
            #expect(result.origins == [1, nil, 4, 6, nil])
        }

        @Test func originsSkipPayloadLinesDroppedByARepair() throws {
            let result = try Self.apply("a\nb\nc\nd\ne\n", "PUT 2.=3:\n+a\n+X\n+d")
            #expect(result.text == "a\nX\nd\ne\n")
            #expect(result.origins == [1, nil, 4, 5])
            #expect(result.warnings.count == 1)
        }

        @Test func originsWithoutEditsAreTheIdentity() throws {
            #expect(try HashlineApplier.applyEdits("a\nb\n", edits: []).origins == [1, 2])
            #expect(try HashlineApplier.applyEdits("a\nb", edits: []).origins == [1, 2])
        }

        @Test func emptyResultHasASingleNilOrigin() throws {
            #expect(try Self.apply("a\n", "CUT 1.=1").origins == [nil])
            #expect(try Self.apply("a", "CUT 1.=1").origins == [nil])
        }

        @Test func originsCountMatchesAddressableLines() throws {
            let cases: [(text: String, diff: String)] = [
                ("a\nb\nc\n", "PUT >$:\n+x"),
                ("a\nb\nc", "PUT >$:\n+x"),
                ("a\nb\nc\n", "PUT <1:\n+x\nCUT 3.=3"),
                ("", "PUT >$:\n+x\n+y"),
                ("\n", "PUT >$:\n+x"),
                ("a\nb", "PUT 2.=2:\n+"),
                ("a\nb\n", "PUT 2.=3:\n+X\n+Y"),
                ("a\nb\nc\nd\n", "CUT 1.=2\nPUT >4:\n+z"),
            ]
            for c in cases {
                let result = try Self.apply(c.text, c.diff)
                let addressable = HashlineFormat.splitAddressableFileLines(result.text)
                #expect(
                    result.origins.count == addressable.count,
                    "\(c.text.debugDescription) + \(c.diff.debugDescription) -> \(result.text.debugDescription)")
            }
        }
    }

    // MARK: - Replacement boundary repair

    @Suite struct HashlineRepairTests {

        private static func apply(_ text: String, _ diff: String) throws -> ApplyResult {
            try HashlineApplier.applyEdits(text, edits: HashlineParser.parsePatch(diff).edits)
        }

        private static func rejection(_ text: String, _ diff: String) -> String? {
            do {
                _ = try apply(text, diff)
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        @Test func shiftedRangeIsRejectedWithTheReferenceMessage() {
            let text = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\n"
            let message = Self.rejection(text, "PUT 5.=7:\n+L6\n+L7\n+l8")
            #expect(message?.contains("`PUT 5.=7:` rejected") == true)
            #expect(message?.contains("ends by restating the 1 line(s) just below the range") == true)
        }

        @Test func leadingShiftedRangeIsRejected() {
            let text = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n"
            let message = Self.rejection(text, "PUT 4.=6:\n+l3\n+L4\n+L5")
            #expect(message?.contains("opens by restating the 1 line(s) just above the range") == true)
        }

        @Test func oneSidedEchoNeedsMultiLineRange() throws {
            let result = try Self.apply("a\nb\nc\nd\n", "PUT 2.=2:\n+X\n+c")
            #expect(result.text == "a\nX\nc\nc\nd\n")
            #expect(result.warnings.isEmpty)
        }

        @Test func oneSidedEchoThatIsNotBalanceNeutralIsLeftAlone() throws {
            // The payload is balanced against its range, but the echoed `}` is
            // structure of its own (it closes the payload's `{`), not a restated keeper.
            let result = try Self.apply("f\na\nb\n}\nz\n", "PUT 2.=3:\n+A {\n+}")
            #expect(result.text == "f\nA {\n}\n}\nz\n")
            #expect(result.warnings.isEmpty)
        }

        @Test func duplicatedCloserThatExplainsTheImbalanceIsDropped() throws {
            let result = try Self.apply("f {\n  a\n  b\n}\nz\n", "PUT 2.=3:\n+  A\n+  B\n+}")
            #expect(result.text == "f {\n  A\n  B\n}\nz\n")
            #expect(result.warnings.count == 1)
            #expect(result.warnings[0].contains("delimiter-balance mismatch"))
        }

        @Test func wholePayloadEchoIsLeftAlone() throws {
            let result = try Self.apply("a\nb\nc\n", "PUT 2.=2:\n+a\n+c")
            #expect(result.text == "a\na\nc\nc\n")
            #expect(result.warnings.isEmpty)
        }

        @Test func blankBoundaryLinesAreNotEchoes() throws {
            let result = try Self.apply("a\n\nb\nc\n\nd\n", "PUT 3.=4:\n+\n+X\n+Y\n+")
            #expect(result.text == "a\n\n\nX\nY\n\n\nd\n")
            #expect(result.warnings.isEmpty)
        }
    }

    // MARK: - Delimiter balance

    @Suite struct DelimiterBalanceTests {

        private func balance(_ lines: [String]) -> DelimiterBalance {
            DelimiterBalance(counting: lines)
        }

        @Test func countsEachDelimiterKind() {
            #expect(balance(["foo(a[1]) {"]) == DelimiterBalance(paren: 0, bracket: 0, brace: 1))
            #expect(balance(["}", "])"]) == DelimiterBalance(paren: -1, bracket: -1, brace: -1))
            #expect(balance(["x = 1"]).isZero)
        }

        @Test func skipsLineComments() {
            #expect(balance(["x // ) } ]"]).isZero)
        }

        @Test func skipsStringLiterals() {
            #expect(balance([#"print("}")"#, "call('(')"]).isZero)
            #expect(balance([#"s = "a\"}" + {"#]) == DelimiterBalance(paren: 0, bracket: 0, brace: 1))
        }

        @Test func blockCommentsSpanLines() {
            #expect(balance(["/* {", "} */ {"]) == DelimiterBalance(paren: 0, bracket: 0, brace: 1))
        }

        @Test func templateLiteralsSpanLines() {
            #expect(balance(["`a {", "b }` }"]) == DelimiterBalance(paren: 0, bracket: 0, brace: -1))
        }

        @Test func plainQuotesDoNotSpanLines() {
            #expect(balance(["\"abc {", "}"]) == DelimiterBalance(paren: 0, bracket: 0, brace: -1))
        }

        @Test func arithmetic() {
            let a = DelimiterBalance(paren: 2, bracket: 0, brace: -1)
            let b = DelimiterBalance(paren: 1, bracket: 1, brace: -1)
            #expect(a - b == DelimiterBalance(paren: 1, bracket: -1, brace: 0))
            #expect(a + b == DelimiterBalance(paren: 3, bracket: 1, brace: -2))
            #expect(a.negated == DelimiterBalance(paren: -2, bracket: 0, brace: 1))
            #expect((a - a).isZero)
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
            #expect(result.text == "line1\nline2\nnew last line\n")
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
            #expect(stripped.content == "line1\nline2\nline3")
            #expect(stripped.stripped)
        }

        @Test func stripPastedPrefixesNoPrefix() {
            let content = "line1\nline2\nline3"
            let stripped = HashlineFormat.stripPastedPrefixes(content)
            #expect(stripped.content == "line1\nline2\nline3")
            #expect(!stripped.stripped)
        }

        @Test func stripPastedPrefixesMixed() {
            // Not all lines have prefix — should not strip
            let content = "1:line1\nnoPrefix\n3:line3"
            let stripped = HashlineFormat.stripPastedPrefixes(content)
            #expect(stripped.content == "1:line1\nnoPrefix\n3:line3")
            #expect(!stripped.stripped)
        }

        @Test func stripPastedPrefixesKeepsPortAndTimeLines() {
            // Without a header or a numbered run from line 1 these are real content.
            for content in ["8080:80", "12:00 a\n13:00 b", "5:x\n6:y\n7:z", "1:x\n3:y"] {
                let stripped = HashlineFormat.stripPastedPrefixes(content)
                #expect(stripped.content == content, "\(content.debugDescription) was modified")
                #expect(!stripped.stripped)
            }
        }

        @Test func stripPastedPrefixesWithoutHeaderNeedsConsecutiveRunFromOne() {
            let stripped = HashlineFormat.stripPastedPrefixes("1:x\n2:y")
            #expect(stripped.content == "x\ny")
            #expect(stripped.stripped)
        }

        @Test func stripPastedPrefixesHeaderIsEvidenceOnItsOwn() {
            let single = HashlineFormat.stripPastedPrefixes("[f#ABCD]\n8080:80")
            #expect(single.content == "80")
            #expect(single.stripped)
            // A header with un-numbered content still drops the header.
            let bare = HashlineFormat.stripPastedPrefixes("[f#ABCD]\nhello")
            #expect(bare.content == "hello")
            #expect(bare.stripped)
        }

        @Test func stripPastedPrefixesDropsReadNoticesWhenPasted() {
            let content = "[f#ABCD]\n1:a\n2:b\n... (truncated at 2000 lines)"
            let stripped = HashlineFormat.stripPastedPrefixes(content)
            #expect(stripped.content == "a\nb")
        }

        @Test func stripPastedPrefixesKeepsEllipsisLineWithoutEvidence() {
            let content = "intro\n...\noutro"
            let stripped = HashlineFormat.stripPastedPrefixes(content)
            #expect(stripped.content == content)
            #expect(!stripped.stripped)
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

        @Test func parseAcceptsCRLFPatch() throws {
            let input =
                "*** Begin Patch\r\n[src/app.swift#A1B2]\r\nPUT 1.=1:\r\n+world\r\n+again\r\n*** End Patch\r\n"
            let patch = try HashlineEdit.parse(input)
            #expect(patch.sections.count == 1)
            #expect(patch.sections[0].path == "src/app.swift")
            #expect(patch.sections[0].fileHash == "A1B2")
            let texts = patch.sections[0].edits.compactMap { edit -> String? in
                if case .insert(_, let text, _, _, _) = edit { return text }
                return nil
            }
            #expect(texts == ["world", "again"])
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

    // MARK: - Strict parsing

    @Suite struct HashlineStrictParsingTests {

        private static func failure(_ body: () throws -> Void) -> String? {
            do {
                try body()
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        private static func parseFailure(_ diff: String) -> String? {
            failure { _ = try HashlineParser.parsePatch(diff) }
        }

        private static func patchFailure(_ input: String) -> String? {
            failure { _ = try HashlineEdit.parse(input) }
        }

        // MARK: Hunk headers

        @Test func textAfterColonIsRejected() {
            let message = Self.parseFailure("PUT 3.=3: foo")
            #expect(message?.contains("text after `:`") == true, "\(message ?? "parsed")")
        }

        @Test func textAfterColonInsideHunkIsRejected() {
            let message = Self.parseFailure("PUT 1.=1:\n+a\nPUT 3.=3: foo")
            #expect(message?.contains("line 3") == true, "\(message ?? "parsed")")
            #expect(message?.contains("text after `:`") == true)
        }

        @Test func textAfterColonIsNeverAnImplicitCut() {
            // Used to parse as an empty body and delete line 3.
            #expect(Self.parseFailure("PUT 3.=3: foo") != nil)
            #expect(Self.parseFailure("CUT 3.=3: foo") != nil)
        }

        @Test func trailingTextWithoutColonIsRejected() {
            let message = Self.parseFailure("PUT 5 items")
            #expect(message?.contains("unexpected text `items`") == true, "\(message ?? "parsed")")
        }

        @Test func blockAndRegisterSyntaxIsRejected() {
            for diff in ["PUT 5*:", "CUT 5.=9 @fn", "PUT >20 @fn", "PUT >5*:", "CUT 5*"] {
                let message = Self.parseFailure(diff)
                #expect(message?.contains("not supported") == true, "\(diff): \(message ?? "parsed")")
            }
        }

        @Test func starAfterColonIsBodyTextNotBlockSyntax() {
            let message = Self.parseFailure("PUT 3.=3: *bold*")
            #expect(message?.contains("text after `:`") == true, "\(message ?? "parsed")")
        }

        @Test func literalBodyRowThatLooksLikeHeaderWithTextStillInserts() throws {
            let result = try HashlineParser.parsePatch("PUT 1.=1:\n+PUT 3.=3: foo")
            guard case .insert(_, let text, _, _, _) = result.edits[0] else {
                Issue.record("expected insert")
                return
            }
            #expect(text == "PUT 3.=3: foo")
        }

        @Test func firstPendingErrorWins() {
            let message = Self.parseFailure("PUT <3:\nPUT <5:\n+x\nPUT >7:")
            #expect(message?.contains("line 1") == true, "\(message ?? "parsed")")
        }

        // MARK: Section headers

        @Test func malformedHeaderMidPatchIsRejected() {
            let input = "[a.txt#ABCD]\nPUT 1.=1:\n+x\n[b.txt#12G4]\nPUT 1.=1:\n+y"
            let message = Self.patchFailure(input)
            #expect(message?.contains("Input header must be") == true, "\(message ?? "parsed")")
            #expect(message?.contains("[b.txt#12G4]") == true)
        }

        @Test func shortAndLongTagsAreRejected() {
            for header in ["[a.txt#ABC]", "[a.txt#ABCDE]", "[a.txt#ABCD:42]"] {
                let message = Self.patchFailure("\(header)\nPUT 1.=1:\n+x")
                #expect(message?.contains("Input header must be") == true, "\(header): \(message ?? "parsed")")
            }
        }

        @Test func opsBeforeFirstHeaderAreRejected() {
            let message = Self.patchFailure("PUT 1.=1:\n+x\n[a.txt#ABCD]\nPUT 1.=1:\n+y")
            #expect(message?.contains("must begin with") == true, "\(message ?? "parsed")")
            #expect(message?.contains("PUT 1.=1:") == true)
        }

        @Test func proseBeforeFirstHeaderIsRejected() {
            let message = Self.patchFailure("Here is the patch:\n[a.txt#ABCD]\nPUT 1.=1:\n+y")
            #expect(message?.contains("must begin with") == true, "\(message ?? "parsed")")
        }

        @Test func foreignSentinelBeforeFirstHeaderGetsFocusedError() {
            let message = Self.patchFailure("*** Update File: a.txt\nPUT 1.=1:\n+y")
            #expect(message?.contains("apply_patch sentinel") == true, "\(message ?? "parsed")")
        }

        @Test func blankLinesAndEnvelopeBeforeFirstHeaderAreFine() throws {
            let patch = try HashlineEdit.parse("\n\n*** Begin Patch\n\n[a.txt#ABCD]\nCUT 1.=1\n*** End Patch")
            #expect(patch.sections.count == 1)
        }

        @Test func abortIsAnErrorNotAnEnd() {
            let input = "[a.txt#ABCD]\nPUT 1.=1:\n+x\n*** Abort"
            let message = Self.patchFailure(input)
            #expect(message?.contains("aborted") == true, "\(message ?? "parsed")")
            #expect(Self.parseFailure("PUT 1.=1:\n+x\n*** Abort")?.contains("aborted") == true)
        }

        @Test func contentAfterEndPatchIsIgnored() throws {
            let patch = try HashlineEdit.parse("[a.txt#ABCD]\nCUT 1.=1\n*** End Patch\nnoise")
            #expect(patch.sections.count == 1)
        }

        @Test func allEmptySectionsReportNoOperations() {
            let message = Self.patchFailure("[a.txt#ABCD]\n\n[b.txt#ABCD]\n")
            #expect(message?.contains("no operations") == true, "\(message ?? "parsed")")
            #expect(message?.contains("must begin with") == false)
        }

        @Test func emptySectionAmongOthersIsIgnored() throws {
            let patch = try HashlineEdit.parse("[a.txt#ABCD]\n[b.txt#ABCD]\nCUT 1.=1")
            #expect(patch.sections.map(\.path) == ["b.txt"])
        }

        @Test func parseErrorsNameTheSection() {
            let input = "[a.txt#ABCD]\nCUT 1.=1\n[b.txt#ABCD]\nPUT 1.=1:\n+x\nPUT 3.=3: foo"
            let message = Self.patchFailure(input)
            #expect(message?.hasPrefix("[b.txt] line 3:") == true, "\(message ?? "parsed")")
        }

        @Test func parseErrorsAreEditErrors() {
            #expect(throws: HashlineEditError.self) {
                _ = try HashlineEdit.parse("[a.txt#ABCD]\nPUT 3.=3: foo")
            }
        }

        // MARK: Same-path merge

        @Test func samePathSectionsMergeBeforeParsing() throws {
            let input = "[a.txt#ABCD]\nPUT 1.=1:\n+x\n[b.txt#ABCD]\nCUT 1.=1\n[a.txt#ABCD]\nCUT 5.=5"
            let patch = try HashlineEdit.parse(input)
            #expect(patch.sections.map(\.path) == ["a.txt", "b.txt"])
            #expect(patch.sections[0].edits.count == 3)
        }

        @Test func samePathSectionsWithOverlappingRangesAreRejected() {
            let input = "[a.txt#ABCD]\nPUT 2.=4:\n+x\n[a.txt#ABCD]\nPUT 3.=5:\n+y"
            let message = Self.patchFailure(input)
            #expect(message?.contains("already targeted") == true, "\(message ?? "parsed")")
            #expect(message?.hasPrefix("[a.txt]") == true)
        }

        @Test func samePathSectionsWithConflictingTagsAreRejected() {
            let message = Self.patchFailure("[a.txt#AAAA]\nCUT 1.=1\n[a.txt#BBBB]\nCUT 3.=3")
            #expect(message?.contains("Conflicting") == true, "\(message ?? "parsed")")
        }

        @Test func samePathSectionTakesTheTagFromWhicheverHasOne() throws {
            let patch = try HashlineEdit.parse("[a.txt]\nCUT 1.=1\n[a.txt#ABCD]\nCUT 3.=3")
            #expect(patch.sections.count == 1)
            #expect(patch.sections[0].fileHash == "ABCD")
        }

        @Test func samePathRemWithLineOpsIsRejected() {
            #expect(Self.patchFailure("[a.txt#ABCD]\nREM\n[a.txt#ABCD]\nCUT 1.=1") != nil)
            #expect(Self.patchFailure("[a.txt#ABCD]\nCUT 1.=1\n[a.txt#ABCD]\nREM") != nil)
        }

        @Test func samePathTwoFileOpsAreRejected() {
            let message = Self.patchFailure("[a.txt#ABCD]\nREM\n[a.txt#ABCD]\nREM")
            #expect(message?.contains("only one file-level op") == true, "\(message ?? "parsed")")
        }

        // MARK: Overlapping ranges

        @Test func partiallyOverlappingRangesAreRejected() {
            let message = Self.parseFailure("PUT 2.=4:\n+x\nPUT 3.=5:\n+y")
            #expect(
                message
                    == "line 3: anchor line 3 is already targeted by another hunk on line 1. Issue ONE hunk per range; the body is only the final content.",
                "\(message ?? "parsed")")
        }

        @Test func cutOverlappingPutIsRejected() {
            #expect(Self.parseFailure("PUT 2.=4:\n+x\nCUT 4.=6") != nil)
        }

        @Test func rangeContainedInAnotherIsRejected() {
            #expect(Self.parseFailure("PUT 2.=6:\n+x\nCUT 3.=4") != nil)
            #expect(Self.parseFailure("CUT 3.=4\nPUT 2.=6:\n+x") != nil)
        }

        @Test func repeatedIdenticalRangeIsCoalescedToTheLastHunk() throws {
            let result = try HashlineParser.parsePatch("PUT 2.=3:\n+first\nPUT 2.=3:\n+second")
            let texts = result.edits.compactMap { edit -> String? in
                if case .insert(_, let text, _, _, _) = edit { return text }
                return nil
            }
            #expect(texts == ["second"])
            #expect(result.edits.count == 3)
            #expect(result.warnings.contains(where: { $0.contains("Coalesced") }))
        }

        @Test func repeatedRangeAppliesTheLastBody() throws {
            let result = try HashlineParser.parsePatch("PUT 2.=3:\n+first\nCUT 2.=3")
            let applied = try HashlineApplier.applyEdits("a\nb\nc\nd", edits: result.edits)
            #expect(applied.text == "a\nd")
        }

        @Test func adjacentRangesAreFine() throws {
            let result = try HashlineParser.parsePatch("PUT 2.=3:\n+x\nPUT 4.=5:\n+y")
            #expect(result.edits.count == 6)
            #expect(result.warnings.isEmpty)
        }

        @Test func insertAnchoredAtDeletedLineIsFine() throws {
            let result = try HashlineParser.parsePatch("PUT >5:\n+x\nCUT 5.=5")
            #expect(result.edits.count == 2)
            #expect(result.warnings.isEmpty)
        }

        @Test func overlapIsCheckedWhenTheLaterHunkSharesOneLine() {
            let message = Self.parseFailure("CUT 1.=2\nCUT 2.=3")
            #expect(message?.contains("anchor line 2") == true, "\(message ?? "parsed")")
        }

        // MARK: Small items

        @Test func cutWithColonWarns() throws {
            let result = try HashlineParser.parsePatch("CUT 2.=3:")
            #expect(result.edits.count == 2)
            #expect(result.warnings.contains(where: { $0.contains("trailing `:`") }))
        }

        @Test func cutWithoutColonDoesNotWarn() throws {
            let result = try HashlineParser.parsePatch("CUT 2.=3")
            #expect(result.warnings.isEmpty)
        }

        @Test func indentedCommentBeforeHunkIsSkipped() throws {
            let result = try HashlineParser.parsePatch("  # drop the old call\nCUT 2.=2")
            #expect(result.edits.count == 1)
            #expect(result.warnings.isEmpty)
        }
    }
}
