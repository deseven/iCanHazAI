import Foundation
import Testing

@testable import iCanHazAI

private let noMetadata = StubMetadataSource(result: .failure(TestFailure()))

private func queryItems(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

extension AllAppTests {
    @Suite("ProviderAdapters")
    struct ProviderAdapterTests {

        // MARK: - Anthropic

        @Test("Anthropic maps capabilities and skips retired models, following has_more")
        func anthropicMapping() async throws {
            let fetcher = StubFetcher { url in
                queryItems(url)["after_id"] == nil
                    ? .json(ProviderFixtures.anthropicPage1) : .json(ProviderFixtures.anthropicPage2)
            }
            let listing = try await AnthropicAdapter().fetchListing(
                apiKey: "fake-key", fetcher: fetcher, metadata: noMetadata)
            #expect(listing.models.map(\.id.name) == ["claude-opus-x", "claude-haiku-old", "claude-text-only"])

            let opus = listing.models[0]
            #expect(opus.displayName == "Claude Opus X")
            #expect(opus.capabilities.imageInput)
            #expect(opus.capabilities.contextWindow == 1_000_000)
            #expect(opus.capabilities.maxOutputTokens == 128_000)
            #expect(opus.capabilities.reasoning.supported)
            #expect(opus.capabilities.reasoning.levels == ["low", "medium", "high", "max"])
            #expect(opus.capabilities.reasoning.defaultLevel == nil)

            let haiku = listing.models[1]
            #expect(haiku.capabilities.reasoning.supported)
            #expect(haiku.capabilities.reasoning.levels.isEmpty)
            // No `types` in the listing: opt-in, budget-based thinking.
            #expect(haiku.capabilities.reasoning.canDisable)
            #expect(haiku.capabilities.reasoning.budgetOnly)

            // Adaptive thinking whose listing doesn't advertise `disabled`.
            #expect(opus.capabilities.reasoning.canDisable == false)
            #expect(opus.capabilities.reasoning.budgetOnly == false)

            let textOnly = listing.models[2]
            #expect(textOnly.capabilities.imageInput == false)
            #expect(textOnly.capabilities.reasoning == .unsupported)
        }

        @Test("Anthropic reads the supported thinking types")
        func anthropicThinkingTypes() throws {
            func parse(_ types: String) throws -> ReasoningCapability {
                let json = """
                    {"id":"m","capabilities":{"effort":{"supported":true},
                      "thinking":{"supported":true,"types":\(types)}}}
                    """
                let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                return try #require(AnthropicAdapter.parse(object)).capabilities.reasoning
            }
            let all = try parse(
                #"{"adaptive":{"supported":true},"enabled":{"supported":true},"disabled":{"supported":true}}"#)
            #expect(all.canDisable && !all.budgetOnly)
            let legacy = try parse(#"{"enabled":{"supported":true},"disabled":{"supported":true}}"#)
            #expect(legacy.canDisable && legacy.budgetOnly)
            let always = try parse(#"{"adaptive":{"supported":true}}"#)
            #expect(!always.canDisable && !always.budgetOnly)
        }

        @Test("Anthropic requests limit=1000, pages by last_id and sends its headers")
        func anthropicRequests() async throws {
            let fetcher = StubFetcher { url in
                queryItems(url)["after_id"] == nil
                    ? .json(ProviderFixtures.anthropicPage1) : .json(ProviderFixtures.anthropicPage2)
            }
            _ = try await AnthropicAdapter(baseUrl: "https://anthropic.test/v1").fetchListing(
                apiKey: "fake-key", fetcher: fetcher, metadata: noMetadata)
            let requests = fetcher.requests
            #expect(requests.count == 2)
            #expect(requests[0].url.path == "/v1/models")
            #expect(queryItems(requests[0].url)["limit"] == "1000")
            #expect(queryItems(requests[1].url)["after_id"] == "claude-haiku-old")
            #expect(requests[0].headers["x-api-key"] == "fake-key")
            #expect(requests[0].headers["anthropic-version"] == "2023-06-01")
        }

        @Test("Anthropic validate reports the model count and rejects a bad key")
        func anthropicValidate() async throws {
            let ok = StubFetcher { _ in .json(ProviderFixtures.anthropicPage2) }
            let result = try await AnthropicAdapter().validate(apiKey: "fake", fetcher: ok, metadata: noMetadata)
            #expect(result.modelCount == 1)
            #expect(result.seed.count == 1)

            let rejected = StubFetcher { _ in .status(401) }
            await #expect(throws: ProviderError.self) {
                try await AnthropicAdapter().validate(apiKey: "bad", fetcher: rejected, metadata: noMetadata)
            }
        }

        // MARK: - DeepSeek

        @Test("DeepSeek maps modalities and effort levels and skips non-text models")
        func deepseekMapping() async throws {
            let fetcher = StubFetcher { _ in .json(ProviderFixtures.deepseek) }
            let listing = try await DeepSeekAdapter(baseUrl: "https://deepseek.test").fetchListing(
                apiKey: "fake-key", fetcher: fetcher, metadata: noMetadata)
            #expect(listing.models.map(\.id.name) == ["deepseek-flash", "deepseek-v4-pro"])

            let flash = listing.models[0]
            #expect(flash.displayName == "DeepSeek-V4.1-Flash")
            #expect(flash.capabilities.imageInput)
            #expect(flash.capabilities.contextWindow == 1_048_576)
            #expect(flash.capabilities.maxOutputTokens == 393_216)
            #expect(flash.capabilities.reasoning.supported)
            #expect(flash.capabilities.reasoning.levels == ["low", "high", "max"])
            #expect(flash.capabilities.reasoning.defaultLevel == "high")
            #expect(flash.capabilities.reasoning.canDisable)

            let pro = listing.models[1]
            #expect(pro.capabilities.imageInput == false)
            #expect(pro.capabilities.reasoning == .unsupported)

            let request = try #require(fetcher.requests.first)
            #expect(request.url.absoluteString == "https://deepseek.test/models")
            #expect(request.headers["Authorization"] == "Bearer fake-key")
        }

        @Test("DeepSeek treats 403 as an invalid key and other statuses as http errors")
        func deepseekErrors() async throws {
            let forbidden = StubFetcher { _ in .status(403) }
            do {
                _ = try await DeepSeekAdapter().fetchListing(apiKey: "x", fetcher: forbidden, metadata: noMetadata)
                Issue.record("expected an error")
            } catch ProviderError.invalidKey {
            }

            let broken = StubFetcher { _ in .json(#"{"error":{"message":"overloaded"}}"#, status: 503) }
            do {
                _ = try await DeepSeekAdapter().fetchListing(apiKey: "x", fetcher: broken, metadata: noMetadata)
                Issue.record("expected an error")
            } catch ProviderError.http(let status, let message) {
                #expect(status == 503)
                #expect(message == "overloaded")
            }

            let garbage = StubFetcher { _ in .json("not json") }
            do {
                _ = try await DeepSeekAdapter().fetchListing(apiKey: "x", fetcher: garbage, metadata: noMetadata)
                Issue.record("expected an error")
            } catch ProviderError.badResponse {
            }
        }

        // MARK: - OpenRouter

        @Test("OpenRouter maps images, reasoning with and without the reasoning object, and the total")
        func openRouterMapping() async throws {
            let fetcher = StubFetcher { _ in .json(ProviderFixtures.openRouterTop) }
            let listing = try await OpenRouterAdapter().fetchListing(
                apiKey: "fake", fetcher: fetcher, metadata: noMetadata)
            #expect(listing.totalCount == 471)
            #expect(listing.modelCount == 471)
            #expect(listing.models.count == 3)

            let claude = listing.models[0]
            #expect(claude.id == ModelID(provider: .openrouter, name: "anthropic/claude-x"))
            #expect(claude.displayName == "Anthropic: Claude X")
            #expect(claude.capabilities.imageInput)
            #expect(claude.capabilities.contextWindow == 200_000)
            #expect(claude.capabilities.maxOutputTokens == 64_000)
            #expect(claude.capabilities.reasoning.levels == ["low", "high"])
            #expect(claude.capabilities.reasoning.defaultLevel == "medium")

            let free = listing.models[1]
            #expect(free.id.name == "foo/bar:free")
            #expect(free.capabilities.imageInput == false)
            #expect(free.capabilities.maxOutputTokens == nil)
            #expect(free.capabilities.reasoning == ReasoningCapability(supported: true, levels: [], defaultLevel: nil))

            #expect(listing.models[2].capabilities.reasoning == .unsupported)
        }

        @Test("OpenRouter can disable reasoning unless the model marks it mandatory")
        func openRouterMandatory() throws {
            func parse(_ reasoning: String) throws -> ReasoningCapability {
                let json = #"{"id":"a/b","architecture":{},"reasoning":\#(reasoning)}"#
                let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                return try #require(OpenRouterAdapter.parse(object)).capabilities.reasoning
            }
            let optional = try parse(#"{"mandatory":false,"supported_efforts":["high","low","none"]}"#)
            #expect(optional.canDisable)
            #expect(optional.options == [ReasoningSetting.off, "low", "high"])
            let mandatory = try parse(#"{"mandatory":true,"supported_efforts":["high","medium","low"]}"#)
            #expect(!mandatory.canDisable)
            #expect(mandatory.options == ["low", "medium", "high"])
            let toggle = try parse(#"{"mandatory":false,"default_enabled":true}"#)
            #expect(toggle.options == [ReasoningSetting.off, ReasoningSetting.on])
            let always = try parse(#"{"mandatory":true}"#)
            #expect(always.isConfigurable == false)
        }

        @Test("OpenRouter lists the whole text catalog in one request")
        func openRouterRequests() async throws {
            let fetcher = StubFetcher { _ in .json(ProviderFixtures.openRouterTop) }
            let adapter = OpenRouterAdapter(baseUrl: "https://openrouter.test/api/v1")
            _ = try await adapter.fetchListing(apiKey: "fake", fetcher: fetcher, metadata: noMetadata)

            #expect(fetcher.requests.count == 1)
            let listing = try #require(fetcher.requests.first).url
            #expect(listing.path == "/api/v1/models")
            #expect(queryItems(listing) == ["output_modalities": "text", "sort": "most-popular", "limit": "1000"])
        }

        @Test("OpenRouter keeps ~vendor/model-latest aliases")
        func openRouterAliases() throws {
            let json =
                #"{"id":"~deepseek/deepseek-v4-flash-latest","name":"DeepSeek: DeepSeek V4 Flash Latest","architecture":{}}"#
            let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect(OpenRouterAdapter.parse(object)?.id.name == "~deepseek/deepseek-v4-flash-latest")
        }

        @Test("OpenRouter lookup matches the exact id among variants")
        func openRouterLookup() async throws {
            let fetcher = StubFetcher { _ in .json(ProviderFixtures.openRouterLookup) }
            let adapter = OpenRouterAdapter()
            let found = try await adapter.lookup("foo/bar", fetcher: fetcher)
            #expect(found?.id.name == "foo/bar")
            #expect(found?.capabilities.contextWindow == 2000)
            #expect(try await adapter.lookup("foo/missing", fetcher: fetcher) == nil)
        }

        @Test("OpenRouter validate checks /key and reads total_count")
        func openRouterValidate() async throws {
            let fetcher = StubFetcher { url in
                url.path.hasSuffix("/key") ? .json(#"{"data":{}}"#) : .json(ProviderFixtures.openRouterTop)
            }
            let result = try await OpenRouterAdapter().validate(apiKey: "fake", fetcher: fetcher, metadata: noMetadata)
            #expect(result.modelCount == 471)
            #expect(result.seed.count == 3)
            #expect(fetcher.requests.first { $0.url.path.hasSuffix("/key") }?.headers["Authorization"] == "Bearer fake")
        }

        @Test("OpenRouter validate maps a 401 on /key to invalidKey even though /models is public")
        func openRouterInvalidKey() async throws {
            let fetcher = StubFetcher { url in
                url.path.hasSuffix("/key") ? .status(401) : .json(ProviderFixtures.openRouterTop)
            }
            do {
                _ = try await OpenRouterAdapter().validate(apiKey: "bad", fetcher: fetcher, metadata: noMetadata)
                Issue.record("expected an error")
            } catch ProviderError.invalidKey {
            }
        }

        // MARK: - Metadata parsing

        @Test("LiteLLM parsing keeps only openai and chatgpt entries")
        func liteLLMSubset() throws {
            let entries = try parseLiteLLMFixture()
            #expect(entries["claude-3-opus"] == nil)
            #expect(entries["sample_spec"] == nil)
            #expect(entries["gpt-5"]?.litellmProvider == "openai")
            #expect(entries["chatgpt/chatgpt-4o-latest"]?.litellmProvider == "chatgpt")
        }

        @Test("LiteLLM reasoning levels are synthesized and reasoning_effort_levels takes precedence")
        func liteLLMReasoningLevels() throws {
            let entries = try parseLiteLLMFixture()
            #expect(entries["gpt-5"]?.reasoningLevels == ["minimal", "low", "medium", "high"])
            #expect(entries["gpt-5.2"]?.reasoningLevels == ["none", "low", "medium", "high", "xhigh"])
            #expect(entries["o4-custom"]?.reasoningLevels == ["low", "high"])
            #expect(entries["gpt-4o"]?.reasoningLevels == [])
            #expect(entries["gpt-4o"]?.supportsReasoning == false)
        }

        @Test("LiteLLM source fetches and parses through the fetcher")
        func liteLLMSource() async throws {
            let fetcher = StubFetcher { _ in .json(ProviderFixtures.liteLLM) }
            let entries = try await LiteLLMMetadataSource(fetcher: fetcher).openAIEntries()
            #expect(entries["gpt-4o"]?.maxInputTokens == 128_000)
            let broken = StubFetcher { _ in .status(500) }
            await #expect(throws: ProviderError.self) {
                try await LiteLLMMetadataSource(fetcher: broken).openAIEntries()
            }
        }
    }
}
