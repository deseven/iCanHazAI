// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// What the model currently knows about each file is not stored anywhere: the
// file tools attach small `FileViewEvent`s to their results (persisted with the
// chat) and `FileViewState.fold` replays them over the active message path.
// A regenerate, branch switch or message deletion therefore changes the state
// for free, and nothing needs invalidating.

// MARK: - FileKey

/// Identity of a file or directory across tool calls. Local: the path with its
/// parent directory symlink-resolved. SSH: `ssh://<host>` plus the normalized
/// remote path (the local filesystem is never consulted for remote paths).
struct FileKey: Hashable, Codable, Sendable {
    let raw: String

    init(raw: String) {
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    /// The parent directory is resolved with `realpath` (the nearest existing
    /// ancestor when it does not exist yet) and the last component is appended
    /// as written. The key is thus stable for paths that don't exist (a `MV`
    /// destination, a file after `REM`) and doesn't depend on the `/var` vs
    /// `/private/var` spelling the caller used.
    static func local(resolved: String) -> FileKey {
        let normalized = Workdir.posixNormalize(resolved)
        guard normalized != "/" else { return FileKey(raw: "/") }
        let name = (normalized as NSString).lastPathComponent
        var existing = (normalized as NSString).deletingLastPathComponent
        if existing.isEmpty { existing = "." }
        var missing: [String] = []
        while existing != "/", existing != ".", resolveSymlinks(existing) == nil {
            missing.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
            if existing.isEmpty { existing = "." }
        }
        var path = resolveSymlinks(existing) ?? existing
        for component in missing.reversed() + [name] {
            path = (path as NSString).appendingPathComponent(component)
        }
        return FileKey(raw: path)
    }

    /// `resolved` is the output of `Workdir.resolve`, which already normalized
    /// it. A leading `~` (remote home) stays literal. Paths that are not
    /// absolute get a `/./` marker, which no normalized absolute path contains.
    static func ssh(host: String, resolved: String) -> FileKey {
        let normalized = Workdir.posixNormalize(resolved)
        let path = normalized.hasPrefix("/") ? normalized : "/./" + normalized
        return FileKey(raw: "ssh://\(host)\(path)")
    }

    /// Whether `other` is this key or lives under it (directory semantics).
    func covers(_ other: FileKey) -> Bool {
        other.raw == raw || other.raw.hasPrefix(raw.hasSuffix("/") ? raw : raw + "/")
    }

    /// Re-roots a key under `old` (see `covers`) onto `new`.
    func rebased(from old: FileKey, to new: FileKey) -> FileKey {
        FileKey(raw: new.raw + raw.dropFirst(old.raw.count))
    }

    private static func resolveSymlinks(_ path: String) -> String? {
        path.withCString { cstr in
            guard let resolved = realpath(cstr, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}

// MARK: - LineSet

/// A set of 1-indexed line numbers, stored as sorted, disjoint, non-adjacent
/// closed ranges. Encoded compactly as `"1-200,350,360-362"` (empty set: `""`),
/// so recording a 2000-line read costs a few bytes rather than per-line data.
struct LineSet: Equatable, Codable, Sendable {
    private(set) var ranges: [ClosedRange<Int>]

    init() {
        ranges = []
    }

    init(range: ClosedRange<Int>) {
        self.init(ranges: [range])
    }

    /// Numbers below 1 are not lines and are dropped.
    init<S: Sequence>(_ lines: S) where S.Element == Int {
        var ranges: [ClosedRange<Int>] = []
        for line in Set(lines).sorted() where line >= 1 {
            if let last = ranges.last, last.upperBound + 1 == line {
                ranges[ranges.count - 1] = last.lowerBound...line
            } else {
                ranges.append(line...line)
            }
        }
        self.ranges = ranges
    }

    /// Sorts, clamps to line 1 and merges overlapping or adjacent ranges.
    private init(ranges input: [ClosedRange<Int>]) {
        var merged: [ClosedRange<Int>] = []
        for range in input.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.upperBound >= 1 else { continue }
            let range = max(range.lowerBound, 1)...range.upperBound
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        ranges = merged
    }

    var isEmpty: Bool { ranges.isEmpty }

    var count: Int { ranges.reduce(0) { $0 + $1.count } }

    func contains(_ line: Int) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].upperBound < line {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < ranges.count && ranges[low].lowerBound <= line
    }

    func union(_ other: LineSet) -> LineSet {
        LineSet(ranges: ranges + other.ranges)
    }

    /// The set after an edit: for each post-edit line (`origins[i]` is the
    /// pre-edit line number of post-edit line `i + 1`, nil for new content),
    /// it is in the result when its origin is in this set.
    func remapped(throughOrigins origins: [Int?]) -> LineSet {
        var lines: [Int] = []
        for (index, origin) in origins.enumerated() {
            if let origin, contains(origin) { lines.append(index + 1) }
        }
        return LineSet(lines)
    }

    var encoded: String {
        ranges.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
            .joined(separator: ",")
    }

    /// Nil for anything that is not a comma-separated list of `N` / `A-B`
    /// (with `1 <= A <= B`). Overlapping or unsorted input is normalized.
    init?(encoded: String) {
        let text = encoded.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            self.init()
            return
        }
        var parsed: [ClosedRange<Int>] = []
        for piece in text.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = piece.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count <= 2, let low = Self.line(bounds[0]) else { return nil }
            let high = bounds.count == 2 ? Self.line(bounds[1]) : low
            guard let high, low <= high else { return nil }
            parsed.append(low...high)
        }
        self.init(ranges: parsed)
    }

    private static func line(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let value = Int(text), value >= 1
        else { return nil }
        return value
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let set = LineSet(encoded: text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid line set \"\(text)\""))
        }
        self = set
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encoded)
    }
}

