// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Builds the compact, line-numbered preview echoed after a successful
/// `edit_file` so the model can immediately verify the edit landed. This is
/// the *tool-result* text the model reads; the approval UI keeps the unified
/// format from `DiffBuilder`.
///
/// Mirrors the reference `buildCompactDiffPreview`: removed lines are not
/// printed (the model named them, echoing them would only cost context), and
/// every row (added or context) carries its **post-edit** line number, so a
/// follow-up edit can reuse the numbers directly.
///
/// Like the reference, what counts as added comes from a text diff of the old
/// and new content (the same alignment as the approval diff, see
/// `DiffBuilder.lineOrigins`), not from how the patch was written: a body row
/// that retypes the line it replaces is an unchanged line. The applier's own
/// origins still carry the seen lines through the edit (`HashlinePatcher`).
///
/// Unlike the reference, the removals are still reported as a count (see
/// `changeSummary`): a wrong range would otherwise leave no trace in the result.
enum HashlineDiffPreview {

    /// Maximum total lines in the preview before truncation.
    static let maxLines = 200
    /// Maximum UTF-8 bytes in the preview before truncation.
    static let maxBytes = 8_192
    /// Lines of context around each change.
    static let contextLines = 2
    /// Shown instead of rows when an edit removed every line of the file.
    static let emptyFileNotice = "(empty file)"

    /// The preview text plus the post-edit lines it printed in full. Those are
    /// lines the model has now seen, so the caller records them (see
    /// [`FileViewEvent`](src/Tools/Hashline/FileViews.swift)); rows cut by the
    /// truncation caps are not among them. `added`/`removed` count the lines
    /// the text diff added and removed, truncation aside.
    struct Preview: Equatable {
        let text: String
        let shownLines: LineSet
        let added: Int
        let removed: Int
    }

    /// One printed row. `line` is the post-edit line number of an added or
    /// context row; blank separators have none.
    private struct Row {
        let text: String
        let line: Int?
    }

    /// Produces the numbered preview of an edit. Returns nil when no line
    /// changed (identical text, a bare move, only the final newline changed).
    ///
    /// Added lines are shown with context around them. A deletion leaves no
    /// line to print, so the lines on both sides of the cut are shown as
    /// context instead.
    static func generate(old: String, new: String) -> Preview? {
        if old == new { return nil }
        let oldLines = old.isEmpty ? [] : HashlineFormat.splitAddressableFileLines(old)
        if new.isEmpty {
            return Preview(text: emptyFileNotice, shownLines: LineSet(), added: 0, removed: oldLines.count)
        }

        let lines = HashlineFormat.splitAddressableFileLines(new)
        // One entry per line of `new`: the pre-edit line it is, or nil when added.
        let origins = DiffBuilder.lineOrigins(old: oldLines, new: lines)
        let added = origins.filter { $0 == nil }.count
        let removed = oldLines.count - (origins.count - added)
        if added == 0, removed == 0 { return nil }

        var visible = [Bool](repeating: false, count: lines.count)
        func show(_ range: ClosedRange<Int>) {
            let lower = max(0, range.lowerBound)
            let upper = min(lines.count - 1, range.upperBound)
            guard lower <= upper else { return }
            for index in lower...upper { visible[index] = true }
        }

        // `expected` is the pre-edit line a kept line would have if nothing
        // had been deleted before it; a different origin marks a cut there.
        var expected = 1
        for (index, origin) in origins.enumerated() {
            guard let origin else {
                show((index - contextLines)...(index + contextLines))
                continue
            }
            if origin != expected { show((index - contextLines)...(index + contextLines - 1)) }
            expected = origin + 1
        }
        if expected != oldLines.count + 1 {
            show((lines.count - contextLines)...(lines.count - 1))
        }

        var rows: [Row] = []
        for index in lines.indices where visible[index] {
            if index > 0, !visible[index - 1], !rows.isEmpty { rows.append(Row(text: "", line: nil)) }
            let number = index + 1
            let marker = origins[index] == nil ? "+" : " "
            rows.append(Row(text: "\(marker)\(number):\(lines[index])", line: number))
        }
        let (text, shownLines) = truncate(rows)
        return Preview(text: text, shownLines: shownLines, added: added, removed: removed)
    }

    // MARK: - Change counts

    /// `(+3 -1)`, with a zero side left out; nil when nothing was added or removed.
    static func changeSummary(added: Int, removed: Int) -> String? {
        let parts = [added > 0 ? "+\(added)" : nil, removed > 0 ? "-\(removed)" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : "(\(parts.joined(separator: " ")))"
    }

    // MARK: - Truncation

    /// Keeps the rows that fit in `maxLines` / `maxBytes` and appends a marker
    /// when some were dropped. Whole rows only: a row cut in the middle would
    /// be shown but not really seen, and a split multi-byte character would
    /// render as U+FFFD.
    private static func truncate(_ rows: [Row]) -> (text: String, shownLines: LineSet) {
        var kept: [Row] = []
        var bytes = 0
        for row in rows.prefix(maxLines) {
            let cost = row.text.utf8.count + (kept.isEmpty ? 0 : 1)
            if bytes + cost > maxBytes { break }
            kept.append(row)
            bytes += cost
        }
        let truncated = kept.count < rows.count
        if truncated {
            while let last = kept.last, last.line == nil { kept.removeLast() }
        }
        var text = kept.map(\.text).joined(separator: "\n")
        if truncated {
            text += (kept.isEmpty ? "" : "\n") + "... (diff preview truncated)"
        }
        return (text, LineSet(kept.compactMap(\.line)))
    }
}
