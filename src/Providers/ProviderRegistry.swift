// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Configured providers and their API keys. Secrets are read once in `load()`
/// and kept in memory, so decryption doesn't happen per request.
actor ProviderRegistry {
    static let shared = ProviderRegistry(store: EncryptedSecretStore.shared)

    private let store: SecretStore
    private var keys: [StoredKey] = []
    private var secrets: [UUID: String] = [:]

    init(store: SecretStore) {
        self.store = store
    }

    /// Number of distinct providers with a stored key, from key metadata only
    /// (no secrets are decrypted).
    nonisolated func storedProviderCount() -> Int {
        Set((try? store.listKeys())?.map(\.provider) ?? []).count
    }

    /// A key that can't be decrypted (e.g. the data directory came from another
    /// Mac) is deleted and skipped. With no keys left, the app shows the New
    /// Provider wizard.
    func load() throws {
        var listed: [StoredKey] = []
        var loaded: [UUID: String] = [:]
        for key in try store.listKeys() {
            do {
                loaded[key.id] = try store.secret(for: key)
                listed.append(key)
            } catch SecretStoreError.undecryptable {
                debugLog("Providers", "⚠️ discarding undecryptable \(key.provider.displayName) key '\(key.name)'")
                try store.deleteKey(key)
            }
        }
        keys = listed
        secrets = loaded
    }

    /// Unique, in `Provider.allCases` order.
    var configuredProviders: [Provider] {
        let present = Set(keys.map(\.provider))
        return Provider.allCases.filter(present.contains)
    }

    func isConfigured(_ provider: Provider) -> Bool {
        keys.contains { $0.provider == provider }
    }

    /// The first key of the provider (only `Default` exists for now).
    func apiKey(for provider: Provider) -> String? {
        keys.first { $0.provider == provider }.flatMap { secrets[$0.id] }
    }

    func addKey(provider: Provider, name: String, secret: String) throws {
        let key = try store.addKey(provider: provider, name: name, secret: secret)
        keys.append(key)
        secrets[key.id] = secret
    }
}
