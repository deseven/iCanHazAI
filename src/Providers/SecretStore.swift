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
}

enum SecretStoreError: Error, LocalizedError, Equatable {
    case keyNotFound
    case keychain(operation: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .keyNotFound:
            return "The requested API key was not found in the keychain."
        case .keychain(let operation, let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain \(operation) failed: \(message)"
        }
    }
}

/// Test double that keeps keys in memory.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [StoredKey] = []
    private var secrets: [UUID: String] = [:]

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
}