// MARK: - Events

/// One statement about what the model now knows, attached to the result of the
/// tool that produced it. Persisted on `ToolResult.fileViews`, never sent to a
/// provider.
struct FileViewEvent: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Lines of a version of the file were shown (read, search hit,
        /// revealed anchor lines).
        case seen
        /// The file now has this content and the model knows these lines of it
        /// (it wrote it, or the edit result showed it).
        case set
        /// The file (or directory) is gone.
        case drop
        /// The file (or directory) moved; `key` is the source, `to` the target.
        case move
    }

    var kind: Kind
    var key: FileKey
    var to: FileKey?
    /// `HashlineFormat.computeContentID` of the version: `seen` and `set`.
    var contentID: String?
    var lines: LineSet?

    static func seen(_ key: FileKey, contentID: String, lines: LineSet) -> FileViewEvent {
        FileViewEvent(kind: .seen, key: key, to: nil, contentID: contentID, lines: lines)
    }

    static func set(_ key: FileKey, contentID: String, lines: LineSet) -> FileViewEvent {
        FileViewEvent(kind: .set, key: key, to: nil, contentID: contentID, lines: lines)
    }

    static func drop(_ key: FileKey) -> FileViewEvent {
        FileViewEvent(kind: .drop, key: key, to: nil, contentID: nil, lines: nil)
    }

    static func move(from key: FileKey, to destination: FileKey) -> FileViewEvent {
        FileViewEvent(kind: .move, key: key, to: destination, contentID: nil, lines: nil)
    }
}

// MARK: - State

/// The latest known version of a file and the lines of it the model has seen.
struct FileView: Equatable, Sendable {
    let contentID: String
    var lines: LineSet
}

/// What the model knows per file, derived from the events on the tool results
/// of a message path. Only the latest version of each file is kept.
struct FileViewState: Equatable, Sendable {
    private(set) var files: [FileKey: FileView] = [:]

    init() {}

    /// Replays the events of every tool result in `messages` (error results
    /// included) in order. Pass the chat's active path: events on abandoned
    /// branches must not count. Result text is never parsed.
    static func fold(_ messages: [ChatMessage]) -> FileViewState {
        var state = FileViewState()
        for message in messages {
            for result in message.toolResults ?? [] {
                for event in result.fileViews ?? [] { state.apply(event) }
            }
        }
        return state
    }

    func view(for key: FileKey) -> FileView? {
        files[key]
    }

    mutating func apply(_ event: FileViewEvent) {
        switch event.kind {
        case .seen:
            guard let contentID = event.contentID else { return }
            let lines = event.lines ?? LineSet()
            if var current = files[event.key], current.contentID == contentID {
                current.lines = current.lines.union(lines)
                files[event.key] = current
            } else {
                files[event.key] = FileView(contentID: contentID, lines: lines)
            }
        case .set:
            guard let contentID = event.contentID else { return }
            files[event.key] = FileView(contentID: contentID, lines: event.lines ?? LineSet())
        case .drop:
            files = files.filter { !event.key.covers($0.key) }
        case .move:
            guard let destination = event.to, destination != event.key else { return }
            let moved = files.filter { event.key.covers($0.key) }
            for key in moved.keys { files[key] = nil }
            files = files.filter { !destination.covers($0.key) }
            for (key, view) in moved { files[key.rebased(from: event.key, to: destination)] = view }
        }
    }
}
