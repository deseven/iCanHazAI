import Foundation
import TOML
import Testing

@testable import iCanHazAI

private let customHost = "custom.test"
private let customBase = "http://custom.test/v1"
private let ollama = Provider.custom("Ollama")

private let liteLLMExcerpt = """
    {
      "sample_spec": {"litellm_provider": "one of https://docs.litellm.ai/docs/providers", "mode": "one of"},
      "gpt-4o": {"litellm_provider":"openai","mode":"chat","supports_vision":true,
        "max_input_tokens":128000,"max_output_tokens":16384},
      "gpt-5": {"litellm_provider":"openai","mode":"chat","supported_endpoints":["/v1/chat/completions"],
        "supports_vision":true,"max_input_tokens":272000,"max_output_tokens":128000,
        "supports_reasoning":true,"supports_minimal_reasoning_effort":true},
      "claude-3-opus": {"litellm_provider":"anthropic","mode":"chat","max_input_tokens":200000,
        "max_output_tokens":4096},
      "text-embedding-3-small": {"litellm_provider":"openai","mode":"embedding","max_input_tokens":8191},
      "whisper-1": {"litellm_provider":"openai","mode":"audio_transcription"},
      "together_ai/meta-llama/Llama-3.3-70B-Instruct-Turbo": {"litellm_provider":"together_ai","mode":"chat",
        "max_input_tokens":131072},
      "no-limit-model": {"litellm_provider":"other","mode":"chat","supports_vision":true}
    }
    """

private func modelsBody(_ ids: [String]) -> String {
    ProviderFixtures.openAIModels(ids)
}

/// Serves `/models` of the custom endpoint and LiteLLM's list.
private func customFetcher(
    models: @escaping @Sendable () -> StubResponse,
    liteLLM: @escaping @Sendable () -> StubResponse = {
        .json(liteLLMExcerpt)
    }
) -> StubFetcher {
    StubFetcher { url in url.host == customHost ? models() : liteLLM() }
}

private func adapter(_ base: String = customBase, provider: Provider = ollama) -> CustomProviderAdapter {
    CustomProviderAdapter(provider: provider, baseUrl: base)
}

private func litellm(_ fetcher: HTTPFetching) -> ModelMetadataSource {
    LiteLLMMetadataSource(fetcher: fetcher)
}

private func models(_ listing: ProviderListing) -> [String: CatalogModel] {
    Dictionary(uniqueKeysWithValues: listing.models.map { ($0.id.name, $0) })
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("custom-provider-\(UUID().uuidString)")
}

extension AllAppTests {

    // MARK: - Provider identity

    @Suite("Provider identity")
    struct ProviderIdentityTests {
        @Test("built-in ids parse to the built-in providers, anything else is a custom provider")
        func rawValues() {
            for provider in Provider.allCases {
                #expect(Provider(rawValue: provider.rawValue) == provider)
                #expect(!provider.isCustom)
            }
            #expect(Provider(rawValue: "Ollama") == .custom("Ollama"))
            #expect(Provider(rawValue: "OpenAI") == .custom("OpenAI"))
            #expect(Provider(rawValue: "") == nil)
            #expect(Provider.custom("Ollama").rawValue == "Ollama")
            #expect(Provider.custom("Ollama").isCustom)
            #expect(Provider.custom("Ollama").displayName == "Ollama")
            #expect(Provider.custom("Ollama").alias == "ollama")
        }

        @Test("allCases lists the built-in providers only")
        func allCases() {
            #expect(Provider.allCases == [.openai, .anthropic, .deepseek, .openrouter])
        }

        @Test("built-ins come first, in their own order, then custom providers by name")
        func ordering() {
            let providers: [Provider] = [
                .custom("zed"), .openrouter, .custom("Alpha"), .openai, .custom("beta"), .deepseek, .anthropic,
            ]
            #expect(
                providers.sorted() == [
                    .openai, .anthropic, .deepseek, .openrouter, .custom("Alpha"), .custom("beta"), .custom("zed"),
                ])
        }

