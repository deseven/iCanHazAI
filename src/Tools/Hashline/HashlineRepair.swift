// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Repair pass for the most common silent-corruption failure in replacements:
/// the model writes a `PUT N.=M:` body that restates unchanged lines bordering
/// the range (the "retyped the keeper inside the range" mistake). The restated
/// lines get silently duplicated in the output.
///
/// Evidence-complete by design — fires only on exact (byte-for-byte) line
/// equality and never consumes the whole payload, so no parser veto is needed:
/// a payload that is entirely a restatement is ambiguous (mistake vs.
/// intentional duplication) and is left alone.
enum HashlineRepair {

    /// A run of `.insert(.replacement)` edits (the body lines) immediately
    /// followed by the contiguous `.delete` edits of the range they replace.
    private struct ReplacementGroup {
        let insertIndices: [Int]
        let deleteIndices: [Int]
        let payload: [String]
        let startLine: Int
        let endLine: Int
    }

    /// Scans `edits` for replacement groups and repairs boundary echoes in
    /// place, returning the adjusted edit list plus one warning per repair.
    static func repairReplacementBoundaries(_ edits: [Edit], fileLines: [String])
        -> (edits: [Edit], warnings: [String])
    {
        var out: [Edit] = []
        var warnings: [String] = []
        var i = 0
        while i < edits.count {
            guard let group = findReplacementGroup(edits, start: i) else {
                out.append(edits[i])
                i += 1
                continue
            }
            let inserts = group.insertIndices.map { edits[$0] }
            let deletes = group.deleteIndices.map { edits[$0] }
            i = (group.deleteIndices.last ?? i) + 1

            let leading = countDuplicateLeadingBoundaryLines(group, fileLines: fileLines)
            let trailing = countDuplicateTrailingBoundaryLines(group, fileLines: fileLines)

            // Two-sided echo: the payload restates both edges of the range.
            // Never consume the whole payload — that is ambiguous.
            if leading > 0, trailing > 0, leading + trailing < group.payload.count {
                let keep = Array(inserts[leading...(inserts.count - 1 - trailing)])
                out.append(contentsOf: keep)
                out.append(contentsOf: deletes)
                warnings.append(
                    "Auto-repaired a replacement boundary echo at line \(group.startLine): "
                        + "dropped \(leading) leading and \(trailing) trailing payload line(s) "
                        + "already present outside the range. Issue the payload as the final "
                        + "desired content for the selected range only.")
                continue
            }

            // One-sided echo: the payload restates only the leading or trailing
            // edge — the range was one line short of the retyped content.
            if (leading > 0) != (trailing > 0), max(leading, trailing) < group.payload.count {
                let count = max(leading, trailing)
                let side = leading > 0 ? "leading" : "trailing"
                let trimmed =
                    leading > 0
                    ? Array(inserts[count...])
                    : Array(inserts[..<(inserts.count - count)])
                out.append(contentsOf: trimmed)
                out.append(contentsOf: deletes)
                warnings.append(
                    "Auto-repaired a replacement boundary echo at line \(group.startLine): "
                        + "dropped \(count) \(side) payload line(s) identical to the surviving "
                        + "line(s) just \(leading > 0 ? "above" : "below") the range. The range was "
                        + "one line short of the content you retyped — issue the payload as the "
                        + "final content for the selected range only, and widen the range to "
                        + "consume any keeper you restate.")
                continue
            }

            out.append(contentsOf: inserts)
            out.append(contentsOf: deletes)
        }
        return (out, warnings)
    }

    // MARK: - Group detection

    /// Detects a replacement group starting at `start`: a run of `beforeAnchor`
    /// replacement inserts sharing one source op line, immediately followed by
    /// the contiguous range deletes for that same op. Mirrors how the parser
    /// lowers a `PUT N.=M:` hunk with a body.
    private static func findReplacementGroup(_ edits: [Edit], start: Int) -> ReplacementGroup? {
        guard case .insert(let cursor, _, let lineNum, _, let mode)? = edits[safe: start],
            mode == .replacement,
            case .beforeAnchor(let anchor) = cursor
        else { return nil }
        let anchorLine = anchor.line

        var insertIndices: [Int] = []
        var payload: [String] = []
        var i = start
        while i < edits.count {
            guard case .insert(let c, let text, let ln, _, let m) = edits[i],
                m == .replacement,
                ln == lineNum,
                case .beforeAnchor(let a) = c,
                a.line == anchorLine
            else { break }
            insertIndices.append(i)
            payload.append(text)
            i += 1
        }

        var deleteIndices: [Int] = []
        var expectedLine = anchorLine
        while i < edits.count {
            guard case .delete(let a, let ln, _) = edits[i], ln == lineNum, a.line == expectedLine else {
                break
            }
            deleteIndices.append(i)
            expectedLine += 1
            i += 1
        }
        guard !deleteIndices.isEmpty else { return nil }

        return ReplacementGroup(
            insertIndices: insertIndices,
            deleteIndices: deleteIndices,
            payload: payload,
            startLine: anchorLine,
            endLine: anchorLine + deleteIndices.count - 1
        )
    }

    // MARK: - Echo detection

    /// Largest `k` such that the payload's first `k` lines exactly equal the
    /// `k` surviving file lines just above the range. Blank-only runs don't
    /// count — a whitespace boundary is not restated content.
    private static func countDuplicateLeadingBoundaryLines(
        _ group: ReplacementGroup, fileLines: [String]
    ) -> Int {
        let maxCount = min(group.payload.count, group.startLine - 1)
        for count in stride(from: maxCount, through: 1, by: -1) {
            var matches = true
            var hasContent = false
            for offset in 0..<count {
                let line = group.payload[offset]
                guard line == fileLines[group.startLine - 1 - count + offset] else {
                    matches = false
                    break
                }
                hasContent = hasContent || !line.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if matches, hasContent { return count }
        }
        return 0
    }

    /// Largest `j` such that the payload's last `j` lines exactly equal the
    /// `j` surviving file lines just below the range. Same blank-line guard as
    /// the leading counter.
    private static func countDuplicateTrailingBoundaryLines(
        _ group: ReplacementGroup, fileLines: [String]
    ) -> Int {
        let maxCount = min(group.payload.count, fileLines.count - group.endLine)
        for count in stride(from: maxCount, through: 1, by: -1) {
            var matches = true
            var hasContent = false
            for offset in 0..<count {
                let line = group.payload[group.payload.count - count + offset]
                guard line == fileLines[group.endLine + offset] else {
                    matches = false
                    break
                }
                hasContent = hasContent || !line.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if matches, hasContent { return count }
        }
        return 0
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
