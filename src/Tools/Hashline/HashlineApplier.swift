// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Pure function that splices a parsed list of edits into file text.
/// No I/O, no session state — the caller provides the file content and
/// the edits, and gets back the post-edit text.
///
/// Terminology: `text.components(separatedBy: "\n")` yields one element per
/// line plus, for newline-terminated text, a trailing `""` — the *phantom*
/// line. It is not content, so edits never delete it, line numbers shown to
/// the model never include it, and inserts anchored on it land at EOF.
enum HashlineApplier {

    /// Apply a parsed list of edits to a text body. Pure function — no I/O.
    ///
    /// Returns the post-edit text, the first changed line number (1-indexed)
    /// and, for every post-edit line, the pre-edit line it came from.
    /// Throws if an anchor is out of bounds or a repair is ambiguous.
    static func applyEdits(_ text: String, edits: [Edit]) throws -> ApplyResult {
        let fileLines = HashlineFormat.splitLines(text)
        let phantom = HashlineFormat.phantomLineNumber(in: fileLines)
        let addressableCount = fileLines.count - (phantom == nil ? 0 : 1)

        if edits.isEmpty {
            return ApplyResult(
                text: text, firstChangedLine: nil, warnings: [],
                origins: (1...addressableCount).map { Optional($0) })
        }

        let dropped = dropPhantomDeletes(edits, phantom: phantom)
        try validateLineBounds(dropped, fileLines: fileLines, addressableCount: addressableCount, text: text)
        let anchored = redirectEOFAnchors(dropped, fileLines: fileLines, phantom: phantom)

        // Repair replacement boundary echoes before materializing: a replace
        // body that restates unchanged lines bordering the range would silently
        // duplicate them in the output. Repairs only see addressable lines.
        let repaired = try HashlineRepair.repairReplacementBoundaries(
            anchored, fileLines: Array(fileLines.prefix(addressableCount)))

        let result = materializeEdits(originalLines: fileLines, edits: repaired.edits)
        return ApplyResult(
            text: result.text,
            firstChangedLine: result.firstChangedLine,
            warnings: repaired.warnings,
            origins: result.origins
        )
    }

    // MARK: - Validation

    /// Reject anchors outside file bounds. The phantom line is in bounds (it
    /// is a legal EOF anchor) but is not counted in the reported line total.
    private static func validateLineBounds(
        _ edits: [Edit], fileLines: [String], addressableCount: Int, text: String
    ) throws {
        let maxLine = fileLines.count
        let lineTotal = text.isEmpty ? 0 : addressableCount
        let noun = lineTotal == 1 ? "line" : "lines"
        func check(_ anchor: Anchor) throws {
            if anchor.line < 1 || anchor.line > maxLine {
                throw HashlineParseError.message(
                    "Anchor line \(anchor.line) is out of bounds (file has \(lineTotal) \(noun)).")
            }
        }
        for edit in edits {
            switch edit {
            case .insert(let cursor, _, _, _, _):
                switch cursor {
                case .beforeAnchor(let anchor), .afterAnchor(let anchor): try check(anchor)
                case .bof, .eof: break
                }
            case .delete(let anchor, _, _):
                try check(anchor)
            }
        }
    }

    // MARK: - Phantom line handling

    /// Deleting the phantom line would only strip the file's final newline, so
    /// such deletes are dropped: an inclusive range ending at EOF then deletes
    /// through the last real line and keeps the newline.
    private static func dropPhantomDeletes(_ edits: [Edit], phantom: Int?) -> [Edit] {
        guard let phantom else { return edits }
        return edits.filter { edit in
            if case .delete(let anchor, _, _) = edit {
                return anchor.line != phantom
            }
            return true
        }
    }

    /// Plain inserts (before/after) anchored on the file's trailing empty
    /// element — the phantom line, or the lone line of an empty file — are EOF
    /// inserts. Replacement inserts are left alone: they belong to a range
    /// that ends on the phantom line, whose delete was already dropped, so
    /// they land before it.
    private static func redirectEOFAnchors(_ edits: [Edit], fileLines: [String], phantom: Int?) -> [Edit] {
        let eofSlot = phantom ?? (fileLines == [""] ? 1 : nil)
        guard let eofSlot else { return edits }
        return edits.map { edit in
            guard case .insert(let cursor, let text, let lineNum, let index, let mode) = edit, mode == nil else {
                return edit
            }
            switch cursor {
            case .beforeAnchor(let anchor), .afterAnchor(let anchor):
                guard anchor.line == eofSlot else { return edit }
                return .insert(cursor: .eof, text: text, lineNum: lineNum, index: index, mode: nil)
            case .bof, .eof:
                return edit
            }
        }
    }

    // MARK: - Materialization

    private struct IndexedEdit {
        let edit: Edit
        let idx: Int
    }

    /// File lines with, in lockstep, the pre-edit line each one came from.
    private struct LineBuffer {
        private(set) var lines: [String]
        private(set) var origins: [Int?]

