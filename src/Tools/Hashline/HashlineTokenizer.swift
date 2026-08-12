// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Target of an op-block token, parsed from a hunk header line.
enum BlockTarget: Equatable {
    case replace(ParsedRange)
    case cut(ParsedRange)
    case insertBefore(Anchor)
    case insertAfter(Anchor)
    case bof
    case eof
    case rem
    case move(String)
}

/// A classified line from the tokenizer.
enum Token: Equatable {
    case blank(lineNum: Int)
    case envelopeBegin(lineNum: Int)
    case envelopeEnd(lineNum: Int)
    case header(lineNum: Int, path: String, fileHash: String?)
    case opBlock(lineNum: Int, target: BlockTarget, hadColon: Bool)
    case payloadLiteral(lineNum: Int, text: String)
    case raw(lineNum: Int, text: String)
}

/// Stateful, line-oriented classifier for hashline diff text.
///
/// Format shape:
/// ```
/// [path/to/file.ts#1A2B]
/// PUT 5.=7:
/// +literal new line
/// ```
final class HashlineTokenizer {

    // MARK: - Public API

    private var buffer = ""
    private var nextLineNum = 1
    private var closed = false

    func feed(_ chunk: String) -> [Token] {
        if closed { return [] }
        if chunk.isEmpty { return [] }
        buffer += chunk
        return drainCompleteLines()
    }

    func end() -> [Token] {
        if closed { return [] }
        closed = true
        let buf = buffer
        buffer = ""
        if buf.isEmpty { return [] }
        var stop = buf.endIndex
        if stop > buf.startIndex, buf[buf.index(before: stop)] == "\r" {
            stop = buf.index(before: stop)
        }
        return [Self.classifyLine(String(buf[..<stop]), lineNum: nextLineNum)]
    }

    func reset() {
        buffer = ""
        nextLineNum = 1
        closed = false
    }

    func tokenizeAll(_ text: String) -> [Token] {
        reset()
        let first = feed(text)
        let last = end()
        return last.isEmpty ? first : first + last
    }

    static func tokenize(_ line: String, lineNum: Int = 0) -> Token {
        classifyLine(line, lineNum: lineNum)
    }

    static func isOp(_ line: String) -> Bool {
        tryParseHunkHeader(line) != nil
    }

    static func isHeader(_ line: String) -> Bool {
        tryParseHeader(line) != nil
    }

    static func isEnvelopeMarker(_ line: String) -> Bool {
        markerLineEquals(line, HashlineFormat.beginPatch)
            || markerLineEquals(line, HashlineFormat.endPatch)
            || markerLineEquals(line, HashlineFormat.abortMarker)
    }

    // MARK: - Internal line splitting

    private func drainCompleteLines() -> [Token] {
        var tokens: [Token] = []
        let buf = buffer
        var start = buf.startIndex
        var idx = buf.startIndex
        while idx < buf.endIndex {
            if buf[idx] != "\n" {
                idx = buf.index(after: idx)
                continue
            }
            var stop = idx
            if stop > start, buf[buf.index(before: stop)] == "\r" {
                stop = buf.index(before: stop)
            }
            tokens.append(Self.classifyLine(String(buf[start..<stop]), lineNum: nextLineNum))
            nextLineNum += 1
            start = buf.index(after: idx)
            idx = buf.index(after: idx)
        }
        buffer = start < buf.endIndex ? String(buf[start...]) : ""
        return tokens
    }

    // MARK: - Line classification

