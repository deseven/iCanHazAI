// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Errors from the hashline parser.
enum HashlineParseError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let msg): return msg
        }
    }
}

/// Token-driven state machine that turns a stream of `Token`s into a
/// flat list of `Edit`s. Sits between the `HashlineTokenizer` and the
/// `HashlineApplier`.
final class HashlineParser {

    // MARK: - Warnings & messages

    private static let bareBodyAutoPipedWarning =
        "Auto-prefixed bare body row(s) with `+`. Body rows must be `+TEXT` literal lines."
    private static let bareRangeAutoPutWarning =
        "Recovered a bare `N.=M:` header as `PUT N.=M:`. Prefix replacement ranges with `PUT`."
    private static let snapshotRowsAutoPutWarning =
        "Recovered top-level `N:TEXT` snapshot row(s) as single-line `PUT N.=N:` replacements. Use explicit `PUT` headers for reliable edits."
    private static let emptyPutAutoCutWarning =
        "Empty `PUT` bodies are deprecated and will be rejected in a future version; use `CUT N.=M` for bodyless deletes. (For now the empty body was interpreted as deletion.)"
    private static let cutColonIgnoredWarning =
        "Ignored a trailing `:` on bodyless `CUT`. Prefer `CUT N.=M` without a colon."
    private static let diffOldRowsIgnoredWarning =
        "Ignored unified-diff `-old` row(s); the range already removes old content, so only `+new` rows were kept."
    private static let minusBulletAutoPipedWarning =
        "Auto-prefixed bare `- ` bullet row(s) as literal content. `-` rows never remove lines — the range does that; always prefix literal body rows with `+`: `+- item`."
    private static let minusRowRejected =
        "`-` rows are not valid; the range already names the lines being changed. For Markdown bullets or other literal `-` lines, prefix the literal row with `+`: `+- item`."
    private static let cutTakesNoBody = "`CUT` takes no body rows."
    private static let remTakesNoBody = "`REM` deletes the whole file and cannot be combined with line ops."
    private static let moveTakesNoBody = "file-level op already set; no body rows allowed."
    private static let colonlessPutTakesNoBody =
        "bodyless `PUT` without `:` takes no body. Add `:` and body rows for an insert, or use `CUT` for deletion."
    private static let colonlessSpanPut =
        "`PUT N.=M` without `:` and without body is ambiguous. Add `:` and body rows, or use `CUT N.=M`."
    private static let emptyInsert = "insert `PUT` header requires body rows."
    private static let readMetadataIgnoredWarning =
        "Ignored copied read-output elision row(s). Re-read elided ranges before editing them."

    // MARK: - State

    private struct Pending {
        var target: BlockTarget
        var lineNum: Int
        var payloads: [PayloadRow]
        var hadColon: Bool
        var deferredBlanks: [PayloadRow]
    }

    private struct PayloadRow {
        var text: String
        var lineNum: Int
        var bare: Bool
        var minus: Bool
    }

    private struct PendingComment {
        let lineNum: Int
        let text: String
    }

    private var edits: [Edit] = []
    private var warnings: [String] = []
    private var editIndex = 0
    private var pending: Pending?
    private var fileOp: FileOp?
    private var terminated = false
    private var skippableComments: [PendingComment] = []
    private var recoveredSnapshotLines: Set<Int> = []
    private var pendingError: Error?

    // MARK: - Public API

    func feed(_ token: Token) throws {
        if terminated { return }
        switch token {
        case .envelopeBegin:
            consumePendingSkippableComments()
            return
        case .envelopeEnd:
            consumePendingSkippableComments()
            terminated = true
            return
        case .header:
            consumePendingSkippableComments()
            flushPending()
            return
        case .blank(let lineNum):
            consumePendingSkippableComments()
            handleBlank("", lineNum: lineNum)
            return
        case .payloadLiteral(let lineNum, let text):
            consumePendingSkippableComments()
            try handleLiteralPayload(text, lineNum: lineNum)
            return
        case .raw(let lineNum, let text):
            if pending == nil, isSkippableCommentLine(text) {
                skippableComments.append(PendingComment(lineNum: lineNum, text: text))
                return
            }
            consumePendingSkippableComments()
            try handleRaw(text, lineNum: lineNum)
            return
        case .opBlock(let lineNum, let target, let hadColon):
            discardPendingSkippableComments()
            try handleOpBlock(target: target, lineNum: lineNum, hadColon: hadColon)
            return
        }
    }

