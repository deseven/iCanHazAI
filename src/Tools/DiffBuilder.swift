// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Differ
import Foundation

/// Builds unified-diff text for `write_file` tool calls so the chat renderer
/// can show a colorized diff instead of raw JSON arguments.
///
/// The diff is computed against the file's current on-disk content (the "before"
/// state) and the content the tool call would write (the "after" state).
enum DiffBuilder {

    /// Maximum diff size (characters). Diffs exceeding this are truncated so the
    /// renderer never gets a multi-megabyte string for a large file write.
    private static let maxDiffSize = 64_000

    // MARK: - Public entry points

    /// Builds a diff for a `write_file` tool call. Returns `nil` when the
    /// arguments are invalid (not JSON, missing `path` or `content`).
    static func diffForWriteFile(arguments: String, workdir: Workdir) -> String? {
        guard let args = parseArgs(arguments),
            let path = args["path"] as? String,
            let content = args["content"] as? String
        else { return nil }
        let resolved = (try? workdir.resolve(path)) ?? path
        let old = readFileAsString(resolved) ?? ""
        return unifiedDiff(old: old, new: content, oldPath: path, newPath: path)
    }

    /// Outcome of the `edit_file` preflight: either the unified diffs for the
    /// patch's sections, or an error message to relay to the model (instead of
    /// asking the user for approval).
    enum EditFilePreflight {
        case ok(diff: String?)
        case error(message: String)
    }

    /// Preflights an `edit_file` tool call without writing anything: parses
    /// the patch, validates each section's #TAG against the current file
    /// content, applies the edits in memory, and produces unified diffs for
    /// the approval UI. Any parse/hash/apply failure becomes `.error` so the
    /// caller can relay it to the model instead of prompting the user.
    static func preflightEditFile(arguments: String, workdir: Workdir) -> EditFilePreflight {
        guard let args = parseArgs(arguments), let input = args["input"] as? String else {
            return .error(message: "Invalid arguments: expected an 'input' string.")
        }
        let patch: ParsedPatch
        do {
            patch = try HashlineEdit.parse(input)
        } catch {
            return .error(message: error.localizedDescription)
        }
        var diffs: [String] = []
        var warnings: [String] = []
        for section in patch.sections {
            let resolved: String
            do {
                resolved = try workdir.resolve(section.path)
            } catch {
                return .error(message: error.localizedDescription)
            }
            guard let data = FileManager.default.contents(atPath: resolved) else {
                return .error(message: "invalid argument 'input': file not found: \(section.path)")
            }
            guard let old = String(data: data, encoding: .utf8) else {
                return .error(
                    message:
                        "File \(section.path) is not a text file and cannot be edited with edit_file. Use write_file to replace it entirely."
                )
            }
            let result: ApplyResult
            do {
                result = try HashlineEdit.applySection(section, fileContent: old)
            } catch {
                return .error(message: error.localizedDescription)
            }
            warnings.append(contentsOf: result.warnings)
            switch section.fileOp {
            case .rem:
                diffs.append(unifiedDiff(old: old, new: "", oldPath: section.path, newPath: nil))
            case .move(let dest):
                diffs.append(unifiedDiff(old: old, new: result.text, oldPath: section.path, newPath: dest))
            case nil:
                diffs.append(unifiedDiff(old: old, new: result.text, oldPath: section.path, newPath: section.path))
            }
        }
        var joined = diffs.filter { !$0.isEmpty }.joined(separator: "\n")
        // Mirror the tool result: parser warnings (bare rows auto-piped,
        // empty-PUT auto-cut, etc.) are appended so the model sees them.
        if !warnings.isEmpty {
            let unique = Array(NSOrderedSet(array: warnings)).compactMap { $0 as? String }
            let block = unique.map { "// WARNING: \($0)" }.joined(separator: "\n")
            joined += (joined.isEmpty ? "" : "\n") + block
        }
        return .ok(diff: joined.isEmpty ? nil : joined)
    }

    // MARK: - Unified diff generation

    /// Builds a unified diff between `old` and `new`. Returns an empty string
    /// when they are identical. `oldPath`/`newPath` are the file paths shown in
    /// the `---`/`+++` headers; pass `nil` for `/dev/null` (new/deleted file).
    static func unifiedDiff(old: String, new: String, oldPath: String?, newPath: String?, context: Int = 3) -> String {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        // Fast path: identical content.
        if oldLines == newLines { return "" }

        let diff = oldLines.diff(newLines)
        let entries = buildEntries(oldLines: oldLines, newLines: newLines, diff: diff)

        // No changes after all (can happen if lines differ only by trailing newline).
        if !entries.contains(where: { $0.isChange }) { return "" }

        let hunks = computeHunks(entries: entries, context: context)
        if hunks.isEmpty { return "" }

        var out = ""
        out += "--- \(oldPath ?? "/dev/null")\n"
        out += "+++ \(newPath ?? "/dev/null")\n"
        for hunk in hunks {
            out += formatHunk(entries: entries, range: hunk, oldLines: oldLines, newLines: newLines)
        }
        return truncate(out)
    }

