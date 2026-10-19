// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Case-insensitive search shared by the pickers and the chat filter.
///
/// The query is split on whitespace; every word must match at least one of
/// the item's keys (words may match different keys). A word matches as a
/// substring, ranked best-first: whole key, key prefix, start of a word
/// (after punctuation or a space), anywhere. Items are scored by the sum of
/// their words' ranks; ties keep the input order (so a recency-ordered list
/// stays recency-ordered).
///
/// Only when no item matches as substrings does a second pass also accept a
/// word as a subsequence of a key (`dpl` finds "Deploy scripts"), ranked
/// below any substring match. Keeping it a fallback stops short queries from
/// matching nearly everything.
///
/// Linear in the total key length, so it stays instant on large catalogs
/// even in debug builds.
enum SearchMatcher {
    /// Returns the items matching `query`, best matches first. An empty
    /// (or whitespace-only) query returns the items unchanged.
    static func rank<Item>(_ items: [Item], query: String, keys: (Item) -> [String]) -> [Item] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(Word.init)
        guard !words.isEmpty else { return items }

        let prepared = items.map { item in keys(item).map(Key.init) }
        var ranked = scored(prepared, words: words, allowSubsequence: false)
        if ranked.isEmpty { ranked = scored(prepared, words: words, allowSubsequence: true) }
        ranked.sort { $0.score == $1.score ? $0.index < $1.index : $0.score < $1.score }
        return ranked.map { items[$0.index] }
    }

    private struct Word {
        let bytes: [UInt8]
        let scalars: [Unicode.Scalar]

        init(_ word: Substring) {
            bytes = Array(word.utf8)
            scalars = Array(word.unicodeScalars)
        }
    }

    private struct Key {
        let bytes: [UInt8]
        let lowered: String

        init(_ key: String) {
            lowered = key.lowercased()
            bytes = Array(lowered.utf8)
        }
    }

    private static let subsequenceRank = 4

    private static func scored(
        _ prepared: [[Key]], words: [Word], allowSubsequence: Bool
    ) -> [(index: Int, score: Int)] {
        var result: [(index: Int, score: Int)] = []
        for (index, keys) in prepared.enumerated() {
            var total = 0
            var matchedAll = true
            for word in words {
                var best: Int?
                for key in keys {
                    var rank = substringRank(word.bytes, in: key.bytes)
                    if rank == nil, allowSubsequence, isSubsequence(word.scalars, of: key.lowered) {
                        rank = subsequenceRank
                    }
                    if let rank, rank < (best ?? Int.max) { best = rank }
                }
                guard let best else {
                    matchedAll = false
                    break
                }
                total += best
            }
            if matchedAll { result.append((index, total)) }
        }
        return result
    }

    /// 0 whole key, 1 prefix, 2 start of a word, 3 elsewhere; nil when absent.
    private static func substringRank(_ word: [UInt8], in key: [UInt8]) -> Int? {
        let n = key.count
        let m = word.count
        guard m > 0, m <= n else { return nil }
        var best: Int?
        var i = 0
        while i <= n - m {
            if key[i] == word[0] && matches(word, in: key, at: i) {
                if i == 0 { return m == n ? 0 : 1 }
                let rank = isWordByte(key[i - 1]) ? 3 : 2
                if rank < (best ?? Int.max) { best = rank }
            }
            i += 1
        }
        return best
    }

    private static func matches(_ word: [UInt8], in key: [UInt8], at start: Int) -> Bool {
        var j = 1
        while j < word.count {
            if key[start + j] != word[j] { return false }
            j += 1
        }
        return true
    }

    /// Letters and digits (and any non-ASCII byte, so a multi-byte character
    /// never looks like it contains a boundary) continue a word.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A) || byte >= 0x80
    }

    private static func isSubsequence(_ word: [Unicode.Scalar], of key: String) -> Bool {
        var next = 0
        for scalar in key.unicodeScalars where scalar == word[next] {
            next += 1
            if next == word.count { return true }
        }
        return false
    }
}
