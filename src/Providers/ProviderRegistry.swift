// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Configured providers and their API keys. Secrets are read once in `load()`
/// and kept in memory, so decryption doesn't happen per request.
///
/// A provider can hold several keys, one of which is the active key that new
/// requests use. The choice is persisted by the caller (`[providers]` in
/// `config.toml`); the registry only keeps it in memory and guarantees that a
/// provider with keys always has a usable active key.
actor ProviderRegistry {
    static let shared = ProviderRegistry(store: EncryptedSecretStore.shared)

    private let store: SecretStore
    /// In storage order: per provider, the oldest key first.
    private var keys: [StoredKey] = []
    private var secrets: [UUID: String] = [:]
    /// The preferred active key per provider. May point at a key that no
    /// longer exists; `selectedKey(for:)` falls back to the first key then.
    private var selected: [Provider: UUID] = [:]

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

    /// A provider without any key is disabled.
    func isConfigured(_ provider: Provider) -> Bool {
        keys.contains { $0.provider == provider }
    }

    /// The provider's keys, oldest first.
    func keys(for provider: Provider) -> [StoredKey] {
        keys.filter { $0.provider == provider }
    }

    /// The key as the UI shows it (see `StoredKey.preview(of:)`); the secret itself never leaves the registry.
    func preview(of keyID: UUID) -> String? {
        secrets[keyID].map(StoredKey.preview(of:))
    }

    /// The key new requests use: the chosen one while it exists, else the
    /// provider's first key. Nil only for a provider without keys.
    func selectedKey(for provider: Provider) -> StoredKey? {
        let candidates = keys(for: provider)
        return candidates.first { $0.id == selected[provider] } ?? candidates.first
    }

    /// The active key id of every configured provider.
    var selectedKeyIDs: [Provider: UUID] {
        var result: [Provider: UUID] = [:]
        for provider in configuredProviders { result[provider] = selectedKey(for: provider)?.id }
        return result
    }

    /// The secret of the active key.
    func apiKey(for provider: Provider) -> String? {
        selectedKey(for: provider).flatMap { secrets[$0.id] }
    }

    /// Adopts the persisted choice. Per provider the active key becomes the
    /// preferred one if it still exists, else the one that was active, else the
    /// first. Returns the effective choice, so the caller can write back what
    /// actually applies.
    @discardableResult
    func applySelection(_ preferred: [Provider: UUID]) -> [Provider: UUID] {
        var next: [Provider: UUID] = [:]
        for provider in configuredProviders {
            let ids = keys(for: provider).map(\.id)
            if let id = preferred[provider], ids.contains(id) {
                next[provider] = id
            } else if let id = selectedKey(for: provider)?.id {
                next[provider] = id
            }
        }
        selected = next
        return next
    }

    /// Makes the key the active one. Returns the key when the selection
    /// changed, nil when it is unknown or already active.
    @discardableResult
    func selectKey(_ id: UUID) -> StoredKey? {
        guard let key = keys.first(where: { $0.id == id }), selectedKey(for: key.provider)?.id != id else {
            return nil
        }
        selected[key.provider] = id
        return key
    }

    /// Changes the key's description. Nil when the key is unknown.
    @discardableResult
    func renameKey(_ id: UUID, to name: String) throws -> StoredKey? {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return nil }
        let renamed = try store.renameKey(keys[index], to: name)
        keys[index] = renamed
        return renamed
    }

    /// Removes the key and its secret. When it was the provider's active key,
    /// the next one takes over; a provider left without keys is disabled.
    /// Nil when the key is unknown.
    @discardableResult
    func deleteKey(_ id: UUID) throws -> StoredKey? {
        guard let key = keys.first(where: { $0.id == id }) else { return nil }
        try store.deleteKey(key)
        keys.removeAll { $0.id == id }
        secrets[id] = nil
        if selected[key.provider] == id { selected[key.provider] = nil }
        return key
    }

    /// The first key of a provider always becomes active; later ones only when `select` is set.
    @discardableResult
    func addKey(provider: Provider, name: String, secret: String, select: Bool = false) throws -> StoredKey {
        let isFirst = !isConfigured(provider)
        let key = try store.addKey(provider: provider, name: name, secret: secret)
        keys.append(key)
        secrets[key.id] = secret
        if isFirst || select { selected[provider] = key.id }
        return key
    }
}
