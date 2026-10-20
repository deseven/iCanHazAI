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

        // MARK: - Several keys per provider

        @Test("the first key becomes active, later ones only when asked to")
        func activeOnAdd() async throws {
            let registry = ProviderRegistry(store: InMemorySecretStore())
            let first = try await registry.addKey(provider: .openai, name: "Default", secret: "1")
            let second = try await registry.addKey(provider: .openai, name: "Work", secret: "2")
            #expect(await registry.selectedKey(for: .openai) == first)
            #expect(await registry.apiKey(for: .openai) == "1")

            let third = try await registry.addKey(provider: .openai, name: "Spare", secret: "3", select: true)
            #expect(await registry.selectedKey(for: .openai) == third)
            #expect(await registry.apiKey(for: .openai) == "3")
            #expect(await registry.keys(for: .openai) == [first, second, third])
        }

        @Test("keys are tracked per provider")
        func perProvider() async throws {
            let registry = ProviderRegistry(store: InMemorySecretStore())
            let openai = try await registry.addKey(provider: .openai, name: "Default", secret: "1")
            let anthropic = try await registry.addKey(provider: .anthropic, name: "Default", secret: "2")
            try await registry.addKey(provider: .anthropic, name: "Work", secret: "3", select: true)
            #expect(await registry.keys(for: .openai) == [openai])
            #expect(await registry.keys(for: .anthropic).count == 2)
            #expect(await registry.keys(for: .deepseek).isEmpty)
            #expect(await registry.selectedKey(for: .openai) == openai)
            #expect(await registry.selectedKey(for: .anthropic) != anthropic)
            #expect(await registry.selectedKey(for: .deepseek) == nil)
            #expect(await registry.selectedKeyIDs.keys.sorted { $0.rawValue < $1.rawValue } == [.anthropic, .openai])
        }

        @Test("selectKey switches the key that requests use")
        func selectKey() async throws {
            let registry = ProviderRegistry(store: InMemorySecretStore())
            try await registry.addKey(provider: .openai, name: "Default", secret: "1")
            let second = try await registry.addKey(provider: .openai, name: "Work", secret: "2")

            #expect(await registry.selectKey(second.id) == second)
            #expect(await registry.apiKey(for: .openai) == "2")
            // Already active or unknown: nothing changes.
            #expect(await registry.selectKey(second.id) == nil)
            #expect(await registry.selectKey(UUID()) == nil)
            #expect(await registry.apiKey(for: .openai) == "2")
        }

        @Test("the active key is adopted from the persisted choice")
        func applySelection() async throws {
            let store = InMemorySecretStore()
            let first = try store.addKey(provider: .openai, name: "Default", secret: "1")
            let second = try store.addKey(provider: .openai, name: "Work", secret: "2")
            let registry = ProviderRegistry(store: store)
            try await registry.load()
            #expect(await registry.selectedKey(for: .openai) == first)

            let effective = await registry.applySelection([.openai: second.id])
            #expect(effective == [.openai: second.id])
            #expect(await registry.apiKey(for: .openai) == "2")
        }

        @Test("a missing key falls back to the first remaining one, and a provider without keys is dropped")
        func applySelectionFallback() async throws {
            let store = InMemorySecretStore()
            let first = try store.addKey(provider: .openai, name: "Default", secret: "1")
            _ = try store.addKey(provider: .openai, name: "Work", secret: "2")
            let registry = ProviderRegistry(store: store)
            try await registry.load()

            let effective = await registry.applySelection([.openai: UUID(), .deepseek: UUID()])
            #expect(effective == [.openai: first.id])
            #expect(await registry.apiKey(for: .openai) == "1")
            #expect(!(await registry.isConfigured(.deepseek)))
        }

        // MARK: - Renaming and deleting keys

        @Test("renaming changes only the description, in memory and in the store")
        func renameKey() async throws {
            let store = InMemorySecretStore()
            let registry = ProviderRegistry(store: store)
            let first = try await registry.addKey(provider: .openai, name: "Default", secret: "1")
            try await registry.addKey(provider: .openai, name: "Work", secret: "2")

            let renamed = try await registry.renameKey(first.id, to: "Personal")
            #expect(renamed == StoredKey(id: first.id, provider: .openai, name: "Personal"))
            #expect(await registry.keys(for: .openai).map(\.name) == ["Personal", "Work"])
            #expect(try store.listKeys().map(\.name) == ["Personal", "Work"])
            // The renamed key is still the active one, with the same secret.
            #expect(await registry.selectedKey(for: .openai)?.name == "Personal")
            #expect(await registry.apiKey(for: .openai) == "1")

            #expect(try await registry.renameKey(UUID(), to: "Ghost") == nil)
        }

        @Test("deleting the active key hands over to the first remaining one")
        func deleteActiveKey() async throws {
            let store = InMemorySecretStore()
            let registry = ProviderRegistry(store: store)
            let first = try await registry.addKey(provider: .openai, name: "Default", secret: "1")
            let second = try await registry.addKey(provider: .openai, name: "Work", secret: "2", select: true)
            let third = try await registry.addKey(provider: .openai, name: "Spare", secret: "3")

            #expect(try await registry.deleteKey(second.id) == second)
            #expect(await registry.keys(for: .openai) == [first, third])
            #expect(await registry.selectedKey(for: .openai) == first)
            #expect(await registry.apiKey(for: .openai) == "1")
            #expect(await registry.selectedKeyIDs == [.openai: first.id])
            #expect(await registry.preview(of: second.id) == nil)
            #expect(try store.listKeys() == [first, third])
        }

        @Test("deleting another key keeps the active one")
        func deleteInactiveKey() async throws {
            let registry = ProviderRegistry(store: InMemorySecretStore())
            try await registry.addKey(provider: .openai, name: "Default", secret: "1")
            let second = try await registry.addKey(provider: .openai, name: "Work", secret: "2", select: true)
            let third = try await registry.addKey(provider: .openai, name: "Spare", secret: "3")

            try await registry.deleteKey(third.id)
            #expect(await registry.selectedKey(for: .openai) == second)
            #expect(await registry.apiKey(for: .openai) == "2")
        }

        @Test("deleting the last key of a provider disables it, and a new key starts over")
        func deleteLastKey() async throws {
            let store = InMemorySecretStore()
            let registry = ProviderRegistry(store: store)
            let only = try await registry.addKey(provider: .openai, name: "Default", secret: "1")
            let other = try await registry.addKey(provider: .anthropic, name: "Default", secret: "2")

            try await registry.deleteKey(only.id)
            #expect(!(await registry.isConfigured(.openai)))
            #expect(await registry.configuredProviders == [.anthropic])
            #expect(await registry.apiKey(for: .openai) == nil)
            #expect(await registry.selectedKeyIDs == [.anthropic: other.id])
            #expect(try store.listKeys() == [other])

            let again = try await registry.addKey(provider: .openai, name: "Fresh", secret: "3")
            #expect(await registry.selectedKey(for: .openai) == again)
        }

        @Test("deleting an unknown key changes nothing")
        func deleteUnknownKey() async throws {
            let registry = ProviderRegistry(store: InMemorySecretStore())
            let key = try await registry.addKey(provider: .openai, name: "Default", secret: "1")
            #expect(try await registry.deleteKey(UUID()) == nil)
            #expect(await registry.keys(for: .openai) == [key])
        }

        @Test("a key is previewed as its first and last 4 characters, a short one fully masked, an empty one as none")
        func preview() async throws {
            #expect(StoredKey.preview(of: "sk-ant-api03-abcdefghijklmnop") == "sk-a…mnop")
            #expect(StoredKey.preview(of: "123456789012") == "1234…9012")
            #expect(StoredKey.preview(of: "12345678901") == "••••••••")
            #expect(StoredKey.preview(of: "") == "No API key")

            let registry = ProviderRegistry(store: InMemorySecretStore())
            let key = try await registry.addKey(provider: .openai, name: "Default", secret: "sk-proj-0123456789-WXYZ")
            #expect(await registry.preview(of: key.id) == "sk-p…WXYZ")
            #expect(await registry.preview(of: UUID()) == nil)
        }

        @Test("an unreadable key is skipped and the next one becomes active")
        func undecryptableActiveKey() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent(".storage/secrets.store")
            let other = EncryptedSecretStore(storeURL: url, machineID: { "MACHINE-A" })
            let lost = try other.addKey(provider: .openai, name: "Default", secret: "old")

            let store = EncryptedSecretStore(storeURL: url, machineID: { "MACHINE-B" })
            let kept = try store.addKey(provider: .openai, name: "Work", secret: "new")
            let registry = ProviderRegistry(store: store)
            try await registry.load()

            let effective = await registry.applySelection([.openai: lost.id])
            #expect(effective == [.openai: kept.id])
            #expect(await registry.apiKey(for: .openai) == "new")
        }
    }
}
