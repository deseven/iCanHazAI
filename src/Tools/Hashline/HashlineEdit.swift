// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Errors from the hashline edit pipeline.
enum HashlineEditError: Error, LocalizedError {
    case parseError(String)
    case hashMismatch(path: String, expected: String, actual: String)
    case applyError(String)
    case noop(path: String)

    var errorDescription: String? {
        switch self {
        case .parseError(let msg):
            return msg
        case .hashMismatch(let path, let expected, let actual):
            return
                "File \(path) has changed since you last read it (expected tag #\(expected), current is #\(actual)). Re-read the file and retry."
        case .applyError(let msg):
            return msg
        case .noop(let path):
            return "No changes to \(path)."
        }
    }
}

/// High-level entry point for the hashline format: parse a patch, validate
/// file hashes, and apply edits.
enum HashlineEdit {

    /// Parse a full hashline patch input (envelope + sections) into a
    /// `ParsedPatch` with one `HashlineSection` per `[path#TAG]` header.
    static func parse(_ input: String) throws -> ParsedPatch {
        let lines = HashlineTokenizer.splitHashlineLines(input)

        var sections: [HashlineSection] = []
        var currentHeader: (path: String, fileHash: String?)?
        var currentLines: [String] = []

        func flush() throws {
            guard let header = currentHeader else { return }
            let hasOps = currentLines.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard hasOps else {
                currentLines = []
                return
            }
            let diff = currentLines.joined(separator: "\n")
            let result = try HashlineParser.parsePatch(diff)
            sections.append(
                HashlineSection(
                    path: header.path,
                    fileHash: header.fileHash,
                    edits: result.edits,
                    fileOp: result.fileOp,
                    warnings: result.warnings
                ))
            currentLines = []
        }

        for line in lines {
            let token = HashlineTokenizer.tokenize(line)
            if case .envelopeEnd = token { break }
            if case .envelopeBegin = token { continue }

            if line.hasPrefix(HashlineFormat.filePrefix) {
                if let header = HashlineTokenizer.tryParseHeader(line) {
                    try flush()
                    currentHeader = (path: header.path, fileHash: header.fileHash)
                    currentLines = []
                    continue
                }
            }
            currentLines.append(line)
        }
        try flush()

        guard !sections.isEmpty else {
            throw HashlineEditError.parseError(
                "Input must begin with `\(HashlineFormat.filePrefix)PATH\(HashlineFormat.fileHashSep)HASH\(HashlineFormat.fileSuffix)` on the first non-blank line. Example: `\(HashlineFormat.filePrefix)src/foo.ts\(HashlineFormat.fileHashSep)1A2B\(HashlineFormat.fileSuffix)` then edit ops."
            )
        }

        return ParsedPatch(sections: sections)
    }

    /// Apply a single section's edits to file content. Validates the file hash
    /// (computes from `fileContent`, compares with `section.fileHash`), then
    /// applies the edits.
    static func applySection(_ section: HashlineSection, fileContent: String) throws -> ApplyResult {
        // Validate hash.
        if let expectedHash = section.fileHash {
            let actualHash = HashlineFormat.computeFileHash(fileContent)
            guard actualHash == expectedHash else {
                throw HashlineEditError.hashMismatch(
                    path: section.path,
                    expected: expectedHash,
                    actual: actualHash
                )
            }
        } else {
            throw HashlineEditError.parseError(
                "Section for \(section.path) is missing a `#TAG` file-version hash. Re-read the file and copy the `\(HashlineFormat.filePrefix)path\(HashlineFormat.fileHashSep)TAG\(HashlineFormat.fileSuffix)` header into your edit."
            )
        }

        // Apply edits.
        let result = try HashlineApplier.applyEdits(fileContent, edits: section.edits)

        // Noop detection.
        if result.text == fileContent, section.fileOp == nil {
            throw HashlineEditError.noop(path: section.path)
        }

        var warnings = section.warnings
        warnings += result.warnings
        return ApplyResult(
            text: result.text,
            firstChangedLine: result.firstChangedLine,
            warnings: warnings
        )
    }
}
