import Foundation
import Testing

@testable import iCanHazAI

private struct EngineHarness {
    let engine: ChatEngine
    let temp: TempEnv
    let catalogStore: ModelCatalogStore
    let fetcher: StubFetcher
}

private func makeEngine(
    providers: [Provider], handler: @escaping StubFetcher.Handler = { _ in .status(500) }
) async throws -> EngineHarness {
    let temp = try TempEnv()
    let secrets = InMemorySecretStore()
    for provider in providers { _ = try secrets.addKey(provider: provider, name: "Default", secret: "fake-key") }
    let registry = ProviderRegistry(store: secrets)
    try await registry.load()
    let fetcher = StubFetcher(handler)
    let catalogStore = ModelCatalogStore()
    let catalog = ModelCatalog(
        registry: registry, store: catalogStore, fetcher: fetcher,
        metadata: StubMetadataSource(result: .failure(TestFailure())),
        baseUrls: [.deepseek: "https://deepseek.test", .openrouter: "https://openrouter.test/api/v1"],
        lookupTimeout: 5)
    let engine = ChatEngine(store: temp.store, env: temp.env, registry: registry, catalog: catalog)
    return EngineHarness(engine: engine, temp: temp, catalogStore: catalogStore, fetcher: fetcher)
}

private func seedChat(_ h: EngineHarness, model: String?, filename: String = "c.json") throws {
    try h.temp.writeChatDirect(
        Fixtures.chat(messages: [Fixtures.message()], model: model, role: "Assistant"), filename: filename)
}

private func writeRole(_ h: EngineHarness, name: String, toml: String) throws {
    try toml.write(
        to: h.temp.env.rolesURL.appendingPathComponent("\(name).toml"), atomically: true, encoding: .utf8)
}

extension AllAppTests {
    @Suite("New chat initial model")
    struct NewChatInitialModelTests {

        private func harness(roles: [String: String]) async throws -> EngineHarness {
            let h = try await makeEngine(providers: [.openrouter]) { _ in
                .json(ProviderFixtures.openRouterLookup)
            }
            for (name, toml) in roles { try writeRole(h, name: name, toml: toml) }
            await h.engine.applyConfigChange(.roles)
            return h
        }

        @Test("a role's preferred_model is preselected and marked used")
        func preferredModelSelected() async throws {
            let h = try await harness(roles: ["Pref": "preferred_model = \"openrouter:foo/bar\"\n"])
            let filename = await h.engine.createNewChat(role: "Pref")
            #expect(await h.engine.chatModel(filename: filename) == "openrouter:foo/bar")
            #expect(h.catalogStore.allModels().filter(\.isUsed).map(\.model.id.description) == ["openrouter:foo/bar"])
        }

        @Test("a preferred_model that doesn't exist leaves the new chat without a model")
        func missingPreferredModel() async throws {
            let h = try await harness(roles: [
                "Gone": "preferred_model = \"openai:gpt-5\"\n",
                "Garbage": "preferred_model = \"not a model\"\n",
            ])
            let gone = await h.engine.createNewChat(role: "Gone")
            let garbage = await h.engine.createNewChat(role: "Garbage")
            #expect(await h.engine.chatModel(filename: gone) == nil)
            #expect(await h.engine.chatModel(filename: garbage) == nil)
        }

        @Test("a role without preferred_model starts without a model when no default is set")
        func noPreference() async throws {
            let h = try await harness(roles: ["Plain": "description = \"x\"\n"])
            let filename = await h.engine.createNewChat(role: "Plain")
            #expect(await h.engine.chatModel(filename: filename) == nil)
        }

        @Test("an explicit model is applied as given")
        func explicitModel() async throws {
            let h = try await harness(roles: ["Pref": "preferred_model = \"openai:gpt-5\"\n"])
            let filename = await h.engine.createNewChat(role: "Pref", model: "openrouter:foo/bar")
            #expect(await h.engine.chatModel(filename: filename) == "openrouter:foo/bar")
        }
    }

    @Suite("Chat load model validity")
    struct ChatLoadModelTests {

        @Test("an unusable model is reset on load and the reset is persisted")
        func invalidIsReset() async throws {
            let h = try await makeEngine(providers: [.deepseek])
            try seedChat(h, model: "openai:gpt-5")
            await h.engine.loadFromCache()
            await h.engine.ensureChatLoaded(filename: "c.json")

            let loaded = try #require(await h.engine.record(for: "c.json")?.chat)
            #expect(loaded.model == nil)
            #expect(try h.temp.readChatDirect("c.json").model == nil)
        }

        @Test("an unparsable model is reset")
        func unparsableIsReset() async throws {
            let h = try await makeEngine(providers: [.deepseek])
            try seedChat(h, model: "not a model")
            await h.engine.loadFromCache()
            await h.engine.ensureChatLoaded(filename: "c.json")
            #expect(await h.engine.record(for: "c.json")?.chat?.model == nil)
        }

