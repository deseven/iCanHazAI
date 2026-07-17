// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - Patch format (Codex apply_patch compatible)

// Grammar:
//   Patch     := "*** Begin Patch" NL { FileOp } "*** End Patch" NL
//   FileOp    := AddFile | DeleteFile | UpdateFile
//   AddFile   := "*** Add File: " path NL { "+" line NL }
//   DeleteFile:= "*** Delete File: " path NL
//   UpdateFile:= "*** Update File: " path NL [ "*** Move to: " newPath NL ] { Hunk }
//   Hunk      := "@@" [ header ] NL { HunkLine } [ "*** End of File" NL ]
//   HunkLine  := (" " | "-" | "+") text NL

let BEGIN_PATCH = "*** Begin Patch"
let END_PATCH = "*** End Patch"
let ADD_FILE = "*** Add File: "
let DELETE_FILE = "*** Delete File: "
let UPDATE_FILE = "*** Update File: "
let MOVE_TO = "*** Move to: "
let EOF_MARKER = "*** End of File"
let CONTEXT_MARKER = "@@ "
let EMPTY_CONTEXT = "@@"

struct PatchParseError: Error, CustomStringConvertible {
    let message: String
    let lineNumber: Int?
    var description: String {
        if let n = lineNumber { return "Line \(n): \(message)" }
        return message
    }
}

struct UpdateFileChunk {
    var changeContext: String?
    var oldLines: [String]
    var newLines: [String]
    var isEndOfFile: Bool
}

enum PatchHunk {
    case addFile(path: String, contents: String)
    case deleteFile(path: String)
    case updateFile(path: String, movePath: String?, chunks: [UpdateFileChunk])
}

struct ParsedPatch {
    let hunks: [PatchHunk]
}

enum PatchParser {
    static func parse(_ patch: String) throws -> ParsedPatch {
        let trimmed = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmed.components(separatedBy: "\n")

        // Handle heredoc-wrapped patches (lenient mode).
        if lines.count >= 4 {
            let first = lines[0]
            let last = lines[lines.count - 1]
            if (first == "<<EOF" || first == "<<'EOF'" || first == "<<\"EOF\"") && last.hasSuffix("EOF") {
                lines = Array(lines[1..<(lines.count - 1)])
            }
        }

        try checkBoundaries(lines)

        let body = Array(lines[1..<(lines.count - 1)])  // skip Begin/End
        var hunks: [PatchHunk] = []
        var idx = 0
        var lineNumber = 2
        while idx < body.count {
            let consumed = try parseOneHunk(body, idx, lineNumber)
            hunks.append(consumed.hunk)
            lineNumber += consumed.linesConsumed
            idx += consumed.linesConsumed
        }
        return ParsedPatch(hunks: hunks)
    }

    private static func checkBoundaries(_ lines: [String]) throws {
        guard !lines.isEmpty else { throw PatchParseError(message: "Empty patch", lineNumber: nil) }
        guard lines[0].trimmingCharacters(in: .whitespaces) == BEGIN_PATCH else {
            throw PatchParseError(message: "The first line of the patch must be '*** Begin Patch'", lineNumber: 1)
        }
        guard lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == END_PATCH else {
            throw PatchParseError(message: "The last line of the patch must be '*** End Patch'", lineNumber: lines.count)
        }
    }

    private static func parseOneHunk(_ lines: [String], _ start: Int, _ lineNumber: Int) throws -> (hunk: PatchHunk, linesConsumed: Int) {
        let firstLine = lines[start].trimmingCharacters(in: .whitespaces)

        if firstLine.hasPrefix(ADD_FILE) {
            let path = String(firstLine.dropFirst(ADD_FILE.count))
            var contents = ""
            var consumed = 1
            var i = start + 1
            while i < lines.count, lines[i].hasPrefix("+") {
                contents += String(lines[i].dropFirst()) + "\n"
                consumed += 1
                i += 1
            }
            return (.addFile(path: path, contents: contents), consumed)
        }

        if firstLine.hasPrefix(DELETE_FILE) {
            let path = String(firstLine.dropFirst(DELETE_FILE.count))
            return (.deleteFile(path: path), 1)
        }

        if firstLine.hasPrefix(UPDATE_FILE) {
            let path = String(firstLine.dropFirst(UPDATE_FILE.count))
            var consumed = 1
            var i = start + 1

            var movePath: String? = nil
            if i < lines.count, lines[i].hasPrefix(MOVE_TO) {
                movePath = String(lines[i].dropFirst(MOVE_TO.count))
                consumed += 1
                i += 1
            }

            var chunks: [UpdateFileChunk] = []
            while i < lines.count {
                // Skip blank lines between chunks.
                if lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    consumed += 1
                    i += 1
                    continue
                }
                // Stop at the next file operation marker.
                if lines[i].hasPrefix("***") { break }

                let r = try parseUpdateFileChunk(lines, i, lineNumber + consumed, allowMissingContext: chunks.isEmpty)
                chunks.append(r.chunk)
                consumed += r.linesConsumed
                i += r.linesConsumed
            }

            guard !chunks.isEmpty else {
                throw PatchParseError(message: "Update file hunk for path '\(path)' is empty", lineNumber: lineNumber)
            }
            return (.updateFile(path: path, movePath: movePath, chunks: chunks), consumed)
        }

