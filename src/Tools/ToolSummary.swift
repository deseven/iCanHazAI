// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CoreFoundation

/// Single-line, human-readable summaries of tool calls and their results —
/// the backend counterpart of the chat renderer's collapsed tool-call block.
/// The engine stamps these onto `ToolCall.summary` / `ToolResult.summary`
/// (persisted in the chat data) so every surface — the chat renderer and the
/// CLI — renders the same text without re-deriving it.
///
/// For internal tools we know which arguments matter (path for read_file, the
/// command for shell, the affected paths for apply_patch, ...). For everything
/// else we fall back to `key: value` pairs ordered required-first (the engine
/// stamps the schema's `required` list onto each ToolCall), then optional;
/// without that list the JSON key order is preserved.
enum ToolSummary {

    /// One piece of the collapsed argument summary. `key: nil` marks a tool's
    /// primary argument, rendered as a bare value (e.g. the path for
    /// read_file); everything else renders as `key: value`.
    struct Entry: Equatable, Sendable {
        let key: String?
        /// Single-line value (newlines already collapsed to ⏎).
        let value: String
    }

    /// The persisted one-line status summary of a finished tool call —
    /// `tool_call_result_summary` in the chat data. Only final states are
    /// stored (done/error/denied/cancelled); transient states (pending,
    /// running) are derived live by each surface.
    struct Status: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case pending, running, done, error, denied, cancelled
        }
        let kind: Kind
        /// Badge text shown before the description ("done", "error", ...).
        let label: String
        /// Single-line description (error text, denial reason, result gist).
        /// May be empty when there's nothing meaningful to say.
        let description: String
    }

    // MARK: - Public API

    /// The collapsed argument summary of a tool call, as display entries.
    static func callEntries(name: String, arguments: String, requiredArgs: [String]? = nil) -> [Entry] {
        guard let obj = parseJSONObject(arguments) else {
            // Not a JSON object (malformed or still streaming): show the raw
            // string if there's anything to show.
            let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [Entry(key: nil, value: oneLine(trimmed))]
        }
        if let known = knownToolSummary(name: name, obj: obj) {
            return known
        }
        return genericSummary(entries: parseArgs(arguments, object: obj), requiredArgs: requiredArgs)
    }

    /// The collapsed argument summary as a single pre-joined line, e.g.
    /// `src/main.swift · offset: 10`. This is what gets persisted on
    /// `ToolCall.summary`.
    static func callLine(name: String, arguments: String, requiredArgs: [String]? = nil) -> String {
        callEntries(name: name, arguments: arguments, requiredArgs: requiredArgs)
            .map { entry in
                guard let key = entry.key else { return entry.value }
                return "\(key): \(entry.value)"
            }
            .joined(separator: " · ")
    }

    /// The status summary for a final tool result. Returns nil for transient
    /// states (streaming results) — those are never persisted.
    static func resultStatus(name: String, result: ToolResult) -> Status? {
        if result.isStreaming { return nil }
        if result.isDenied {
            return Status(kind: .denied, label: "denied", description: denialReason(result.content))
        }
        if result.isCancelled {
            // The content is a fixed boilerplate sentence — the badge says it all.
            return Status(kind: .cancelled, label: "cancelled", description: "")
        }
        if result.isError {
            return Status(kind: .error, label: "error", description: firstLine(result.content))
        }
        return Status(kind: .done, label: "done", description: doneDescription(name: name, content: result.content))
    }
}

// MARK: - Value formatting

private extension ToolSummary {

    /// Collapse newlines so a value fits the single-line summary. Whitespace
    /// around the break is dropped; the break itself becomes a visible marker.
    static func oneLine(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        var pendingBreak = false
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\n" {
                pendingBreak = true
                // Skip the newline run plus surrounding whitespace.
                var j = i
                while j < s.endIndex, s[j] == "\n" || s[j] == " " || s[j] == "\t" { j = s.index(after: j) }
                i = j
                if !out.isEmpty, i < s.endIndex { out.append("⏎") }
                continue
            }
            if pendingBreak, ch == " " || ch == "\t" {
                i = s.index(after: i)
                continue
            }
            pendingBreak = false
            out.append(ch)
            i = s.index(after: i)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Display string for a scalar argument value; nil for objects/arrays.
    static func scalar(_ v: Any) -> String? {
        if let s = v as? String { return oneLine(s) }
        if let n = v as? NSNumber {
            if isBool(n) { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        return nil
    }

    /// Display string for any argument value: scalars verbatim, arrays of
    /// scalars joined, anything else compact JSON.
    static func anyValue(_ v: Any) -> String {
        if let s = scalar(v) { return s }
        if let arr = v as? [Any], arr.allSatisfy({ scalar($0) != nil }) {
            return arr.compactMap { scalar($0) }.joined(separator: " ")
        }
        return compactJSON(v)
    }

    static func compactJSON(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(withJSONObject: v),
              let s = String(data: data, encoding: .utf8) else { return "\(v)" }
        return s
    }

    static func prettyJSON(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted]),
              let s = String(data: data, encoding: .utf8) else { return "\(v)" }
        return s
    }

