// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A provider with a stored key, plus the state of its model list.
struct ConfiguredProvider: Sendable, Equatable, Identifiable {
    let provider: Provider
    var modelCount: Int?
    var isRefreshing: Bool
    var lastRefresh: Date?
    var lastError: String?

    var id: Provider { provider }
}