        throw PatchParseError(message: "'\(firstLine)' is not a valid hunk header. Valid: '*** Add File: {path}', '*** Delete File: {path}', '*** Update File: {path}'", lineNumber: lineNumber)
    }

    private static func parseUpdateFileChunk(_ lines: [String], _ start: Int, _ lineNumber: Int, allowMissingContext: Bool) throws -> (chunk: UpdateFileChunk, linesConsumed: Int) {
        guard start < lines.count else {
            throw PatchParseError(message: "Update hunk does not contain any lines", lineNumber: lineNumber)
        }

        var changeContext: String? = nil
        var idx = start

        if lines[idx] == EMPTY_CONTEXT {
            changeContext = nil
            idx += 1
        } else if lines[idx].hasPrefix(CONTEXT_MARKER) {
            changeContext = String(lines[idx].dropFirst(CONTEXT_MARKER.count))
            idx += 1
        } else if !allowMissingContext {
            throw PatchParseError(message: "Expected update hunk to start with a @@ context marker, got: '\(lines[idx])'", lineNumber: lineNumber)
        }

        guard idx < lines.count else {
            throw PatchParseError(message: "Update hunk does not contain any lines", lineNumber: lineNumber + 1)
        }

        var chunk = UpdateFileChunk(changeContext: changeContext, oldLines: [], newLines: [], isEndOfFile: false)
        var parsed = 0
        var i = idx
        while i < lines.count {
            let line = lines[i]

            if line == EOF_MARKER {
                if parsed == 0 {
                    throw PatchParseError(message: "Update hunk does not contain any lines", lineNumber: lineNumber + 1)
                }
                chunk.isEndOfFile = true
                parsed += 1
                i += 1
                break
            }

            if line.isEmpty {
                chunk.oldLines.append("")
                chunk.newLines.append("")
                parsed += 1
                i += 1
                continue
            }

            let first = line.first!
            switch first {
            case " ":
                let rest = String(line.dropFirst())
                chunk.oldLines.append(rest)
                chunk.newLines.append(rest)
                parsed += 1
            case "+":
                chunk.newLines.append(String(line.dropFirst()))
                parsed += 1
            case "-":
                chunk.oldLines.append(String(line.dropFirst()))
                parsed += 1
            default:
                if parsed == 0 {
                    throw PatchParseError(message: "Unexpected line found in update hunk: '\(line)'. Every line should start with ' ' (context), '+' (added), or '-' (removed)", lineNumber: lineNumber + 1)
                }
                return (chunk, parsed + (idx - start))
            }
            i += 1
        }

        return (chunk, parsed + (idx - start))
    }
}

// MARK: - Patch application

struct ApplyPatchError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum PatchApplier {
    /// A planned replacement: [startIndex, oldLength, newLines].
    struct Replacement {
        let start: Int
        let oldLength: Int
        let newLines: [String]
    }

    /// Compute the replacements needed to transform `originalLines` according
    /// to the update chunks.
    static func computeReplacements(originalLines: [String], filePath: String, chunks: [UpdateFileChunk]) throws -> [Replacement] {
        var replacements: [Replacement] = []
        var lineIndex = 0

        for chunk in chunks {
            // If a chunk has a change_context, find it first.
            if let ctx = chunk.changeContext {
                guard let idx = SeekSequence.seek(lines: originalLines, pattern: [ctx], start: lineIndex, eof: false) else {
                    throw ApplyPatchError(message: "Failed to find context '\(ctx)' in \(filePath)")
                }
                lineIndex = idx + 1
            }

            if chunk.oldLines.isEmpty {
                // Pure addition (no old lines). Add at the end or before a trailing empty line.
                let insertionIdx: Int
                if !originalLines.isEmpty && originalLines[originalLines.count - 1].isEmpty {
                    insertionIdx = originalLines.count - 1
                } else {
                    insertionIdx = originalLines.count
                }
                replacements.append(Replacement(start: insertionIdx, oldLength: 0, newLines: chunk.newLines))
                continue
            }

            // Find the old_lines in the file.
            var pattern = chunk.oldLines
            var newSlice = chunk.newLines
            var found = SeekSequence.seek(lines: originalLines, pattern: pattern, start: lineIndex, eof: chunk.isEndOfFile)

            // If not found and pattern ends with an empty string (trailing newline), retry without it.
            if found == nil, !pattern.isEmpty, pattern.last!.isEmpty {
                pattern = Array(pattern.dropLast())
                if !newSlice.isEmpty, newSlice.last!.isEmpty {
                    newSlice = Array(newSlice.dropLast())
                }
                found = SeekSequence.seek(lines: originalLines, pattern: pattern, start: lineIndex, eof: chunk.isEndOfFile)
            }

            if let f = found {
                replacements.append(Replacement(start: f, oldLength: pattern.count, newLines: newSlice))
                lineIndex = f + pattern.count
            } else {
                let preview = chunk.oldLines.joined(separator: "\n")
                let truncated = preview.count > 200 ? String(preview.prefix(200)) + "..." : preview
                throw ApplyPatchError(message: "Failed to find expected lines in \(filePath):\n\(truncated)")
            }
        }

        return replacements.sorted { $0.start < $1.start }
    }