        init(_ lines: [String]) {
            self.lines = lines
            self.origins = lines.indices.map { Optional($0 + 1) }
        }

        mutating func splice(_ range: Range<Int>, with newLines: [String], origins newOrigins: [Int?]) {
            lines.replaceSubrange(range, with: newLines)
            origins.replaceSubrange(range, with: newOrigins)
        }

        /// Inserts brand-new lines (no origin) before `index`, optionally
        /// replacing `replacing` existing elements there.
        mutating func insert(_ newLines: [String], at index: Int, replacing: Int = 0) {
            splice(
                index..<(index + replacing), with: newLines,
                origins: Array(repeating: nil, count: newLines.count))
        }
    }

    /// Splice edits into original lines, applying bottom-up so earlier
    /// indices stay valid.
    private static func materializeEdits(
        originalLines: [String], edits: [Edit]
    ) -> (text: String, firstChangedLine: Int?, origins: [Int?]) {
        var buffer = LineBuffer(originalLines)
        var firstChangedLine: Int?
        func trackFirstChanged(_ line: Int) {
            if firstChangedLine == nil || line < firstChangedLine! { firstChangedLine = line }
        }

        // Partition edits into bof, eof, and anchor-targeted buckets.
        var bofLines: [String] = []
        var eofLines: [String] = []
        var anchorEdits: [IndexedEdit] = []

        for (idx, edit) in edits.enumerated() {
            switch edit {
            case .insert(let cursor, let text, _, _, _):
                switch cursor {
                case .bof:
                    bofLines.append(text)
                case .eof:
                    eofLines.append(text)
                default:
                    anchorEdits.append(IndexedEdit(edit: edit, idx: idx))
                }
            case .delete:
                anchorEdits.append(IndexedEdit(edit: edit, idx: idx))
            }
        }

        // Bucket anchor edits by line.
        var byLine: [Int: [IndexedEdit]] = [:]
        for ie in anchorEdits {
            let line: Int
            switch ie.edit {
            case .insert(let cursor, _, _, _, _):
                switch cursor {
                case .beforeAnchor(let anchor): line = anchor.line
                case .afterAnchor(let anchor): line = anchor.line
                default: continue
                }
            case .delete(let anchor, _, _): line = anchor.line
            }
            byLine[line, default: []].append(ie)
        }

        // Apply per-line buckets bottom-up (highest line first).
        for line in byLine.keys.sorted(by: >) {
            guard var bucket = byLine[line] else { continue }
            bucket.sort { $0.idx < $1.idx }

            let idx = line - 1
            var beforeInsertLines: [String] = []
            var afterInsertLines: [String] = []
            var replacementLines: [String] = []
            var deleteLine = false

            for ie in bucket {
                switch ie.edit {
                case .insert(let cursor, let text, _, _, let mode):
                    if mode == .replacement {
                        replacementLines.append(text)
                    } else {
                        switch cursor {
                        case .afterAnchor: afterInsertLines.append(text)
                        default: beforeInsertLines.append(text)
                        }
                    }
                case .delete:
                    deleteLine = true
                }
            }

            if beforeInsertLines.isEmpty && replacementLines.isEmpty
                && afterInsertLines.isEmpty && !deleteLine
            {
                continue
            }

            let leadingCount = beforeInsertLines.count + replacementLines.count
            var newLines = beforeInsertLines + replacementLines
            var newOrigins = [Int?](repeating: nil, count: leadingCount)
            if !deleteLine {
                newLines.append(buffer.lines[idx])
                newOrigins.append(buffer.origins[idx])
            }
            newLines += afterInsertLines
            newOrigins += [Int?](repeating: nil, count: afterInsertLines.count)

            buffer.splice(idx..<(idx + 1), with: newLines, origins: newOrigins)
            trackFirstChanged(line)
        }

        // An untouched empty file is a placeholder: BOF/EOF inserts replace its
        // lone `""` element instead of landing beside it.
        func isUntouchedEmptyFile() -> Bool {
            originalLines == [""] && buffer.origins == [1]
        }

        if !bofLines.isEmpty {
            buffer.insert(bofLines, at: 0, replacing: isUntouchedEmptyFile() ? 1 : 0)
            trackFirstChanged(1)
        }

        if !eofLines.isEmpty {
            if isUntouchedEmptyFile() {
                buffer.insert(eofLines, at: 0, replacing: 1)
                trackFirstChanged(1)
            } else {
                // Land before the phantom line, which stays last whenever the
                // original text ended in a newline.
                let hasPhantom = HashlineFormat.phantomLineNumber(in: originalLines) != nil
                let at = buffer.lines.count - (hasPhantom ? 1 : 0)
                buffer.insert(eofLines, at: at)
                trackFirstChanged(at + 1)
            }
        }

        let text = buffer.lines.joined(separator: "\n")
        var origins = buffer.origins
        if HashlineFormat.phantomLineNumber(in: buffer.lines) != nil { origins.removeLast() }
        if text.isEmpty { origins = [nil] }
        return (text, firstChangedLine, origins)
    }
}
