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
/// follow-up edit can reuse the numbers directly. What counts as added comes
/// from the applier's `origins`, so the preview, the line numbers the model is
/// told and the lines recorded as authored always agree.
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
    /// truncation caps are not among them.
    struct Preview: Equatable {
        let text: String
        let shownLines: LineSet
    }

    /// One printed row. `line` is the post-edit line number of an added or
    /// context row; blank separators have none.
    private struct Row {
        let text: String
        let line: Int?
    }

    /// Produces the numbered preview of an edit. `origins` is
    /// `ApplyResult.origins` (one entry per addressable line of `new`: the
    /// pre-edit line it is, or nil when the patch wrote it). Returns nil when
    /// the content did not change.
    ///
    /// Added lines are shown with context around them. A deletion leaves no
    /// line to print, so the lines on both sides of the cut are shown as
    /// context instead.
    static func generate(old: String, new: String, origins: [Int?]) -> Preview? {
        if old == new { return nil }
        if new.isEmpty { return Preview(text: emptyFileNotice, shownLines: LineSet()) }

        let lines = HashlineFormat.splitAddressableFileLines(new)
        guard origins.count == lines.count else { return nil }

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
        if expected != HashlineFormat.splitAddressableFileLines(old).count + 1 {
            show((lines.count - contextLines)...(lines.count - 1))
        }

        var rows: [Row] = []
        for index in lines.indices where visible[index] {
            if index > 0, !visible[index - 1], !rows.isEmpty { rows.append(Row(text: "", line: nil)) }
            let number = index + 1
            let marker = origins[index] == nil ? "+" : " "
            rows.append(Row(text: "\(marker)\(number):\(lines[index])", line: number))
        }
        if rows.isEmpty { return nil }
        return truncate(rows)
    }

    // MARK: - Change counts

    /// How many lines an edit wrote and removed, from the applier's `origins`
    /// (see `generate`): lines without an origin are the ones the patch wrote,
    /// pre-edit lines no origin points at are gone.
    static func changeCounts(old: String, new: String, origins: [Int?]) -> (added: Int, removed: Int) {
        let oldCount = old.isEmpty ? 0 : HashlineFormat.splitAddressableFileLines(old).count
        if new.isEmpty { return (0, oldCount) }
        let added = origins.filter { $0 == nil }.count
        return (added, max(0, oldCount - (origins.count - added)))
    }

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
    private static func truncate(_ rows: [Row]) -> Preview {
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
        return Preview(text: text, shownLines: LineSet(kept.compactMap(\.line)))
    }
}
