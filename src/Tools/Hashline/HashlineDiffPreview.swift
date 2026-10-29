// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Builds the compact, line-numbered preview echoed after a successful
/// `edit_file` or `replace_text` so the model can immediately verify the edit landed. This is
/// the *tool-result* text the model reads; the approval UI keeps the unified
/// format from `DiffBuilder`.
///
/// Added and context rows carry their **post-edit** line number, so a
/// follow-up edit can reuse the numbers directly. Removed lines are printed
/// too, as unnumbered `-:` rows before whatever replaced them: they no longer
/// exist, so they can't be anchors, but they are what makes an off-by-one
/// range visible. The reference leaves them out; we don't, since the model
/// names a range, not its content. Long removed runs keep only their edges.
///
/// Like the reference, what counts as added comes from a text diff of the old
/// and new content (the same alignment as the approval diff, see
/// `DiffBuilder.lineOrigins`), not from how the patch was written: a body row
/// that retypes the line it replaces is an unchanged line. The applier's own
/// origins still carry the seen lines through the edit (`HashlinePatcher`).
enum HashlineDiffPreview {

    /// Maximum total lines in the preview before truncation.
    static let maxLines = 200
    /// Maximum UTF-8 bytes in the preview before truncation.
    static let maxBytes = 8_192
    /// Lines of context around each change.
    static let contextLines = 2
    /// A removed run longer than `2 * removedRunEdge + 1` shows only this many
    /// lines at each end.
    static let removedRunEdge = 2
    /// Removed lines are cut at this many characters. They are never anchors,
    /// so a cut one costs nothing but context.
    static let maxRemovedLineLength = 300
    static let removedPrefix = "-:"
    /// Shown after the removed rows when an edit removed every line of the file.
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

    private enum RowKind {
        /// An added or context row: its post-edit line number.
        case line(Int)
        case removed
        case separator
    }

    private struct Row {
        let text: String
        let kind: RowKind
    }

    /// A post-edit line or a removed pre-edit line (0-based), in diff order.
    private enum Item {
        case line(Int)
        case removed(Int)
    }

    /// Produces the numbered preview of an edit. Returns nil when no line
    /// changed (identical text, a bare move, only the final newline changed).
    ///
    /// Changes are shown with context around them; a deletion shows the lines
    /// on both sides of the cut as context.
    static func generate(old: String, new: String) -> Preview? {
        if old == new { return nil }
        let oldLines = old.isEmpty ? [] : HashlineFormat.splitAddressableFileLines(old)
        let lines = new.isEmpty ? [] : HashlineFormat.splitAddressableFileLines(new)
        // One entry per line of `new`: the pre-edit line it is, or nil when added.
        let origins = DiffBuilder.lineOrigins(old: oldLines, new: lines)
        let added = origins.filter { $0 == nil }.count
        let removed = oldLines.count - (origins.count - added)
        if added == 0, removed == 0 { return nil }

        let items = diffItems(origins: origins, oldCount: oldLines.count)

        var visible = [Bool](repeating: false, count: lines.count)
        func show(_ range: ClosedRange<Int>) {
            let lower = max(0, range.lowerBound)
            let upper = min(lines.count - 1, range.upperBound)
            guard lower <= upper else { return }
            for index in lower...upper { visible[index] = true }
        }
        // `position` is the post-edit line a removed item sits before.
        var position = 0
        for item in items {
            switch item {
            case .line(let index):
                if origins[index] == nil { show((index - contextLines)...(index + contextLines)) }
                position = index + 1
            case .removed:
                show((position - contextLines)...(position + contextLines - 1))
            }
        }

        var rows: [Row] = []
        var lastLine: Int?
        var removedRun: [Int] = []
        func flushRemoved() {
            rows += removedRows(removedRun, oldLines: oldLines)
            removedRun = []
        }
        for item in items {
            switch item {
            case .removed(let oldIndex):
                removedRun.append(oldIndex)
            case .line(let index):
                flushRemoved()
                guard visible[index] else { continue }
                if let lastLine, index > lastLine + 1 { rows.append(Row(text: "", kind: .separator)) }
                let marker = origins[index] == nil ? "+" : " "
                rows.append(Row(text: "\(marker)\(index + 1):\(lines[index])", kind: .line(index + 1)))
                lastLine = index
            }
        }
        flushRemoved()
        if lines.isEmpty { rows.append(Row(text: emptyFileNotice, kind: .removed)) }

        let (text, shownLines) = truncate(rows)
        return Preview(text: text, shownLines: shownLines, added: added, removed: removed)
    }

    /// Walks the alignment in diff order: the pre-edit lines removed before a
    /// kept line come first, then the lines added there, then the kept line.
    private static func diffItems(origins: [Int?], oldCount: Int) -> [Item] {
        var items: [Item] = []
        var nextOld = 0
        var pendingAdded: [Int] = []
        func flush(upTo oldIndex: Int) {
            if nextOld < oldIndex { items += (nextOld..<oldIndex).map { Item.removed($0) } }
            items += pendingAdded.map { Item.line($0) }
            pendingAdded = []
        }
        for (index, origin) in origins.enumerated() {
            guard let origin else {
                pendingAdded.append(index)
                continue
            }
            flush(upTo: origin - 1)
            items.append(.line(index))
            nextOld = origin
        }
        flush(upTo: oldCount)
        return items
    }

    private static func removedRows(_ run: [Int], oldLines: [String]) -> [Row] {
        func row(_ oldIndex: Int) -> Row {
            var text = oldLines[oldIndex]
            if text.count > maxRemovedLineLength { text = String(text.prefix(maxRemovedLineLength)) + "…" }
            return Row(text: removedPrefix + text, kind: .removed)
        }
        guard run.count > removedRunEdge * 2 + 1 else { return run.map(row) }
        let hidden = run.count - removedRunEdge * 2
        return run.prefix(removedRunEdge).map(row)
            + [Row(text: "-… (\(hidden) more removed)", kind: .removed)]
            + run.suffix(removedRunEdge).map(row)
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
            while let last = kept.last, case .separator = last.kind { kept.removeLast() }
        }
        var text = kept.map(\.text).joined(separator: "\n")
        if truncated {
            text += (kept.isEmpty ? "" : "\n") + "... (diff preview truncated)"
        }
        let shown = kept.compactMap { row -> Int? in
            if case .line(let number) = row.kind { return number }
            return nil
        }
        return (text, LineSet(shown))
    }
}
