// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A line-number anchor (1-indexed).
struct Anchor: Equatable, Hashable {
    let line: Int
}

/// Where an `insert` edit should land relative to existing content.
enum Cursor: Equatable, Hashable {
    case bof
    case eof
    case beforeAnchor(Anchor)
    case afterAnchor(Anchor)
}

/// Tags inserts that are part of a range replacement.
enum InsertMode {
    case replacement
}

/// A single low-level edit produced by the parser and consumed by the applier.
/// Multi-line replacements decompose to one `insert` per replacement line plus
/// one `delete` per consumed line.
enum Edit {
    case insert(cursor: Cursor, text: String, lineNum: Int, index: Int, mode: InsertMode? = nil)
    case delete(anchor: Anchor, lineNum: Int, index: Int)

    var editIndex: Int {
        switch self {
        case .insert(_, _, _, let index, _): return index
        case .delete(_, _, let index): return index
        }
    }

    var sourceLineNum: Int {
        switch self {
        case .insert(_, _, let lineNum, _, _): return lineNum
        case .delete(_, let lineNum, _): return lineNum
        }
    }
}

/// A parsed `A-B` inclusive line range.
struct ParsedRange: Equatable {
    let start: Anchor
    let end: Anchor
}

/// File-level operation parsed from a section body (`REM` / `MV`).
enum FileOp: Equatable {
    case rem
    case move(String)
}

/// Result of applying a parsed set of edits to a text body.
struct ApplyResult {
    let text: String
    let firstChangedLine: Int?
    let warnings: [String]

    init(text: String, firstChangedLine: Int?, warnings: [String] = []) {
        self.text = text
        self.firstChangedLine = firstChangedLine
        self.warnings = warnings
    }
}

/// One per `[path#TAG]` header in a patch.
struct HashlineSection {
    let path: String
    let fileHash: String?
    let edits: [Edit]
    let fileOp: FileOp?
    let warnings: [String]

    /// The 1-indexed file lines this section's edits anchor to: every
    /// `beforeAnchor`/`afterAnchor` insert cursor and every delete anchor.
    /// Used by the seen-lines guard to reject edits targeting lines the model
    /// never displayed.
    var anchorLines: [Int] {
        edits.compactMap { edit in
            switch edit {
            case .insert(let cursor, _, _, _, _):
                switch cursor {
                case .beforeAnchor(let a), .afterAnchor(let a): return a.line
                default: return nil
                }
            case .delete(let a, _, _): return a.line
            }
        }
    }
}

/// The full parsed patch.
struct ParsedPatch {
    let sections: [HashlineSection]
}
