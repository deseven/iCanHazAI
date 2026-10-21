import Foundation
import Testing

@testable import iCanHazAI

// Provider setup against the mock: the wizard path (validate → add) and the catalog it fills, with the
// real adapters parsing each provider's documented listing.
extension AllSmokeTests {
    @Suite("Provider setup")
    struct SmokeProviderSetupTests {

        private func models(_ fx: SmokeFixture, _ sp: SmokeProvider) async -> [String: ModelCapabilities] {
            let listed = await fx.engine.models.filter { $0.id.provider == sp.provider }
            return Dictionary(uniqueKeysWithValues: listed.map { ($0.id.name, $0.capabilities) })
        }

        @Test("adding a provider lists exactly the models the app should offer", arguments: SmokeProvider.allCases)
        func listsModels(_ sp: SmokeProvider) async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(sp)

                #expect(Set(await models(fx, sp).keys) == sp.expectedModels)
                #expect(await fx.registry.isConfigured(sp.provider))
                #expect(await fx.registry.apiKey(for: sp.provider) == SmokeFixture.apiKey)
            }
        }

        @Test("the key reaches the provider the way its API wants it", arguments: SmokeProvider.allCases)
        func sendsKey(_ sp: SmokeProvider) async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(sp)

                let requests = try await fx.mock.requests(sp.channel)
                let listing = try #require(requests.first { $0.path == sp.modelsPath })
                #expect(listing.status == 200)
                if sp == .openrouter {
                    // /models is public; only /key proves the key.
                    #expect(listing.header("authorization") == nil)
                    let key = try #require(requests.first { $0.path.hasSuffix("/key") })
                    sp.expectAuth(key)
                } else {
                    sp.expectAuth(listing)
                }
            }
        }

        @Test("capabilities come from each provider's listing", arguments: SmokeProvider.allCases)
        func capabilities(_ sp: SmokeProvider) async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(sp)
                let caps = await models(fx, sp)

                switch sp {
                case .deepseek:
                    let flash = try #require(caps["deepseek-flash"])
                    #expect(flash.imageInput)
                    #expect(flash.contextWindow == 1_048_576)
                    #expect(flash.maxOutputTokens == 393_216)
                    #expect(flash.reasoning.supported)
                    #expect(flash.reasoning.levels == ["low", "high", "max"])
                    #expect(flash.reasoning.defaultLevel == "high")
                    #expect(caps["deepseek-v4-pro"]?.imageInput == false)
                case .openai:
                    let gpt5 = try #require(caps["gpt-5"])
                    #expect(gpt5.imageInput)
                    #expect(gpt5.contextWindow == 272_000)
                    #expect(gpt5.maxOutputTokens == 128_000)
                    #expect(gpt5.reasoning.supported)
                    #expect(caps["gpt-4o"]?.reasoning.supported == false)
                case .anthropic:
                    let opus = try #require(caps["claude-opus-5-5"])
                    #expect(opus.imageInput)
                    #expect(opus.maxOutputTokens == 64_000)
                    #expect(opus.reasoning.levels == ["low", "medium", "high", "max"])
                    #expect(opus.reasoning.canDisable)
                    #expect(!opus.reasoning.budgetOnly)
                    let haiku = try #require(caps["claude-haiku-5-5"])
                    #expect(haiku.reasoning.supported)
                    #expect(haiku.reasoning.budgetOnly)
                    let textOnly = try #require(caps["claude-text-only"])
                    #expect(!textOnly.imageInput)
                    #expect(!textOnly.reasoning.supported)
                case .openrouter:
                    let gpt5 = try #require(caps["openai/gpt-5"])
                    #expect(gpt5.reasoning.levels == ["minimal", "low", "medium", "high"])
                    #expect(!gpt5.reasoning.canDisable)
                    #expect(caps["anthropic/claude-sonnet-5-5"]?.imageInput == true)
                    let plain = try #require(caps["foo/bar"])
                    #expect(plain.contextWindow == 32_000)
                    #expect(plain.maxOutputTokens == 8_192)
                    #expect(!plain.reasoning.supported)
                case .ollama:
                    // Ollama says it itself: capabilities and thinking levels from /api/show, and the context a
                    // model really runs with (the Modelfile's, else the loaded one, else the default).
                    let llama = try #require(caps["llama3.2:latest"])
                    #expect(!llama.imageInput)
                    #expect(!llama.reasoning.supported)
                    #expect(llama.contextWindow == OllamaAdapter.defaultContextWindow)
                    let vision = try #require(caps["qwen3-vl:8b"])
                    #expect(vision.imageInput)
                    #expect(vision.contextWindow == 8192)
                    #expect(vision.reasoning.options == [ReasoningSetting.off, ReasoningSetting.on])
                    let oss = try #require(caps["gpt-oss:20b"])
                    #expect(oss.contextWindow == 32_768)
                    #expect(oss.reasoning.levels == ["low", "medium", "high"])
                    #expect(oss.reasoning.defaultLevel == "medium")
                    #expect(!oss.reasoning.canDisable)
                    #expect(!oss.imageInput)
                case .ollamaOpenAI:
                    // Known to LiteLLM: enriched. Unknown: the custom-provider defaults.
                    let oss = try #require(caps["gpt-oss:20b"])
                    #expect(oss.reasoning.supported)
                    #expect(oss.contextWindow == 131_072)
                    #expect(caps["qwen3-vl:8b"]?.imageInput == true)
                    #expect(caps["llama3.2:latest"] == ModelCapabilities.customProviderDefaults)
                case .llamaCpp:
                    // The loaded model's own context, and a reasoning switch because its template has one.
                    let qwen = try #require(caps["qwen3-8b"])
                    #expect(qwen.contextWindow == 32_768)
                    #expect(!qwen.imageInput)
                    #expect(qwen.reasoning.supported)
                    #expect(qwen.reasoning.options == [ReasoningSetting.off, ReasoningSetting.on])
                }
            }
        }

        @Test("a rejected key fails validation and nothing is stored", arguments: SmokeProvider.allCases)
        func rejectedKey(_ sp: SmokeProvider) async throws {
            try await SmokeFixture.run { fx in
                fx.allowMockRejections = true
                do {
                    try await fx.addProvider(sp, apiKey: "bad-key")
                    Issue.record("validation should have failed")
                } catch let error as ProviderError {
                    guard case .invalidKey = error else {
                        Issue.record("expected invalidKey, got \(error)")
                        return
                    }
                }
                #expect(await fx.registry.isConfigured(sp.provider) == false)
                #expect(await fx.engine.models.isEmpty)
            }
        }

        @Test("a failing listing endpoint is reported with its status")
        func listingFailure() async throws {
            try await SmokeFixture.run { fx in
                fx.allowMockRejections = true
                try await fx.mock.configure(.deepseek, ["models_status": 503])
                do {
                    try await fx.addProvider(.deepseek)
                    Issue.record("validation should have failed")
                } catch let error as ProviderError {
                    guard case .http(let status, _) = error else {
                        Issue.record("expected an HTTP error, got \(error)")
                        return
                    }
                    #expect(status == 503)
                }
            }
        }

        @Test("a paginated Anthropic listing is followed to its end")
        func anthropicPagination() async throws {
            try await SmokeFixture.run { fx in
                try await fx.mock.configure(.anthropic, ["page_size": 2])
                try await fx.addProvider(.anthropic)

                #expect(Set(await models(fx, .anthropic).keys) == SmokeProvider.anthropic.expectedModels)
                let pages = try await fx.mock.requests(.anthropic).filter {
                    $0.path == SmokeProvider.anthropic.modelsPath
                }
                #expect(pages.count == 2)
                #expect(pages.first?.query["after_id"] == nil)
                #expect(pages.last?.query["after_id"] == "claude-sonnet-5-5")
            }
        }

        @Test("an OpenRouter model missing from the listing is looked up by name")
        func openRouterLookup() async throws {
            try await SmokeFixture.run { fx in
                // The server returns one model per page, so the rest are only reachable by lookup.
                try await fx.mock.configure(.openrouter, ["page_size": 1])
                try await fx.addProvider(.openrouter)
                #expect(await models(fx, .openrouter).count == 1)

                let found = await fx.catalog.ensureModel(ModelID(provider: .openrouter, name: "foo/bar"))
                guard case .found(let model) = found else {
                    Issue.record("expected the lookup to find foo/bar, got \(found)")
                    return
                }
                #expect(model.capabilities.contextWindow == 32_000)
                let lookups = try await fx.mock.requests(.openrouter).filter { $0.query["q"] == "foo/bar" }
                #expect(lookups.count == 1)

                let missing = await fx.catalog.ensureModel(ModelID(provider: .openrouter, name: "nope/none"))
                guard case .missing = missing else {
                    Issue.record("expected the lookup to report nope/none as missing, got \(missing)")
                    return
                }
            }
        }
    }
}
