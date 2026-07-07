import Foundation

// Parser for the apply_patch format (Codex-compatible).
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

struct ParseError: Error, CustomStringConvertible {
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

enum Hunk {
    case addFile(path: String, contents: String)
    case deleteFile(path: String)
    case updateFile(path: String, movePath: String?, chunks: [UpdateFileChunk])
}

struct ApplyPatchArgs {
    let hunks: [Hunk]
}

enum PatchParser {
    static func parse(_ patch: String) throws -> ApplyPatchArgs {
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
        var hunks: [Hunk] = []
        var idx = 0
        var lineNumber = 2
        while idx < body.count {
            let consumed = try parseOneHunk(body, idx, lineNumber)
            hunks.append(consumed.hunk)
            lineNumber += consumed.linesConsumed
            idx += consumed.linesConsumed
        }
        return ApplyPatchArgs(hunks: hunks)
    }

    private static func checkBoundaries(_ lines: [String]) throws {
        guard !lines.isEmpty else { throw ParseError(message: "Empty patch", lineNumber: nil) }
        guard lines[0].trimmingCharacters(in: .whitespaces) == BEGIN_PATCH else {
            throw ParseError(message: "The first line of the patch must be '*** Begin Patch'", lineNumber: 1)
        }
        guard lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == END_PATCH else {
            throw ParseError(message: "The last line of the patch must be '*** End Patch'", lineNumber: lines.count)
        }
    }

    private static func parseOneHunk(_ lines: [String], _ start: Int, _ lineNumber: Int) throws -> (hunk: Hunk, linesConsumed: Int) {
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
                throw ParseError(message: "Update file hunk for path '\(path)' is empty", lineNumber: lineNumber)
            }
            return (.updateFile(path: path, movePath: movePath, chunks: chunks), consumed)
        }

        throw ParseError(message: "'\(firstLine)' is not a valid hunk header. Valid: '*** Add File: {path}', '*** Delete File: {path}', '*** Update File: {path}'", lineNumber: lineNumber)
    }

    private static func parseUpdateFileChunk(_ lines: [String], _ start: Int, _ lineNumber: Int, allowMissingContext: Bool) throws -> (chunk: UpdateFileChunk, linesConsumed: Int) {
        guard start < lines.count else {
            throw ParseError(message: "Update hunk does not contain any lines", lineNumber: lineNumber)
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
            throw ParseError(message: "Expected update hunk to start with a @@ context marker, got: '\(lines[idx])'", lineNumber: lineNumber)
        }

        guard idx < lines.count else {
            throw ParseError(message: "Update hunk does not contain any lines", lineNumber: lineNumber + 1)
        }

        var chunk = UpdateFileChunk(changeContext: changeContext, oldLines: [], newLines: [], isEndOfFile: false)
        var parsed = 0
        var i = idx
        while i < lines.count {
            let line = lines[i]

            if line == EOF_MARKER {
                if parsed == 0 {
                    throw ParseError(message: "Update hunk does not contain any lines", lineNumber: lineNumber + 1)
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
                    throw ParseError(message: "Unexpected line found in update hunk: '\(line)'. Every line should start with ' ' (context), '+' (added), or '-' (removed)", lineNumber: lineNumber + 1)
                }
                return (chunk, parsed + (idx - start))
            }
            i += 1
        }

        return (chunk, parsed + (idx - start))
    }
}
