// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Configured providers and their API keys. Secrets are read once in `load()`
/// and kept in memory, because keychain access can prompt and must not happen
/// per request.
actor ProviderRegistry {
    static let shared = ProviderRegistry(store: KeychainSecretStore(env: EnvironmentManager.shared))

    private let store: SecretStore
    private var keys: [StoredKey] = []
    private var secrets: [UUID: String] = [:]

    init(store: SecretStore) {
        self.store = store
    }

    /// Number of distinct providers with a stored key, from key metadata only
    /// (no secrets are read, so it can't trigger a keychain prompt).
    nonisolated func storedProviderCount() -> Int {
        Set((try? store.listKeys())?.map(\.provider) ?? []).count
    }

    func load() throws {
        let listed = try store.listKeys()
        var loaded: [UUID: String] = [:]
        for key in listed {
            loaded[key.id] = try store.secret(for: key)
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
