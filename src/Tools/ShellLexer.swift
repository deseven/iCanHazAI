// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A lexed token plus what the quoting around it says about how the shell
/// will treat it.
struct ShellToken: Equatable {
    let text: String
    /// Produced from an unquoted run of `|&;()<>` — a control operator or a
    /// redirection, as opposed to a word that merely contains those characters
    /// (quoted or escaped).
    let isPunctuation: Bool
    /// Contains a `$` outside single quotes. The shell may substitute it, so
    /// `text` is not what the command will actually receive.
    let expands: Bool
    /// An unquoted run of digits written directly against a following `<` or
    /// `>` (the `2` in `2>&1`), i.e. a file-descriptor prefix rather than an
    /// argument. `2 >&1` has no such token: there the `2` is an argument.
    let isIONumber: Bool
    /// Any part of the token was quoted or backslash-escaped.
    let isQuoted: Bool
}

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
    private var tokenIsPunctuation = false
    private var tokenExpands = false
    private var tokenIsIONumber = false
    private var tokenIsQuoted = false

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
        tokenIsPunctuation = false
        tokenExpands = false
        tokenIsIONumber = false
        tokenIsQuoted = false

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
                    tokenIsPunctuation = true
                } else if Self.quoteChars.contains(c) {
                    state = c == "'" ? .singleQuote : .doubleQuote
                } else {
                    token = String(c)
                    state = .word
                    if c == "$" { tokenExpands = true }
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
                    if c == "$" { tokenExpands = true }
                    token.append(c)
                } else {
                    if c == "<" || c == ">", !tokenIsQuoted,
                        !token.isEmpty, token.allSatisfy({ $0.isASCII && $0.isNumber })
                    {
                        tokenIsIONumber = true
                    }
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
                tokenIsQuoted = true
                guard let c = nextchar else { throw Error.unclosedQuote }
                if c == "'" {
                    state = .word
                } else {
                    token.append(c)
                }

            case .doubleQuote:
                quoted = true
                tokenIsQuoted = true
                guard let c = nextchar else { throw Error.unclosedQuote }
                if c == "\"" {
                    state = .word
                } else if c == Self.escapeChar {
                    escapedState = .doubleQuote
                    state = .escape
                } else {
                    if c == "$" { tokenExpands = true }
                    token.append(c)
                }

            case .escape:
                guard let c = nextchar else { throw Error.danglingEscape }
                // Backslash-newline is a line continuation: the shell drops
                // both characters, so `-\<nl>i` is the single word `-i`.
                if c == "\n" {
                    state = escapedState
                    continue
                }
                tokenIsQuoted = true
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

    mutating func allTokenInfos() throws -> [ShellToken] {
        var tokens: [ShellToken] = []
        while let text = try nextToken() {
            tokens.append(
                ShellToken(
                    text: text, isPunctuation: tokenIsPunctuation, expands: tokenExpands,
                    isIONumber: tokenIsIONumber, isQuoted: tokenIsQuoted))
        }
        return tokens
    }
}

/// One simple command of a (possibly compound) command line: its name and the
/// raw arguments that follow it.
struct ShellSegment: Equatable {
    let command: String
    let args: [String]
    /// False when the shell may rewrite `args` before the command sees them
    /// (`$VAR` expansion), or the segment has a redirection that could write
    /// or read a file, or stray operators. Pattern-based validation of `args`
    /// is meaningless then, so templates refuse such segments. Harmless
    /// redirections (`2>&1`, `>/dev/null`, see `ShellCommandExtractor`) are
    /// dropped from `args` and don't clear this flag.
    let argsAreLiteral: Bool
}

/// Splits a shell command string into simple commands for whitelist checking.
///
/// Returns nil when the command contains constructs too complex to parse safely
/// (command substitution, subshells, loops, conditionals, heredocs, etc.),
/// signaling the caller to require user confirmation. Returns the segments
/// (possibly none) when parsing succeeds.
enum ShellCommandExtractor {

    /// Shell operators that delimit command segments.
    private static let operators: Set<String> = ["|", "||", "&&", ";", "&", "(", ")"]

    /// Patterns that, if present in the raw command, make it too complex to
    /// parse safely — bail (return nil) to require user confirmation.
    private static let bailPatterns: [String] = [
        "$(",  // command substitution
        "${",  // parameter expansion (can contain commands)
        "`",  // backtick command substitution
        "((",  // arithmetic expansion
        "<<<",  // herestring
        "<<",  // heredoc
        "<(",  // process substitution
        ">(",  // process substitution
    ]

    /// Shell keywords that indicate a compound command we can't safely parse.
    /// Checked as the first token of each command segment.
    private static let bailKeywords: Set<String> = [
        "if", "for", "while", "until", "case", "function", "select", "time",
    ]

    /// Extracts the command names from a shell command string.
    static func extractCommands(_ command: String) -> [String]? {
        extractSegments(command)?.map(\.command)
    }

