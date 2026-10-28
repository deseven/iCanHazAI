// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Errors from the hashline edit pipeline.
enum HashlineEditError: Error, LocalizedError {
    case parseError(String)
    case hashMismatch(path: String, expected: String)
    case applyError(String)
    case noop(path: String)

    var errorDescription: String? {
        switch self {
        case .parseError(let msg):
            return msg
        case .hashMismatch(let path, let expected):
            return
                "File \(path) has changed since you last read it (expected tag #\(expected)). Re-read the file and retry."
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

    /// One `[path#TAG]` header and the raw body lines under it.
    private struct RawSection {
        let path: String
        var fileHash: String?
        var lines: [String]
    }

    /// Parse a full hashline patch input (envelope + sections) into a
    /// `ParsedPatch` with one `HashlineSection` per distinct path. Sections
    /// naming the same path are merged at text level before parsing, so all
    /// per-section validation (file ops, overlapping ranges) sees the whole
    /// batch.
    static func parse(_ input: String) throws -> ParsedPatch {
        let raw = try splitRawSections(HashlineTokenizer.splitHashlineLines(input))

        var sections: [HashlineSection] = []
        for section in try mergeSamePath(raw) {
            let result: HashlineParser.ParseResult
            do {
                result = try HashlineParser.parsePatch(section.lines.joined(separator: "\n"))
            } catch let error as HashlineParseError {
                throw HashlineEditError.parseError("[\(section.path)] \(error.localizedDescription)")
            }
            sections.append(
                HashlineSection(
                    path: section.path,
                    fileHash: section.fileHash,
                    edits: result.edits,
                    fileOp: result.fileOp,
                    warnings: result.warnings
                ))
        }
        return ParsedPatch(sections: sections)
    }

    private static func headerExample() -> String {
        "`\(HashlineFormat.filePrefix)src/foo.ts\(HashlineFormat.fileHashSep)1A2B\(HashlineFormat.fileSuffix)`"
    }

    private static func preview(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }

    /// Split the patch into header-led sections. Anything but blank lines and
    /// the envelope before the first header is an error, and so is any line
    /// that looks like a header but isn't one — silently treating it as body
    /// text would route the following ops to the wrong file. Sections without
    /// ops are dropped.
    private static func splitRawSections(_ lines: [String]) throws -> [RawSection] {
        var sections: [RawSection] = []
        var current: RawSection?
        var sawHeader = false

        func flush() {
            guard let section = current else { return }
            current = nil
            if section.lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                sections.append(section)
            }
        }

        loop: for line in lines {
            switch HashlineTokenizer.tokenize(line) {
            case .envelopeEnd: break loop
            case .envelopeBegin: continue loop
            case .abort: throw HashlineEditError.parseError(HashlineFormat.patchAbortedMessage)
            default: break
            }

            if line.hasPrefix(HashlineFormat.filePrefix) {
                guard let header = HashlineTokenizer.tryParseHeader(line) else {
                    throw HashlineEditError.parseError(
                        "Input header must be `\(HashlineFormat.filePrefix)PATH\(HashlineFormat.fileHashSep)TAG\(HashlineFormat.fileSuffix)` with a \(HashlineFormat.fileHashLength)-hex tag; got `\(preview(line))`."
                    )
                }
                flush()
                current = RawSection(path: header.path, fileHash: header.fileHash, lines: [])
                sawHeader = true
                continue
            }

            if current == nil {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                if let foreign = HashlineParser.detectForeignPatchSyntax(line) {
                    throw HashlineEditError.parseError(foreign)
                }
                throw missingHeaderError(got: line)
            }
            current?.lines.append(line)
        }
        flush()

        guard sawHeader else { throw missingHeaderError(got: nil) }
        guard !sections.isEmpty else {
            throw HashlineEditError.parseError(
                "The patch has no operations: every header is empty. Add `\(HashlineFormat.putKeyword)`/`\(HashlineFormat.cutKeyword)`/`\(HashlineFormat.remKeyword)`/`\(HashlineFormat.moveKeyword)` ops under a header."
            )
        }
        return sections
    }

    private static func missingHeaderError(got line: String?) -> HashlineEditError {
        let found = line.map { " Got: `\(preview($0))`." } ?? ""
        return .parseError(
            "Input must begin with `\(HashlineFormat.filePrefix)PATH\(HashlineFormat.fileHashSep)HASH\(HashlineFormat.fileSuffix)` on the first non-blank line.\(found) Example: \(headerExample()) then edit ops."
        )
    }

    /// Collapse sections targeting the same path into one with concatenated
    /// bodies. Anchors authored against the same file snapshot must apply as
    /// one batch; otherwise the first sub-edit shifts line numbers out from
    /// under the second's anchors (or advances the #TAG), so the later section
    /// fails the stale-tag check after the first already landed — a
    /// half-applied, non-atomic edit. Order is preserved by first occurrence.
    private static func mergeSamePath(_ sections: [RawSection]) throws -> [RawSection] {
        var merged: [RawSection] = []
        var indexByPath: [String: Int] = [:]

        for section in sections {
            guard let index = indexByPath[section.path] else {
                indexByPath[section.path] = merged.count
                merged.append(section)
                continue
            }
            if let existingHash = merged[index].fileHash, let sectionHash = section.fileHash,
                existingHash != sectionHash
            {
                throw HashlineEditError.parseError(
                    "Conflicting hashline snapshot tags for \(section.path): #\(existingHash) and #\(sectionHash). Re-read the file and retry with one current header."
                )
            }
            merged[index].fileHash = merged[index].fileHash ?? section.fileHash
            merged[index].lines += section.lines
        }
        return merged
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
                    expected: expectedHash
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
            warnings: warnings,
            origins: result.origins
        )
    }
}
