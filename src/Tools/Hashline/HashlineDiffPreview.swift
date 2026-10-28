// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Differ
import Foundation

/// Builds the compact, line-numbered diff echoed after a successful
/// `edit_file` so the model can immediately verify the edit landed. This is
/// the *tool-result* text the model reads; the approval UI keeps the unified
/// format from `DiffBuilder`.
///
/// Mirrors the reference `buildCompactDiffPreview`: removed lines are dropped,
/// and every visible row (added + context) is anchored to its **post-edit**
/// line number so a follow-up edit can reuse the numbers directly.
enum HashlineDiffPreview {

    /// Maximum total lines in the preview before truncation.
    static let maxLines = 200
    /// Maximum UTF-8 bytes in the preview before truncation.
    static let maxBytes = 8_192
    /// Lines of context around each change.
    static let contextLines = 2

    private enum Kind: Equatable {
        case context, added, removed
    }

    private struct Entry {
        let kind: Kind
        let lineNum: Int
        let content: String

        var isChange: Bool { kind == .added || kind == .removed }
    }

    /// The preview text plus the post-edit lines it printed in full. Those are
    /// lines the model has now seen, so the caller records them (see
    /// [`FileViewEvent`](src/Tools/Hashline/FileViews.swift)); rows cut by the
    /// truncation caps are not among them.
    struct Preview: Equatable {
        let text: String
        let shownLines: LineSet
    }

    /// One printed row. `line` is the post-edit line number of an added or
    /// context row; removed rows and blank separators have none.
    private struct Row {
        let text: String
        let line: Int?
    }

    /// Produces the numbered preview between the pre-edit and post-edit file
    /// content. Returns nil when there are no changes.
    static func generate(old: String, new: String) -> Preview? {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        // Fast path: identical content.
        if oldLines == newLines { return nil }

        let diff = oldLines.diff(newLines)
        let entries = buildEntries(oldLines: oldLines, newLines: newLines, diff: diff)
        if !entries.contains(where: { $0.isChange }) { return nil }

        let groups = groupHunks(entries: entries)
        var rows: [Row] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { rows.append(Row(text: "", line: nil)) }
            for entry in group {
                rows.append(Row(text: formatEntry(entry), line: entry.kind == .removed ? nil : entry.lineNum + 1))
            }
        }
        return truncate(rows)
    }

    // MARK: - Diff alignment

    /// Splits a string into lines, normalizing `\r\n` → `\n` and dropping the
    /// trailing empty element produced by a final newline.
    private static func splitLines(_ s: String) -> [String] {
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Reconstructs the full alignment (including equal/context lines) from a
    /// Differ `Diff`. The result interleaves equal, delete, and insert entries
    /// in the order they occur when walking old → new.
    private static func buildEntries(oldLines: [String], newLines: [String], diff: Diff) -> [Entry] {
        var oldIdx = 0
        var newIdx = 0
        var entries: [Entry] = []

        for op in diff.elements {
            switch op {
            case .delete(let at):
                while oldIdx < at {
                    // Context rows are anchored to their post-edit position:
                    // `newIdx` tracks the net offset (inserts − deletes) so far.
                    entries.append(Entry(kind: .context, lineNum: newIdx, content: oldLines[oldIdx]))
                    oldIdx += 1
                    newIdx += 1
                }
                entries.append(Entry(kind: .removed, lineNum: oldIdx, content: oldLines[oldIdx]))
                oldIdx += 1
            case .insert(let at):
                while newIdx < at {
                    entries.append(Entry(kind: .context, lineNum: newIdx, content: oldLines[oldIdx]))
                    oldIdx += 1
                    newIdx += 1
                }
                entries.append(Entry(kind: .added, lineNum: newIdx, content: newLines[newIdx]))
                newIdx += 1
            }
        }
        // Remaining lines (all equal for a correct diff, but handle safely).
        while oldIdx < oldLines.count || newIdx < newLines.count {
            if oldIdx < oldLines.count && newIdx < newLines.count {
                entries.append(Entry(kind: .context, lineNum: newIdx, content: oldLines[oldIdx]))
                oldIdx += 1
                newIdx += 1
            } else if oldIdx < oldLines.count {
                entries.append(Entry(kind: .removed, lineNum: oldIdx, content: oldLines[oldIdx]))
                oldIdx += 1
            } else {
                entries.append(Entry(kind: .added, lineNum: newIdx, content: newLines[newIdx]))
                newIdx += 1
            }
        }
        return entries
    }

    // MARK: - Hunks and formatting

    /// Groups change entries into hunks, each surrounded by `contextLines` of
    /// context. Changes separated by more than `2 * contextLines` equal lines
    /// land in separate hunks; closer changes share one.
    private static func groupHunks(entries: [Entry]) -> [[Entry]] {
        let changeIndices = entries.indices.filter { entries[$0].isChange }
        guard !changeIndices.isEmpty else { return [] }
        let maxGap = contextLines * 2

        var groups: [[Entry]] = []
        var groupStart = changeIndices[0]
        var groupEnd = changeIndices[0]

        for i in 1..<changeIndices.count {
            let idx = changeIndices[i]
            if idx - groupEnd - 1 > maxGap {
                groups.append(
                    Array(entries[max(0, groupStart - contextLines)...min(entries.count - 1, groupEnd + contextLines)]))
                groupStart = idx
            }
            groupEnd = idx
        }
        groups.append(
            Array(entries[max(0, groupStart - contextLines)...min(entries.count - 1, groupEnd + contextLines)]))
        return groups
    }

    /// Formats a row: `-{oldLineNum}:{content}` for removed lines, and
    /// `+{newLineNum}:{content}` / ` {newLineNum}:{content}` for added and
    /// context lines — all post-edit coordinates.
    private static func formatEntry(_ entry: Entry) -> String {
        switch entry.kind {
        case .removed:
            return "-\(entry.lineNum + 1):\(entry.content)"
        case .added:
            return "+\(entry.lineNum + 1):\(entry.content)"
        case .context:
            return " \(entry.lineNum + 1):\(entry.content)"
        }
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
        var text = kept.map(\.text).joined(separator: "\n")
        if kept.count < rows.count {
            text += (kept.isEmpty ? "" : "\n") + "... (diff preview truncated)"
        }
        return Preview(text: text, shownLines: LineSet(kept.compactMap(\.line)))
    }
}