    /// Extracts the simple commands (name + raw args) from a shell command
    /// string, or nil when it is too complex to parse safely.
    static func extractSegments(_ command: String) -> [ShellSegment]? {
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

        var segments: [ShellSegment] = []
        for line in lines {
            if line.allSatisfy({ $0.isWhitespace }) { continue }

            let tokens: [ShellToken]
            do {
                var lexer = ShellLexer(line)
                tokens = try lexer.allTokenInfos()
            } catch {
                return nil
            }

            var currentCmd: String? = nil
            var args: [String] = []
            var literal = true
            func flush() {
                if let cmd = currentCmd {
                    segments.append(ShellSegment(command: cmd, args: args, argsAreLiteral: literal))
                }
                currentCmd = nil
                args = []
                literal = true
            }

            var i = 0
            while i < tokens.count {
                let token = tokens[i]
                if token.isPunctuation && operators.contains(token.text) {
                    flush()
                    i += 1
                } else if let redirect = redirection(in: tokens, at: i) {
                    if let end = redirect.harmlessEnd {
                        i = end
                    } else {
                        // Only the operator is consumed; a target word, if any,
                        // is seen next as an ordinary token.
                        if currentCmd != nil { args += tokens[i..<redirect.operatorEnd].map(\.text) }
                        literal = false
                        i = redirect.operatorEnd
                    }
                } else if currentCmd == nil {
                    if bailKeywords.contains(token.text) { return nil }
                    currentCmd = token.text
                    i += 1
                } else {
                    if token.isPunctuation || token.expands || mayBraceExpand(token.text) { literal = false }
                    args.append(token.text)
                    i += 1
                }
            }
            flush()
        }

        return segments
    }

    /// `{a,b}` / `{1..3}` turn one word into several, which can conjure
    /// option-like words out of a token that doesn't look like one. (A lone
    /// `{u}`, as in `@{u}`, is left alone by the shell.) The lexer doesn't
    /// track quoting per character, so a quoted one is flagged too — the
    /// cost is only an approval prompt.
    private static func mayBraceExpand(_ text: String) -> Bool {
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { return false }
            let inner = rest[rest.index(after: open)..<close]
            if inner.contains(",") || inner.contains("..") { return true }
            rest = rest[rest.index(after: close)...]
        }
        return false
    }

    /// A token is a redirection operator if it is an unquoted run made up
    /// entirely of `><&` chars (e.g. `>`, `>>`, `<`, `>&`, `<&`).
    private static func isRedirection(_ token: ShellToken) -> Bool {
        token.isPunctuation && !token.text.isEmpty && token.text.allSatisfy { "><&".contains($0) }
    }

    /// Parses a redirection at `start`: optional fd prefix, operator, target.
    /// Returns nil when there is none. `operatorEnd` is the index just past
    /// the operator; `harmlessEnd` is the index just past the target when the
    /// whole redirection is on the short list of harmless ones, else nil:
    ///
    /// - fd duplication between stdout and stderr: `2>&1`, `1>&2`, `>&2`
    /// - discarding output: `>/dev/null`, `>>/dev/null`, `2>/dev/null`,
    ///   `&>/dev/null`
    /// - `</dev/null`
    ///
    /// Everything else (any other file, other fds, `>|`, `<>`...) is not.
    private static func redirection(
        in tokens: [ShellToken], at start: Int
    ) -> (operatorEnd: Int, harmlessEnd: Int?)? {
        var j = start
        var fd: String?
        if tokens[j].isIONumber {
            fd = tokens[j].text
            j += 1
        }
        guard j < tokens.count, isRedirection(tokens[j]) else { return nil }
        let op = tokens[j].text
        let operatorEnd = j + 1
        guard operatorEnd < tokens.count else { return (operatorEnd, nil) }
        let target = tokens[operatorEnd]
        guard !target.isPunctuation, !target.expands else { return (operatorEnd, nil) }

        let stdStreams: Set<String?> = [nil, "1", "2"]
        let harmless: Bool
        switch op {
        case ">&":
            // `>&word` writes to a file unless word is a plain digit.
            harmless = !target.isQuoted && ["1", "2"].contains(target.text) && stdStreams.contains(fd)
        case ">", ">>":
            harmless = target.text == "/dev/null" && stdStreams.contains(fd)
        case "&>", "&>>":
            harmless = target.text == "/dev/null" && fd == nil
        case "<":
            harmless = target.text == "/dev/null" && (fd == nil || fd == "0")
        default:
            harmless = false
        }
        return (operatorEnd, harmless ? operatorEnd + 1 : nil)
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
                if char == "\\" {
                    escaped = true
                    current.append(char)
                    continue
                }
                if char == "\"" { inDouble = false }
                current.append(char)
                continue
            }
            if char == "'" {
                inSingle = true
                current.append(char)
                continue
            }
            if char == "\"" {
                inDouble = true
                current.append(char)
                continue
            }
            if char == "\\" {
                escaped = true
                current.append(char)
                continue
            }
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
