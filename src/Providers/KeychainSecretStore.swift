// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security

/// API keys as generic passwords in the user's login keychain.
///
/// `namespace` (the workdir path in production) is stored on every item, so the
/// dev and release apps, which use different workdirs, never see each other's
/// keys. Calls can block and may show an access prompt, so keep them off the
/// main actor.
final class KeychainSecretStore: SecretStore, Sendable {
    private static let servicePrefix = "icanhazai.provider."

    private let namespace: Data

    init(namespace: String) {
        self.namespace = Data(namespace.utf8)
    }

    convenience init(env: EnvironmentManager) {
        self.init(namespace: env.rootURL.standardizedFileURL.path)
    }

    // MARK: - SecretStore

    func listKeys() throws -> [StoredKey] {
        var keys: [StoredKey] = []
        for provider in Provider.allCases {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: Self.service(for: provider),
                kSecAttrGeneric: namespace,
                kSecReturnAttributes: true,
                kSecMatchLimit: kSecMatchLimitAll,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else {
                throw SecretStoreError.keychain(operation: "list", status: status)
            }
            let items = result as? [[String: Any]] ?? []
            let found: [StoredKey] = items.compactMap { item in
                guard let account = item[kSecAttrAccount as String] as? String,
                    let id = UUID(uuidString: account)
                else { return nil }
                return StoredKey(id: id, provider: provider, name: item[kSecAttrComment as String] as? String ?? "")
            }
            keys += found.sorted { $0.name < $1.name }
        }
        return keys
    }

    func secret(for key: StoredKey) throws -> String {
        var query = identity(of: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw SecretStoreError.keyNotFound }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychain(operation: "read", status: status)
        }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.keyNotFound
        }
        return secret
    }

    func addKey(provider: Provider, name: String, secret: String) throws -> StoredKey {
        let key = StoredKey(id: UUID(), provider: provider, name: name)
        var attributes = identity(of: key)
        attributes[kSecAttrLabel] = "iCanHazAI \(provider.displayName) (\(name))"
        attributes[kSecAttrComment] = name
        attributes[kSecValueData] = Data(secret.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.keychain(operation: "add", status: status)
        }
        return key
    }

    /// Not part of `SecretStore` (there is no key deletion in the app yet);
    /// used to clean up after tests.
    func deleteKey(_ key: StoredKey) throws {
        let status = SecItemDelete(identity(of: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(operation: "delete", status: status)
        }
    }

    // MARK: - Helpers

    private static func service(for provider: Provider) -> String {
        servicePrefix + provider.rawValue
    }

    private func identity(of key: StoredKey) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service(for: key.provider),
            kSecAttrAccount: key.id.uuidString,
            kSecAttrGeneric: namespace,
        ]
    }
}
