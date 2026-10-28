// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Net count of opening minus closing `()` / `[]` / `{}` over a run of lines.
/// Used by the boundary-echo repairs as evidence: a repair may only drop
/// payload lines when doing so keeps the delimiters of the result balanced.
struct DelimiterBalance: Equatable {
    var paren = 0
    var bracket = 0
    var brace = 0

    var isZero: Bool { paren == 0 && bracket == 0 && brace == 0 }

    var negated: DelimiterBalance {
        DelimiterBalance(paren: -paren, bracket: -bracket, brace: -brace)
    }

    static func + (lhs: DelimiterBalance, rhs: DelimiterBalance) -> DelimiterBalance {
        DelimiterBalance(
            paren: lhs.paren + rhs.paren, bracket: lhs.bracket + rhs.bracket, brace: lhs.brace + rhs.brace)
    }

    static func - (lhs: DelimiterBalance, rhs: DelimiterBalance) -> DelimiterBalance {
        lhs + rhs.negated
    }
}

extension DelimiterBalance {
    /// Counts delimiters across `lines`, skipping those inside `//` line
    /// comments, `/* */` block comments, and string/template literals.
    /// Block-comment and backtick state carries across lines; `"` and `'`
    /// reset at the end of a line since they cannot span lines.
    ///
    /// Deliberately language-light: constructs it cannot classify (regex
    /// literals, `#` comments, Rust lifetimes) are counted naively, which at
    /// worst suppresses a repair — a repair is never forced by a miscount
    /// alone, since the caller also requires exact textual equality.
    init<Lines: Sequence>(counting lines: Lines) where Lines.Element == String {
        self.init()
        var inBlockComment = false
        var quote: Unicode.Scalar?
        let none: Unicode.Scalar = "\u{0}"

        for line in lines {
            let scalars = Array(line.unicodeScalars)
            var i = 0
            scan: while i < scalars.count {
                let ch = scalars[i]
                let next = i + 1 < scalars.count ? scalars[i + 1] : none

                if inBlockComment {
                    if ch == "*" && next == "/" {
                        inBlockComment = false
                        i += 1
                    }
                    i += 1
                    continue
                }
                if let open = quote {
                    if ch == "\\" {
                        i += 1
                    } else if ch == open {
                        quote = nil
                    }
                    i += 1
                    continue
                }

                switch ch {
                case "\"", "'", "`": quote = ch
                case "/" where next == "/": break scan
                case "/" where next == "*":
                    inBlockComment = true
                    i += 1
                case "(": paren += 1
                case ")": paren -= 1
                case "[": bracket += 1
                case "]": bracket -= 1
                case "{": brace += 1
                case "}": brace -= 1
                default: break
                }
                i += 1
            }
            if quote == "\"" || quote == "'" { quote = nil }
        }
    }
}
