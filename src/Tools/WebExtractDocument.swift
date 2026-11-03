// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

/// A page extracted by `web_extract`, in the form it is cached and served: a
/// metadata header plus the content as lines no longer than `maxLineLength`,
/// so one minified blob can't blow a read's line budget.
struct WebExtractDocument: Equatable, Sendable {
    /// Longest line (in characters) kept; longer ones are split.
    static let maxLineLength = 1000
    /// Lines shown before and after every `regex` match.
    static let regexContext = 5

    /// `URL:` / `Title:` / ... lines, without a trailing newline.
    let header: String
    let lines: [String]

    init(page: BuiltinToolsWeb.ExtractedPage) {
        var header = "URL: \(page.url)"
        if let title = page.title, !title.isEmpty { header += "\nTitle: \(title)" }
        if let published = page.published, !published.isEmpty { header += "\nPublished: \(published)" }
        if let author = page.author, !author.isEmpty { header += "\nAuthor: \(author)" }
        self.header = header
        self.lines = HashlineFormat.splitAddressableFileLines(page.content).flatMap {
            Self.split(HashlineFormat.dropTrailingCR($0))
        }
    }

    /// Splits a line into chunks of at most `limit` characters, cutting after
    /// the last space/tab in the second half of the window when there is one
    /// (so words survive) and hard otherwise. Concatenating the chunks gives
    /// the original line back.
    static func split(_ line: String, limit: Int = maxLineLength) -> [String] {
        if line.utf8.count <= limit { return [line] }
        var chunks: [String] = []
        var rest = Substring(line)
        while let hardEnd = rest.index(rest.startIndex, offsetBy: limit, limitedBy: rest.endIndex),
            hardEnd < rest.endIndex
        {
            let half = rest.index(rest.startIndex, offsetBy: limit / 2)
            var cut = hardEnd
            if let space = rest[half..<hardEnd].lastIndex(where: { $0 == " " || $0 == "\t" }) {
                cut = rest.index(after: space)
            }
            chunks.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        chunks.append(String(rest))
        return chunks
    }

    /// The tool result: the header, a blank line, then the selected rows.
    func render(_ selection: WebExtractSelection) -> String {
        let rows: [String]
        switch selection {
        case .ranges(let selector):
            rows = BuiltinTools.readRows(lines, selector.resolve(total: lines.count), numbered: true)
        case .regex(let pattern, let regex):
            let hits = lines.indices.filter { lines[$0].firstMatch(of: regex) != nil }
            if hits.isEmpty {
                rows = ["(no lines match regex \"\(pattern)\"; \(lines.count) lines total)"]
            } else {
                let resolution = Self.contextWindows(hits: hits, total: lines.count)
                rows =
                    ["(\(hits.count) matching \(hits.count == 1 ? "line" : "lines"))"]
                    + BuiltinTools.readRows(lines, resolution, numbered: true)
            }
        }
        return header + "\n\n" + rows.joined(separator: "\n")
    }

    /// Windows of `regexContext` lines around every hit (0-based indices),
    /// merged where they touch and cut off at `ReadSelector.maxLines` in total.
    static func contextWindows(
        hits: [Int], total: Int, context: Int = regexContext, maxLines: Int = ReadSelector.maxLines
    ) -> ReadSelector.Resolution {
        var merged: [ClosedRange<Int>] = []
        for hit in hits {
            let window = max(1, hit + 1 - context)...min(total, hit + 1 + context)
            if let last = merged.last, window.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, window.upperBound)
            } else {
                merged.append(window)
            }
        }
        var resolution = ReadSelector.Resolution()
        var remaining = maxLines
        for window in merged {
            guard remaining > 0 else {
                resolution.truncated = true
                break
            }
            let taken = min(window.count, remaining)
            resolution.windows.append(window.lowerBound...(window.lowerBound + taken - 1))
            remaining -= taken
            if taken < window.count { resolution.truncated = true }
        }
        return resolution
    }
}

/// What part of a document one `web_extract` call reads: `ranges` or `regex`
/// (never both).
enum WebExtractSelection {
    case ranges(ReadSelector)
    /// Matched case-insensitively, line by line.
    case regex(pattern: String, Regex<AnyRegexOutput>)

    init(args: [String: Any]) throws {
        let selector = try ReadSelector(arguments: args)
        guard let pattern = BuiltinTools.optionalString(args, "regex"), !pattern.isEmpty else {
            self = .ranges(selector)
            return
        }
        guard selector == .whole else {
            throw BuiltinToolError("invalid arguments: use either 'ranges' or 'regex', not both")
        }
        do {
            self = .regex(pattern: pattern, try Regex(pattern, as: AnyRegexOutput.self).ignoresCase())
        } catch {
            throw BuiltinToolError("invalid argument 'regex': \(error)")
        }
    }
}

/// Runtime-only cache of successfully extracted pages, per chat. Entries live
/// only while the chat is loaded (`ChatEngine` clears them when it releases or
/// deletes the chat) and are keyed by a hash of the URL as the model asked
/// for it.
final class WebExtractCache: @unchecked Sendable {
    static let shared = WebExtractCache()

    private let lock = NSLock()
    private var entries: [String: [String: WebExtractDocument]] = [:]

    static func key(for url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func document(chat: String, url: String) -> WebExtractDocument? {
        lock.withLock { entries[chat]?[Self.key(for: url)] }
    }

    func store(_ document: WebExtractDocument, chat: String, url: String) {
        lock.withLock { entries[chat, default: [:]][Self.key(for: url)] = document }
    }

    func clear(chat: String) {
        lock.withLock { _ = entries.removeValue(forKey: chat) }
    }
}
