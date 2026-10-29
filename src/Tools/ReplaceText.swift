// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The arguments of a `replace_text` call. Both texts are LF-normalized, like
/// the file content they are matched against.
struct ReplaceTextRequest: Sendable {
    let path: String
    let oldText: String
    let newText: String
    let replaceAll: Bool

    init(args: [String: Any]) throws {
        path = try BuiltinTools.requireString(args, "path")
        oldText = Self.lf(try BuiltinTools.requireString(args, "old_text"))
        newText = Self.lf(try BuiltinTools.requireString(args, "new_text"))
        if let raw = args["replace_all"], !(raw is NSNull) {
            guard let flag = raw as? Bool else {
                throw BuiltinToolError("invalid argument 'replace_all': expected a boolean")
            }
            replaceAll = flag
        } else {
            replaceAll = false
        }
        if oldText.isEmpty {
            throw BuiltinToolError(
                "invalid argument 'old_text': must not be empty. To insert text, match a nearby line and repeat it in new_text."
            )
        }
        if oldText == newText {
            throw BuiltinToolError(
                "invalid argument 'new_text': identical to old_text, so the replacement changes nothing.")
        }
    }

    private static func lf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
    }
}

/// A replacement checked against the file as it is now, ready to be written.
struct PreparedReplacement {
    let path: String
    let resolved: String
    let key: FileKey
    let file: TextFile
    /// The LF-normalized content after the replacement.
    let text: String
    /// The lines of `text` that `new_text` was written into.
    let produced: LineSet
    /// The lines of this exact version of the file the model has seen.
    let seenBefore: LineSet
}

/// `replace_text`: an exact, literal find-and-replace on one existing text
/// file, for small edits where a hashline patch would mean line arithmetic.
/// Like [`HashlinePatcher`](src/Tools/Hashline/HashlinePatcher.swift) it runs
/// the same `prepare` for the approval preflight and for the execution, on
/// local and SSH workdirs alike (through `FileAccess`), and its result has the
/// same shape as an `edit_file` section, so either tool can follow the other
/// without a re-read.
///
/// There is no `#TAG` and no seen-lines guard: the exact `old_text` match is
/// the staleness check, and a model that reproduced the text exactly knows it.
/// The result still records what the model now knows, so `edit_file` can
/// follow.
enum ReplaceText {
    /// Most match line numbers listed in an ambiguity error.
    static let maxListedMatches = 10

    // MARK: - Prepare

    /// Resolves and reads the file, finds `old_text` and builds the new
    /// content in memory. Writes nothing.
    static func prepare(
        _ request: ReplaceTextRequest, access: any FileAccess, views: FileViewState
    ) async throws -> PreparedReplacement {
        do {
            return try await prepareReplacement(request, access: access, views: views)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HashlinePatcher.patchError(error)
        }
    }

    private static func prepareReplacement(
        _ request: ReplaceTextRequest, access: any FileAccess, views: FileViewState
    ) async throws -> PreparedReplacement {
        let resolved = try access.resolve(request.path)
        let key = access.key(resolved)

        let data: Data
        switch try await access.read(resolved) {
        case .missing:
            throw HashlinePatchError("File not found: \(request.path). Use write_file to create new files.")
        case .directory:
            throw HashlinePatchError("invalid argument 'path': is a directory: \(request.path)")
        case .data(let bytes):
            data = bytes
        }
        guard let file = TextFile.decode(data) else {
            throw HashlinePatchError(
                "File \(request.path) is not a text file and cannot be edited with replace_text. Use write_file to replace it entirely."
            )
        }

        let replaced = try replace(in: file.text, request)
        // Only a view of this exact version of the file says anything about it.
        var seenBefore = LineSet()
        if let view = views.view(for: key), view.contentID == HashlineFormat.computeContentID(file.text) {
            seenBefore = view.lines
        }
        return PreparedReplacement(
            path: request.path, resolved: resolved, key: key, file: file, text: replaced.text,
            produced: replaced.produced, seenBefore: seenBefore)
    }

    /// Byte-exact matching, so no normalization or Unicode equivalence can
    /// make a near miss match: UTF-8 is self-synchronizing, so a valid needle
    /// only ever matches on character boundaries.
    private static func replace(
        in text: String, _ request: ReplaceTextRequest
    ) throws -> (text: String, produced: LineSet) {
        let haystack = Array(text.utf8)
        let needle = Array(request.oldText.utf8)
        let replacement = Array(request.newText.utf8)

        let starts = occurrences(of: needle, in: haystack)
        guard !starts.isEmpty else {
            throw HashlinePatchError(
                "old_text was not found in \(request.path). It must match the file exactly: whitespace, indentation and line breaks included, without read_file's 'N:' line-number prefixes. Re-read the lines you mean to change if unsure."
            )
        }
        if starts.count > 1, !request.replaceAll {
            throw HashlinePatchError(ambiguityMessage(starts, in: haystack, path: request.path))
        }

        var out: [UInt8] = []
        out.reserveCapacity(haystack.count + starts.count * max(0, replacement.count - needle.count))
        var written: [Range<Int>] = []
        var cursor = 0
        for start in starts {
            out += haystack[cursor..<start]
            let from = out.count
            out += replacement
            if !replacement.isEmpty { written.append(from..<out.count) }
            cursor = start + needle.count
        }
        out += haystack[cursor...]

        // A deleted span produces no line; the lines around it that changed
        // show up in the preview.
        let ends = written.flatMap { [$0.lowerBound, $0.upperBound - 1] }
        let numbers = lineNumbers(at: ends, in: out)
        var produced: [Int] = []
        for index in stride(from: 0, to: numbers.count, by: 2) {
            produced += numbers[index]...numbers[index + 1]
        }
        return (String(decoding: out, as: UTF8.self), LineSet(produced))
    }

