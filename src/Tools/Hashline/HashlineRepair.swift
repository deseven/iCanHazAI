// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Repair pass for the most common silent-corruption failure in replacements:
/// the model writes a `PUT N.=M:` body that restates unchanged lines bordering
/// the range (the "retyped the keeper inside the range" mistake). The restated
/// lines get silently duplicated in the output.
///
/// Evidence-complete by design — a repair fires only on exact (byte-for-byte)
/// line equality, never consumes the whole payload, and must keep the
/// delimiter balance of the result intact (see `DelimiterBalance`). A payload
/// that is entirely a restatement is ambiguous (mistake vs. intentional
/// duplication) and is left alone. Evidence that points two ways is rejected
/// instead of guessed at.
enum HashlineRepair {

    /// A run of `.insert(.replacement)` edits (the body lines) immediately
    /// followed by the contiguous `.delete` edits of the range they replace.
    private struct ReplacementGroup {
        let insertIndices: [Int]
        let deleteIndices: [Int]
        let payload: [String]
        let startLine: Int
        let endLine: Int

        var rangeLength: Int { deleteIndices.count }
    }

    private enum Side {
        case leading, trailing
    }

    /// Payload lines to drop from each edge of a group, with the warning to
    /// report.
    private struct Repair {
        let dropLeading: Int
        let dropTrailing: Int
        let warning: String
    }

    /// Scans `edits` for replacement groups and repairs boundary echoes in
    /// place, returning the adjusted edit list plus one warning per repair.
    /// `fileLines` are the addressable lines (no phantom). Throws when a
    /// detected echo cannot be repaired without guessing.
    static func repairReplacementBoundaries(_ edits: [Edit], fileLines: [String]) throws
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

