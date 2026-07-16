// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Reports the rendered height of a single row so a list can size its scroll
/// area to fit an exact number of rows (calculated at runtime rather than
/// hard-coded in points).
struct RowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Tags this view with its rendered height via `RowHeightKey`. Attach to a
    /// row inside a `ForEach`; the enclosing list reads the (max) row height.
    func measureRowHeight() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: RowHeightKey.self, value: geo.size.height)
            }
        )
    }
}

/// Collects per-row heights keyed by index, for lists whose rows have variable
/// heights (e.g. multi-line subtitles). The enclosing list sums the heights it
/// needs to size its scroll area to fit an exact number of rows.
struct IndexedRowHeightKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Tags this view with its rendered height at `index` via
    /// `IndexedRowHeightKey`.
    func measureRowHeight(at index: Int) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: IndexedRowHeightKey.self, value: [index: geo.size.height])
            }
        )
    }
}
