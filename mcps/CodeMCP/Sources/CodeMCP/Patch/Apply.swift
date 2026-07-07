import Foundation

// Core patch application logic: transforms file contents using parsed hunks.

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