    /// Split text into lines, normalizing CRLF to LF.
    static func splitHashlineLines(_ text: String) -> [String] {
        if text.isEmpty { return [""] }
        var lines: [String] = []
        var start = text.startIndex
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx] != "\n" {
                idx = text.index(after: idx)
                continue
            }
            var end = idx
            if end > start, text[text.index(before: end)] == "\r" {
                end = text.index(before: end)
            }
            lines.append(String(text[start..<end]))
            start = text.index(after: idx)
            idx = text.index(after: idx)
        }
        if start < text.endIndex {
            var end = text.endIndex
            if end > start, text[text.index(before: end)] == "\r" {
                end = text.index(before: end)
            }
            lines.append(String(text[start..<end]))
        }
        return lines
    }

    static func classifyLine(_ line: String, lineNum: Int) -> Token {
        if line.isEmpty { return .blank(lineNum: lineNum) }
        if markerLineEquals(line, HashlineFormat.beginPatch) { return .envelopeBegin(lineNum: lineNum) }
        if markerLineEquals(line, HashlineFormat.endPatch) { return .envelopeEnd(lineNum: lineNum) }
        if markerLineEquals(line, HashlineFormat.abortMarker) { return .envelopeEnd(lineNum: lineNum) }

        if line.hasPrefix(HashlineFormat.filePrefix) {
            if let header = tryParseHeader(line) {
                return .header(lineNum: lineNum, path: header.path, fileHash: header.fileHash)
            }
        }

        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" })
        let isHunkLead =
            trimmed.hasPrefix(HashlineFormat.putKeyword)
            || trimmed.hasPrefix(HashlineFormat.cutKeyword)
            || trimmed.hasPrefix(HashlineFormat.remKeyword)
            || trimmed.hasPrefix(HashlineFormat.moveKeyword)
        if isHunkLead {
            if let hunk = tryParseHunkHeader(line) {
                return .opBlock(lineNum: lineNum, target: hunk.target, hadColon: hunk.hadColon)
            }
        }

        if line.first == Character(HashlineFormat.payloadReplace) {
            let text = String(line.dropFirst())
            return .payloadLiteral(lineNum: lineNum, text: text)
        }

        return .raw(lineNum: lineNum, text: line)
    }

    // MARK: - Header parsing

    struct ParsedHeader {
        let path: String
        let fileHash: String?
    }

    static func tryParseHeader(_ line: String) -> ParsedHeader? {
        guard line.hasPrefix(HashlineFormat.filePrefix) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefixLen = HashlineFormat.filePrefix.count
        let suffixLen = HashlineFormat.fileSuffix.count
        guard trimmed.count > prefixLen + suffixLen else { return nil }
        guard trimmed.hasSuffix(HashlineFormat.fileSuffix) else { return nil }

        let body = String(trimmed.dropFirst(prefixLen).dropLast(suffixLen))
        guard !body.isEmpty else { return nil }

        var pathEnd = body.endIndex
        var fileHash: String?

        let hashLen = HashlineFormat.fileHashLength
        if body.count >= hashLen + 1 {
            let hashStart = body.index(body.endIndex, offsetBy: -(hashLen + 1))
            if body[hashStart] == "#" {
                let hashContent = String(body[body.index(after: hashStart)...])
                if hashContent.allSatisfy({ $0.isHexDigit && $0.isASCII }) {
                    pathEnd = hashStart
                    fileHash = hashContent.uppercased()
                }
            }
        }

        var i = body.startIndex
        while i < pathEnd {
            if body[i] == "#" { return nil }
            i = body.index(after: i)
        }

        guard pathEnd > body.startIndex else { return nil }
        let path = String(body[..<pathEnd])
        return ParsedHeader(path: path, fileHash: fileHash)
    }

    // MARK: - Hunk header parsing

    struct ParsedHunkHeader {
        let target: BlockTarget
        let hadColon: Bool
    }

    static func tryParseHunkHeader(_ line: String) -> ParsedHunkHeader? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let scan = scanHunkAnchor(trimmed, start: trimmed.startIndex) else { return nil }
        return ParsedHunkHeader(target: scan.target, hadColon: scan.hadColon)
    }

    static func isHunkHeaderText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let isHunkLead =
            trimmed.hasPrefix(HashlineFormat.putKeyword)
            || trimmed.hasPrefix(HashlineFormat.cutKeyword)
            || trimmed.hasPrefix(HashlineFormat.remKeyword)
            || trimmed.hasPrefix(HashlineFormat.moveKeyword)
        return isHunkLead && tryParseHunkHeader(text) != nil
    }

    // MARK: - Scanning helpers

    private struct NumberScan {
        let line: Int
        let nextIndex: String.Index
    }

    private struct RangeScan {
        let range: ParsedRange
        let nextIndex: String.Index
        let hadSeparator: Bool
    }

    private struct TargetScan {
        let target: BlockTarget
        let nextIndex: String.Index
        let hadColon: Bool
    }

    private struct ColonScan {
        let nextIndex: String.Index
        let hadColon: Bool
    }

    private static func isDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }

    private static func isNonZeroDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber && c != "0"
    }

    private static func isHexDigit(_ c: Character) -> Bool {
        c.isHexDigit && c.isASCII
    }

    private static func isWhitespace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\r" || c == "\n"
    }

    private static func skipWhitespace(_ s: String, from index: String.Index, end: String.Index) -> String.Index {
        var i = index
        while i < end, isWhitespace(s[i]) {
            i = s.index(after: i)
        }
        return i
    }

    private static func trimEnd(_ s: String) -> String.Index {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if !isWhitespace(s[prev]) { break }
            end = prev
        }
        return end
    }

    private static func markerLineEquals(_ line: String, _ marker: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == marker
    }

    private static func scanLineNumber(_ s: String, from index: String.Index, end: String.Index) -> NumberScan? {
        guard index < end, isNonZeroDigit(s[index]) else { return nil }
        var lineNumber = 0
        var nextIndex = index
        while nextIndex < end {
            let c = s[nextIndex]
            if !isDigit(c) { break }
            lineNumber = lineNumber * 10 + Int(c.asciiValue! - Character("0").asciiValue!)
            guard lineNumber > 0, lineNumber <= Int.max else { return nil }
            nextIndex = s.index(after: nextIndex)
        }
        return NumberScan(line: lineNumber, nextIndex: nextIndex)
    }

    private static func scanRangeSeparator(_ s: String, from index: String.Index, end: String.Index) -> String.Index? {
        var cursor = index
        var consumed = false
        while cursor < end {
            let c = s[cursor]
            if isWhitespace(c) || c == "-" || c == "." || c == "=" || c == "…" {
                cursor = s.index(after: cursor)
                consumed = true
                continue
            }
            break
        }
        guard consumed, cursor < end, isNonZeroDigit(s[cursor]) else { return nil }
        return cursor
    }

    private static func scanHeaderRange(
        _ s: String,
        from index: String.Index,
        end: String.Index,
        allowSingle: Bool = false
    ) -> RangeScan? {
        let numberStart = skipWhitespace(s, from: index, end: end)
        guard let start = scanLineNumber(s, from: numberStart, end: end) else { return nil }
        guard let afterFirst = scanRangeSeparator(s, from: start.nextIndex, end: end) else {
            if !allowSingle { return nil }
            return RangeScan(
                range: ParsedRange(start: Anchor(line: start.line), end: Anchor(line: start.line)),
                nextIndex: skipWhitespace(s, from: start.nextIndex, end: end),
                hadSeparator: false
            )
        }
        guard let endNumber = scanLineNumber(s, from: afterFirst, end: end) else { return nil }
        return RangeScan(
            range: ParsedRange(start: Anchor(line: start.line), end: Anchor(line: endNumber.line)),
            nextIndex: skipWhitespace(s, from: endNumber.nextIndex, end: end),
            hadSeparator: true
        )
    }

    private static func scanKeyword(_ s: String, from index: String.Index, end: String.Index, keyword: String) -> String
        .Index?
    {
        guard index < end else { return nil }
        let kwEnd = s.index(index, offsetBy: keyword.count, limitedBy: end) ?? end
        let sub = String(s[index..<kwEnd])
        guard sub == keyword else { return nil }
        let next = kwEnd
        if next < end {
            let c = s[next]
            if !isWhitespace(c) && c != Character(HashlineFormat.headerColon) { return nil }
        }
        return next
    }

    private static func consumeOptionalColon(_ s: String, from index: String.Index, end: String.Index) -> ColonScan {
        let cursor = skipWhitespace(s, from: index, end: end)
        if cursor < end, s[cursor] == Character(HashlineFormat.headerColon) {
            let next = s.index(after: cursor)
            return ColonScan(nextIndex: skipWhitespace(s, from: next, end: end), hadColon: true)
        }
        return ColonScan(nextIndex: cursor, hadColon: false)
    }

    private static func scanMoveDest(_ s: String, from index: String.Index, end: String.Index) -> String? {
        let cursor = skipWhitespace(s, from: index, end: end)
        guard cursor < end else { return nil }
        let first = s[cursor]
        if first == "\"" || first == "'" {
            let quote = first
            var next = s.index(after: cursor)
            while next < end {
                let c = s[next]
                if c == "\\" {
                    let skip = s.index(next, offsetBy: 2, limitedBy: end) ?? end
                    next = skip
                    continue
                }
                if c == quote {
                    let after = skipWhitespace(s, from: s.index(after: next), end: end)
                    return after == end ? unquotePath(String(s[cursor...next])) : nil
                }
                next = s.index(after: next)
            }
            return nil
        }
        let raw = String(s[cursor..<end]).trimmingCharacters(in: .whitespaces)
        return unquotePath(raw)
    }

    private static func unquotePath(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if first == "\"" || first == "'", first == last {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func scanPutTarget(_ s: String, from index: String.Index, end: String.Index) -> TargetScan? {
        let cursor = skipWhitespace(s, from: index, end: end)
        guard cursor < end else { return nil }
        let sigil = s[cursor]
        if sigil == Character(HashlineFormat.gapBefore) || sigil == Character(HashlineFormat.gapAfter) {
            let isAfter = sigil == Character(HashlineFormat.gapAfter)
            let probe = skipWhitespace(s, from: s.index(after: cursor), end: end)
            if isAfter, probe < end, s[probe] == Character(HashlineFormat.eofAnchor) {
                return finishTargetScan(s, from: s.index(after: probe), end: end, target: .eof)
            }
            guard let anchor = scanLineNumber(s, from: probe, end: end) else { return nil }
            if isAfter {
                return finishTargetScan(
                    s, from: anchor.nextIndex, end: end,
                    target: .insertAfter(Anchor(line: anchor.line))
                )
            }
            let target: BlockTarget = anchor.line == 1 ? .bof : .insertBefore(Anchor(line: anchor.line))
            return finishTargetScan(s, from: anchor.nextIndex, end: end, target: target)
        }
        guard let range = scanHeaderRange(s, from: cursor, end: end, allowSingle: true) else { return nil }
        return finishTargetScan(s, from: range.nextIndex, end: end, target: .replace(range.range))
    }

    private static func scanCutTarget(_ s: String, from index: String.Index, end: String.Index) -> TargetScan? {
        guard let range = scanHeaderRange(s, from: index, end: end, allowSingle: true) else { return nil }
        return finishTargetScan(s, from: range.nextIndex, end: end, target: .cut(range.range))
    }

    private static func finishTargetScan(
        _ s: String,
        from index: String.Index,
        end: String.Index,
        target: BlockTarget
    ) -> TargetScan {
        let cursor = skipWhitespace(s, from: index, end: end)
        let colon = consumeOptionalColon(s, from: cursor, end: end)
        return TargetScan(target: target, nextIndex: colon.nextIndex, hadColon: colon.hadColon)
    }

    private static func scanHunkAnchor(_ s: String, start: String.Index) -> TargetScan? {
        let end = s.endIndex
        let cursor = skipWhitespace(s, from: start, end: end)

        if let remEnd = scanKeyword(s, from: cursor, end: end, keyword: HashlineFormat.remKeyword) {
            let next = skipWhitespace(s, from: remEnd, end: end)
            guard next == end else { return nil }
            return TargetScan(target: .rem, nextIndex: next, hadColon: false)
        }
        if let moveEnd = scanKeyword(s, from: cursor, end: end, keyword: HashlineFormat.moveKeyword) {
            guard let dest = scanMoveDest(s, from: moveEnd, end: end), !dest.isEmpty else { return nil }
            return TargetScan(target: .move(dest), nextIndex: end, hadColon: false)
        }
        if let putEnd = scanKeyword(s, from: cursor, end: end, keyword: HashlineFormat.putKeyword) {
            return scanPutTarget(s, from: putEnd, end: end)
        }
        if let cutEnd = scanKeyword(s, from: cursor, end: end, keyword: HashlineFormat.cutKeyword) {
            return scanCutTarget(s, from: cutEnd, end: end)
        }
        return nil
    }
}
