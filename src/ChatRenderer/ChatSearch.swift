import AppKit

/// One occurrence of the query in a message's visible text.
struct SearchMatch: Equatable, Sendable {
    let rowID: String
    /// Range in the rendered (not the markdown source) text of the message body.
    let range: NSRange
}

/// What a row's text view paints: every match of the row, and which of them is
/// the current one.
struct SearchHighlight: Equatable {
    var ranges: [NSRange]
    var current: Int?
}

struct ChatSearchStatus: Equatable {
    var count = 0
    /// Index of the current match among all matches.
    var current: Int?
}

struct SearchRowInput: Sendable {
    let id: String
    let content: String
}

enum ChatSearch {
    /// Only the body text of user and assistant messages is searchable; thinking,
    /// tool calls and results, errors and attachments are not.
    static func isSearchable(_ m: ChatRowModel) -> Bool {
        (m.role == .user || m.role == .assistant) && m.hasContent
    }

    /// Non-overlapping, case- and diacritic-insensitive occurrences.
    nonisolated static func ranges(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(
                of: query, options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            out.append(r)
            from = NSMaxRange(r)
        }
        return out
    }

    /// The text a message body shows, which is what matches are located in.
    nonisolated static func renderedText(_ content: String, theme: Theme) -> String {
        MarkdownRenderer.render(content, theme: theme).string.string
    }
}

/// Matches of the current query across a chat, and which one is current.
/// Matching runs off the main actor; rendered texts are cached per message so
/// typing a longer query or a streaming reply doesn't re-render the whole chat.
@MainActor
final class ChatSearchIndex {
    private struct RowMatches {
        var ranges: [NSRange]
        var start: Int
    }

    private struct ScanResult: Sendable {
        var texts: [String: CachedText]
        var ranges: [(id: String, ranges: [NSRange])]
    }

    private struct CachedText: Sendable {
        let content: String
        let text: String
    }

    private(set) var query = ""
    private(set) var matches: [SearchMatch] = []
    private(set) var current: Int?
    private var byRow: [String: RowMatches] = [:]
    private var cache: [String: CachedText] = [:]
    private var generation = 0

    var isActive: Bool { !query.isEmpty }
    var currentMatch: SearchMatch? { current.map { matches[$0] } }
    var status: ChatSearchStatus { ChatSearchStatus(count: matches.count, current: current) }

    /// Returns whether the query changed.
    func setQuery(_ new: String) -> Bool {
        guard new != query else { return false }
        query = new
        if new.isEmpty { clear() }
        return true
    }

    /// Drops all results and cached text, and discards any scan in flight.
    func clear() {
        query = ""
        generation += 1
        matches = []
        current = nil
        byRow = [:]
        cache = [:]
    }

    func highlight(forRow id: String) -> SearchHighlight? {
        guard let e = byRow[id] else { return nil }
        var inRow: Int?
        if let c = current, c >= e.start, c < e.start + e.ranges.count { inRow = c - e.start }
        return SearchHighlight(ranges: e.ranges, current: inRow)
    }

    func step(_ direction: Int) {
        guard !matches.isEmpty else { return }
        let base = current ?? (direction > 0 ? -1 : 0)
        current = ((base + direction) % matches.count + matches.count) % matches.count
    }

    /// Rescans `inputs` (in row order). The current match becomes the first one
    /// at or after `anchor` (wrapping to the first), so it stays put while the
    /// content changes and follows the viewport on a fresh query. Returns false
    /// when a newer scan or a cleared query made this result obsolete.
    func refresh(
        inputs: [SearchRowInput], theme: Theme, rowIndex: [String: Int], anchor: (row: Int, location: Int)
    ) async -> Bool {
        generation += 1
        let gen = generation
        let query = query
        let cached = cache
        let result = await Task.detached(priority: .userInitiated) {
            Self.scan(query: query, inputs: inputs, cache: cached, theme: theme)
        }.value
        guard gen == generation, query == self.query else { return false }

        cache = result.texts
        matches = []
        byRow = [:]
        for entry in result.ranges where !entry.ranges.isEmpty {
            byRow[entry.id] = RowMatches(ranges: entry.ranges, start: matches.count)
            matches.append(contentsOf: entry.ranges.map { SearchMatch(rowID: entry.id, range: $0) })
        }
        if matches.isEmpty {
            current = nil
        } else {
            current =
                matches.firstIndex {
                    (rowIndex[$0.rowID] ?? .max, $0.range.location) >= (anchor.row, anchor.location)
                } ?? 0
        }
        return true
    }

    private nonisolated static func scan(
        query: String, inputs: [SearchRowInput], cache: [String: CachedText], theme: Theme
    ) -> ScanResult {
        var texts: [String: CachedText] = [:]
        var ranges: [(id: String, ranges: [NSRange])] = []
        for input in inputs {
            let entry: CachedText
            if let hit = cache[input.id], hit.content == input.content {
                entry = hit
            } else {
                entry = CachedText(
                    content: input.content, text: ChatSearch.renderedText(input.content, theme: theme))
            }
            texts[input.id] = entry
            ranges.append((input.id, ChatSearch.ranges(of: query, in: entry.text)))
        }
        return ScanResult(texts: texts, ranges: ranges)
    }
}