    /// Apply replacements to the original lines, returning the modified lines.
    /// Replacements are applied in reverse order to preserve indices.
    static func applyReplacements(_ lines: [String], _ replacements: [Replacement]) -> [String] {
        var result = lines
        for r in replacements.reversed() {
            result.replaceSubrange(r.start..<(r.start + r.oldLength), with: r.newLines)
        }
        return result
    }

    /// Apply update chunks to file content, returning the new content.
    static func applyChunksToContent(originalContent: String, filePath: String, chunks: [UpdateFileChunk]) throws -> String {
        var originalLines = originalContent.components(separatedBy: "\n")
        // Drop trailing empty element from a final newline so line counts match diff behavior.
        if !originalLines.isEmpty, originalLines.last!.isEmpty {
            originalLines = Array(originalLines.dropLast())
        }

        let replacements = try computeReplacements(originalLines: originalLines, filePath: filePath, chunks: chunks)
        var newLines = applyReplacements(originalLines, replacements)

        // Ensure file ends with newline.
        if newLines.isEmpty || newLines.last! != "" {
            newLines.append("")
        }
        return newLines.joined(separator: "\n")
    }
}

// MARK: - SeekSequence (multi-pass sequence matching)

// Multi-pass sequence matching to locate old_lines within a file.
// Matches are attempted with decreasing strictness:
//   1. Exact
//   2. Ignoring trailing whitespace
//   3. Ignoring leading and trailing whitespace
//   4. Unicode-normalized (typographic chars → ASCII)
// When `eof` is true, the search starts at the end of the file so patterns
// intended to match file endings are applied there first.

enum SeekSequence {
    /// Normalize common Unicode punctuation to ASCII equivalents so patches
    /// written with plain ASCII can match source files containing typographic
    /// characters.
    static func normalizeUnicode(_ s: String) -> String {
        var out = ""
        for c in s.trimmingCharacters(in: .whitespaces) {
            switch c {
            case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}":
                out.append("-")
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}":
                out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}":
                out.append("\"")
            case "\u{00A0}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{202F}", "\u{205F}", "\u{3000}":
                out.append(" ")
            default:
                out.append(c)
            }
        }
        return out
    }

    static func exactMatch(_ lines: [String], _ pattern: [String], _ start: Int) -> Bool {
        for i in 0..<pattern.count {
            if lines[start + i] != pattern[i] { return false }
        }
        return true
    }

    static func trimEndMatch(_ lines: [String], _ pattern: [String], _ start: Int) -> Bool {
        for i in 0..<pattern.count {
            if lines[start + i].trimmingCharacters(in: .whitespaces) != pattern[i].trimmingCharacters(in: .whitespaces) {
                return false
            }
        }
        return true
    }

    static func trimMatch(_ lines: [String], _ pattern: [String], _ start: Int) -> Bool {
        for i in 0..<pattern.count {
            let a = lines[start + i].trimmingCharacters(in: .whitespacesAndNewlines)
            let b = pattern[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if a != b { return false }
        }
        return true
    }

    static func normalizedMatch(_ lines: [String], _ pattern: [String], _ start: Int) -> Bool {
        for i in 0..<pattern.count {
            let a = start + i < lines.count ? normalizeUnicode(lines[start + i]) : ""
            let b = i < pattern.count ? normalizeUnicode(pattern[i]) : ""
            if a != b { return false }
        }
        return true
    }

    /// Find the starting index of `pattern` within `lines` at or after `start`,
    /// or nil if not found. When `eof` is true, search begins at the end of the
    /// file (so end-of-file patterns match there first).
    static func seek(lines: [String], pattern: [String], start: Int, eof: Bool) -> Int? {
        if pattern.isEmpty { return start }
        if pattern.count > lines.count { return nil }

        let searchStart = eof && lines.count >= pattern.count ? lines.count - pattern.count : start
        let maxStart = lines.count - pattern.count

        for i in searchStart...maxStart { if exactMatch(lines, pattern, i) { return i } }
        for i in searchStart...maxStart { if trimEndMatch(lines, pattern, i) { return i } }
        for i in searchStart...maxStart { if trimMatch(lines, pattern, i) { return i } }
        for i in searchStart...maxStart { if normalizedMatch(lines, pattern, i) { return i } }

        return nil
    }
}