        @Test("an undecidable model is kept (cold catalog, offline OpenRouter)")
        func unavailableIsKept() async throws {
            let h = try await makeEngine(providers: [.deepseek, .openrouter]) { _ in .status(503) }
            try seedChat(h, model: "deepseek:flash", filename: "cold.json")
            try seedChat(h, model: "openrouter:foo/bar", filename: "offline.json")
            await h.engine.loadFromCache()
            await h.engine.ensureChatLoaded(filename: "cold.json")
            await h.engine.ensureChatLoaded(filename: "offline.json")

            #expect(await h.engine.record(for: "cold.json")?.chat?.model == "deepseek:flash")
            #expect(await h.engine.record(for: "offline.json")?.chat?.model == "openrouter:foo/bar")
            #expect(try h.temp.readChatDirect("cold.json").model == "deepseek:flash")
        }

        @Test("a usable model is kept and marked used")
        func okIsMarkedUsed() async throws {
            let h = try await makeEngine(providers: [.openrouter]) { _ in
                .json(ProviderFixtures.openRouterLookup)
            }
            try seedChat(h, model: "openrouter:foo/bar")
            await h.engine.loadFromCache()
            await h.engine.ensureChatLoaded(filename: "c.json")

            #expect(await h.engine.record(for: "c.json")?.chat?.model == "openrouter:foo/bar")
            let used = h.catalogStore.allModels().filter(\.isUsed).map(\.model.id.description)
            #expect(used == ["openrouter:foo/bar"])
        }

        @Test("concurrent loads of one chat resolve its model once")
        func singleFlight() async throws {
            let h = try await makeEngine(providers: [.openrouter]) { _ in
                try await Task.sleep(for: .milliseconds(200))
                return .json(ProviderFixtures.openRouterLookup)
            }
            try seedChat(h, model: "openrouter:foo/bar")
            await h.engine.loadFromCache()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 { group.addTask { await h.engine.ensureChatLoaded(filename: "c.json") } }
            }
            #expect(h.fetcher.count { $0.host == "openrouter.test" } == 1)
            #expect(await h.engine.record(for: "c.json")?.chat?.model == "openrouter:foo/bar")
        }

        @Test("chats without a model load untouched")
        func noModel() async throws {
            let h = try await makeEngine(providers: [.deepseek])
            try seedChat(h, model: nil)
            await h.engine.loadFromCache()
            await h.engine.ensureChatLoaded(filename: "c.json")
            #expect(await h.engine.record(for: "c.json")?.chat != nil)
            #expect(h.fetcher.requests.isEmpty)
        }

        @Test("setModel stores the identity and marks it used")
        func setModel() async throws {
            let h = try await makeEngine(providers: [.openrouter]) { _ in
                .json(ProviderFixtures.openRouterLookup)
            }
            h.catalogStore.upsert(
                [
                    CatalogModel(
                        id: ModelID(provider: .openrouter, name: "foo/bar"), displayName: nil,
                        capabilities: .safeDefaults)
                ], now: Date())
            try seedChat(h, model: nil)
            await h.engine.loadFromCache()
            await h.engine.setModel(filename: "c.json", modelID: "openrouter:foo/bar")

            #expect(try h.temp.readChatDirect("c.json").model == "openrouter:foo/bar")
            #expect(h.catalogStore.allModels().filter(\.isUsed).map(\.model.id.description) == ["openrouter:foo/bar"])
        }

        @Test("resolveModel for a chat follows the engine's endpoint overrides")
        func endpointOverrides() async throws {
            let h = try await makeEngine(providers: [.openrouter]) { _ in
                .json(ProviderFixtures.openRouterLookup)
            }
            await h.engine.setEndpointOverrides([.openrouter: "http://127.0.0.1:9"])
            let chat = Chat(model: "openrouter:foo/bar")
            guard case .ok(let resolved, _) = await h.engine.resolveModel(for: chat) else {
                Issue.record("expected ok")
                return
            }
            #expect(resolved.baseUrl == "http://127.0.0.1:9")
            #expect(await h.engine.resolveModel(for: Chat()) == .invalid)
        }

        // MARK: - One-shot failure text

        @Test("one-shot failures name the model and the way out")
        func oneShotMessages() {
            #expect(ChatEngine.noOneShotModelMessage.contains("--model provider:model-id"))
            let invalid = ChatEngine.oneShotModelFailure("openai:nope", .invalid)
            #expect(invalid?.contains("\"openai:nope\" is not available") == true)
            #expect(invalid?.contains("Refresh Models") == true)
            #expect(ChatEngine.oneShotModelFailure("openai:x", .unavailable)?.contains("could not verify") == true)
            let ok = ModelResolution.ok(
                ResolvedModel(provider: .openai, modelID: "x", apiKey: "k"),
                CatalogModel(id: ModelID(provider: .openai, name: "x"), displayName: nil, capabilities: .safeDefaults))
            #expect(ChatEngine.oneShotModelFailure("openai:x", ok) == nil)
        }
    }
}