    /// Parses the arguments string into a JSON object, or nil when it isn't
    /// one (malformed JSON, or a valid non-object value).
    static func parseJSONObject(_ args: String) -> [String: Any]? {
        guard let data = args.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any] else { return nil }
        return obj
    }

    /// Top-level key order of a JSON object string, recovered by a lightweight
    /// scan (`JSONSerialization` dictionaries don't preserve order). Only used
    /// to keep the generic fallback summary's argument order stable.
    static func topLevelKeys(of json: String) -> [String] {
        var keys: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var token = ""
        var pendingKey: String?
        for ch in json {
            if inString {
                if escaped {
                    escaped = false
                    if depth == 1 { token.append(ch) }
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    continue
                }
                if ch == "\"" {
                    inString = false
                    if depth == 1 { pendingKey = token }
                } else if depth == 1 {
                    token.append(ch)
                }
                continue
            }
            switch ch {
            case "\"":
                inString = true
                token = ""
            case "{", "[":
                depth += 1
            case "}", "]":
                depth -= 1
            case ":":
                if depth == 1, let key = pendingKey {
                    keys.append(key)
                    pendingKey = nil
                }
            default:
                break
            }
        }
        return keys
    }

    struct ArgEntry {
        let key: String
        let value: String
        let multiline: Bool
    }

    /// Port of the renderer's `parseToolArgs`: one display entry per top-level
    /// key, values pre-formatted (strings verbatim, containers pretty-printed).
    static func parseArgs(_ args: String, object obj: [String: Any]) -> [ArgEntry] {
        let scanned = topLevelKeys(of: args).filter { obj[$0] != nil }
        let missing = obj.keys.filter { !scanned.contains($0) }.sorted()
        return (scanned + missing).map { key in
            let v = obj[key]!
            if let s = v as? String {
                return ArgEntry(key: key, value: s, multiline: s.contains("\n"))
            }
            if v is NSNull {
                return ArgEntry(key: key, value: "null", multiline: false)
            }
            if let n = v as? NSNumber {
                return ArgEntry(key: key, value: isBool(n) ? (n.boolValue ? "true" : "false") : n.stringValue, multiline: false)
            }
            let json = prettyJSON(v)
            return ArgEntry(key: key, value: json, multiline: json.contains("\n"))
        }
    }
}

// MARK: - Internal (known) tools

private extension ToolSummary {

    struct KnownToolSpec {
        /// Arg keys rendered bare (no `key:` prefix), in order.
        var primary: [String]
        /// Arg keys rendered as `key: value` after the primary ones, in order.
        var secondary: [String] = []
    }

