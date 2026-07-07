import Foundation

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