    /// Start offsets of the non-overlapping matches, left to right.
    private static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> [Int] {
        guard let first = needle.first, haystack.count >= needle.count else { return [] }
        var found: [Int] = []
        let last = haystack.count - needle.count
        var index = 0
        while index <= last {
            if haystack[index] == first, haystack[index..<index + needle.count].elementsEqual(needle) {
                found.append(index)
                index += needle.count
            } else {
                index += 1
            }
        }
        return found
    }

    /// The 1-based line of each offset, which must be ascending.
    private static func lineNumbers(at offsets: [Int], in bytes: [UInt8]) -> [Int] {
        var numbers: [Int] = []
        numbers.reserveCapacity(offsets.count)
        var line = 1
        var position = 0
        for offset in offsets {
            while position < offset {
                if bytes[position] == 0x0A { line += 1 }
                position += 1
            }
            numbers.append(line)
        }
        return numbers
    }

    private static func ambiguityMessage(_ starts: [Int], in haystack: [UInt8], path: String) -> String {
        let listed = lineNumbers(at: Array(starts.prefix(maxListedMatches)), in: haystack)
            .map(String.init).joined(separator: ", ")
        let more = starts.count > maxListedMatches ? " and \(starts.count - maxListedMatches) more" : ""
        return
            "old_text matches \(starts.count) times in \(path) (lines \(listed)\(more)). Add surrounding text to old_text so that it matches exactly once, or set replace_all to true to replace every occurrence."
    }

    // MARK: - Commit

    /// Writes the new content, keeping the file's BOM and line endings, and
    /// reports it like an `edit_file` section (without its `[path#TAG]` when
    /// the model has no `edit_file` to use it with, see `ToolContext.fileTags`).
    /// The model knows of the new version what it knew before (carried through
    /// the text diff's line origins), the lines it wrote, and the rows of the
    /// preview it is about to read.
    static func commit(
        _ prepared: PreparedReplacement, access: any FileAccess, fileTags: Bool = true
    ) async throws -> PatchCommit {
        do {
            try await access.write(prepared.resolved, prepared.file.encode(prepared.text))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HashlinePatcher.patchError(error)
        }

        let known = prepared.seenBefore.remapped(throughOrigins: lineOrigins(prepared)).union(prepared.produced)
        let outcome = HashlinePatcher.updatedBlock(
            path: prepared.path, newPath: prepared.path, newKey: prepared.key, old: prepared.file.text,
            new: prepared.text, known: known, warnings: [], fileTags: fileTags)
        return PatchCommit(summaries: [outcome.summary], fileViews: outcome.events)
    }

    /// The alignment the approval diff and the result preview use, so the
    /// seen lines move with exactly the lines those show as unchanged.
    private static func lineOrigins(_ prepared: PreparedReplacement) -> [Int?] {
        func lines(_ text: String) -> [String] {
            text.isEmpty ? [] : HashlineFormat.splitAddressableFileLines(text)
        }
        return DiffBuilder.lineOrigins(old: lines(prepared.file.text), new: lines(prepared.text))
    }

    // MARK: - Preflight

    /// Runs `prepare` for a `replace_text` call (JSON `arguments`) without
    /// writing anything. Failures, transport errors included, come back as
    /// `.error`; only a cancellation throws.
    static func preflight(
        arguments: String, workdir: Workdir, views: FileViewState
    ) async throws -> HashlinePatcher.Preflight {
        let parsed: [String: Any]?
        if let data = arguments.data(using: .utf8), !data.isEmpty {
            parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else {
            parsed = arguments.isEmpty ? [:] : nil
        }
        guard let args = parsed else {
            return .error(message: "Invalid arguments: expected a JSON object.", fileViews: [])
        }
        do {
            let request = try ReplaceTextRequest(args: args)
            let prepared = try await prepare(request, access: try workdir.fileAccess(), views: views)
            let diff = DiffBuilder.unifiedDiff(
                old: prepared.file.text, new: prepared.text, oldPath: prepared.path, newPath: prepared.path)
            return .ok(diff: diff.isEmpty ? nil : diff)
        } catch let error as HashlinePatchError {
            return .error(message: error.message, fileViews: error.fileViews)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .error(message: HashlinePatcher.patchError(error).message, fileViews: [])
        }
    }
}