    /// Per-tool argument importance for internal (built-in + configurator)
    /// tools. Tools with no meaningful arguments map to an empty primary list.
    static let knownTools: [String: KnownToolSpec] = [
        // Built-in: Filesystem
        "read_file": KnownToolSpec(primary: ["path"], secondary: ["offset", "limit"]),
        "write_file": KnownToolSpec(primary: ["path"]),
        "ls": KnownToolSpec(primary: ["path"], secondary: ["recursive", "include_hidden"]),
        "find_file": KnownToolSpec(primary: ["pattern"], secondary: ["path", "case_insensitive", "include_hidden"]),
        "find_text": KnownToolSpec(primary: ["regex"], secondary: ["path", "file_pattern", "case_insensitive", "context"]),
        "mkdir": KnownToolSpec(primary: ["path"]),
        "rm": KnownToolSpec(primary: ["path"], secondary: ["recursive"]),
        "stat": KnownToolSpec(primary: ["path"]),
        "pwd": KnownToolSpec(primary: []),
        // Built-in: Shell
        "shell": KnownToolSpec(primary: ["command"], secondary: ["cwd", "timeout"]),
        "applescript": KnownToolSpec(primary: ["script"]),
        // Built-in: Utils
        "calc": KnownToolSpec(primary: ["expression"]),
        "hash": KnownToolSpec(primary: ["input"], secondary: ["algorithm"]),
        "base64_encode": KnownToolSpec(primary: ["input"]),
        "base64_decode": KnownToolSpec(primary: ["input"]),
        "sleep": KnownToolSpec(primary: ["seconds"]),
        "datetime": KnownToolSpec(primary: []),
        "uuid": KnownToolSpec(primary: []),
        // Configurator
        "read_connection": KnownToolSpec(primary: ["id"]),
        "write_connection": KnownToolSpec(primary: ["id"]),
        "delete_connection": KnownToolSpec(primary: ["id"]),
        "check_connection": KnownToolSpec(primary: ["id"]),
        "read_mcp": KnownToolSpec(primary: ["name"]),
        "write_mcp": KnownToolSpec(primary: ["name"]),
        "delete_mcp": KnownToolSpec(primary: ["name"]),
        "read_role": KnownToolSpec(primary: ["name"]),
        "write_role": KnownToolSpec(primary: ["name"]),
        "delete_role": KnownToolSpec(primary: ["name"]),
        "read_prompt": KnownToolSpec(primary: ["name"]),
        "write_prompt": KnownToolSpec(primary: ["name"]),
        "delete_prompt": KnownToolSpec(primary: ["name"]),
        "write_config": KnownToolSpec(primary: ["content"]),
        "check_mcp_stdio": KnownToolSpec(primary: ["command"]),
        "check_mcp_http": KnownToolSpec(primary: ["endpoint"]),
        "list_connections": KnownToolSpec(primary: []),
        "list_mcps": KnownToolSpec(primary: []),
        "list_roles": KnownToolSpec(primary: []),
        "list_prompts": KnownToolSpec(primary: []),
        "read_config": KnownToolSpec(primary: []),
        "read_log": KnownToolSpec(primary: []),
    ]

    /// Extract the affected paths from an apply_patch patch text. A `Move to`
    /// renames the previously listed path into `old → new`.
    static func extractPatchPaths(_ patch: String) -> [String] {
        var paths: [String] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if let m = firstMatch(of: #"^\*\*\* (?:Add|Delete|Update) File: (.+)$"#, in: s) {
                paths.append(m.trimmingCharacters(in: .whitespaces))
                continue
            }
            if let m = firstMatch(of: #"^\*\*\* Move to: (.+)$"#, in: s), !paths.isEmpty {
                paths[paths.count - 1] = "\(paths[paths.count - 1]) → \(m.trimmingCharacters(in: .whitespaces))"
            }
        }
        return paths
    }

    static func firstMatch(of pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// Custom summaries for internal tools whose primary value isn't a plain
    /// argument lookup. Returns nil when the expected arguments are missing,
    /// so the caller falls back to the generic spec-based rendering.
    static func customKnownSummary(name: String, obj: [String: Any]) -> [Entry]? {
        switch name {
        case "mv":
            guard let src = obj["src"].flatMap(scalar), let dst = obj["dst"].flatMap(scalar) else { return nil }
            return [Entry(key: nil, value: "\(src) → \(dst)")]
        case "apply_patch":
            guard let patch = obj["patch"] as? String else { return nil }
            let paths = extractPatchPaths(patch)
            return paths.isEmpty ? nil : [Entry(key: nil, value: paths.joined(separator: ", "))]
        default:
            return nil
        }
    }

    static let customKnownTools: Set<String> = ["mv", "apply_patch"]

    /// Summary for an internal tool, or nil when the tool isn't known.
    static func knownToolSummary(name: String, obj: [String: Any]) -> [Entry]? {
        if customKnownTools.contains(name), let custom = customKnownSummary(name: name, obj: obj) {
            return custom
        }
        guard let spec = knownTools[name] else { return nil }
        var out: [Entry] = []
        for key in spec.primary {
            if let v = obj[key] { out.append(Entry(key: nil, value: anyValue(v))) }
        }
        for key in spec.secondary {
            if let v = obj[key] { out.append(Entry(key: key, value: anyValue(v))) }
        }
        return out
    }
}

// MARK: - Generic (unknown tools)

private extension ToolSummary {

    /// Single-line value for a parsed argument entry. Multi-line structured
    /// values (arrays/objects) are compacted; multi-line strings get ⏎ marks.
    static func inlineEntryValue(_ e: ArgEntry) -> String {
        guard e.multiline else { return e.value }
        if let data = e.value.data(using: .utf8),
           let v = try? JSONSerialization.jsonObject(with: data),
           let arr = v as? [Any], arr.allSatisfy({ scalar($0) != nil }) {
            return arr.compactMap { scalar($0) }.joined(separator: " ")
        }
        return oneLine(e.value)
    }

