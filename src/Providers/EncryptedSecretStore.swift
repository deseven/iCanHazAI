// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import IOKit
import SwiftData

enum MachineID {
    /// The hardware UUID (`IOPlatformUUID`). It's readable by any local
    /// process, so it only ties data to this Mac; it is not a secret.
    static func current() throws -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { throw SecretStoreError.machineIDUnavailable }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        guard let id = property?.takeRetainedValue() as? String, !id.isEmpty else {
            throw SecretStoreError.machineIDUnavailable
        }
        return id
    }
}

@Model
final class StoredSecretEntry {
    @Attribute(.unique) var id: UUID
    var provider: String
    var name: String
    var createdAt: Date
    /// AES-GCM combined box (nonce + ciphertext + tag).
    var sealed: Data

    init(id: UUID, provider: String, name: String, createdAt: Date, sealed: Data) {
        self.id = id
        self.provider = provider
        self.name = name
        self.createdAt = createdAt
        self.sealed = sealed
    }
}

/// A standalone secret that isn't a provider key, e.g. `web_search.token`.
@Model
final class StoredNamedSecret {
    @Attribute(.unique) var name: String
    var sealed: Data

    init(name: String, sealed: Data) {
        self.name = name
        self.sealed = sealed
    }
}

/// Secrets in a SwiftData store (`.storage/secrets.store`), each one sealed
/// with AES-GCM under a key derived from the machine UUID. A copy of the data
/// directory is useless on another Mac, but this is not protection against
/// code running as the user on this one.
///
/// The container and the key are created lazily on first use, so failures
/// surface as `SecretStoreError`s from the operations rather than from `init`.
final class EncryptedSecretStore: SecretStore, @unchecked Sendable {
    static let shared = EncryptedSecretStore(env: EnvironmentManager.shared)

    private static let salt = Data("wtf.d7.icanhazai.secrets".utf8)
    private static let info = Data("api-key-encryption.v1".utf8)

    private let storeURL: URL
    private let machineID: @Sendable () throws -> String
    private let queue = DispatchQueue(label: "iCanHazAI.secretStore")
    private var _context: ModelContext?
    private var _key: SymmetricKey?

    init(storeURL: URL, machineID: @escaping @Sendable () throws -> String = MachineID.current) {
        self.storeURL = storeURL
        self.machineID = machineID
    }

    convenience init(env: EnvironmentManager) {
        self.init(storeURL: env.rootURL.appendingPathComponent(".storage/secrets.store"))
    }

    // MARK: - Provider keys

    func listKeys() throws -> [StoredKey] {
        try queue.sync {
            let order = Dictionary(uniqueKeysWithValues: Provider.allCases.enumerated().map { ($1, $0) })
            let keys: [StoredKey] = try fetch(StoredSecretEntry.self).compactMap { entry in
                guard let provider = Provider(rawValue: entry.provider) else { return nil }
                return StoredKey(id: entry.id, provider: provider, name: entry.name)
            }
            return keys.sorted {
                ($0.provider != $1.provider) ? order[$0.provider]! < order[$1.provider]! : $0.name < $1.name
            }
        }
    }

    func secret(for key: StoredKey) throws -> String {
        try queue.sync {
            guard let entry = try fetch(StoredSecretEntry.self).first(where: { $0.id == key.id }) else {
                throw SecretStoreError.keyNotFound
            }
            return try open(entry.sealed, aad: Self.aad(id: entry.id, provider: entry.provider))
        }
    }

    func addKey(provider: Provider, name: String, secret: String) throws -> StoredKey {
        try queue.sync {
            let key = StoredKey(id: UUID(), provider: provider, name: name)
            let sealed = try seal(secret, aad: Self.aad(id: key.id, provider: provider.rawValue))
            let context = try openContext()
            context.insert(
                StoredSecretEntry(
                    id: key.id, provider: provider.rawValue, name: name, createdAt: Date(), sealed: sealed))
            try save(context)
            return key
        }
    }

    func deleteKey(_ key: StoredKey) throws {
        try queue.sync {
            let context = try openContext()
            for entry in try fetch(StoredSecretEntry.self) where entry.id == key.id { context.delete(entry) }
            try save(context)
        }
    }

    // MARK: - Named secrets

    func namedSecret(_ name: String) throws -> String? {
        try queue.sync {
            guard let entry = try fetch(StoredNamedSecret.self).first(where: { $0.name == name }) else { return nil }
            return try open(entry.sealed, aad: Self.aad(named: name))
        }
    }

    func setNamedSecret(_ name: String, to value: String?) throws {
        try queue.sync {
            let context = try openContext()
            let existing = try fetch(StoredNamedSecret.self).first { $0.name == name }
            if let value {
                let sealed = try seal(value, aad: Self.aad(named: name))
                if let existing {
                    existing.sealed = sealed
                } else {
                    context.insert(StoredNamedSecret(name: name, sealed: sealed))
                }
            } else if let existing {
                context.delete(existing)
            } else {
                return
            }
            try save(context)
        }
    }

    // MARK: - Crypto

    /// Binds a sealed secret to its slot, so rows can't be swapped in the database.
    private static func aad(id: UUID, provider: String) -> Data {
        Data("key|\(id.uuidString)|\(provider)".utf8)
    }

    private static func aad(named name: String) -> Data {
        Data("named|\(name)".utf8)
    }

    private func derivedKey() throws -> SymmetricKey {
        if let key = _key { return key }
        let id = try machineID()
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(id.utf8)), salt: Self.salt, info: Self.info,
            outputByteCount: 32)
        _key = key
        return key
    }

    private func seal(_ secret: String, aad: Data) throws -> Data {
        do {
            let box = try AES.GCM.seal(Data(secret.utf8), using: try derivedKey(), authenticating: aad)
            guard let combined = box.combined else { throw SecretStoreError.storage("could not seal the secret") }
            return combined
        } catch let error as SecretStoreError {
            throw error
        } catch {
            throw SecretStoreError.storage("could not seal the secret: \(error.localizedDescription)")
        }
    }

    private func open(_ sealed: Data, aad: Data) throws -> String {
        let key = try derivedKey()
        do {
            let data = try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
            guard let secret = String(data: data, encoding: .utf8) else { throw SecretStoreError.undecryptable }
            return secret
        } catch {
            throw SecretStoreError.undecryptable
        }
    }

    // MARK: - SwiftData

    /// Must be called on `queue`.
    private func openContext() throws -> ModelContext {
        if let context = _context { return context }
        do {
            let directory = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let schema = Schema([StoredSecretEntry.self, StoredNamedSecret.self])
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: storeURL))
            let context = ModelContext(container)
            _context = context
            return context
        } catch {
            throw SecretStoreError.storage(error.localizedDescription)
        }
    }

    private func fetch<T: PersistentModel>(_ type: T.Type) throws -> [T] {
        let context = try openContext()
        do {
            return try context.fetch(FetchDescriptor<T>())
        } catch {
            throw SecretStoreError.storage(error.localizedDescription)
        }
    }

    private func save(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw SecretStoreError.storage(error.localizedDescription)
        }
    }
}
