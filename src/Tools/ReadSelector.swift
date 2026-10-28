// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The `ranges` argument of `read_file`: comma-separated line selectors.
///
/// - `A-B`: lines A to B, inclusive
/// - `A+C`: C lines starting at A
/// - `N-` or `N`: line N to the end of the file
///
/// `A..B` and an `L` before a number (`L5-L9`) are accepted too but not
/// advertised. Chunks are sorted and merged, so the output never repeats a line.
struct ReadSelector: Equatable {
    /// Most lines one read returns, however many ranges it asks for.
    static let maxLines = 2000

    struct Chunk: Equatable {
        let start: Int
        /// Nil: through the end of the file.
        let end: Int?

        /// How the chunk is spelled in a notice (an open end is just the start).
        var label: String { end.map { "\(start)-\($0)" } ?? "\(start)" }
    }

    /// Sorted, disjoint and non-adjacent.
    let chunks: [Chunk]

    static let whole = ReadSelector(chunks: [Chunk(start: 1, end: nil)])

    /// What a selector covers in a file of known length.
    struct Resolution: Equatable {
        /// Lines to show: ascending, disjoint, within the file and `maxLines` in total.
        var windows: [ClosedRange<Int>] = []
        /// Requested lines were left out because of `maxLines`.
        var truncated = false
        /// One notice per requested range that starts past the end of the file.
        var notices: [String] = []
    }

    // MARK: - Parsing

    /// Reads `ranges` from the call's arguments. No `ranges` (or an empty one)
    /// is the whole file. `offset`/`limit` are gone and rejected, so a model
    /// that still sends them is told instead of silently getting the whole file.
    init(arguments args: [String: Any]) throws {
        for legacy in ["offset", "limit"] where args[legacy] != nil {
            throw BuiltinToolError(
                "invalid argument '\(legacy)': read_file has no offset/limit, use 'ranges' instead (e.g. \"10-29\" or \"10+20\" for 20 lines from line 10)"
            )
        }
        switch args["ranges"] {
        case nil, is NSNull:
            self = .whole
        case let text as String:
            self = try ReadSelector(parsing: text)
        case let list as [Any]:
            let parts = try list.map { item -> String in
                guard let part = item as? String else { throw Self.invalidType }
                return part
            }
            self = try ReadSelector(parsing: parts.joined(separator: ","))
        default:
            throw Self.invalidType
        }
    }

    init(parsing text: String) throws {
        var chunks: [Chunk] = []
        for piece in text.split(separator: ",") {
            let piece = piece.trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { chunks.append(try Self.parseChunk(piece)) }
        }
        self = chunks.isEmpty ? .whole : ReadSelector(chunks: Self.merged(chunks))
    }

    private init(chunks: [Chunk]) {
        self.chunks = chunks
    }

    private static var invalidType: BuiltinToolError {
        BuiltinToolError("invalid argument 'ranges': expected a string such as \"10-29\" or \"1-40,1220-1270\"")
    }

    // Groups: 1 start, 2 '+', 3 count, 4 '-' or '..', 5 end.
    private static let chunkRegex = try! NSRegularExpression(
        pattern: #"^[Ll]?(\d+)(?:(\+)[Ll]?(\d+)|(-|\.\.)(?:[Ll]?(\d+))?)?$"#)

    private static func parseChunk(_ piece: String) throws -> Chunk {
        let whole = NSRange(piece.startIndex..., in: piece)
        guard let match = chunkRegex.firstMatch(in: piece, range: whole) else {
            throw BuiltinToolError(
                "invalid argument 'ranges': cannot parse \"\(piece)\"; use A-B, A+C or N-, comma-separated (e.g. \"1-40,1220-1270\")"
            )
        }
        func number(_ group: Int) throws -> Int? {
            guard let range = Range(match.range(at: group), in: piece) else { return nil }
            guard let value = Int(piece[range]) else {
                throw BuiltinToolError("invalid argument 'ranges': number out of range in \"\(piece)\"")
            }
            return value
        }

        guard let start = try number(1) else { throw BuiltinToolError("invalid argument 'ranges': \"\(piece)\"") }
        guard start >= 1 else {
            throw BuiltinToolError("invalid argument 'ranges': lines are 1-indexed, \"\(piece)\" starts at \(start)")
        }
        if let count = try number(3) {
            guard count >= 1 else {
                throw BuiltinToolError("invalid argument 'ranges': the count in \"\(piece)\" must be >= 1")
            }
            let (end, overflow) = start.addingReportingOverflow(count - 1)
            return Chunk(start: start, end: overflow ? nil : end)
        }
        if let end = try number(5) {
            guard end >= start else {
                throw BuiltinToolError("invalid argument 'ranges': \"\(piece)\" ends before it starts")
            }
            return Chunk(start: start, end: end)
        }
        return Chunk(start: start, end: nil)
    }

    private static func merged(_ chunks: [Chunk]) -> [Chunk] {
        var result: [Chunk] = []
        for chunk in chunks.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.end == nil || chunk.start - 1 <= last.end! {
                let end = (last.end == nil || chunk.end == nil) ? nil : max(last.end!, chunk.end!)
                result[result.count - 1] = Chunk(start: last.start, end: end)
            } else {
                result.append(chunk)
            }
        }
        return result
    }

    // MARK: - Resolving

    /// The windows to show in a file of `total` lines, spending at most
    /// `maxLines` lines across them. Ranges starting past the end are skipped
    /// with a notice rather than failing the read.
    func resolve(total: Int, maxLines: Int = ReadSelector.maxLines) -> Resolution {
        var resolution = Resolution()
        var remaining = maxLines
        for chunk in chunks {
            guard chunk.start <= total else {
                let lines = "\(total) \(total == 1 ? "line" : "lines")"
                resolution.notices.append("[Range \(chunk.label) is beyond end of file (\(lines) total); skipped]")
                continue
            }
            let count = min(chunk.end ?? total, total) - chunk.start + 1
            guard remaining > 0 else {
                resolution.truncated = true
                continue
            }
            let taken = min(count, remaining)
            resolution.windows.append(chunk.start...(chunk.start + taken - 1))
            remaining -= taken
            if taken < count { resolution.truncated = true }
        }
        return resolution
    }

    /// Ranges in the argument's own grammar, so a model can paste them into a
    /// follow-up call: `1-40, 1220-1270`. A single line is `5-5`, since a bare
    /// `5` would mean "from 5 on".
    static func format<S: Sequence>(_ ranges: S) -> String where S.Element == ClosedRange<Int> {
        ranges.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ", ")
    }
}
