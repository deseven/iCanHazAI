// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Runtime resolver for the `{load_first_available:file1,file2,...}` prompt
/// variable.
///
/// Given a comma-separated file list, the first readable text file wins.
/// Relative paths resolve against the chat's working directory, or the user's
/// home directory when no working directory is set. The substitution is the
/// candidate as written in parentheses followed by the file contents:
///
/// ```
/// (info.txt)
/// hello world
/// ```
///
/// When nothing in the list is a readable text file the variable substitutes
/// to an empty string.
///
/// To avoid re-reading files on every LLM request, the picked file's contents
/// and modification date are cached per (base directory, argument list). Each
/// resolve still stats the filesystem: a higher-priority candidate that
/// appears later takes over, and a changed modification date triggers a
/// re-read. Nothing is persisted; the cache lives as long as its owner.
final class LoadFirstAvailableCache {

    private struct Entry {
        /// Index of the picked candidate within the argument list.
        let candidateIndex: Int
        /// The candidate as written in the variable (used for the header).
        let displayName: String
        /// Absolute path the candidate resolved to.
        let resolvedPath: String
        let modificationDate: Date?
        let contents: String
    }

    /// Keyed by base directory + raw argument list.
    private var entries: [String: Entry] = [:]

    /// Resolves one `{load_first_available:...}` reference. `rawArgs` is the
    /// text between `:` and `}`; `baseDirectory` is the chat's working
    /// directory (nil/empty → the user's home directory).
    func resolve(args rawArgs: String, baseDirectory: String?) -> String {
        let candidates = rawArgs.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return "" }
        let base = (baseDirectory?.isEmpty == false) ? baseDirectory! : NSHomeDirectory()
        let key = base + "\u{0}" + rawArgs

        if let entry = entries[key] {
            // A more important file may have appeared since the pick.
            for i in 0..<entry.candidateIndex {
                if let picked = load(candidates[i], base: base, index: i) {
                    entries[key] = picked
                    return format(picked)
                }
            }
            // Re-use the cached contents unless the file changed on disk.
            if let mtime = modificationDate(at: entry.resolvedPath), mtime == entry.modificationDate {
                return format(entry)
            }
            if let picked = load(candidates[entry.candidateIndex], base: base, index: entry.candidateIndex) {
                entries[key] = picked
                return format(picked)
            }
            // The picked file is gone or unreadable — fall back to anything
            // lower-priority that still works.
            for i in (entry.candidateIndex + 1)..<candidates.count {
                if let picked = load(candidates[i], base: base, index: i) {
                    entries[key] = picked
                    return format(picked)
                }
            }
            entries[key] = nil
            return ""
        }

        for i in candidates.indices {
            if let picked = load(candidates[i], base: base, index: i) {
                entries[key] = picked
                return format(picked)
            }
        }
        // Nothing found: deliberately not cached, so a file appearing later is
        // picked up on the next request.
        return ""
    }

    // MARK: - Internals

    private func format(_ entry: Entry) -> String {
        var out = "(\(entry.displayName))\n\(entry.contents)"
        if !out.hasSuffix("\n") { out.append("\n") }
        return out
    }

    private func resolve(_ candidate: String, base: String) -> String {
        candidate.hasPrefix("/")
            ? candidate
            : (base as NSString).appendingPathComponent(candidate)
    }

    private func modificationDate(at path: String) -> Date? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Reads a candidate if it is a regular file with valid UTF-8 text
    /// contents (no NUL bytes). Returns nil for anything else — missing,
    /// unreadable, directory, or binary.
    private func load(_ candidate: String, base: String, index: Int) -> Entry? {
        let path = resolve(candidate, base: base)
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
            values.isRegularFile == true,
            let data = try? Data(contentsOf: url),
            !data.contains(0),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return Entry(
            candidateIndex: index,
            displayName: candidate,
            resolvedPath: path,
            modificationDate: values.contentModificationDate,
            contents: text
        )
    }
}
