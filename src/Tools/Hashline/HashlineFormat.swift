// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

/// Format primitives: sigils, separators, hash function, and display helpers.
/// Single source of truth for the parser, tokenizer, prompt, and grammar.
enum HashlineFormat {

    // MARK: - Sigils and separators

    static let filePrefix = "["
    static let fileSuffix = "]"
    static let fileHashSep = "#"
    static let payloadReplace = "+"
    static let putKeyword = "PUT"
    static let cutKeyword = "CUT"
    static let remKeyword = "REM"
    static let moveKeyword = "MV"
    static let headerColon = ":"
    static let gapBefore = "<"
    static let gapAfter = ">"
    static let eofAnchor = "$"
    static let rangeSep = ".="
    static let lineBodySep = ":"

    static let beginPatch = "*** Begin Patch"
    static let endPatch = "*** End Patch"
    static let abortMarker = "*** Abort"

    /// Number of hex characters in a content-derived file-hash tag.
    static let fileHashLength = 4

    // MARK: - Hash function

    /// Normalize text before hashing: trim trailing `[ \t\r]` from every line
    /// so CRLF endings and display-trimmed lines do not invalidate a tag.
    static func normalizeFileHashText(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            lines[i] = lines[i].replacingOccurrences(of: "[ \t\r]+$", with: "", options: .regularExpression)
        }
        return lines.joined(separator: "\n")
    }

    /// Compute the content-derived hash tag. A 4-hex fingerprint of the whole
    /// file's normalized text: byte-identical content mints the same tag.
    static func computeFileHash(_ text: String) -> String {
        let normalized = normalizeFileHashText(text)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let bytes = digest.withUnsafeBytes { Array($0) }
        let low2 = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return String(format: "%04X", low2)
    }

    // MARK: - Display helpers

    /// Format a hashline section header for a file path and snapshot tag.
    static func formatHashlineHeader(path: String, fileHash: String) -> String {
        "\(filePrefix)\(path)\(fileHashSep)\(fileHash)\(fileSuffix)"
    }

    /// Formats a single numbered line as `LINE:TEXT`.
    static func formatNumberedLine(lineNumber: Int, content: String) -> String {
        "\(lineNumber)\(lineBodySep)\(content)"
    }

    /// Split LF-delimited file text into lines hashline anchors can address.
    /// A terminal newline terminates the preceding line; it is not content.
    static func splitAddressableFileLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1 && lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// Format file text with hashline-mode line-number prefixes for display.
    static func formatNumberedLines(_ text: String, startLine: Int = 1) -> String {
        text.components(separatedBy: "\n").enumerated().map { i, line in
            formatNumberedLine(lineNumber: startLine + i, content: line)
        }.joined(separator: "\n")
    }

    // MARK: - Prefix stripping

    /// Regex for a leading line-number prefix (`N:` or `N|`), optionally with
    /// leading whitespace or `>>>`/`>>` markers.
    private static let prefixRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:>>>|>>)?\s*(?:[+*-]\s*)?\d+[:|]"#
    )

    /// Regex for a hashline header line (`[path#TAG]`).
    private static let headerRegex = try! NSRegularExpression(
        pattern: #"^\s*\[[^#\r\n]+#[0-9a-fA-F]{4}\]\s*$"#
    )

    /// Regex for read truncation notice lines emitted by `read_file`.
    private static let truncationNoticeRegex = try! NSRegularExpression(
        pattern:
            #"^\s*\[(?:(?:Showing lines \d+-\d+ of \d+|\d+ more lines? in (?:file|\S+))\b.*\bUse :L?\d+|(?:…|\.\.\.)?\d+\s*ln elided;\s*re-read needed ranges with .+)\]\s*$"#
    )

    /// Regex for read range elision lines (`N-M:...`).
    private static let rangeElisionRegex = try! NSRegularExpression(
        pattern: #"^\s*[1-9]\d*\s*-\s*[1-9]\d*:.*(?:…|\.\.\.).*$"#
    )

    /// Regex for single-line elision (`…` or `...`).
    private static let singleElisionRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:…|\.\.\.)\s*$"#
    )

    /// Whether a row is display-only metadata emitted by `read`, never source.
    static func isReadMetadataLine(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return truncationNoticeRegex.firstMatch(in: line, range: range) != nil
            || rangeElisionRegex.firstMatch(in: line, range: range) != nil
            || singleElisionRegex.firstMatch(in: line, range: range) != nil
    }

    /// Strip a single leading line-number prefix (`N:`, `N|`, `>>>N:`, `+N:`).
    /// Does not loop — at most one prefix is removed.
    static func stripOneLeadingHashlinePrefix(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = prefixRegex.firstMatch(in: line, range: range) else {
            return line
        }
        let r = Range(match.range, in: line)!
        return String(line[r.upperBound...])
    }

    /// Whether a line carries a hashline line-number prefix.
    static func hasHashlinePrefix(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return prefixRegex.firstMatch(in: line, range: range) != nil
    }

    /// Whether a line is a hashline header (`[path#TAG]`).
    static func isHashlineHeader(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return headerRegex.firstMatch(in: line, range: range) != nil
    }

    /// Strict strip: remove hashline prefixes only when every non-empty content
    /// line carries one. Returns the lines unchanged otherwise.
    static func stripHashlinePrefixes(_ lines: [String]) -> [String] {
        var nonEmpty = 0
        var headerCount = 0
        var prefixCount = 0
        for line in lines {
            if line.isEmpty { continue }
            if isHashlineHeader(line) {
                nonEmpty += 1
                headerCount += 1
                continue
            }
            nonEmpty += 1
            if hasHashlinePrefix(line) { prefixCount += 1 }
        }
        let contentCount = nonEmpty - headerCount
        guard contentCount > 0, prefixCount == contentCount else { return lines }

        return lines.filter { line in
            !isReadMetadataLine(line) && !isHashlineHeader(line)
        }.map { line in
            stripOneLeadingHashlinePrefix(line)
        }
    }

    /// Strip pasted `read_file` output (header + line-number prefixes) from
    /// content before writing. Removes a leading `[path#TAG]` header line and
    /// uniform `N:` prefixes from all content lines.
    static func stripPastedPrefixes(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")

        // Remove leading header line(s).
        while let first = lines.first, isHashlineHeader(first) {
            lines.removeFirst()
        }

        // Remove read metadata lines.
        lines = lines.filter { !isReadMetadataLine($0) }

        // Strip uniform line-number prefixes.
        lines = stripHashlinePrefixes(lines)

        return lines.joined(separator: "\n")
    }
}