    struct ParseResult {
        let edits: [Edit]
        let fileOp: FileOp?
        let warnings: [String]
    }

    func end() throws -> ParseResult {
        consumePendingSkippableComments()
        flushPending()
        if let err = pendingError { throw err }
        try validateFileOp()
        return ParseResult(edits: edits, fileOp: fileOp, warnings: warnings)
    }

    func reset() {
        edits = []
        warnings = []
        editIndex = 0
        pending = nil
        fileOp = nil
        skippableComments = []
        terminated = false
        recoveredSnapshotLines = []
        pendingError = nil
    }

    // MARK: - Internal

    private func discardPendingSkippableComments() {
        skippableComments = []
    }

    private func consumePendingSkippableComments() {
        guard !skippableComments.isEmpty else { return }
        for comment in skippableComments {
            try? handleRaw(comment.text, lineNum: comment.lineNum)
        }
        skippableComments = []
    }

    private func isSkippableCommentLine(_ line: String) -> Bool {
        line.hasPrefix("#")
    }

    private func handleOpBlock(target: BlockTarget, lineNum: Int, hadColon: Bool) throws {
        if case .replace(let range) = target {
            try validateRange(range, lineNum: lineNum, op: "replace")
        }
        if case .cut(let range) = target {
            try validateRange(range, lineNum: lineNum, op: "cut")
        }
        switch target {
        case .rem:
            flushPending()
            try setFileOp(.rem, lineNum: lineNum)
            return
        case .move(let dest):
            flushPending()
            try setFileOp(.move(dest), lineNum: lineNum)
            return
        default:
            flushPending()
            pending = Pending(
                target: target,
                lineNum: lineNum,
                payloads: [],
                hadColon: hadColon,
                deferredBlanks: []
            )
        }
    }

    private func setFileOp(_ op: FileOp, lineNum: Int) throws {
        guard fileOp == nil else {
            throw HashlineParseError.message("line \(lineNum): only one file-level op (`REM` or `MV`) per section.")
        }
        if case .rem = op, !edits.isEmpty {
            throw HashlineParseError.message("line \(lineNum): \(Self.remTakesNoBody)")
        }
        fileOp = op
    }

    private func validateFileOp() throws {
        guard case .rem = fileOp else { return }
        if !edits.isEmpty {
            throw HashlineParseError.message("`REM` deletes the whole file and cannot be combined with line ops.")
        }
    }

    private func validateRange(_ range: ParsedRange, lineNum: Int, op: String) throws {
        guard range.start.line >= 1, range.end.line >= 1 else {
            throw HashlineParseError.message("line \(lineNum): \(op) range endpoints must be positive integers.")
        }
        guard range.end.line >= range.start.line else {
            throw HashlineParseError.message(
                "line \(lineNum): Invalid absolute range: start \(range.start.line), end \(range.end.line). The value after `\(HashlineFormat.rangeSep)` is an absolute source line, not a line count. For one line use `PUT \(range.start.line):`."
            )
        }
        let span = range.end.line - range.start.line + 1
        guard span <= 100_000 else {
            throw HashlineParseError.message(
                "line \(lineNum): \(op) range spans \(span) lines; the maximum is 100000. Split it into smaller hunks.")
        }
    }

    private func bodylessTargetMessage(_ target: BlockTarget, _ hadColon: Bool) -> String? {
        switch target {
        case .replace:
            return nil
        case .cut:
            return Self.cutTakesNoBody
        case .rem, .move:
            return nil
        case .bof, .eof, .insertBefore, .insertAfter:
            if !hadColon { return Self.colonlessPutTakesNoBody }
            return nil
        }
    }

    private func handleLiteralPayload(_ text: String, lineNum: Int) throws {
        guard var p = pending else {
            if fileOp != nil {
                throw HashlineParseError.message("line \(lineNum): \(Self.moveTakesNoBody)")
            }
            throw HashlineParseError.message(
                "line \(lineNum): payload line has no preceding hunk header. Got `+\(text)`.")
        }
        if let msg = bodylessTargetMessage(p.target, p.hadColon) {
            throw HashlineParseError.message("line \(lineNum): \(msg)")
        }
        commitDeferredBlanks(&p)
        if HashlineTokenizer.isHunkHeaderText(text) {
            addWarning(
                "line \(lineNum): body row `+\(text)` is itself a valid hunk header, so it was inserted into the file as literal text rather than executed."
            )
        }
        p.payloads.append(PayloadRow(text: text, lineNum: lineNum, bare: false, minus: false))
        pending = p
    }

