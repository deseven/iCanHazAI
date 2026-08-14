// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Pure function that splices a parsed list of edits into file text.
/// No I/O, no session state — the caller provides the file content and
/// the edits, and gets back the post-edit text.
enum HashlineApplier {

    /// Apply a parsed list of edits to a text body. Pure function — no I/O.
    ///
    /// Returns the post-edit text and the first changed line number (1-indexed).
    /// Throws if an anchor is out of bounds.
    static func applyEdits(_ text: String, edits: [Edit]) throws -> ApplyResult {
        if edits.isEmpty {
            return ApplyResult(text: text, firstChangedLine: nil)
        }

        let fileLines = text.components(separatedBy: "\n")

        let dropped = dropTrailingPhantomDeletes(edits, fileLines: fileLines)
        try validateLineBounds(dropped, fileLines: fileLines)

        // Repair replacement boundary echoes before materializing: a replace
        // body that restates unchanged lines bordering the range would silently
        // duplicate them in the output.
        let repaired = HashlineRepair.repairReplacementBoundaries(dropped, fileLines: fileLines)

        let result = materializeEdits(originalLines: fileLines, edits: repaired.edits)
        return ApplyResult(
            text: result.text,
            firstChangedLine: result.firstChangedLine,
            warnings: result.warnings + repaired.warnings
        )
    }

    // MARK: - Validation

    /// Reject anchors outside file bounds.
    private static func validateLineBounds(_ edits: [Edit], fileLines: [String]) throws {
        let maxLine = fileLines.count
        for edit in edits {
            switch edit {
            case .insert(let cursor, _, _, _, _):
                switch cursor {
                case .beforeAnchor(let anchor), .afterAnchor(let anchor):
                    if anchor.line < 1 || anchor.line > maxLine {
                        throw HashlineParseError.message(
                            "Anchor line \(anchor.line) is out of bounds (file has \(maxLine) lines).")
                    }
                case .bof, .eof:
                    break
                }
            case .delete(let anchor, _, _):
                if anchor.line < 1 || anchor.line > maxLine {
                    throw HashlineParseError.message(
                        "Anchor line \(anchor.line) is out of bounds (file has \(maxLine) lines).")
                }
            }
        }
    }

    // MARK: - Phantom delete dropping

    /// Ignore delete of trailing empty line from final newline — it's not
    /// a real line, just an artifact of splitting on `\n`.
    private static func dropTrailingPhantomDeletes(_ edits: [Edit], fileLines: [String]) -> [Edit] {
        // If the file ends with a newline, the split produces a trailing "".
        // A delete of that phantom line is a no-op; drop it silently.
        guard fileLines.last == "" else { return edits }
        let phantomLine = fileLines.count
        return edits.filter { edit in
            if case .delete(let anchor, _, _) = edit {
                return anchor.line != phantomLine
            }
            return true
        }
    }

    // MARK: - Materialization

    private struct IndexedEdit {
        let edit: Edit
        let idx: Int
    }

    /// Splice edits into original lines, applying bottom-up so earlier
    /// indices stay valid.
    private static func materializeEdits(originalLines: [String], edits: [Edit]) -> ApplyResult {
        var fileLines = originalLines
        var firstChangedLine: Int?

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
        let sortedLines = byLine.keys.sorted(by: >)
        for line in sortedLines {
            guard var bucket = byLine[line] else { continue }
            bucket.sort { $0.idx < $1.idx }
            byLine[line] = bucket

            let idx = line - 1
            let currentLine = idx < fileLines.count ? fileLines[idx] : ""
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

            let replacement =
                deleteLine
                ? beforeInsertLines + replacementLines + afterInsertLines
                : beforeInsertLines + replacementLines + [currentLine] + afterInsertLines

            if idx < fileLines.count {
                fileLines.replaceSubrange(idx...idx, with: replacement)
            } else {
                fileLines.append(contentsOf: replacement)
            }

            if firstChangedLine == nil || line < firstChangedLine! {
                firstChangedLine = line
            }
        }

        // Apply bof inserts.
        if !bofLines.isEmpty {
            if fileLines.count == 1 && fileLines[0] == "" {
                fileLines = bofLines
            } else {
                fileLines.insert(contentsOf: bofLines, at: 0)
            }
            if firstChangedLine == nil || 1 < firstChangedLine! {
                firstChangedLine = 1
            }
        }

        // Apply eof inserts.
        if !eofLines.isEmpty {
            if fileLines.count == 1 && fileLines[0] == "" {
                fileLines = eofLines
                if firstChangedLine == nil || 1 < firstChangedLine! {
                    firstChangedLine = 1
                }
            } else {
                let eofLine = fileLines.count + 1
                fileLines.append(contentsOf: eofLines)
                if firstChangedLine == nil || eofLine < firstChangedLine! {
                    firstChangedLine = eofLine
                }
            }
        }

        return ApplyResult(
            text: fileLines.joined(separator: "\n"),
            firstChangedLine: firstChangedLine,
            warnings: []
        )
    }
}