    // MARK: - Internals

    private enum Entry {
        case equal(oldIdx: Int, newIdx: Int)
        case delete(oldIdx: Int, newIdx: Int)
        case insert(oldIdx: Int, newIdx: Int)

        var isChange: Bool {
            switch self {
            case .equal: return false
            case .delete, .insert: return true
            }
        }
    }

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
                    entries.append(.equal(oldIdx: oldIdx, newIdx: newIdx))
                    oldIdx += 1
                    newIdx += 1
                }
                entries.append(.delete(oldIdx: oldIdx, newIdx: newIdx))
                oldIdx += 1
            case .insert(let at):
                while newIdx < at {
                    entries.append(.equal(oldIdx: oldIdx, newIdx: newIdx))
                    oldIdx += 1
                    newIdx += 1
                }
                entries.append(.insert(oldIdx: oldIdx, newIdx: newIdx))
                newIdx += 1
            }
        }
        // Remaining lines (all equal for a correct diff, but handle safely).
        while oldIdx < oldLines.count || newIdx < newLines.count {
            if oldIdx < oldLines.count && newIdx < newLines.count {
                entries.append(.equal(oldIdx: oldIdx, newIdx: newIdx))
                oldIdx += 1
                newIdx += 1
            } else if oldIdx < oldLines.count {
                entries.append(.delete(oldIdx: oldIdx, newIdx: newIdx))
                oldIdx += 1
            } else {
                entries.append(.insert(oldIdx: oldIdx, newIdx: newIdx))
                newIdx += 1
            }
        }
        return entries
    }

    /// Groups change entries into hunks, each surrounded by `context` lines.
    /// Changes separated by more than `2 * context` equal lines land in separate
    /// hunks; closer changes share a single hunk.
    private static func computeHunks(entries: [Entry], context: Int) -> [(start: Int, end: Int)] {
        let changeIndices = entries.indices.filter { entries[$0].isChange }
        guard !changeIndices.isEmpty else { return [] }
        let maxGap = context * 2

        var hunks: [(start: Int, end: Int)] = []
        var groupStart = changeIndices[0]
        var groupEnd = changeIndices[0]

        for i in 1..<changeIndices.count {
            let idx = changeIndices[i]
            // Gap = number of equal lines between consecutive changes.
            if idx - groupEnd - 1 > maxGap {
                hunks.append((max(0, groupStart - context), min(entries.count - 1, groupEnd + context)))
                groupStart = idx
            }
            groupEnd = idx
        }
        hunks.append((max(0, groupStart - context), min(entries.count - 1, groupEnd + context)))
        return hunks
    }

    /// Formats a single hunk: the `@@` header followed by context/added/removed
    /// lines.
    private static func formatHunk(
        entries: [Entry], range: (start: Int, end: Int), oldLines: [String], newLines: [String]
    ) -> String {
        let slice = entries[range.start...range.end]

        // Compute hunk header: oldStart,oldCount +newStart,newCount (1-based).
        guard let first = slice.first else { return "" }
        let oldStart: Int
        let newStart: Int
        switch first {
        case .equal(let o, let n):
            oldStart = o
            newStart = n
        case .delete(let o, let n):
            oldStart = o
            newStart = n
        case .insert(let o, let n):
            oldStart = o
            newStart = n
        }
        var oldCount = 0
        var newCount = 0
        for e in slice {
            switch e {
            case .equal:
                oldCount += 1
                newCount += 1
            case .delete: oldCount += 1
            case .insert: newCount += 1
            }
        }
        var out = "@@ -\(oldStart + 1),\(oldCount) +\(newStart + 1),\(newCount) @@\n"
        for e in slice {
            switch e {
            case .equal(let o, _):
                out += " \(oldLines[o])\n"
            case .delete(let o, _):
                out += "-\(oldLines[o])\n"
            case .insert(_, let n):
                out += "+\(newLines[n])\n"
            }
        }
        return out
    }

    // MARK: - Helpers

    /// Parses a tool-call arguments JSON string into a dictionary. Returns `nil`
    /// for invalid JSON or a non-object.
    private static func parseArgs(_ arguments: String) -> [String: Any]? {
        guard let data = arguments.data(using: .utf8), !data.isEmpty else { return [:] }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Reads a file as a UTF-8 string. Returns `nil` if the file doesn't exist
    /// or isn't valid UTF-8 (binary).
    private static func readFileAsString(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Truncates a diff to `maxDiffSize`, appending a note if cut.
    private static func truncate(_ s: String) -> String {
        if s.count <= maxDiffSize { return s }
        let prefix = String(s.prefix(maxDiffSize))
        return prefix + "\n... (diff truncated)"
    }
}
