import Foundation
import Testing

@testable import iCanHazAI

extension AllAppTests {
    @Suite("ProviderRegistry")
    struct ProviderRegistryTests {
        @Test("empty store has no configured providers")
        func empty() async throws {
            let registry = ProviderRegistry(store: InMemorySecretStore())
            try await registry.load()
            #expect(await registry.configuredProviders.isEmpty)
            #expect(await registry.isConfigured(.openai) == false)
            #expect(await registry.apiKey(for: .openai) == nil)
        }

        @Test("load reads existing keys and secrets")
        func load() async throws {
            let store = InMemorySecretStore()
            _ = try store.addKey(provider: .anthropic, name: "Default", secret: "fake-a")
            let registry = ProviderRegistry(store: store)
            try await registry.load()
            #expect(await registry.isConfigured(.anthropic))
            #expect(await registry.isConfigured(.openai) == false)
            #expect(await registry.apiKey(for: .anthropic) == "fake-a")
        }

        @Test("addKey updates the in-memory cache and the store")
        func add() async throws {
            let store = InMemorySecretStore()
            let registry = ProviderRegistry(store: store)
            try await registry.addKey(provider: .deepseek, name: "Default", secret: "fake-d")
            #expect(await registry.apiKey(for: .deepseek) == "fake-d")
            #expect(try store.listKeys().map(\.provider) == [.deepseek])
        }

        @Test("load discards keys that can't be decrypted")
        func discardsUndecryptable() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent(".storage/secrets.store")
            let old = EncryptedSecretStore(storeURL: url, machineID: { "MACHINE-A" })
            _ = try old.addKey(provider: .openai, name: "Default", secret: "fake")

            let registry = ProviderRegistry(store: EncryptedSecretStore(storeURL: url, machineID: { "MACHINE-B" }))
            try await registry.load()
            #expect(await registry.configuredProviders.isEmpty)
            #expect(try old.listKeys().isEmpty)
        }

        @Test("configured providers follow Provider.allCases order and are unique")
        func ordering() async throws {
            let registry = ProviderRegistry(store: InMemorySecretStore())
            try await registry.addKey(provider: .openrouter, name: "Default", secret: "1")
            try await registry.addKey(provider: .openai, name: "Default", secret: "2")
            try await registry.addKey(provider: .openai, name: "Second", secret: "3")
            #expect(await registry.configuredProviders == [.openai, .openrouter])
            #expect(await registry.apiKey(for: .openai) == "2")
        }
    }
}
