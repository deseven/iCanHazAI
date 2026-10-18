// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Key metadata only; the secret is read separately.
struct StoredKey: Identifiable, Hashable, Sendable {
    let id: UUID
    let provider: Provider
    let name: String
}

protocol SecretStore: Sendable {
    func listKeys() throws -> [StoredKey]
    func secret(for key: StoredKey) throws -> String
    func addKey(provider: Provider, name: String, secret: String) throws -> StoredKey
    func deleteKey(_ key: StoredKey) throws

    /// Standalone secrets that aren't provider keys, e.g. `web_search.token`.
    /// Setting `nil` deletes the secret.
    func namedSecret(_ name: String) throws -> String?
    func setNamedSecret(_ name: String, to value: String?) throws
}

enum SecretStoreError: Error, LocalizedError, Equatable {
    case keyNotFound
    case machineIDUnavailable
    /// The stored secret can't be opened, e.g. after the data directory moved to another Mac.
    case undecryptable
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .keyNotFound:
            return "The requested API key was not found."
        case .machineIDUnavailable:
            return "Could not read this Mac's hardware UUID, which the API keys are encrypted with."
        case .undecryptable:
            return "A stored API key can't be decrypted. It was probably saved on another Mac; add it again."
        case .storage(let message):
            return "Secret storage failed: \(message)"
        }
    }
}

/// Test double that keeps keys in memory.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [StoredKey] = []
    private var secrets: [UUID: String] = [:]
    private var named: [String: String] = [:]

    init() {}

    func listKeys() throws -> [StoredKey] {
        lock.withLock { keys }
    }

    func secret(for key: StoredKey) throws -> String {
        try lock.withLock {
            guard let secret = secrets[key.id] else { throw SecretStoreError.keyNotFound }
            return secret
        }
    }

    func addKey(provider: Provider, name: String, secret: String) throws -> StoredKey {
        lock.withLock {
            let key = StoredKey(id: UUID(), provider: provider, name: name)
            keys.append(key)
            secrets[key.id] = secret
            return key
        }
    }

    func deleteKey(_ key: StoredKey) throws {
        lock.withLock {
            keys.removeAll { $0.id == key.id }
            secrets[key.id] = nil
        }
    }

    func namedSecret(_ name: String) throws -> String? {
        lock.withLock { named[name] }
    }

    func setNamedSecret(_ name: String, to value: String?) throws {
        lock.withLock { named[name] = value }
    }
}
