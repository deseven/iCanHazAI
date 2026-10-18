import Foundation
import Testing

@testable import iCanHazAI

extension AllAppTests {
    @Suite("EncryptedSecretStore")
    struct EncryptedSecretStoreTests {
        private func makeDir() -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("secrets-\(UUID().uuidString)")
        }

        private func makeStore(_ dir: URL, machine: String = "MACHINE-A") -> EncryptedSecretStore {
            EncryptedSecretStore(storeURL: dir.appendingPathComponent(".storage/secrets.store"), machineID: { machine })
        }

        @Test("add, list and read, from a fresh instance too")
        func roundTrip() throws {
            let dir = makeDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = makeStore(dir)
            #expect(try store.listKeys().isEmpty)

            let openai = try store.addKey(provider: .openai, name: "Default", secret: "sk-secret-1")
            let anthropic = try store.addKey(provider: .anthropic, name: "Default", secret: "other-secret")

            let keys = try store.listKeys()
            #expect(keys.map(\.provider) == [.openai, .anthropic])
            #expect(keys.first?.id == openai.id)
            #expect(keys.first?.name == "Default")
            #expect(try store.secret(for: openai) == "sk-secret-1")
            #expect(try store.secret(for: anthropic) == "other-secret")

            let reopened = makeStore(dir)
            #expect(try reopened.listKeys().map(\.id) == keys.map(\.id))
            #expect(try reopened.secret(for: openai) == "sk-secret-1")
        }

        @Test("the secret is not stored in plain text")
        func notPlainText() throws {
            let dir = makeDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = makeStore(dir)
            let secret = "sk-very-recognizable-\(UUID().uuidString)"
            _ = try store.addKey(provider: .openai, name: "Default", secret: secret)
            try store.setNamedSecret("web_search.token", to: secret)

            let storage = dir.appendingPathComponent(".storage")
            let files = try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
            #expect(!files.isEmpty)
            for file in files {
                let data = try Data(contentsOf: file)
                #expect(data.range(of: Data(secret.utf8)) == nil)
            }
        }

        @Test("another machine can't decrypt")
        func otherMachine() throws {
            let dir = makeDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let key = try makeStore(dir).addKey(provider: .deepseek, name: "Default", secret: "fake")
            try makeStore(dir).setNamedSecret("web_search.token", to: "tok")

            let other = makeStore(dir, machine: "MACHINE-B")
            #expect(try other.listKeys().map(\.id) == [key.id])
            #expect(throws: SecretStoreError.undecryptable) { try other.secret(for: key) }
            #expect(throws: SecretStoreError.undecryptable) { try other.namedSecret("web_search.token") }
        }

        @Test("a deleted or unknown key reports keyNotFound")
        func missingKey() throws {
            let dir = makeDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = makeStore(dir)
            let key = try store.addKey(provider: .openrouter, name: "Default", secret: "fake")
            try store.deleteKey(key)
            #expect(try store.listKeys().isEmpty)
            #expect(throws: SecretStoreError.keyNotFound) { try store.secret(for: key) }
        }

        @Test("named secrets: set, replace, read, delete")
        func namedSecrets() throws {
            let dir = makeDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = makeStore(dir)
            #expect(try store.namedSecret("web_search.token") == nil)

            try store.setNamedSecret("web_search.token", to: "one")
            #expect(try store.namedSecret("web_search.token") == "one")
            try store.setNamedSecret("web_search.token", to: "two")
            #expect(try makeStore(dir).namedSecret("web_search.token") == "two")

            try store.setNamedSecret("web_search.token", to: nil)
            #expect(try store.namedSecret("web_search.token") == nil)
            try store.setNamedSecret("web_search.token", to: nil)
        }

        @Test("a unavailable machine ID is reported")
        func machineIDUnavailable() throws {
            let dir = makeDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = EncryptedSecretStore(
                storeURL: dir.appendingPathComponent(".storage/secrets.store"),
                machineID: { throw SecretStoreError.machineIDUnavailable })
            #expect(throws: SecretStoreError.machineIDUnavailable) {
                try store.addKey(provider: .openai, name: "Default", secret: "x")
            }
        }

        @Test("the real machine ID is readable")
        func realMachineID() throws {
            #expect(try !MachineID.current().isEmpty)
        }
    }
}