    private func handleRaw(_ text: String, lineNum: Int) throws {
        if pending == nil, HashlineFormat.isReadMetadataLine(text) {
            addWarning(Self.readMetadataIgnoredWarning)
            return
        }
        if let contamination = detectApplyPatchContamination(text) {
            throw HashlineParseError.message("line \(lineNum): \(contamination)")
        }
        if fileOp != nil {
            throw HashlineParseError.message("line \(lineNum): \(Self.moveTakesNoBody)")
        }
        if var p = pending {
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                handleBlank(text, lineNum: lineNum)
                return
            }
            if let msg = bodylessTargetMessage(p.target, p.hadColon) {
                throw HashlineParseError.message("line \(lineNum): \(msg)")
            }
            var row = PayloadRow(text: text, lineNum: lineNum, bare: true, minus: false)
            if text.first == "-" {
                row.minus = true
            } else {
                addWarning(Self.bareBodyAutoPipedWarning)
            }
            commitDeferredBlanks(&p)
            p.payloads.append(row)
            pending = p
            return
        }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return
        }
        if let bareRange = parseTopLevelBareRangeHeader(text) {
            try validateRange(bareRange, lineNum: lineNum, op: "replace")
            pending = Pending(
                target: .replace(bareRange),
                lineNum: lineNum,
                payloads: [],
                hadColon: true,
                deferredBlanks: []
            )
            addWarning(Self.bareRangeAutoPutWarning)
            return
        }
        if let snapshotRow = parseTopLevelSnapshotRow(text) {
            if recoveredSnapshotLines.contains(snapshotRow.line) {
                throw HashlineParseError.message(
                    "line \(lineNum): two or more pasted `\(snapshotRow.line):TEXT` read-output rows name line \(snapshotRow.line). Write the hunk explicitly."
                )
            }
            recoveredSnapshotLines.insert(snapshotRow.line)
            let range = ParsedRange(start: Anchor(line: snapshotRow.line), end: Anchor(line: snapshotRow.line))
            try validateRange(range, lineNum: lineNum, op: "replace")
            pushInsert(
                cursor: .beforeAnchor(Anchor(line: snapshotRow.line)),
                text: snapshotRow.text,
                lineNum: lineNum,
                mode: .replacement
            )
            pushDeleteRange(range, lineNum: lineNum)
            addWarning(Self.snapshotRowsAutoPutWarning)
            return
        }
        throw HashlineParseError.message(
            "line \(lineNum): payload line has no preceding hunk header. Use `PUT N.=M:`, `CUT N.=M`, or `PUT <N:`/`PUT >N:` above the body. Got \(text)."
        )
    }

    private func handleBlank(_ text: String, lineNum: Int) {
        guard var p = pending else { return }
        if bodylessTargetMessage(p.target, p.hadColon) != nil { return }
        if p.payloads.isEmpty { return }
        p.deferredBlanks.append(PayloadRow(text: text, lineNum: lineNum, bare: true, minus: false))
        pending = p
    }

    private func commitDeferredBlanks(_ pending: inout Pending) {
        guard !pending.deferredBlanks.isEmpty else { return }
        addWarning(Self.bareBodyAutoPipedWarning)
        pending.payloads.append(contentsOf: pending.deferredBlanks)
        pending.deferredBlanks = []
    }

    // MARK: - Minus row resolution

    private static let mdBulletRowRegex = try! NSRegularExpression(
        pattern: #"^\s*- \S"#
    )

    private func resolveMinusRows(_ payloads: inout [PayloadRow]) throws {
        var firstMinus: PayloadRow?
        var allBulletShaped = true
        var hasExplicit = false
        var hasExplicitBullet = false

        for row in payloads {
            if row.minus {
                if firstMinus == nil { firstMinus = row }
                let range = NSRange(row.text.startIndex..., in: row.text)
                if Self.mdBulletRowRegex.firstMatch(in: row.text, range: range) == nil {
                    allBulletShaped = false
                }
            } else if !row.bare {
                hasExplicit = true
                let range = NSRange(row.text.startIndex..., in: row.text)
                if Self.mdBulletRowRegex.firstMatch(in: row.text, range: range) != nil {
                    hasExplicitBullet = true
                }
            }
        }
        guard let first = firstMinus else { return }
        if allBulletShaped, !hasExplicit || hasExplicitBullet {
            addWarning(Self.minusBulletAutoPipedWarning)
            return
        }
        if hasExplicit, !allBulletShaped {
            addWarning(Self.diffOldRowsIgnoredWarning)
            for i in stride(from: payloads.count - 1, through: 0, by: -1) {
                if payloads[i].minus {
                    payloads.remove(at: i)
                }
            }
            return
        }
        throw HashlineParseError.message("line \(first.lineNum): \(Self.minusRowRejected)")
    }

    // MARK: - Bare prefix stripping

    private static let bareLiteralValueRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:"[^"]*"|'[^']*'|[-+]?\d+(?:\.\d+)?)\s*,?\s*$"#
    )

    private func stripBarePrefixesIfUniform(_ payloads: inout [PayloadRow]) {
        var sawBare = false
        var allLiteralValues = true
        for row in payloads {
            if !row.bare || row.text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            sawBare = true
            let stripped = HashlineFormat.stripOneLeadingHashlinePrefix(row.text)
            if stripped == row.text { return }
            let range = NSRange(stripped.startIndex..., in: stripped)
            if Self.bareLiteralValueRegex.firstMatch(in: stripped, range: range) == nil {
                allLiteralValues = false
            }
        }
        guard sawBare, !allLiteralValues else { return }
        for i in payloads.indices {
            if payloads[i].bare, !payloads[i].text.trimmingCharacters(in: .whitespaces).isEmpty {
                payloads[i].text = HashlineFormat.stripOneLeadingHashlinePrefix(payloads[i].text)
            }
        }
    }

    // MARK: - Contamination detection

    private func detectApplyPatchContamination(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("*** Update File:")
            || trimmed.hasPrefix("*** Add File:")
            || trimmed.hasPrefix("*** Delete File:")
            || trimmed.hasPrefix("*** Move to:")
        {
            let preview = trimmed.prefix(48)
            return
                "apply_patch sentinel `\(preview)` is not valid in hashline. File sections start with `[path#HASH]` (no `Update File:` / `Add File:` keyword). Use `PUT N.=M:`, `CUT N.=M`, or `PUT <N:`/`PUT >N:` ops."
        }
        if trimmed.range(of: #"^@@\s+[-+]?\d+,\d+\s+[-+]?\d+,\d+\s+@@"#, options: .regularExpression) != nil {
            return
                "unified-diff hunk header (`@@ -N,M +N,M @@`) is not valid in hashline. Use `PUT N.=M:`, `CUT N.=M`, or `PUT <N:`/`PUT >N:` ops."
        }
        if trimmed.hasPrefix("@@") {
            let preview = trimmed.prefix(48)
            return
                "`@@`-bracketed hunk header `\(preview)` is not valid in hashline. Drop the `@@ ... @@` brackets and write a header such as `PUT N.=M:`."
        }
        if trimmed.range(of: #"^[1-9]\d*\s*$"#, options: .regularExpression) != nil {
            return
                "hunk headers need a verb and both endpoints. Use `PUT \(trimmed).=\(trimmed):` to replace, or `CUT \(trimmed).=\(trimmed)` to delete."
        }
        if trimmed.range(of: #"^([1-9]\d*)\s+(?:[1-9]\d*)\s*:?$"#, options: .regularExpression) != nil {
            return
                "bare range hunk header `\(trimmed)` is not valid. Hunk headers need a verb: use `PUT N.=M:` or `CUT N.=M`."
        }
        return nil
    }

    // MARK: - Top-level snapshot/bare-range recovery

    private static let topLevelSnapshotRowRegex = try! NSRegularExpression(
        pattern: #"^\s*([1-9]\d*)[:|](.*)$"#
    )

    private static let topLevelBareRangeHeaderRegex = try! NSRegularExpression(
        pattern: #"^\s*([1-9]\d*)(?:\s|[-.=…])+([1-9]\d*)\s*:\s*$"#
    )

    private func parseTopLevelSnapshotRow(_ text: String) -> (line: Int, text: String)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = Self.topLevelSnapshotRowRegex.firstMatch(in: text, range: range) else { return nil }
        let lineRange = Range(match.range(at: 1), in: text)!
        let textRange = Range(match.range(at: 2), in: text)!
        guard let line = Int(text[lineRange]) else { return nil }
        return (line: line, text: String(text[textRange]))
    }

    private func parseTopLevelBareRangeHeader(_ text: String) -> ParsedRange? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = Self.topLevelBareRangeHeaderRegex.firstMatch(in: text, range: range) else { return nil }
        let startRange = Range(match.range(at: 1), in: text)!
        let endRange = Range(match.range(at: 2), in: text)!
        guard let start = Int(text[startRange]), let end = Int(text[endRange]) else { return nil }
        return ParsedRange(start: Anchor(line: start), end: Anchor(line: end))
    }

    // MARK: - Flush pending

    private func flushPending() {
        guard var p = pending else { return }
        let target = p.target
        let lineNum = p.lineNum
        var payloads = p.payloads
        let hadColon = p.hadColon
        pending = nil

        do {
            try resolveMinusRows(&payloads)
        } catch {
            pendingError = error
            return
        }
        stripBarePrefixesIfUniform(&payloads)

        switch target {
        case .rem, .move:
            return
        case .replace(let range):
            if payloads.isEmpty {
                if !hadColon {
                    pendingError = HashlineParseError.message("line \(lineNum): \(Self.colonlessSpanPut)")
                    return
                }
                pushDeleteRange(range, lineNum: lineNum)
                addWarning(Self.emptyPutAutoCutWarning)
                return
            }
            let cursor: Cursor = .beforeAnchor(range.start)
            emitPayloadRows(cursor: cursor, payloads: payloads, lineNum: lineNum, mode: .replacement)
            pushDeleteRange(range, lineNum: lineNum)
            return
        case .cut(let range):
            pushDeleteRange(range, lineNum: lineNum)
            return
        case .insertBefore(let anchor):
            let cursor: Cursor = .beforeAnchor(anchor)
            if payloads.isEmpty {
                pendingError = HashlineParseError.message("line \(lineNum): \(Self.emptyInsert)")
                return
            }
            emitPayloadRows(cursor: cursor, payloads: payloads, lineNum: lineNum)
            return
        case .insertAfter(let anchor):
            let cursor: Cursor = .afterAnchor(anchor)
            if payloads.isEmpty {
                pendingError = HashlineParseError.message("line \(lineNum): \(Self.emptyInsert)")
                return
            }
            emitPayloadRows(cursor: cursor, payloads: payloads, lineNum: lineNum)
            return
        case .bof:
            let cursor: Cursor = .bof
            if payloads.isEmpty {
                pendingError = HashlineParseError.message("line \(lineNum): \(Self.emptyInsert)")
                return
            }
            emitPayloadRows(cursor: cursor, payloads: payloads, lineNum: lineNum)
            return
        case .eof:
            let cursor: Cursor = .eof
            if payloads.isEmpty {
                pendingError = HashlineParseError.message("line \(lineNum): \(Self.emptyInsert)")
                return
            }
            emitPayloadRows(cursor: cursor, payloads: payloads, lineNum: lineNum)
            return
        }
    }

    // MARK: - Push helpers

    private func pushInsert(cursor: Cursor, text: String, lineNum: Int, mode: InsertMode? = nil) {
        edits.append(.insert(cursor: cursor, text: text, lineNum: lineNum, index: editIndex, mode: mode))
        editIndex += 1
    }

    private func pushDelete(_ anchor: Anchor, lineNum: Int) {
        edits.append(.delete(anchor: anchor, lineNum: lineNum, index: editIndex))
        editIndex += 1
    }

    private func pushDeleteRange(_ range: ParsedRange, lineNum: Int) {
        for line in range.start.line...range.end.line {
            pushDelete(Anchor(line: line), lineNum: lineNum)
        }
    }

    private func emitPayloadRows(cursor: Cursor, payloads: [PayloadRow], lineNum: Int, mode: InsertMode? = nil) {
        for payload in payloads {
            pushInsert(cursor: cursor, text: payload.text, lineNum: lineNum, mode: mode)
        }
    }

    private func addWarning(_ msg: String) {
        if !warnings.contains(msg) {
            warnings.append(msg)
        }
    }
}

// MARK: - Top-level parse function

extension HashlineParser {

    /// Parse a hashline diff body (the text between section headers) into
    /// edits, fileOp, and warnings.
    static func parsePatch(_ diff: String) throws -> ParseResult {
        let tokenizer = HashlineTokenizer()
        let parser = HashlineParser()
        let tokens = tokenizer.tokenizeAll(diff)
        for token in tokens {
            try parser.feed(token)
        }
        return try parser.end()
    }
}