        @Test("Codable uses the plain string")
        func codable() throws {
            let providers: [Provider] = [.openai, .custom("My Server")]
            let data = try JSONEncoder().encode(providers)
            #expect(String(data: data, encoding: .utf8) == #"["openai","My Server"]"#)
            #expect(try JSONDecoder().decode([Provider].self, from: data) == providers)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode([Provider].self, from: Data(#"[""]"#.utf8))
            }
        }

        @Test("a custom provider speaks the OpenAI wire and has no default URL")
        func wireAndUrl() {
            #expect(ollama.wire == .openai)
            #expect(ollama.defaultBaseUrl.isEmpty)
            #expect(ResolvedModel(provider: ollama, modelID: "m", apiKey: "").wire == .openai)
        }

        @Test("the picker prefix finds custom providers by name when they're passed in")
        func searchPrefix() {
            let providers = Provider.allCases + [ollama, .custom("My Server")]
            #expect(Provider(searchPrefix: "ollama", among: providers) == ollama)
            #expect(Provider(searchPrefix: "MY SERVER", among: providers) == .custom("My Server"))
            #expect(Provider(searchPrefix: "or", among: providers) == .openrouter)
            #expect(Provider(searchPrefix: "ollama") == nil)

            let query = ModelPickerQuery("ollama.llama3", providers: providers)
            #expect(query.provider == ollama)
            #expect(query.text == "llama3")
            #expect(ModelPickerQuery("my server:qwen", providers: providers).provider == .custom("My Server"))
            #expect(ModelPickerQuery("ollama.llama3").provider == nil)
        }

        @Test("a provider prefix scopes the filter to the custom provider's models")
        func scopedFilter() {
            let all = [
                CatalogModel(
                    id: ModelID(provider: ollama, name: "llama3"), displayName: nil, capabilities: .safeDefaults),
                CatalogModel(
                    id: ModelID(provider: .openai, name: "llama-ish"), displayName: nil, capabilities: .safeDefaults),
            ]
            let result = ModelPickerQuery("ollama:", providers: Provider.allCases + [ollama]).filter(all)
            #expect(result.map(\.id.description) == ["Ollama:llama3"])
        }
    }

    // MARK: - Config entity

    @Suite("Custom provider config")
    struct CustomProviderConfigTests {
        @Test("names are checked for length, characters, built-in names and duplicates")
        func nameProblems() {
            typealias C = CustomProviderConfig
            #expect(C.problem(withName: "Ollama", existing: []) == nil)
            #expect(C.problem(withName: "  LM Studio  ", existing: ["Ollama"]) == nil)
            #expect(C.problem(withName: "", existing: []) == .empty)
            #expect(C.problem(withName: " \n ", existing: []) == .empty)
            #expect(C.problem(withName: String(repeating: "a", count: 30), existing: []) == nil)
            #expect(C.problem(withName: String(repeating: "a", count: 31), existing: []) == .tooLong)
            #expect(C.problem(withName: "a:b", existing: []) == .containsColon)
            #expect(C.problem(withName: "a\tb", existing: []) == .containsControlCharacters)
            #expect(C.problem(withName: "ollama", existing: ["Ollama"]) == .taken)
            for reserved in ["openai", "OpenAI", "DeepSeek", "deepseek", "OpenRouter", "openrouter", "Anthropic"] {
                #expect(C.problem(withName: reserved, existing: []) == .reserved, "\(reserved)")
            }
            #expect(C.problem(withName: "OpenAI Proxy", existing: []) == nil)
        }

        @Test("endpoints must be http(s) URLs with a host and are used as written otherwise")
        func endpoints() {
            typealias C = CustomProviderConfig
            #expect(C.normalizedEndpoint("http://localhost:11434/v1") == "http://localhost:11434/v1")
            #expect(C.normalizedEndpoint(" https://api.example.com/v1/ ") == "https://api.example.com/v1")
            #expect(C.normalizedEndpoint("https://api.example.com") == "https://api.example.com")
            #expect(C.normalizedEndpoint("HTTP://Example.com/api") == "HTTP://Example.com/api")
            for bad in ["", "   ", "localhost:11434", "ftp://example.com", "http://", "example.com/v1", "http:/x"] {
                #expect(C.normalizedEndpoint(bad) == nil, "\(bad)")
            }
        }

        @Test("a missing or unknown color falls back to the default")
        func colors() {
            #expect(CustomProviderConfig(name: "A", endpoint: "http://x", color: "orange").providerColor == .orange)
            #expect(CustomProviderConfig(name: "A", endpoint: "http://x", color: nil).providerColor == .default)
            #expect(
                CustomProviderConfig(name: "A", endpoint: "http://x", color: "chartreuse").providerColor == .default)
            #expect(ProviderColor.default == .teal)
            #expect(ProviderColor.allCases.count == Set(ProviderColor.allCases.map(\.rawValue)).count)
            #expect(ProviderColor.allCases.allSatisfy { !$0.displayName.isEmpty })
        }
    }

    // MARK: - config.toml

    @Suite("Custom providers in config.toml")
    struct CustomProviderConfigFileTests {
        private let id1 = UUID()
        private let id2 = UUID()

        private func encode(_ config: AppConfig) throws -> String {
            let encoder = TOMLEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return String(data: try encoder.encode(config), encoding: .utf8) ?? ""
        }

        @Test("[[custom_providers]] entries decode, and a missing field never fails the whole config")
        func decoding() throws {
            let toml = """
                [[custom_providers]]
                name = "Ollama"
                endpoint = "http://localhost:11434/v1"
                color = "orange"
                key = "\(id1.uuidString)"

                [[custom_providers]]
                name = "Half"
                """
            let config = try ConfigValidation.decodeAppConfig(Data(toml.utf8))
            let list = try #require(config.customProviders)
            #expect(list.count == 2)
            #expect(
                list[0]
                    == CustomProviderConfig(
                        name: "Ollama", endpoint: "http://localhost:11434/v1", color: "orange", key: id1.uuidString))
            #expect(list[1].name == "Half")
            #expect(list[1].endpoint.isEmpty)
            #expect(list[1].key == nil)
        }

        @Test("without the table there are no custom providers, and none are written")
        func absent() throws {
            let config = try ConfigValidation.decodeAppConfig(Data("".utf8))
            #expect(config.customProviders == nil)
            #expect(!(try encode(AppConfig())).contains("custom_providers"))
        }

        @Test("custom providers are written as [[custom_providers]] tables and read back")
        func roundTrip() throws {
            var config = AppConfig()
            config.customProviders = [
                CustomProviderConfig(
                    name: "Ollama", endpoint: "http://localhost:11434/v1", color: "orange", key: id1.uuidString),
                CustomProviderConfig(
                    name: "My Server", endpoint: "https://x.example/api", color: nil, key: id2.uuidString),
            ]
            let toml = try encode(config)
            #expect(toml.contains("[[custom_providers]]"))
            #expect(toml.contains(#"name = "Ollama""#))
            #expect(toml.contains(#"endpoint = "http://localhost:11434/v1""#))
            #expect(toml.contains(#"key = "\#(id1.uuidString)""#))
            #expect(try ConfigValidation.decodeAppConfig(Data(toml.utf8)) == config)
        }

        @Test("the active key of a built-in provider comes from [providers], a custom one's from its entry")
        func providerKeys() throws {
            let toml = """
                [providers]
                anthropic = "\(id1.uuidString)"
                bogus = "\(id2.uuidString)"
                openai = "not-a-uuid"

                [[custom_providers]]
                name = "Ollama"
                endpoint = "http://localhost:11434/v1"
                key = "\(id2.uuidString)"

                [[custom_providers]]
                name = "NoKey"
                endpoint = "http://localhost:1234/v1"
                """
            let config = try ConfigValidation.decodeAppConfig(Data(toml.utf8))
            #expect(config.providerKeys == [.anthropic: id1, ollama: id2])
        }

        @Test("saving the active keys updates [providers] and the custom entries, and never adds or removes entries")
        func settingProviderKeys() {
            var config = AppConfig()
            config.providers = ["deepseek": id1.uuidString]
            config.customProviders = [
                CustomProviderConfig(
                    name: "Ollama", endpoint: "http://localhost:11434/v1", color: "red", key: id1.uuidString),
                CustomProviderConfig(name: "Gone", endpoint: "http://gone.test", color: nil, key: id1.uuidString),
            ]

            config.setProviderKeys([.openai: id1, ollama: id2, .custom("Unknown"): id1])
            #expect(config.providers == ["openai": id1.uuidString])
            let list = config.customProviders ?? []
            #expect(list.map(\.name) == ["Ollama", "Gone"])
            #expect(list.map(\.key) == [id2.uuidString, nil])
            #expect(list.map(\.color) == ["red", nil])

            var empty = AppConfig()
            empty.setProviderKeys([ollama: id1])
            #expect(empty.customProviders == nil)
            #expect(empty.providers.isEmpty)
        }
    }

    // MARK: - Adapter

    @Suite("CustomProviderAdapter")
    struct CustomProviderAdapterTests {
        @Test("models come from /models, with capabilities looked up in LiteLLM by the full model name")
        func capabilitiesFromLiteLLM() async throws {
            let names = ["gpt-4o", "gpt-5", "claude-3-opus", "meta-llama/Llama-3.3-70B-Instruct-Turbo", "mystery"]
            let fetcher = customFetcher(models: { .json(modelsBody(names)) })
            let listing = try await adapter().fetchListing(
                apiKey: "k", fetcher: fetcher, metadata: litellm(fetcher))
            let byName = models(listing)

            #expect(Set(byName.keys) == Set(names))
            #expect(!listing.capabilitiesUnknown)
            #expect(listing.modelCount == names.count)
            #expect(byName["gpt-4o"]?.id == ModelID(provider: ollama, name: "gpt-4o"))
            #expect(byName["gpt-4o"]?.id.description == "Ollama:gpt-4o")

            let gpt4o = try #require(byName["gpt-4o"]?.capabilities)
            #expect(gpt4o.imageInput)
            #expect(gpt4o.contextWindow == 128_000)
            #expect(gpt4o.maxOutputTokens == 16384)
            #expect(!gpt4o.reasoning.supported)

            let gpt5 = try #require(byName["gpt-5"]?.capabilities)
            #expect(gpt5.contextWindow == 272_000)
            #expect(gpt5.reasoning.supported)
            #expect(gpt5.reasoning.levels == ["minimal", "low", "medium", "high"])

            // Another vendor's entry is found as well: the lookup isn't limited to OpenAI models.
            #expect(byName["claude-3-opus"]?.capabilities.contextWindow == 200_000)
        }

        @Test("a model LiteLLM doesn't know gets the defaults: 128k context, no reasoning, no images")
        func defaults() async throws {
            let fetcher = customFetcher(models: {
                .json(modelsBody(["mystery", "meta-llama/Llama-3.3-70B-Instruct-Turbo"]))
            })
            let listing = try await adapter().fetchListing(
                apiKey: "k", fetcher: fetcher, metadata: litellm(fetcher))
            let expected = ModelCapabilities(
                imageInput: false, contextWindow: 128_000, maxOutputTokens: nil, reasoning: .unsupported)
            #expect(ModelCapabilities.customProviderDefaults == expected)
            // Only the exact key counts: LiteLLM files the Together model as `together_ai/meta-llama/...`.
            #expect(listing.models.map(\.capabilities) == [expected, expected])
        }

        @Test("an entry without a context size still gets the default one")
        func entryWithoutContext() async throws {
            let fetcher = customFetcher(models: { .json(modelsBody(["no-limit-model"])) })
            let listing = try await adapter().fetchListing(
                apiKey: "k", fetcher: fetcher, metadata: litellm(fetcher))
            let capabilities = try #require(listing.models.first?.capabilities)
            #expect(capabilities.contextWindow == 128_000)
            #expect(capabilities.imageInput)
        }

        @Test("models LiteLLM files under a non-chat mode are left out")
        func nonChatModelsHidden() async throws {
            let fetcher = customFetcher(models: {
                .json(modelsBody(["text-embedding-3-small", "whisper-1", "gpt-4o"]))
            })
            let listing = try await adapter().fetchListing(
                apiKey: "k", fetcher: fetcher, metadata: litellm(fetcher))
            #expect(listing.models.map(\.id.name) == ["gpt-4o"])
        }

        @Test("when LiteLLM is unreachable every model gets the defaults and the capabilities are marked unknown")
        func liteLLMDown() async throws {
            let fetcher = customFetcher(
                models: { .json(modelsBody(["gpt-4o", "text-embedding-3-small"])) }, liteLLM: { .status(503) })
            let listing = try await adapter().fetchListing(
                apiKey: "k", fetcher: fetcher, metadata: litellm(fetcher))
            #expect(listing.capabilitiesUnknown)
            #expect(listing.models.map(\.id.name) == ["gpt-4o", "text-embedding-3-small"])
            #expect(listing.models.allSatisfy { $0.capabilities == .customProviderDefaults })
        }

        @Test("a metadata source that fails outright doesn't fail the listing")
        func metadataThrows() async throws {
            let fetcher = customFetcher(models: { .json(modelsBody(["a"])) })
            let listing = try await adapter().fetchListing(
                apiKey: "k", fetcher: fetcher, metadata: StubMetadataSource(result: .failure(TestFailure())))
            #expect(listing.models.map(\.id.name) == ["a"])
            #expect(listing.capabilitiesUnknown)
        }

        @Test("the listing is sorted, has no duplicates and skips entries without an id")
        func cleanedUp() async throws {
            let body = #"{"data":[{"id":"b"},{"id":"a"},{"id":"b"},{"object":"model"},{"id":""},{"id":"c"}]}"#
            let fetcher = customFetcher(models: { .json(body) })
            let listing = try await adapter().fetchListing(
                apiKey: "", fetcher: fetcher, metadata: litellm(fetcher))
            #expect(listing.models.map(\.id.name) == ["a", "b", "c"])
        }

        @Test("the endpoint is used as written: /models is appended, no /v1 is added")
        func urls() async throws {
            for (base, expected) in [
                ("http://custom.test/v1", "http://custom.test/v1/models"),
                ("http://custom.test", "http://custom.test/models"),
                ("http://custom.test/api/openai/", "http://custom.test/api/openai/models"),
                ("http://custom.test:8080/v1", "http://custom.test:8080/v1/models"),
            ] {
                let fetcher = customFetcher(models: { .json(modelsBody(["a"])) })
                _ = try await adapter(base).fetchListing(apiKey: "", fetcher: fetcher, metadata: litellm(fetcher))
                let requested = fetcher.requests.map(\.url.absoluteString).filter { $0.contains("custom.test") }
                #expect(requested == [expected])
            }
        }

        @Test("the key is sent as a bearer token, and no Authorization header is sent without one")
        func authorization() async throws {
            let withKey = customFetcher(models: { .json(modelsBody(["a"])) })
            _ = try await adapter().fetchListing(apiKey: "secret", fetcher: withKey, metadata: litellm(withKey))
            #expect(withKey.requests.first { $0.url.host == customHost }?.headers["Authorization"] == "Bearer secret")

            let withoutKey = customFetcher(models: { .json(modelsBody(["a"])) })
            _ = try await adapter().fetchListing(apiKey: "", fetcher: withoutKey, metadata: litellm(withoutKey))
            let request = try #require(withoutKey.requests.first { $0.url.host == customHost })
            #expect(request.headers["Authorization"] == nil)
        }

        @Test("an endpoint that rejects the key, errors, or answers with something else fails the listing")
        func failures() async {
            func failure(_ response: StubResponse) async -> ProviderError? {
                let fetcher = customFetcher(models: { response })
                do {
                    _ = try await adapter().fetchListing(apiKey: "k", fetcher: fetcher, metadata: litellm(fetcher))
                    return nil
                } catch {
                    return error as? ProviderError
                }
            }
            if case .invalidKey? = await failure(.status(401)) {} else { Issue.record("expected invalidKey") }
            if case .http(let status, _)? = await failure(.status(500)) {
                #expect(status == 500)
            } else {
                Issue.record("expected http error")
            }
            if case .badResponse? = await failure(.json("not json")) {} else { Issue.record("expected badResponse") }
            if case .badResponse? = await failure(.json(#"{"models":[]}"#)) {
            } else {
                Issue.record("expected badResponse")
            }
        }

        @Test("an endpoint without models is reachable, which is all validation asks for")
        func emptyList() async throws {
            let fetcher = customFetcher(models: { .json(#"{"object":"list","data":[]}"#) })
            let result = try await adapter().validate(apiKey: "", fetcher: fetcher, metadata: litellm(fetcher))
            #expect(result.modelCount == 0)
            #expect(result.seed.isEmpty)
            // Nothing to look up, so LiteLLM isn't even asked.
            #expect(fetcher.requests.filter { $0.url.host != customHost }.isEmpty)
        }

        @Test("validation returns the models as the seed")
        func validation() async throws {
            let fetcher = customFetcher(models: { .json(modelsBody(["gpt-4o", "mystery"])) })
            let result = try await adapter().validate(apiKey: "k", fetcher: fetcher, metadata: litellm(fetcher))
            #expect(result.modelCount == 2)
            #expect(result.seed.map(\.id.description) == ["Ollama:gpt-4o", "Ollama:mystery"])
            #expect(!result.capabilitiesUnknown)
        }

        @Test("ProviderAdapters builds the custom adapter for a custom provider")
        func factory() {
            let made = ProviderAdapters.make(ollama, baseUrl: customBase)
            #expect((made as? CustomProviderAdapter)?.baseUrl == customBase)
            #expect(made.provider == ollama)
        }
    }

    @Suite("LiteLLM lookup by name")
    struct LiteLLMLookupTests {
        private let data = Data(liteLLMExcerpt.utf8)

        @Test("only the asked-for keys are returned, whichever provider they belong to")
        func byName() throws {
            let found = try LiteLLMMetadataSource.parseEntries(
                from: data, named: ["gpt-4o", "claude-3-opus", "nope", "sample_spec"])
            #expect(Set(found.keys) == ["gpt-4o", "claude-3-opus"])
            #expect(found["claude-3-opus"]?.litellmProvider == "anthropic")
            #expect(found["gpt-4o"]?.maxInputTokens == 128_000)
            #expect(found["gpt-4o"]?.supportsVision == true)
        }

        @Test("the lookup needs the full key")
        func fullKeyOnly() throws {
            let found = try LiteLLMMetadataSource.parseEntries(
                from: data, named: ["meta-llama/Llama-3.3-70B-Instruct-Turbo"])
            #expect(found.isEmpty)
            let full = try LiteLLMMetadataSource.parseEntries(
                from: data, named: ["together_ai/meta-llama/Llama-3.3-70B-Instruct-Turbo"])
            #expect(full.count == 1)
        }

        @Test("garbage is a bad response")
        func garbage() {
            #expect(throws: ProviderError.self) {
                try LiteLLMMetadataSource.parseEntries(from: Data("[]".utf8), named: ["a"])
            }
        }

        @Test("the OpenAI-only parsing is unchanged")
        func openAIOnly() throws {
            let entries = try LiteLLMMetadataSource.parseOpenAIEntries(from: data)
            #expect(Set(entries.keys) == ["gpt-4o", "gpt-5", "text-embedding-3-small", "whisper-1"])
        }

        @Test("capabilities use the default context only when the entry has none")
        func entryCapabilities() throws {
            let found = try LiteLLMMetadataSource.parseEntries(from: data, named: ["gpt-4o", "no-limit-model"])
            #expect(try #require(found["gpt-4o"]).capabilities(defaultContextWindow: 1).contextWindow == 128_000)
            #expect(try #require(found["no-limit-model"]).capabilities(defaultContextWindow: 1).contextWindow == 1)
        }
    }

    // MARK: - Registry

    @Suite("Custom providers in the registry")
    struct CustomProviderRegistryTests {
        private let definition = CustomProviderConfig(name: "Ollama", endpoint: customBase, color: "red")

        @Test("a custom provider's keys only count while the provider is defined")
        func needsDefinition() async throws {
            let store = InMemorySecretStore()
            _ = try store.addKey(provider: ollama, name: "Default", secret: "k")
            _ = try store.addKey(provider: .openai, name: "Default", secret: "o")
            let registry = ProviderRegistry(store: store)
            try await registry.load()

            #expect(await registry.configuredProviders == [.openai])
            #expect(await registry.isConfigured(ollama) == false)
            #expect(await registry.apiKey(for: ollama) == nil)
            #expect(await registry.keys(for: ollama).isEmpty)

            await registry.setCustomProviders([definition])
            #expect(await registry.configuredProviders == [.openai, ollama])
            #expect(await registry.isConfigured(ollama))
            #expect(await registry.apiKey(for: ollama) == "k")
            #expect(await registry.customProvider(for: ollama) == definition)
            #expect(await registry.customProvider(for: .openai) == nil)
        }

        @Test("configured providers list the built-in ones first, then the custom ones by name")
        func ordering() async throws {
            let registry = ProviderRegistry(store: InMemorySecretStore())
            await registry.setCustomProviders([
                CustomProviderConfig(name: "zed", endpoint: "http://z.test"),
                CustomProviderConfig(name: "Alpha", endpoint: "http://a.test"),
            ])
            try await registry.addKey(provider: .custom("zed"), name: "Default", secret: "1")
            try await registry.addKey(provider: .openrouter, name: "Default", secret: "2")
            try await registry.addKey(provider: .custom("Alpha"), name: "Default", secret: "3")
            try await registry.addKey(provider: .openai, name: "Default", secret: "4")
            #expect(await registry.configuredProviders == [.openai, .openrouter, .custom("Alpha"), .custom("zed")])
            #expect(await registry.selectedKeyIDs.count == 4)
        }

        @Test("usable definitions are kept, with trimmed names and normalized endpoints")
        func definitionsAreFiltered() async {
            let registry = ProviderRegistry(store: InMemorySecretStore())
            await registry.setCustomProviders([
                CustomProviderConfig(
                    name: "  Ollama ", endpoint: " http://localhost:11434/v1/ ", color: "red", key: "k"),
                CustomProviderConfig(name: "ollama", endpoint: "http://dup.test"),
                CustomProviderConfig(name: "OpenAI", endpoint: "http://reserved.test"),
                CustomProviderConfig(name: "", endpoint: "http://noname.test"),
                CustomProviderConfig(name: "a:b", endpoint: "http://colon.test"),
                CustomProviderConfig(name: "NoEndpoint", endpoint: ""),
                CustomProviderConfig(name: "BadEndpoint", endpoint: "localhost:1234"),
                CustomProviderConfig(name: "Second", endpoint: "https://second.test"),
            ])
            let kept = await registry.customProviderConfigs
            #expect(kept.map(\.name) == ["Ollama", "Second"])
            #expect(kept.first?.endpoint == "http://localhost:11434/v1")
            #expect(kept.first?.color == "red")
        }

        @Test("definitions without any key are discarded and reported")
        func keylessDefinitionsDiscarded() async throws {
            let store = InMemorySecretStore()
            _ = try store.addKey(provider: ollama, name: "Default", secret: "k")
            let registry = ProviderRegistry(store: store)
            try await registry.load()
            let orphan = CustomProviderConfig(name: "Orphan", endpoint: "http://orphan.test")
            await registry.setCustomProviders([definition, orphan])

            #expect(await registry.discardKeylessCustomProviders() == [orphan])
            #expect(await registry.customProviderConfigs == [definition])
            #expect(await registry.discardKeylessCustomProviders().isEmpty)
        }

        @Test("keys of custom providers without a definition are deleted, everything else is kept")
        func orphanedKeysDeleted() async throws {
            let store = InMemorySecretStore()
            _ = try store.addKey(provider: ollama, name: "Default", secret: "k")
            _ = try store.addKey(provider: .custom("Gone"), name: "Default", secret: "g1")
            _ = try store.addKey(provider: .custom("Gone"), name: "Work", secret: "g2")
            _ = try store.addKey(provider: .openai, name: "Default", secret: "o")
            let registry = ProviderRegistry(store: store)
            try await registry.load()
            await registry.setCustomProviders([definition])

            #expect(try await registry.deleteOrphanedKeys() == 2)
            #expect(try store.listKeys().map(\.provider).sorted() == [.openai, ollama])
            #expect(await registry.configuredProviders == [.openai, ollama])
            #expect(try await registry.deleteOrphanedKeys() == 0)
        }

        @Test("adding a custom provider deletes keys an earlier provider of that name left behind")
        func addingPurgesOrphans() async throws {
            let store = InMemorySecretStore()
            _ = try store.addKey(provider: ollama, name: "Old", secret: "old-secret")
            let registry = ProviderRegistry(store: store)
            try await registry.load()

            try await registry.addCustomProvider(definition)
            #expect(await registry.keys(for: ollama).isEmpty)
            #expect(try store.listKeys().isEmpty)

            let key = try await registry.addKey(provider: ollama, name: "Default", secret: "")
            #expect(await registry.selectedKey(for: ollama) == key)
            #expect(await registry.apiKey(for: ollama) == "")
            #expect(await registry.configuredProviders == [ollama])
        }

        @Test("a provider that is already defined is left alone")
        func addingTwice() async throws {
            let registry = ProviderRegistry(store: InMemorySecretStore())
            try await registry.addCustomProvider(definition)
            try await registry.addKey(provider: ollama, name: "Default", secret: "k")
            try await registry.addCustomProvider(CustomProviderConfig(name: "Ollama", endpoint: "http://other.test"))
            #expect(await registry.customProvider(for: ollama)?.endpoint == customBase)
            #expect(await registry.keys(for: ollama).count == 1)
        }

        @Test("removing a custom provider forgets it and deletes its keys")
        func removing() async throws {
            let store = InMemorySecretStore()
            let registry = ProviderRegistry(store: store)
            try await registry.addCustomProvider(definition)
            try await registry.addKey(provider: ollama, name: "Default", secret: "k")
            try await registry.addKey(provider: .openai, name: "Default", secret: "o")

            try await registry.removeCustomProvider(ollama)
            #expect(await registry.customProvider(for: ollama) == nil)
            #expect(await registry.configuredProviders == [.openai])
            #expect(try store.listKeys().map(\.provider) == [.openai])
        }

        @Test("a key-less custom provider has an empty secret and works like any other")
        func keyLess() async throws {
            let registry = ProviderRegistry(store: InMemorySecretStore())
            try await registry.addCustomProvider(definition)
            let key = try await registry.addKey(provider: ollama, name: "Default", secret: "")
            #expect(await registry.isConfigured(ollama))
            #expect(await registry.apiKey(for: ollama) == "")
            #expect(await registry.preview(of: key.id) == "No API key")

            let second = try await registry.addKey(
                provider: ollama, name: "Work", secret: "secret-key-123456", select: true)
            #expect(await registry.apiKey(for: ollama) == "secret-key-123456")
            #expect(await registry.keys(for: ollama).count == 2)

            try await registry.deleteKey(second.id)
            #expect(await registry.selectedKey(for: ollama) == key)
        }

        @Test("the persisted active key of a custom provider is adopted")
        func selection() async throws {
            let store = InMemorySecretStore()
            _ = try store.addKey(provider: ollama, name: "Default", secret: "1")
            let second = try store.addKey(provider: ollama, name: "Work", secret: "2")
            let registry = ProviderRegistry(store: store)
            try await registry.load()
            await registry.setCustomProviders([definition])

            #expect(await registry.applySelection([ollama: second.id]) == [ollama: second.id])
            #expect(await registry.apiKey(for: ollama) == "2")
            #expect(await registry.applySelection([ollama: UUID()]) == [ollama: second.id])
        }

        @Test("the encrypted store keeps custom providers' keys, an empty one included, after the built-in ones")
        func encryptedStore() throws {
            let dir = tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent(".storage/secrets.store")
            let store = EncryptedSecretStore(storeURL: url, machineID: { "MACHINE-A" })

            let zed = try store.addKey(provider: .custom("zed"), name: "Default", secret: "")
            let alpha = try store.addKey(provider: .custom("Alpha"), name: "Default", secret: "alpha-secret")
            let builtIn = try store.addKey(provider: .openrouter, name: "Default", secret: "or-secret")

            let reopened = EncryptedSecretStore(storeURL: url, machineID: { "MACHINE-A" })
            let keys = try reopened.listKeys()
            #expect(keys.map(\.id) == [builtIn.id, alpha.id, zed.id])
            #expect(keys.map(\.provider) == [.openrouter, .custom("Alpha"), .custom("zed")])
            #expect(try reopened.secret(for: zed) == "")
            #expect(try reopened.secret(for: alpha) == "alpha-secret")
        }

    }

    // MARK: - Catalog and resolver

    @Suite("Custom providers in the catalog")
    struct CustomProviderCatalogTests {
        private let definition = CustomProviderConfig(name: "Ollama", endpoint: customBase, color: "red")

        private struct Setup {
            let catalog: ModelCatalog
            let registry: ProviderRegistry
            let fetcher: StubFetcher
            let store: ModelCatalogStore
        }

        private func makeSetup(
            keys: [(Provider, String)] = [(ollama, "")], definitions: [CustomProviderConfig]? = nil,
            store: ModelCatalogStore = ModelCatalogStore(), fetcher: StubFetcher? = nil,
            models: @escaping @Sendable () -> StubResponse = { .json(modelsBody(["gpt-4o", "mystery"])) }
        ) async throws -> Setup {
            let secrets = InMemorySecretStore()
            for (provider, secret) in keys {
                _ = try secrets.addKey(provider: provider, name: "Default", secret: secret)
            }
            let registry = ProviderRegistry(store: secrets)
            try await registry.load()
            await registry.setCustomProviders(definitions ?? [definition])
            let fetcher = fetcher ?? customFetcher(models: models)
            let catalog = ModelCatalog(
                registry: registry, store: store, fetcher: fetcher, metadata: litellm(fetcher),
                baseUrls: [.openai: "http://openai.test/v1"], clock: ManualClock())
            return Setup(catalog: catalog, registry: registry, fetcher: fetcher, store: store)
        }

        @Test("a refresh lists the models at the provider's own endpoint")
        func refresh() async throws {
            let s = try await makeSetup(keys: [(ollama, "secret")])
            let summary = await s.catalog.refreshAll()
            #expect(try summary.outcomes[ollama]?.get() == 2)

            let snapshot = await s.catalog.snapshot()
            #expect(snapshot.map(\.id.description) == ["Ollama:gpt-4o", "Ollama:mystery"])
            #expect(snapshot.first?.capabilities.contextWindow == 128_000)
            #expect(await s.catalog.hasModels(for: ollama))
            #expect(await s.catalog.refreshInfo(for: ollama)?.modelCount == 2)

            let request = try #require(s.fetcher.requests.first { $0.url.host == customHost })
            #expect(request.url.absoluteString == "http://custom.test/v1/models")
            #expect(request.headers["Authorization"] == "Bearer secret")
        }

        @Test("a provider without a key sends no Authorization header")
        func keyless() async throws {
            let s = try await makeSetup(keys: [(ollama, "")])
            _ = await s.catalog.refreshAll()
            let request = try #require(s.fetcher.requests.first { $0.url.host == customHost })
            #expect(request.headers["Authorization"] == nil)
        }

        @Test("built-in providers sort before custom ones in the snapshot")
        func snapshotOrder() async throws {
            let fetcher = StubFetcher { url in
                switch url.host {
                case customHost: return .json(modelsBody(["a"]))
                case "openai.test": return .json(modelsBody(["gpt-z"]))
                default: return .json(liteLLMExcerpt)
                }
            }
            let s = try await makeSetup(keys: [(ollama, ""), (.openai, "o")], fetcher: fetcher)
            _ = await s.catalog.refreshAll()
            #expect(await s.catalog.snapshot().map(\.id.description) == ["openai:gpt-z", "Ollama:a"])
        }

        @Test("a custom provider that lists no models is taken at its word")
        func emptyListHonored() async throws {
            let body = Locked(StubResponse.json(modelsBody(["gpt-4o"])))
            let s = try await makeSetup(models: { body.value })
            _ = await s.catalog.refreshAll()
            #expect(await s.catalog.hasModels(for: ollama))

            body.value = .json(#"{"object":"list","data":[]}"#)
            let summary = await s.catalog.refreshAll()
            #expect(try summary.outcomes[ollama]?.get() == 0)
            #expect(await s.catalog.snapshot().isEmpty)
            #expect(await s.catalog.refreshInfo(for: ollama)?.modelCount == 0)

            // A chat keeps its model: it's "unavailable" for now, not gone, and nothing is reset.
            let resolver = ModelResolver(registry: s.registry, catalog: s.catalog)
            #expect(await resolver.resolve("Ollama:gpt-4o") == .unavailable)

            body.value = .json(modelsBody(["gpt-4o"]))
            _ = await s.catalog.refreshAll()
            #expect(await s.catalog.snapshot().map(\.id.description) == ["Ollama:gpt-4o"])
        }

        @Test("a custom provider that has no models from the start refreshes without an error")
        func emptyFromTheStart() async throws {
            let s = try await makeSetup { .json(#"{"data":[]}"#) }
            let summary = await s.catalog.refreshAll()
            #expect(try summary.outcomes[ollama]?.get() == 0)
            #expect(await s.catalog.refreshInfo(for: ollama)?.modelCount == 0)
        }

        @Test("a custom provider's malformed or failed answer is still a failure that keeps the cache")
        func badAnswersKeepCache() async throws {
            let response = Locked(StubResponse.json(modelsBody(["gpt-4o"])))
            let s = try await makeSetup(models: { response.value })
            _ = await s.catalog.refreshAll()
            let before = await s.catalog.snapshot()

            for bad in [StubResponse.json(#"{"models":[]}"#), .json("nope"), .status(500), .status(401)] {
                response.value = bad
                let summary = await s.catalog.refreshAll()
                if case .success = try #require(summary.outcomes[ollama]) { Issue.record("expected failure") }
            }
            #expect(await s.catalog.snapshot() == before)
        }

        @Test("models count as pending until every provider's first refresh has answered")
        func pendingModels() {
            var fresh = ConfiguredProvider(provider: ollama, keys: [], isRefreshing: true)
            let other = ConfiguredProvider(provider: .openai, keys: [], isRefreshing: true)
            #expect([fresh].hasPendingModels)
            #expect([fresh, other].hasPendingModels)
            #expect(![ConfiguredProvider]().hasPendingModels)

            fresh.modelCount = 0
            #expect(![fresh].hasPendingModels)
            #expect([fresh, other].hasPendingModels)

            var failed = other
            failed.lastError = "HTTP 500"
            #expect(![fresh, failed].hasPendingModels)
        }

        @Test("validation checks a custom provider that isn't defined yet at the endpoint it is given")
        func validateNewProvider() async throws {
            let s = try await makeSetup(keys: [], definitions: [])
            let result = try await s.catalog.validate(
                provider: .custom("Fresh"), apiKey: "", endpoint: "http://custom.test/api")
            #expect(result.modelCount == 2)
            #expect(result.seed.map(\.id.description) == ["Fresh:gpt-4o", "Fresh:mystery"])
            #expect(
                s.fetcher.requests.contains { $0.url.absoluteString == "http://custom.test/api/models" })
        }

        @Test("validation of an existing custom provider uses its own endpoint")
        func validateExisting() async throws {
            let s = try await makeSetup()
            _ = try await s.catalog.validate(provider: ollama, apiKey: "second")
            let request = try #require(s.fetcher.requests.first { $0.url.host == customHost })
            #expect(request.url.absoluteString == "http://custom.test/v1/models")
            #expect(request.headers["Authorization"] == "Bearer second")
        }

        @Test("an unreachable endpoint fails the validation")
        func validateFailure() async throws {
            let s = try await makeSetup(keys: [], definitions: []) { .status(404) }
            await #expect(throws: ProviderError.self) {
                _ = try await s.catalog.validate(provider: .custom("Fresh"), apiKey: "", endpoint: customBase)
            }
        }

        @Test("the first provider added stores what validation fetched and schedules the refresh")
        func providerAdded() async throws {
            let s = try await makeSetup(keys: [], definitions: [])
            let validation = try await s.catalog.validate(provider: ollama, apiKey: "", endpoint: customBase)
            try await s.registry.addCustomProvider(definition)
            try await s.registry.addKey(provider: ollama, name: "Default", secret: "")
            await s.catalog.providerAdded(ollama, validation: validation)
            #expect(await s.catalog.snapshot().map(\.id.name) == ["gpt-4o", "mystery"])
            #expect(await s.catalog.refreshInfo(for: ollama)?.modelCount == 2)
        }

        @Test("cached models of a custom provider that is gone are dropped at startup")
        func staleCacheDropped() async throws {
            let store = ModelCatalogStore()
            store.upsert(
                [
                    CatalogModel(
                        id: ModelID(provider: ollama, name: "old"), displayName: nil, capabilities: .safeDefaults)
                ],
                now: Date())
            store.recordSuccess(for: ollama, at: Date(), modelCount: 1)
            #expect(store.cachedProviders() == [ollama])

            let s = try await makeSetup(keys: [], definitions: [], store: store)
            await s.catalog.start()
            #expect(await s.catalog.snapshot().isEmpty)
            #expect(store.cachedProviders().isEmpty)
        }

        @Test("removing the provider drops its models and refresh state")
        func removal() async throws {
            let s = try await makeSetup()
            _ = await s.catalog.refreshAll()
            #expect(await s.catalog.hasModels(for: ollama))
            await s.catalog.providerRemoved(ollama)
            #expect(await s.catalog.snapshot().isEmpty)
            #expect(await s.catalog.refreshInfo(for: ollama) == nil)
        }

        @Test("a model of a custom provider resolves to its endpoint, key and capabilities")
        func resolution() async throws {
            let s = try await makeSetup(keys: [(ollama, "secret")])
            _ = await s.catalog.refreshAll()
            let resolver = ModelResolver(registry: s.registry, catalog: s.catalog)

            guard case .ok(let resolved, let model) = await resolver.resolve("Ollama:gpt-4o") else {
                Issue.record("expected the model to resolve")
                return
            }
            #expect(resolved.provider == ollama)
            #expect(resolved.modelID == "gpt-4o")
            #expect(resolved.apiKey == "secret")
            #expect(resolved.baseUrl == customBase)
            #expect(resolved.wire == .openai)
            #expect(resolved.capabilities == model.capabilities)
            #expect(resolved.id == "Ollama:gpt-4o")
            #expect(resolved.imageInput)

            #expect(await resolver.resolve("Ollama:missing") == .invalid)
            #expect(await resolver.resolve("Nobody:gpt-4o") == .invalid)
            #expect(await resolver.resolve("ollama:gpt-4o") == .invalid)
        }

        @Test("a key-less provider resolves with an empty key")
        func keylessResolution() async throws {
            let s = try await makeSetup(keys: [(ollama, "")])
            _ = await s.catalog.refreshAll()
            let resolver = ModelResolver(registry: s.registry, catalog: s.catalog)
            guard case .ok(let resolved, _) = await resolver.resolve("Ollama:mystery") else {
                Issue.record("expected the model to resolve")
                return
            }
            #expect(resolved.apiKey.isEmpty)
            #expect(resolved.capabilities == .customProviderDefaults)
        }

        @Test("an endpoint override beats the provider's own endpoint")
        func overrideWins() async throws {
            let s = try await makeSetup()
            _ = await s.catalog.refreshAll()
            let resolver = ModelResolver(
                registry: s.registry, catalog: s.catalog, endpointOverrides: [ollama: "http://127.0.0.1:9"])
            guard case .ok(let resolved, _) = await resolver.resolve("Ollama:mystery") else {
                Issue.record("expected the model to resolve")
                return
            }
            #expect(resolved.baseUrl == "http://127.0.0.1:9")
        }
    }

    // MARK: - Requests

    @Suite("Requests to custom providers")
    struct CustomProviderRequestTests {
        private func model(apiKey: String = "", reasoning: String? = nil, supported: Bool = false) -> ResolvedModel {
            var capabilities = ModelCapabilities.customProviderDefaults
            capabilities.reasoning = ReasoningCapability(
                supported: supported, levels: supported ? ["low", "medium", "high"] : [], defaultLevel: nil)
            return ResolvedModel(
                provider: ollama, modelID: "llama3", apiKey: apiKey, baseUrl: "http://custom.test/v1",
                capabilities: capabilities, reasoning: reasoning)
        }

        @Test("chat requests go to the endpoint as written, plus /chat/completions")
        func url() throws {
            let request = try LLMTransport.buildRequest(
                model: model(), messages: [ChatMessage(role: .user, content: "hi")], chatFilename: "", tools: nil,
                stream: true)
            #expect(request.url?.absoluteString == "http://custom.test/v1/chat/completions")
        }

        @Test("without a key no Authorization header is sent, with one it is a bearer token")
        func authorization() throws {
            let messages = [ChatMessage(role: .user, content: "hi")]
            let anonymous = try LLMTransport.buildRequest(
                model: model(), messages: messages, chatFilename: "", tools: nil, stream: true)
            #expect(anonymous.value(forHTTPHeaderField: "Authorization") == nil)

            let keyed = try LLMTransport.buildRequest(
                model: model(apiKey: "secret"), messages: messages, chatFilename: "", tools: nil, stream: true)
            #expect(keyed.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        }

        @Test("reasoning is requested the way OpenAI does it")
        func reasoning() {
            func body(_ model: ResolvedModel) -> [String: Any] {
                OpenAIProvider().buildRequestBody(
                    model: model, messages: [ChatMessage(role: .user, content: "hi")], chatFilename: "",
                    tools: nil, stream: true)
            }
            #expect(body(model(reasoning: "high", supported: true))["reasoning_effort"] as? String == "high")
            #expect(body(model(reasoning: "off", supported: true))["reasoning_effort"] as? String == "none")
            #expect(body(model(reasoning: "high", supported: false))["reasoning_effort"] == nil)
            #expect(body(model())["model"] as? String == "llama3")
        }

        @Test("errors name the custom provider")
        func errorLabel() {
            var error = LLMError.parseOpenAI(Data(#"{"error":{"message":"nope"}}"#.utf8), statusCode: 400)
            error.providerName = ollama.displayName
            #expect(error.errorDescription == "Ollama API error (400): nope")
        }
    }
}
