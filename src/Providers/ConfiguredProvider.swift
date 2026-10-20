// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A provider with at least one stored key, plus the state of its model list.
struct ConfiguredProvider: Sendable, Equatable, Identifiable {
    let provider: Provider
    /// The provider's keys, oldest first.
    var keys: [StoredKey]
    /// Per key id, the first and last 4 characters of its secret, for display.
    var keyPreviews: [UUID: String] = [:]
    /// The key new requests are made with.
    var selectedKeyID: UUID?
    var modelCount: Int?
    var isRefreshing: Bool
    var lastRefresh: Date?
    var lastError: String?

    var id: Provider { provider }
}
