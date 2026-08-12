// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Fuse

/// Thin wrapper over fuse-swift providing ranked fuzzy filtering for the
/// picker dialogs (role, MCP, working directory). Fuse scores lower-is-better
/// (0 = perfect match); results are sorted by score, then alphabetically for
/// stable ordering of ties.
enum FuzzySearch {
    /// Returns the candidates matching `query`, best matches first. An empty
    /// (or whitespace-only) query returns the candidates unchanged.
    /// `maxPatternLength` is raised from Fuse's default 32 so long paths can
    /// be used as queries; candidates are matched verbatim.
    static func rank(_ candidates: [String], query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return candidates }
        let fuse = Fuse(distance: 1000, threshold: 0.4, maxPatternLength: 256)
        let pattern = fuse.createPattern(from: q)
        return
            candidates
            .compactMap { candidate -> (String, Double)? in
                guard let result = fuse.search(pattern, in: candidate) else { return nil }
                return (candidate, result.score)
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending : lhs.1 < rhs.1
            }
            .map(\.0)
    }

    /// Ranks items by the best fuzzy score across multiple keys per item
    /// (e.g. a role's name and description).
    static func rank<Item>(_ items: [Item], query: String, keys: (Item) -> [String]) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        let fuse = Fuse(distance: 1000, threshold: 0.4, maxPatternLength: 256)
        let pattern = fuse.createPattern(from: q)
        return
            items
            .compactMap { item -> (Item, Double)? in
                let best = keys(item).compactMap { fuse.search(pattern, in: $0)?.score }.min()
                guard let best else { return nil }
                return (item, best)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }
}
