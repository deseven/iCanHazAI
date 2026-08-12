// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A shell-like tokenizer ported from Python's `shlex` module, configured for
/// POSIX mode with `punctuation_chars='|&;()<>'`. Quote-aware: single and
/// double quotes are respected (operators inside quotes are not treated as
/// operators). Throws on unclosed quotes or dangling escapes.
struct ShellLexer {
    enum Error: Swift.Error {
        case unclosedQuote
        case danglingEscape
    }

    private let chars: [Character]
    private var index: Int = 0
    private var pushback: [Character] = []

    private static let punctuationChars: Set<Character> = ["|", "&", ";", "(", ")", "<", ">"]
    private static let whitespaceChars: Set<Character> = [" ", "\t", "\r", "\n"]
    private static let quoteChars: Set<Character> = ["'", "\""]
    private static let escapeChar: Character = "\\"

    /// Word characters: alphanumerics, underscore, plus `~-./*?=` (added when
    /// punctuation_chars is set, minus any punctuation chars).
    private static let wordChars: Set<Character> = {
        var wc = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_~-./*?=")
        for c in punctuationChars { wc.remove(c) }
        return wc
    }()

    private enum State {
        case whitespace
        case word
        case punctuation
        case singleQuote
        case doubleQuote
        case escape
    }

    init(_ s: String) {
        self.chars = Array(s)
    }

    private mutating func nextChar() -> Character? {
        if !pushback.isEmpty {
            return pushback.removeLast()
        }
        guard index < chars.count else { return nil }
        let c = chars[index]
        index += 1
        return c
    }

    /// Returns the next token, or nil at end of input. Throws on unclosed
    /// quotes or dangling escapes. An empty quoted string (`""`) produces an
    /// empty-string token (distinct from nil).
    mutating func nextToken() throws -> String? {
        var token = ""
        var quoted = false
        var state: State = .whitespace
        var escapedState: State = .whitespace

        while true {
            let nextchar = nextChar()

            switch state {
            case .whitespace:
                guard let c = nextchar else { return nil }
                if Self.whitespaceChars.contains(c) {
                    continue
                } else if c == Self.escapeChar {
                    escapedState = .word
                    state = .escape
                } else if Self.wordChars.contains(c) {
                    token = String(c)
                    state = .word
                } else if Self.punctuationChars.contains(c) {
                    token = String(c)
                    state = .punctuation
                } else if Self.quoteChars.contains(c) {
                    state = c == "'" ? .singleQuote : .doubleQuote
                } else {
                    token = String(c)
                    state = .word
                }

            case .word:
                guard let c = nextchar else {
                    if token.isEmpty && !quoted { return nil }
                    return token
                }
                if Self.whitespaceChars.contains(c) {
                    state = .whitespace
                    if !token.isEmpty || quoted { return token }
                    continue
                } else if Self.quoteChars.contains(c) {
                    state = c == "'" ? .singleQuote : .doubleQuote
                } else if c == Self.escapeChar {
                    escapedState = .word
                    state = .escape
                } else if Self.wordChars.contains(c) || !Self.punctuationChars.contains(c) {
                    token.append(c)
                } else {
                    pushback.append(c)
                    state = .whitespace
                    if !token.isEmpty || quoted { return token }
                    continue
                }

            case .punctuation:
                guard let c = nextchar else { return token }
                if Self.punctuationChars.contains(c) {
                    token.append(c)
                } else {
                    if !Self.whitespaceChars.contains(c) {
                        pushback.append(c)
                    }
                    state = .whitespace
                    return token
                }

            case .singleQuote:
                quoted = true
                guard let c = nextchar else { throw Error.unclosedQuote }
                if c == "'" {
                    state = .word
                } else {
                    token.append(c)
                }

            case .doubleQuote:
                quoted = true
                guard let c = nextchar else { throw Error.unclosedQuote }
                if c == "\"" {
                    state = .word
                } else if c == Self.escapeChar {
                    escapedState = .doubleQuote
                    state = .escape
                } else {
                    token.append(c)
                }

            case .escape:
                guard let c = nextchar else { throw Error.danglingEscape }
                if escapedState == .singleQuote || escapedState == .doubleQuote {
                    let quoteChar: Character = escapedState == .doubleQuote ? "\"" : "'"
                    if c != Self.escapeChar && c != quoteChar {
                        token.append(Self.escapeChar)
                    }
                }
                token.append(c)
                state = escapedState
            }
        }
    }

    mutating func allTokens() throws -> [String] {
        var tokens: [String] = []
        while let token = try nextToken() {
            tokens.append(token)
        }
        return tokens
    }
}

/// Extracts command names from a shell command string for whitelist checking.
///
/// Returns nil when the command contains constructs too complex to parse safely
/// (command substitution, subshells, loops, conditionals, heredocs, etc.),
/// signaling the caller to require user confirmation. Returns an array of
/// command names (possibly empty) when parsing succeeds.
enum ShellCommandExtractor {

    /// Shell operators that delimit command segments.
    private static let operators: Set<String> = ["|", "||", "&&", ";", "&", "(", ")"]

    /// Patterns that, if present in the raw command, make it too complex to
    /// parse safely — bail (return nil) to require user confirmation.
    private static let bailPatterns: [String] = [
        "$(",   // command substitution
        "${",   // parameter expansion (can contain commands)
        "`",    // backtick command substitution
        "((",   // arithmetic expansion
        "<<<",  // herestring
        "<<",   // heredoc
        "<(",   // process substitution
        ">(",   // process substitution
    ]

    /// Shell keywords that indicate a compound command we can't safely parse.
    /// Checked as the first token of each command segment.
    private static let bailKeywords: Set<String> = [
        "if", "for", "while", "until", "case", "function", "select", "time",
    ]

    /// Extracts the command names from a shell command string.
    ///
    /// Returns nil when the command contains constructs too complex to parse
    /// safely, signaling the caller to require user confirmation. Returns an
    /// array of command names (possibly empty for whitespace-only or
    /// operator-only commands) when parsing succeeds.
    static func extractCommands(_ command: String) -> [String]? {
        // Pre-check for complex constructs in the raw string.
        for pattern in bailPatterns {
            if command.contains(pattern) { return nil }
        }
        // Check for command groups ({ ... }) and bash test ([[ ... ]).
        if command.contains(" {") || command.hasPrefix("{ ") { return nil }
        if command.contains("[[ ") { return nil }

        // Split on unquoted newlines (each line is a separate command
        // sequence). Newlines inside quotes are preserved within a line.
        let lines = splitOnUnquotedNewlines(command)

        var allCommands: [String] = []
        for line in lines {
            if line.allSatisfy({ $0.isWhitespace }) { continue }

            let tokens: [String]
            do {
                var lexer = ShellLexer(line)
                tokens = try lexer.allTokens()
            } catch {
                return nil
            }

            var currentCmd: String? = nil
            for (i, token) in tokens.enumerated() {
                if operators.contains(token) {
                    if let cmd = currentCmd { allCommands.append(cmd) }
                    currentCmd = nil
                } else if isRedirection(token) {
                    continue
                } else if isFdPrefix(token, nextToken: i + 1 < tokens.count ? tokens[i + 1] : nil) {
                    continue
                } else if currentCmd == nil {
                    if bailKeywords.contains(token) { return nil }
                    currentCmd = token
                }
            }
            if let cmd = currentCmd { allCommands.append(cmd) }
        }

        return allCommands
    }

    /// A token is a redirection operator if it consists entirely of `><&` chars
    /// (e.g. `>`, `>>`, `<`, `>&`, `<&`).
    private static func isRedirection(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { "><&".contains($0) }
    }

    /// A token is a file-descriptor prefix if it's all digits and the next
    /// token is a redirection operator (e.g. `2` before `>` in `2>&1`).
    private static func isFdPrefix(_ token: String, nextToken: String?) -> Bool {
        guard !token.isEmpty, token.allSatisfy(\.isNumber) else { return false }
        return nextToken.map { isRedirection($0) } ?? false
    }

    /// Splits a command string on newlines that are outside of quotes.
    /// Newlines inside single or double quotes (or escaped with `\`) are
    /// preserved within a line, so the lexer sees them as part of a quoted
    /// token rather than a command separator.
    private static func splitOnUnquotedNewlines(_ s: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false

        for char in s {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if inSingle {
                if char == "'" { inSingle = false }
                current.append(char)
                continue
            }
            if inDouble {
                if char == "\\" { escaped = true; current.append(char); continue }
                if char == "\"" { inDouble = false }
                current.append(char)
                continue
            }
            if char == "'" { inSingle = true; current.append(char); continue }
            if char == "\"" { inDouble = true; current.append(char); continue }
            if char == "\\" { escaped = true; current.append(char); continue }
            if char == "\n" {
                lines.append(current)
                current = ""
                continue
            }
            current.append(char)
        }
        lines.append(current)
        return lines
    }
}