            if let repair = try planRepair(group, fileLines: fileLines) {
                out.append(contentsOf: inserts[repair.dropLeading..<(inserts.count - repair.dropTrailing)])
                warnings.append(repair.warning)
            } else {
                out.append(contentsOf: inserts)
            }
            out.append(contentsOf: deletes)
        }
        return (out, warnings)
    }

    // MARK: - Repair planning

    private static func planRepair(_ group: ReplacementGroup, fileLines: [String]) throws -> Repair? {
        if let echo = findBoundaryEcho(group, fileLines: fileLines) {
            return Repair(
                dropLeading: echo.leading, dropTrailing: echo.trailing,
                warning: describeBoundaryEchoRepair(group, echo))
        }

        let delta =
            DelimiterBalance(counting: group.payload)
            - DelimiterBalance(counting: fileLines[(group.startLine - 1)..<group.endLine])

        if delta.isZero {
            guard let oneSided = findOneSidedBoundaryEcho(group, fileLines: fileLines) else { return nil }
            // A payload shorter than range + echo cannot be the widened range's
            // full content: repairing would delete range line(s) the payload
            // never restates, while the "shifted range" reading keeps them.
            if group.payload.count < group.rangeLength + oneSided.count {
                throw HashlineParseError.message(ambiguousBoundaryEchoMessage(group, oneSided))
            }
            return Repair(
                dropLeading: oneSided.side == .leading ? oneSided.count : 0,
                dropTrailing: oneSided.side == .trailing ? oneSided.count : 0,
                warning: describeOneSidedEchoRepair(group, oneSided))
        }

        // The payload is delimiter-imbalanced against its range: restated
        // lines are dropped only when they exactly account for the imbalance.
        let suffix = findDuplicateSuffix(group, fileLines: fileLines, delta: delta)
        if suffix > 0 {
            return Repair(
                dropLeading: 0, dropTrailing: suffix,
                warning: describeBalanceRepair(group, (.trailing, suffix)))
        }
        let prefix = findDuplicatePrefix(group, fileLines: fileLines, delta: delta)
        if prefix > 0 {
            return Repair(
                dropLeading: prefix, dropTrailing: 0,
                warning: describeBalanceRepair(group, (.leading, prefix)))
        }
        return nil
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
            let above = fileLines[(group.startLine - 1 - count)..<(group.startLine - 1)]
            let echo = group.payload.prefix(count)
            if echo.elementsEqual(above), echo.contains(where: hasContent) { return count }
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
            let below = fileLines[group.endLine..<(group.endLine + count)]
            let echo = group.payload.suffix(count)
            if echo.elementsEqual(below), echo.contains(where: hasContent) { return count }
        }
        return 0
    }

    private static func hasContent(_ line: String) -> Bool {
        !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Two-sided echo: the payload restates both edges of the range. Never
    /// consumes the whole payload, and the dropped lines must either be
    /// delimiter-neutral or exactly cancel the payload-vs-range imbalance — in
    /// brace-heavy code where bare closer lines repeat, an "echo" that shifts
    /// the balance is structure the payload placed intentionally.
    private static func findBoundaryEcho(
        _ group: ReplacementGroup, fileLines: [String]
    ) -> (leading: Int, trailing: Int)? {
        let leading = countDuplicateLeadingBoundaryLines(group, fileLines: fileLines)
        guard leading > 0 else { return nil }
        let trailing = countDuplicateTrailingBoundaryLines(group, fileLines: fileLines)
        guard trailing > 0 else { return nil }
        guard leading + trailing < group.payload.count else { return nil }

        let dropped =
            DelimiterBalance(counting: group.payload.prefix(leading))
            + DelimiterBalance(counting: group.payload.suffix(trailing))
        if !dropped.isZero {
            let delta =
                DelimiterBalance(counting: group.payload)
                - DelimiterBalance(counting: fileLines[(group.startLine - 1)..<group.endLine])
            guard dropped == delta else { return nil }
        }
        return (leading, trailing)
    }

    /// One-sided echo in an otherwise delimiter-balanced multi-line
    /// replacement: the payload's leading XOR trailing edge restates the
    /// surviving line(s) just outside the range — the off-by-one "range one
    /// line short of the keeper I retyped" mistake. The dropped lines must be
    /// delimiter-neutral and must not consume the whole payload.
    ///
    /// Single-line ranges are never repaired: duplicating a neighbouring
    /// statement there is as likely to be intentional as a mistake.
    private static func findOneSidedBoundaryEcho(
        _ group: ReplacementGroup, fileLines: [String]
    ) -> (side: Side, count: Int)? {
        guard group.rangeLength > 1 else { return nil }
        let leading = countDuplicateLeadingBoundaryLines(group, fileLines: fileLines)
        let trailing = countDuplicateTrailingBoundaryLines(group, fileLines: fileLines)
        guard (leading > 0) != (trailing > 0) else { return nil }
        let side: Side = leading > 0 ? .leading : .trailing
        let count = leading > 0 ? leading : trailing
        guard count < group.payload.count else { return nil }
        let echo = side == .leading ? group.payload.prefix(count) : group.payload.suffix(count)
        guard DelimiterBalance(counting: echo).isZero else { return nil }
        return (side, count)
    }

    /// Largest `k` such that the payload's last `k` lines exactly equal the
    /// `k` surviving file lines just below the range AND dropping them zeroes
    /// `delta`. Requires a non-zero `delta`: a zero-balance candidate can never
    /// account for the imbalance, so intentional duplicates of ordinary
    /// statements stay intact, while duplicated structural lines (closers like
    /// `});`, openers like `foo(`) are dropped when they exactly explain it.
    private static func findDuplicateSuffix(
        _ group: ReplacementGroup, fileLines: [String], delta: DelimiterBalance
    ) -> Int {
        guard !delta.isZero else { return 0 }
        let maxCount = min(group.payload.count, fileLines.count - group.endLine)
        for count in stride(from: maxCount, through: 1, by: -1) {
            let below = fileLines[group.endLine..<(group.endLine + count)]
            let tail = group.payload.suffix(count)
            if tail.elementsEqual(below), DelimiterBalance(counting: tail) == delta { return count }
        }
        return 0
    }

    /// Largest `j` such that the payload's first `j` lines exactly equal the
    /// `j` surviving file lines just above the range AND dropping them zeroes
    /// `delta`. Requires a non-zero `delta`; see `findDuplicateSuffix`.
    private static func findDuplicatePrefix(
        _ group: ReplacementGroup, fileLines: [String], delta: DelimiterBalance
    ) -> Int {
        guard !delta.isZero else { return 0 }
        let maxCount = min(group.payload.count, group.startLine - 1)
        for count in stride(from: maxCount, through: 1, by: -1) {
            let above = fileLines[(group.startLine - 1 - count)..<(group.startLine - 1)]
            let head = group.payload.prefix(count)
            if head.elementsEqual(above), DelimiterBalance(counting: head) == delta { return count }
        }
        return 0
    }

    // MARK: - Messages

    /// Every repair message names the hunk and quotes the rows it dropped,
    /// so the model can check the repair without reconstructing it.
    private static func hunkHeader(_ group: ReplacementGroup) -> String {
        "`\(HashlineFormat.putKeyword) \(group.startLine)\(HashlineFormat.rangeSep)\(group.endLine)\(HashlineFormat.headerColon)`"
    }

    /// `2 leading body row(s) repeating lines 3-4 just above the range (`a`, `b`)`.
    private static func describeDrop(
        _ group: ReplacementGroup, side: Side, count: Int
    ) -> String {
        let rows = side == .leading ? group.payload.prefix(count) : group.payload.suffix(count)
        let first = side == .leading ? group.startLine - count : group.endLine + 1
        let lines = count == 1 ? "line \(first)" : "lines \(first)-\(first + count - 1)"
        let name = side == .leading ? "leading" : "trailing"
        let direction = side == .leading ? "above" : "below"
        return "\(count) \(name) body row(s) repeating \(lines) just \(direction) the range (\(quoted(rows)))"
    }

    private static func quoted(_ rows: ArraySlice<String>) -> String {
        let shown = rows.prefix(3).map { row -> String in
            let text = row.count > 80 ? String(row.prefix(80)) + "…" : row
            return "`\(text)`"
        }
        let more = rows.count > 3 ? " and \(rows.count - 3) more" : ""
        return shown.joined(separator: ", ") + more
    }

    private static func describeBoundaryEchoRepair(
        _ group: ReplacementGroup, _ echo: (leading: Int, trailing: Int)
    ) -> String {
        "Auto-repaired \(hunkHeader(group)): dropped "
            + describeDrop(group, side: .leading, count: echo.leading) + " and "
            + describeDrop(group, side: .trailing, count: echo.trailing) + ". "
            + "The body must be only the final content of the range — never restate lines outside it."
    }

    private static func describeOneSidedEchoRepair(
        _ group: ReplacementGroup, _ echo: (side: Side, count: Int)
    ) -> String {
        "Auto-repaired \(hunkHeader(group)): dropped "
            + describeDrop(group, side: echo.side, count: echo.count) + ". "
            + "The range was one line short of the content you retyped: widen the range to consume "
            + "any line you restate, or leave that line out of the body."
    }

    private static func describeBalanceRepair(
        _ group: ReplacementGroup, _ drop: (side: Side, count: Int)
    ) -> String {
        "Auto-repaired \(hunkHeader(group)): dropped "
            + describeDrop(group, side: drop.side, count: drop.count)
            + "; keeping them would have duplicated the bracket(s) they hold. "
            + "Never restate or omit a closing bracket bordering the range."
    }

    private static func ambiguousBoundaryEchoMessage(
        _ group: ReplacementGroup, _ echo: (side: Side, count: Int)
    ) -> String {
        let what =
            echo.side == .leading
            ? "opens by restating the \(echo.count) line(s) just above the range"
            : "ends by restating the \(echo.count) line(s) just below the range"
        let header =
            "\(HashlineFormat.putKeyword) \(group.startLine)\(HashlineFormat.rangeSep)\(group.endLine)"
            + HashlineFormat.headerColon
        return "`\(header)` rejected: the body \(what), "
            + "but is too short to be the full final content of the widened range — applying it as-is or "
            + "auto-repairing would delete range line(s) the body never restates. "
            + "Re-issue with the range covering exactly the lines that change and the body as their complete "
            + "final content: drop the restated keeper from the body, or widen the range to consume it."
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
