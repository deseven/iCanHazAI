import Foundation
import Testing

@testable import iCanHazAI

private func model(
    _ provider: Provider, _ name: String, context: Int = 1000, reasoning: ReasoningCapability = .unsupported
) -> CatalogModel {
    CatalogModel(
        id: ModelID(provider: provider, name: name), displayName: "Display \(name)",
        capabilities: ModelCapabilities(
            imageInput: true, contextWindow: context, maxOutputTokens: 77, reasoning: reasoning))
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func tempEnv() throws -> (EnvironmentManager, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ichai-catalog-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (EnvironmentManager(rootURL: root), root)
}

extension AllAppTests {
    @Suite("ModelCatalogStore")
    struct ModelCatalogStoreTests {

        @Test("round trip keeps every field")
        func roundTrip() {
            let store = ModelCatalogStore()
            let reasoning = ReasoningCapability(supported: true, levels: ["low", "high"], defaultLevel: "high")
            let original = model(.openrouter, "foo/bar:free", context: 4242, reasoning: reasoning)
            store.upsert([original], now: t0)
            let stored = store.allModels()
            #expect(stored.count == 1)
            #expect(stored[0].model == original)
            #expect(stored[0].isUsed == false)
        }

        @Test("upsert updates capabilities and keeps the used flag")
        func upsertKeepsUsed() {
            let store = ModelCatalogStore()
            store.upsert([model(.openrouter, "a", context: 1)], now: t0)
            #expect(store.markUsed(ModelID(provider: .openrouter, name: "a")))
            store.upsert([model(.openrouter, "a", context: 2)], now: t0)
            let stored = store.allModels()
            #expect(stored.count == 1)
            #expect(stored[0].model.capabilities.contextWindow == 2)
            #expect(stored[0].isUsed)
        }

        @Test("markUsed reports models that aren't cached")
        func markUsedMissing() {
            let store = ModelCatalogStore()
            #expect(store.markUsed(ModelID(provider: .openai, name: "nope")) == false)
        }

        @Test("replace swaps one provider's entries and leaves the others")
        func replace() {
            let store = ModelCatalogStore()
            store.upsert([model(.openai, "a"), model(.openai, "b"), model(.deepseek, "d")], now: t0)
            store.replace(provider: .openai, with: [model(.openai, "b"), model(.openai, "c")], now: t0)
            let names = Set(store.allModels().map(\.model.id.description))
            #expect(names == ["openai:b", "openai:c", "deepseek:d"])
        }

        @Test("evictUnused spares used entries and the ones being kept")
        func evictUnused() {
            let store = ModelCatalogStore()
            let ids = ["keep", "used", "unused"].map { ModelID(provider: .openrouter, name: $0) }
            store.upsert(ids.map { model(.openrouter, $0.name) } + [model(.openai, "other")], now: t0)
            store.markUsed(ids[1])
            store.evictUnused(provider: .openrouter, keeping: [ids[0]])
            let names = Set(store.allModels().map(\.model.id.description))
            #expect(names == ["openrouter:keep", "openrouter:used", "openai:other"])
        }

        @Test("delete removes only the given models")
        func delete() {
            let store = ModelCatalogStore()
            store.upsert([model(.openrouter, "a"), model(.openrouter, "b")], now: t0)
            store.delete([ModelID(provider: .openrouter, name: "a")])
            #expect(store.allModels().map(\.model.id.name) == ["b"])
        }

        @Test("refresh state is recorded per provider")
        func refreshState() {
            let store = ModelCatalogStore()
            #expect(store.refreshInfo(for: .openai) == nil)
            store.recordSuccess(for: .openai, at: t0, modelCount: 12)
            store.recordSuccess(for: .openai, at: t0.addingTimeInterval(60), modelCount: 14)
            #expect(
                store.refreshInfo(for: .openai)
                    == ProviderRefreshInfo(lastSuccess: t0.addingTimeInterval(60), modelCount: 14))
            #expect(store.refreshInfo(for: .anthropic) == nil)
        }

        @Test("data survives reopening the store")
        func persistence() throws {
            let (env, root) = try tempEnv()
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let store = try #require(ModelCatalogStore(env: env))
                store.upsert([model(.anthropic, "claude")], now: t0)
                store.markUsed(ModelID(provider: .anthropic, name: "claude"))
                store.recordSuccess(for: .anthropic, at: t0, modelCount: 1)
            }
            let reopened = try #require(ModelCatalogStore(env: env))
            #expect(reopened.allModels().map(\.model.id.name) == ["claude"])
            #expect(reopened.allModels().first?.isUsed == true)
            #expect(reopened.refreshInfo(for: .anthropic)?.modelCount == 1)
            #expect(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(".cache/models.cache").path))
        }

        @Test("a corrupt cache file is dropped and recreated")
        func selfHeal() throws {
            let (env, root) = try tempEnv()
            defer { try? FileManager.default.removeItem(at: root) }
            let cacheDir = root.appendingPathComponent(".cache", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try Data("definitely not a sqlite database".utf8).write(to: cacheDir.appendingPathComponent("models.cache"))

            let store = try #require(ModelCatalogStore(env: env))
            #expect(store.allModels().isEmpty)
            store.upsert([model(.openai, "gpt-5")], now: t0)
            #expect(store.allModels().count == 1)
        }
    }
}