    /// Fallback summary for tools we have no per-tool knowledge of: required
    /// arguments first (alphabetical), then optional ones (alphabetical).
    /// Without a `requiredArgs` list the JSON key order is preserved as-is.
    static func genericSummary(entries: [ArgEntry], requiredArgs: [String]?) -> [Entry] {
        let mapped = entries.map { Entry(key: $0.key, value: inlineEntryValue($0)) }
        guard let requiredArgs else { return mapped }
        let required = Set(requiredArgs)
        let byKey: (Entry, Entry) -> Bool = { ($0.key ?? "") < ($1.key ?? "") }
        let req = mapped.filter { $0.key.map(required.contains) ?? false }.sorted(by: byKey)
        let opt = mapped.filter { !($0.key.map(required.contains) ?? false) }.sorted(by: byKey)
        return req + opt
    }
}

// MARK: - Result descriptions

private extension ToolSummary {

    /// First non-empty line of a (possibly multi-line) text, trimmed.
    static func firstLine(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return ""
    }

    /// Last non-empty line of a (possibly multi-line) text, trimmed.
    static func lastLine(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return ""
    }

    /// Count of non-empty lines, excluding truncation markers ("... (truncated…)").
    static func countResultLines(_ text: String) -> Int {
        var n = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !t.hasPrefix("...") { n += 1 }
        }
        return n
    }

    /// Count of "- " markdown bullet lines (configurator list/check output).
    static func countBulletLines(_ text: String) -> Int {
        var n = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var s = line
            while s.first == " " || s.first == "\t" { s = s.dropFirst() }
            if s.hasPrefix("- ") { n += 1 }
        }
        return n
    }

    /// Line count of a plain-text document; a single trailing newline is ignored.
    static func countTextLines(_ text: String) -> Int {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.count
    }

    /// One-line description of a successful result, specialized for internal
    /// tools whose output is a structured list we can count or a log whose
    /// tail (the exit-code line) is the informative part. Falls back to the
    /// first output line for everything else.
    static func doneDescription(name: String, content: String) -> String {
        switch name {
        case "read_file":
            // Text output lines carry the "N | content" gutter; anything else
            // (image/binary notices) falls back to the first line.
            let re = try? NSRegularExpression(pattern: #"^\s*\d+ \| "#)
            let n = content.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                let s = String(line)
                return re?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            }.count
            if n > 0 { return "Read \(n) \(n == 1 ? "line" : "lines")." }
            return firstLine(content)
        case "ls":
            let n = countResultLines(content)
            return "Listed \(n) \(n == 1 ? "item" : "items")."
        case "find_file", "find_text":
            let n = countResultLines(content)
            return "Found \(n) \(n == 1 ? "item" : "items")."
        case "apply_patch":
            // The result is one "Added:/Updated:/Deleted: path" line per file op.
            var added = 0, updated = 0, deleted = 0
            for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("Added:") { added += 1 }
                else if t.hasPrefix("Updated:") { updated += 1 }
                else if t.hasPrefix("Deleted:") { deleted += 1 }
            }
            let total = added + updated + deleted
            if total == 0 { return firstLine(content) }
            var parts: [String] = []
            if added > 0 { parts.append("\(added) added") }
            if updated > 0 { parts.append("\(updated) updated") }
            if deleted > 0 { parts.append("\(deleted) deleted") }
            return "Patched \(total) \(total == 1 ? "file" : "files") (\(parts.joined(separator: ", ")))."
        case "shell":
            // Output ends with the "[exit code: N]" line — that's the useful part.
            return lastLine(content)
        // Configurator: bullet lists ("- name" per entry, or "(none)").
        case "list_connections", "list_mcps", "list_roles", "list_prompts":
            let n = countBulletLines(content)
            return "Listed \(n) \(n == 1 ? "item" : "items")."
        case "check_mcp_stdio", "check_mcp_http":
            let n = countBulletLines(content)
            return "Found \(n) \(n == 1 ? "tool" : "tools")."
        // Configurator: raw file/log contents.
        case "read_connection", "read_mcp", "read_role", "read_prompt", "read_config", "read_log":
            // Parenthesized notices ("(none)", "(application log is empty)")
            // are already a good one-liner.
            if content.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }).first == "(" {
                return firstLine(content)
            }
            let n = countTextLines(content)
            return "Read \(n) \(n == 1 ? "line" : "lines")."
        default:
            return firstLine(content)
        }
    }

    /// The denial reason without the boilerplate prefix; empty for a generic
    /// (reason-less) denial.
    static func denialReason(_ content: String) -> String {
        let prefix = "User denied this tool call with the following reason: "
        let generic = "User denied this tool call"
        if content.hasPrefix(prefix) {
            return String(content.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if content.hasPrefix(generic) { return "" }
        return firstLine(content)
    }
}
