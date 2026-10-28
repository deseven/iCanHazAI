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

    /// A strong 16-hex (64-bit) identity of the same normalized text the tag
    /// hashes. The 4-hex tag stays model-facing; this one never collides in
    /// practice, so internal bookkeeping can compare versions by it.
    static func computeContentID(_ text: String) -> String {
        let normalized = normalizeFileHashText(text)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02X", $0) }.joined()
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

    /// Splits text on `\n` (UTF-16 literal match). `String.split(separator: "\n")`
    /// and `Character == "\n"` must not be used on file text: `"\r\n"` is a
    /// single `Character`, so a CRLF file would never split. Always yields at
    /// least one element; a terminal newline yields a trailing `""`.
    static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Drops one trailing `\r` left over after splitting CRLF text on `\n`.
    static func dropTrailingCR(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    /// Split LF-normalized file text into lines hashline anchors can address.
    /// A terminal newline terminates the preceding line; it is not content, so
    /// the phantom empty element after it is dropped. `""` still yields one
    /// empty line — callers treat an empty file separately.
    static func splitAddressableFileLines(_ text: String) -> [String] {
        var lines = splitLines(text)
        if lines.count > 1 && lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// Format file text with hashline-mode line-number prefixes for display.
    static func formatNumberedLines(_ text: String, startLine: Int = 1) -> String {
        splitLines(text).enumerated().map { i, line in
            formatNumberedLine(lineNumber: startLine + i, content: line)
        }.joined(separator: "\n")
    }

    // MARK: - Prefix stripping

    /// Regex for a leading line-number prefix (`N:` or `N|`), optionally with
    /// leading whitespace or `>>>`/`>>` markers. Group 1 is the number.
    private static let prefixRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:>>>|>>)?\s*(?:[+*-]\s*)?(\d+)[:|]"#
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

    /// Regex for the plain notices `read_file` prints in place of or after rows.
    private static let readNoticeRegex = try! NSRegularExpression(
        pattern:
            #"^\s*(?:\.\.\. \(truncated at \d+ lines\)|\(empty file\)|\(offset \d+ is past the end of the file: \d+ lines?\))\s*$"#
    )

    /// Whether a row is display-only metadata emitted by `read`, never source.
    static func isReadMetadataLine(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return truncationNoticeRegex.firstMatch(in: line, range: range) != nil
            || rangeElisionRegex.firstMatch(in: line, range: range) != nil
            || singleElisionRegex.firstMatch(in: line, range: range) != nil
            || readNoticeRegex.firstMatch(in: line, range: range) != nil
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

    /// The line number of a leading hashline prefix, nil when there is none.
    static func leadingLineNumber(_ line: String) -> Int? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = prefixRegex.firstMatch(in: line, range: range),
            let digits = Range(match.range(at: 1), in: line)
        else { return nil }
        return Int(line[digits])
    }

    /// Whether a line is a hashline header (`[path#TAG]`).
    static func isHashlineHeader(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return headerRegex.firstMatch(in: line, range: range) != nil
    }

    /// Strip pasted `read_file` output from `write_file` content. Content is
    /// only touched on positive evidence of a paste, since `8080:80` or
    /// `12:00 standup` are legitimate file lines:
    /// - a leading `[path#TAG]` header (also drops read notices and, when every
    ///   content row is numbered, the `N:` prefixes), or
    /// - no header, but every content row is numbered, there are at least two
    ///   of them, and the numbers run consecutively from 1 (a whole-file read).
    static func stripPastedPrefixes(_ content: String) -> (content: String, stripped: Bool) {
        var lines = splitLines(content)
        var hadHeader = false
        while let first = lines.first, isHashlineHeader(first) {
            lines.removeFirst()
            hadHeader = true
        }

        var numbers: [Int] = []
        var allNumbered = true
        for line in lines where !(line.isEmpty || line == "\r") && !isReadMetadataLine(line) {
            if let number = leadingLineNumber(line) {
                numbers.append(number)
            } else {
                allNumbered = false
            }
        }
        let consecutiveFromOne =
            numbers.count >= 2 && numbers[0] == 1
            && zip(numbers, numbers.dropFirst()).allSatisfy { $1 == $0 + 1 }
        let stripPrefixes = allNumbered && !numbers.isEmpty && (hadHeader || consecutiveFromOne)

        guard hadHeader || stripPrefixes else { return (content, false) }
        lines = lines.filter { !isReadMetadataLine($0) }
        if stripPrefixes {
            lines = lines.map { stripOneLeadingHashlinePrefix($0) }
        }
        return (lines.joined(separator: "\n"), true)
    }

    static let strippedPastedPrefixesNote = "Note: stripped pasted read_file line-number prefixes before writing."
}
