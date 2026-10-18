import Foundation
import Testing

@testable import iCanHazAI

/// Whether this environment has a usable login keychain (CI sandboxes may
/// not). The suite is skipped rather than failed when it doesn't.
private let keychainAvailable: Bool = {
    let store = KeychainSecretStore(namespace: "test-probe-\(UUID().uuidString)")
    guard let key = try? store.addKey(provider: .openai, name: "Probe", secret: "probe") else { return false }
    try? store.deleteKey(key)
    return true
}()

/// These touch the real login keychain, using a unique namespace per test and
/// deleting everything they add.
extension AllAppTests {
    @Suite("KeychainSecretStore", .enabled(if: keychainAvailable))
    struct KeychainSecretStoreTests {
        private func makeStore(namespace: String = "test-\(UUID().uuidString)") -> KeychainSecretStore {
            KeychainSecretStore(namespace: namespace)
        }

        @Test("add, list and read, from a fresh instance too")
        func roundTrip() throws {
            let namespace = "test-\(UUID().uuidString)"
            let store = makeStore(namespace: namespace)
            #expect(try store.listKeys().isEmpty)

            let secret = "sk-test-\(UUID().uuidString)"
            let openai = try store.addKey(provider: .openai, name: "Default", secret: secret)
            let anthropic = try store.addKey(provider: .anthropic, name: "Default", secret: "other-secret")
            defer {
                try? store.deleteKey(openai)
                try? store.deleteKey(anthropic)
            }

            let keys = try store.listKeys()
            #expect(keys.map(\.provider) == [.openai, .anthropic])
            #expect(keys.first?.id == openai.id)
            #expect(keys.first?.name == "Default")
            #expect(try store.secret(for: openai) == secret)

            let reopened = makeStore(namespace: namespace)
            #expect(try reopened.listKeys().map(\.id) == keys.map(\.id))
            #expect(try reopened.secret(for: openai) == secret)
        }

        @Test("namespaces are isolated from each other")
        func isolation() throws {
            let a = makeStore()
            let b = makeStore()
            let key = try a.addKey(provider: .deepseek, name: "Default", secret: "fake")
            defer { try? a.deleteKey(key) }

            #expect(try a.listKeys().count == 1)
            #expect(try b.listKeys().isEmpty)
            #expect(throws: SecretStoreError.keyNotFound) { try b.secret(for: key) }
        }

        @Test("a deleted or unknown key reports keyNotFound")
        func missingKey() throws {
            let store = makeStore()
            let key = try store.addKey(provider: .openrouter, name: "Default", secret: "fake")
            try store.deleteKey(key)
            #expect(try store.listKeys().isEmpty)
            #expect(throws: SecretStoreError.keyNotFound) { try store.secret(for: key) }
        }
    }
}
