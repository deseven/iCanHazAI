// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Minimal JSONC (JSON with comments) preprocessor and parser.
///
/// Connection config files use `.jsonc` so they can carry inline documentation
/// and trailing commas. `JSONSerialization` does not understand comments or
/// trailing commas, so this preprocessor strips them before delegating to
/// `JSONSerialization` / `JSONDecoder`.
///
/// Supported syntax:
/// - `//` single-line comments (not inside strings)
/// - `/* ... */` block comments (not inside strings)
/// - trailing commas before `}` and `]` (not inside strings)
enum JSONC {

    /// Strips `//` and `/* */` comments and trailing commas from a JSONC
    /// string, returning plain JSON text. String literals are respected so
    /// that `//` or `/*` inside a JSON string value is left untouched.
    static func preprocess(_ source: String) -> String {
        var output = ""
        output.reserveCapacity(source.count)
        var i = source.startIndex
        let end = source.endIndex

        var inString = false
        var escape = false

        while i < end {
            let ch = source[i]
            let next = source.index(after: i)

            if inString {
                output.append(ch)
                if escape {
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
                i = next
                continue
            }

            // Not inside a string.
            if ch == "\"" {
                inString = true
                output.append(ch)
                i = next
                continue
            }
            // Line comment `//` → skip to end of line.
            if ch == "/", next < end, source[next] == "/" {
                i = next
                while i < end, source[i] != "\n" {
                    i = source.index(after: i)
                }
                continue
            }
            // Block comment `/* ... */` → skip to closing `*/`.
            if ch == "/", next < end, source[next] == "*" {
                i = next
                // Advance past `*`.
                i = source.index(after: i)
                while i < end {
                    if source[i] == "*", source.index(after: i) < end, source[source.index(after: i)] == "/" {
                        i = source.index(after: i) // past `*`
                        i = source.index(after: i) // past `/`
                        break
                    }
                    i = source.index(after: i)
                }
                continue
            }
            output.append(ch)
            i = next
        }

        return stripTrailingCommas(output)
    }

    /// Removes trailing commas that appear immediately before `}` or `]`,
    /// ignoring whitespace between the comma and the closing bracket.
    static func stripTrailingCommas(_ source: String) -> String {
        var output = ""
        output.reserveCapacity(source.count)
        var i = source.startIndex
        let end = source.endIndex

        var inString = false
        var escape = false

        while i < end {
            let ch = source[i]
            let next = source.index(after: i)

            if inString {
                output.append(ch)
                if escape {
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
                i = next
                continue
            }

            if ch == "\"" {
                inString = true
                output.append(ch)
                i = next
                continue
            }

            if ch == "," {
                // Look ahead (skipping whitespace) for `}` or `]`.
                var j = next
                while j < end, source[j].isWhitespace {
                    j = source.index(after: j)
                }
                if j < end, (source[j] == "}" || source[j] == "]") {
                    // Drop the comma; preserve following whitespace by not
                    // emitting the comma here.
                    i = next
                    continue
                }
            }

            output.append(ch)
            i = next
        }

        return output
    }

    // MARK: - Parsing

    /// Parses JSONC text into a plain `Any` (as returned by
    /// `JSONSerialization`). Returns nil on failure.
    static func parse(_ source: String) -> Any? {
        let json = preprocess(source)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Parses JSONC text into a `Decodable` type. Returns nil on failure.
    static func parse<T: Decodable>(_ source: String, as type: T.Type) -> T? {
        let json = preprocess(source)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Parses JSONC `Data` into a `Decodable` type. Returns nil on failure.
    static func parse<T: Decodable>(_ data: Data, as type: T.Type) -> T? {
        guard let source = String(data: data, encoding: .utf8) else { return nil }
        return parse(source, as: type)
    }
}
