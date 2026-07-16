// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Variable substitution for prompt files.
///
/// A prompt may reference variables with `{name}`. At request-build time the
/// engine replaces each known variable with its value; unknown variables are a
/// validation error (the prompt is disabled and surfaced via the config-errors
/// sheet). A literal brace can be produced with `\{` so e.g. `\{text}` is
/// emitted verbatim as `{text}` and never treated as a variable.
///
/// Only `{identifier}`-shaped references are treated as variables — `{` followed
/// by a non-identifier (a quote, a space, a newline, …) is left untouched, so
/// JSON/TOML/code blocks with braces pass through without escaping.
///
/// Prompts are always loaded with their raw text (variables unsubstituted);
/// substitution happens only when building an individual LLM request, so each
/// request gets fresh values (e.g. the current date).
enum PromptVariables {

    /// The set of variables a prompt may reference.
    static let knownVariables: Set<String> = ["output_rendering", "user", "date"]

    // MARK: - Parsing primitives

    /// First character of a variable name (ASCII letter or underscore).
    private static func isNameStart(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
    }

    /// Any character of a variable name (start char or ASCII digit).
    private static func isNameChar(_ c: Character) -> Bool {
        isNameStart(c) || (c >= "0" && c <= "9")
    }

    /// Scans `text` starting at the char after `{`. If the following run is an
    /// identifier immediately closed by `}`, returns `(name, indexAfterBrace)`.
    /// Otherwise returns `nil` (the `{` is not a variable reference).
    private static func readVariable(in chars: [Character], from start: Int) -> (name: String, end: Int)? {
        var j = start
        var name = ""
        while j < chars.count {
            let c = chars[j]
            if name.isEmpty {
                if isNameStart(c) { name.append(c); j += 1 } else { return nil }
            } else {
                if isNameChar(c) { name.append(c); j += 1 } else { break }
            }
        }
        guard !name.isEmpty, j < chars.count, chars[j] == "}" else { return nil }
        return (name, j + 1)
    }

    // MARK: - Validation

    /// Returns the unknown variable names referenced in `text` — unescaped
    /// `{name}` where `name` is an identifier but not in [`knownVariables`](src/PromptVariables.swift).
    /// Escaped `\{…}` and non-identifier braces (e.g. JSON objects) are ignored.
    /// Duplicates are collapsed; the order of first appearance is preserved.
    static func unknownVariables(in text: String) -> [String] {
        let chars = Array(text)
        var i = 0
        var found: [String] = []
        var seen = Set<String>()
        while i < chars.count {
            let c = chars[i]
            // Escaped brace: skip the backslash and the brace, never a variable.
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "{" {
                i += 2
                continue
            }
            if c == "{", let v = readVariable(in: chars, from: i + 1) {
                if !knownVariables.contains(v.name), !seen.contains(v.name) {
                    seen.insert(v.name)
                    found.append(v.name)
                }
                i = v.end
                continue
            }
            i += 1
        }
        return found
    }

    /// A human-readable message for a set of unknown variable names, e.g.
    /// `unknown prompt variable {foo}` or `unknown prompt variables {foo}, {bar}`.
    static func unknownVariablesMessage(_ names: [String]) -> String {
        let vars = names.map { "{\($0)}" }.joined(separator: ", ")
        return "unknown prompt variable\(names.count > 1 ? "s" : "") \(vars)"
    }

    /// The known variables as a comma-separated `{name}` list, for error hints.
    static var knownVariablesList: String {
        knownVariables.sorted().map { "{\($0)}" }.joined(separator: ", ")
    }

    // MARK: - Substitution

    /// Replaces known variables in `text` using `values`. Escaped `\{` becomes a
    /// literal `{`; unknown variables are left verbatim (they should have been
    /// caught by validation, but leaving them is safer than dropping text).
    static func substitute(text: String, values: [String: String]) -> String {
        let chars = Array(text)
        var i = 0
        var result = ""
        result.reserveCapacity(text.count)
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "{" {
                result.append("{")
                i += 2
                continue
            }
            if c == "{", let v = readVariable(in: chars, from: i + 1) {
                if let value = values[v.name] {
                    result.append(value)
                } else {
                    result.append("{")
                    result.append(v.name)
                    result.append("}")
                }
                i = v.end
                continue
            }
            result.append(c)
            i += 1
        }
        return result
    }

    // MARK: - Variable values

    /// The `{output_rendering}` value: a description of the chat renderer's
    /// capabilities, built from the current feature toggles so disabled
    /// features are not advertised to the model.
    static func renderingCapabilities(mermaid: Bool, katex: Bool) -> String {
        var lines: [String] = [
            "Your responses are rendered in a chat UI with the following features:",
            "- GitHub-Flavored Markdown (tables, strikethrough, task lists, autolinks)",
            "- Syntax-highlighted code blocks (fenced with a language tag)",
        ]
        if katex {
            lines.append("- LaTeX math via KaTeX: use `$...$` for inline and `$$...$$` for block equations")
        } else {
            lines.append("- LaTeX math is NOT supported")
        }
        if mermaid {
            lines.append("- Mermaid diagrams: use a fenced code block with language `mermaid`")
        } else {
            lines.append("- Mermaid diagrams are NOT supported")
        }
        lines.append(contentsOf: [
            "- Inline HTML is allowed",
            "",
            "Use these features where appropriate to make your answers clearer.",
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    /// The `{user}` value: the current system user name (the last path
    /// component of the home directory, e.g. `/Users/alice` → `alice`).
    static func currentUserName() -> String {
        (NSHomeDirectory() as NSString).lastPathComponent
    }

    /// The `{date}` value: the current date formatted as `Thu Jun 16 2026`.
    static func currentDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d yyyy"
        return formatter.string(from: Date())
    }
}
