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
    /// The definition (endpoint, color) of a custom provider; nil for a built-in one.
    var custom: CustomProviderConfig?

    var id: Provider { provider }
}

extension Array where Element == ConfiguredProvider {
    /// Some provider hasn't had its first refresh finish, successfully or not,
    /// so its models may still be on their way. Once every provider has
    /// answered, an empty model list is the answer, not a wait.
    var hasPendingModels: Bool {
        contains { $0.modelCount == nil && $0.lastError == nil }
    }
}
