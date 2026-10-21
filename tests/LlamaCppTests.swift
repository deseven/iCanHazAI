import Foundation
import Testing

@testable import iCanHazAI

private let llamaProvider = Provider.custom("Llama")
private let llamaRoot = "http://llama.test:9931"

private func resolvedLlama(
    _ type: CustomProviderType? = .llamacpp, reasoning: String?, capability: ReasoningCapability
) -> ResolvedModel {
    var caps = ModelCapabilities.safeDefaults
    caps.reasoning = capability
    return ResolvedModel(
        provider: llamaProvider, customType: type, modelID: "m", apiKey: "", baseUrl: llamaRoot, capabilities: caps,
        reasoning: reasoning)
}

private func llamaBody(_ model: ResolvedModel) -> [String: Any] {
    OpenAIProvider().buildRequestBody(
        model: model, messages: [ChatMessage(role: .user, content: "hi")], chatFilename: "", tools: nil, stream: true)
}

extension AllAppTests {

    // MARK: - Reasoning dialect

    @Suite("llama.cpp reasoning request")
    struct LlamaCppReasoningRequestTests {
        private let levels = ReasoningCapability(
            supported: true, levels: ["low", "medium", "high"], defaultLevel: nil, canDisable: true)
        private let toggle = ReasoningCapability(supported: true, levels: [], defaultLevel: nil, canDisable: true)

        @Test("off is `reasoning_effort: none`, a level is passed on")
        func offAndLevels() {
            let off = llamaBody(resolvedLlama(reasoning: ReasoningSetting.off, capability: levels))
            #expect(off["reasoning_effort"] as? String == "none")
            #expect(off["chat_template_kwargs"] == nil)

            let high = llamaBody(resolvedLlama(reasoning: "high", capability: levels))
            #expect(high["reasoning_effort"] as? String == "high")
            #expect(high["chat_template_kwargs"] == nil)
        }

        @Test("on sets the template's own switch, which overrides a server started with thinking off")
        func on() {
            let body = llamaBody(resolvedLlama(reasoning: ReasoningSetting.on, capability: toggle))
            #expect((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == true)
            #expect(body["reasoning_effort"] == nil)
        }

        @Test("nothing is sent without a setting or for a model without a reasoning control")
        func nothing() {
            let unset = llamaBody(resolvedLlama(reasoning: nil, capability: levels))
            #expect(unset["reasoning_effort"] == nil && unset["chat_template_kwargs"] == nil)
            let plain = llamaBody(resolvedLlama(reasoning: "high", capability: .unsupported))
            #expect(plain["reasoning_effort"] == nil && plain["chat_template_kwargs"] == nil)
        }

        @Test("an OpenAI-compatible custom provider keeps the plain OpenAI dialect, and `on` sends nothing")
        func openAICustom() {
            let on = llamaBody(resolvedLlama(.openai, reasoning: ReasoningSetting.on, capability: toggle))
            #expect(on["chat_template_kwargs"] == nil && on["reasoning_effort"] == nil)
            let off = llamaBody(resolvedLlama(.openai, reasoning: ReasoningSetting.off, capability: toggle))
            #expect(off["reasoning_effort"] as? String == "none")
        }

        @Test("the chat goes to /v1/chat/completions on the server's address and asks for the usage")
        func request() throws {
            let model = resolvedLlama(reasoning: nil, capability: .unsupported)
            let request = try LLMTransport.buildRequest(
                model: model, messages: [ChatMessage(role: .user, content: "hi")], chatFilename: "", tools: nil,
                stream: true)
            #expect(request.url?.absoluteString == "http://llama.test:9931/v1/chat/completions")
            let body = llamaBody(model)
            #expect((body["stream_options"] as? [String: Bool])?["include_usage"] == true)
        }
    }

    @Suite("llama.cpp errors and usage")
    struct LlamaCppResponseTests {
        @Test("a prompt over the context says how far, from the fields next to the error")
        func contextExceeded() {
            let body = """
                {"error":{"code":400,"message":"the request exceeds the available context size, try increasing it",
                 "type":"exceed_context_size_error"},"n_prompt_tokens":9000,"n_ctx":4096}
                """
            let error = OpenAIProvider().parseError(Data(body.utf8), statusCode: 400)
            #expect(error.errorType == "exceed_context_size_error")
            #expect(error.providerMessage?.contains("the request exceeds the available context size") == true)
            #expect(error.providerMessage?.contains("9000") == true)
            #expect(error.providerMessage?.contains("4096") == true)
        }

        @Test("other OpenAI errors are untouched")
        func otherErrors() {
            let error = OpenAIProvider().parseError(
                Data(#"{"error":{"code":401,"message":"Invalid API Key","type":"authentication_error"}}"#.utf8),
                statusCode: 401)
            #expect(error.providerMessage == "Invalid API Key")
            let withExtras = OpenAIProvider().parseError(
                Data(#"{"error":{"message":"bad","type":"invalid_request_error"},"n_ctx":1,"n_prompt_tokens":2}"#.utf8),
                statusCode: 400)
            #expect(withExtras.providerMessage == "bad")
        }

        @Test("the final usage chunk, with llama.cpp's timings next to it, is read as usual")
        func usageWithTimings() {
            let data = Data(
                #"""
                {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"prompt_tokens_details":{"cached_tokens":60}},"timings":{"cache_n":60,"prompt_n":40,"predicted_n":20}}
                """#.utf8)
            let chunks = OpenAIProvider().parseStreamChunk(data, accumulator: ToolCallAccumulator())
            guard case .usage(let usage)? = chunks.first else {
                Issue.record("no usage in \(chunks)")
                return
            }
            #expect(usage.inputTokens == 40)
            #expect(usage.cachedInputTokens == 60)
            #expect(usage.outputTokens == 20)
        }

        @Test("reasoning_content is thinking")
        func reasoningContent() {
            let data = Data(#"{"choices":[{"delta":{"reasoning_content":"hmm"},"finish_reason":null}]}"#.utf8)
            let chunks = OpenAIProvider().parseStreamChunk(data, accumulator: ToolCallAccumulator())
            guard case .thinking("hmm")? = chunks.first else {
                Issue.record("unexpected \(chunks)")
                return
            }
        }
    }

    // MARK: - Adapter

    @Suite("LlamaCppAdapter")
    struct LlamaCppAdapterTests {
        private func modelEntry(
            _ id: String, nCtx: Int? = 32768, vision: Bool = false, status: String? = nil, outputs: [String] = ["text"]
        ) -> String {
            let inputs = vision ? #"["text","image"]"# : #"["text"]"#
            let outputsJSON = "[" + outputs.map { "\"\($0)\"" }.joined(separator: ",") + "]"
            // A single-model server sends `meta: null` while loading; a router leaves it out for a model it
            // hasn't loaded.
            let meta: String
            if let nCtx {
                meta = #","meta":{"n_ctx":\#(nCtx),"n_ctx_train":40960}"#
            } else {
                meta = status == nil ? #","meta":null"# : ""
            }
            let statusJSON = status.map { #","status":{"value":"\#($0)"}"# } ?? ""
            return
                #"{"id":"\#(id)","object":"model","architecture":{"input_modalities":\#(inputs),"output_modalities":\#(outputsJSON)}\#(meta)\#(statusJSON)}"#
        }

        private func props(
            nCtx: Int = 32768, vision: Bool = false, effort: Bool = false, template: String = "{{ messages }}"
        ) -> String {
            let quoted = String(decoding: (try? JSONEncoder().encode(template)) ?? Data("\"\"".utf8), as: UTF8.self)
            return """
                {"default_generation_settings":{"n_ctx":\(nCtx),"params":{}},"modalities":{"vision":\(vision)},
                 "chat_template":\(quoted),
                 "chat_template_caps":{"supports_tools":true,"supports_reasoning_effort":\(effort)}}
                """
        }

        private func adapter() -> LlamaCppAdapter { LlamaCppAdapter(provider: llamaProvider, baseUrl: llamaRoot) }

        private func fetcher(
            models: StubResponse, props: @escaping @Sendable (String?) -> StubResponse = { _ in .status(404) }
        ) -> StubFetcher {
            StubFetcher.serving({ request in
                switch request.url.path {
                case "/v1/models": return models
                case "/props":
                    let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
                    return props(query?.first { $0.name == "model" }?.value)
                default: return .status(404)
                }
            })
        }

        private func listing(_ stub: StubFetcher, apiKey: String = "") async throws -> ProviderListing {
            try await adapter().fetchListing(
                apiKey: apiKey, fetcher: stub, metadata: StubMetadataSource(result: .failure(TestFailure())))
        }

        private func list(_ entries: [String]) -> StubResponse {
            .json(#"{"object":"list","data":[\#(entries.joined(separator: ","))]}"#)
        }

        @Test("a single-model server: context from the model, vision from its modalities, reasoning from /props")
        func singleModel() async throws {
            let stub = fetcher(
                models: list([modelEntry("qwen3-8b", nCtx: 16384, vision: true)]),
                props: { _ in .json(props(nCtx: 16384, effort: true, template: "{% if enable_thinking %}…{% endif %}"))
                })
            let result = try await listing(stub)
            let model = try #require(result.models.first)
            #expect(result.models.count == 1)
            #expect(model.id == ModelID(provider: llamaProvider, name: "qwen3-8b"))
            #expect(model.capabilities.contextWindow == 16384)
            #expect(model.capabilities.imageInput)
            #expect(model.capabilities.reasoning.levels == ["low", "medium", "high"])
            #expect(model.capabilities.reasoning.canDisable)
            #expect(result.unknownCapabilities.isEmpty)
            #expect(!result.capabilitiesUnknown)
        }

        @Test("the requests: models under /v1 with the key, /props at the root without a model")
        func requests() async throws {
            let stub = fetcher(models: list([modelEntry("m")]), props: { _ in .json(props()) })
            _ = try await listing(stub, apiKey: "secret")
            #expect(
                stub.requests.map(\.url.absoluteString) == [
                    "http://llama.test:9931/v1/models", "http://llama.test:9931/props",
                ])
            #expect(stub.requests.allSatisfy { $0.headers["Authorization"] == "Bearer secret" })

            let keyless = fetcher(models: list([modelEntry("m")]), props: { _ in .json(props()) })
            _ = try await listing(keyless)
            #expect(keyless.requests.allSatisfy { $0.headers["Authorization"] == nil })
        }

        @Test("without /props the model is still listed, its context from the model list, and marked as unknown")
        func noProps() async throws {
            let result = try await listing(fetcher(models: list([modelEntry("m", nCtx: 8192)])))
            let model = try #require(result.models.first)
            #expect(model.capabilities.contextWindow == 8192)
            #expect(!model.capabilities.reasoning.supported)
            #expect(result.unknownCapabilities == [model.id], "so a cached value of the reasoning isn't wiped")
        }

        @Test("a model that is still loading has no meta: the context comes from /props, else the default")
        func loading() async throws {
            let withProps = try await listing(
                fetcher(models: list([modelEntry("m", nCtx: nil)]), props: { _ in .json(props(nCtx: 4096)) }))
            #expect(withProps.models.first?.capabilities.contextWindow == 4096)
            #expect(withProps.unknownCapabilities.isEmpty)

            let bare = try await listing(fetcher(models: list([modelEntry("m", nCtx: nil)])))
            #expect(bare.models.first?.capabilities.contextWindow == LlamaCppAdapter.defaultContextWindow)
            #expect(bare.unknownCapabilities.count == 1)
        }

        @Test("a router lists every model; only the loaded ones are asked for /props, by name")
        func router() async throws {
            let stub = fetcher(
                models: list([
                    modelEntry("loaded-a", nCtx: 8192, status: "loaded"),
                    modelEntry("sleeping", nCtx: nil, status: "sleeping"),
                    modelEntry("unloaded-vision", nCtx: nil, vision: true, status: "unloaded"),
                    modelEntry("loaded-b", nCtx: 4096, status: "loaded"),
                ]),
                props: { model in
                    .json(props(nCtx: model == "loaded-a" ? 8192 : 4096, effort: model == "loaded-b"))
                })
            let result = try await listing(stub)
            let byName = Dictionary(uniqueKeysWithValues: result.models.map { ($0.id.name, $0) })
            #expect(Set(byName.keys) == ["loaded-a", "sleeping", "unloaded-vision", "loaded-b"])

            let asked = stub.requests.filter { $0.url.path == "/props" }.compactMap {
                URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            }
            #expect(Set(asked) == ["loaded-a", "loaded-b"])

            #expect(byName["loaded-a"]?.capabilities.contextWindow == 8192)
            #expect(byName["loaded-a"]?.capabilities.reasoning.supported == false)
            #expect(byName["loaded-b"]?.capabilities.reasoning.supported == true)
            // Unloaded: the modalities are known from the files, the rest isn't.
            #expect(byName["unloaded-vision"]?.capabilities.imageInput == true)
            #expect(
                result.unknownCapabilities == [
                    ModelID(provider: llamaProvider, name: "sleeping"),
                    ModelID(provider: llamaProvider, name: "unloaded-vision"),
                ])
        }

        @Test("models that can't produce text are hidden; an older server without modalities lists everything")
        func nonChat() async throws {
            let result = try await listing(
                fetcher(
                    models: list([
                        modelEntry("chat"), modelEntry("speech", outputs: ["audio"]),
                        modelEntry("decider", outputs: ["decisions"]),
                        modelEntry("both", outputs: ["text", "audio"]),
                        #"{"id":"old","object":"model"}"#,
                    ]), props: { _ in .json(props()) }))
            #expect(Set(result.models.map(\.id.name)) == ["chat", "both", "old"])
        }

        @Test("a server without models, or entries without ids, is reachable")
        func emptyAndOdd() async throws {
            let empty = try await listing(fetcher(models: list([])))
            #expect(empty.models.isEmpty && empty.modelCount == 0)
            let odd = try await listing(
                fetcher(
                    models: list([#"{"object":"model"}"#, modelEntry("a"), modelEntry("a"), #"{"id":""}"#]),
                    props: { _ in .json(props()) }))
            #expect(odd.models.map(\.id.name) == ["a"])
        }

        @Test("a rejected key or a broken answer fails the listing")
        func failures() async {
            func failure(_ response: StubResponse) async -> ProviderError? {
                do {
                    _ = try await listing(fetcher(models: response))
                    return nil
                } catch { return error as? ProviderError }
            }
            if case .invalidKey? = await failure(.status(401)) {} else { Issue.record("invalidKey") }
            if case .http(let status, _)? = await failure(.status(500)) {
                #expect(status == 500)
            } else {
                Issue.record("http")
            }
            if case .badResponse? = await failure(.json("nope")) {} else { Issue.record("badResponse") }
            if case .badResponse? = await failure(.json(#"{"models":[]}"#)) {} else { Issue.record("badResponse") }
        }

        @Test("reasoning follows what the chat template supports")
        func reasoning() {
            func capability(effort: Bool, template: String?) -> ReasoningCapability {
                LlamaCppAdapter.reasoning(templateCaps: ["supports_reasoning_effort": effort], template: template)
            }
            // An effort level only (gpt-oss): no way to switch it off.
            let levels = capability(effort: true, template: "{{ reasoning_effort }}")
            #expect(levels.levels == ["low", "medium", "high"])
            #expect(!levels.canDisable)
            #expect(levels.options == ["low", "medium", "high"])

            // A switch only (Qwen3-style): on and off.
            let toggle = capability(effort: false, template: "{% if enable_thinking %}<think>{% endif %}")
            #expect(toggle.supported && toggle.levels.isEmpty && toggle.canDisable)
            #expect(toggle.options == [ReasoningSetting.off, ReasoningSetting.on])

            // Both: off, then the levels.
            let both = capability(effort: true, template: "enable_thinking reasoning_effort")
            #expect(both.options == [ReasoningSetting.off, "low", "medium", "high"])

            #expect(capability(effort: false, template: "{{ messages }}") == .unsupported)
            #expect(capability(effort: false, template: nil) == .unsupported)
            #expect(LlamaCppAdapter.reasoning(templateCaps: nil, template: nil) == .unsupported)
        }

        @Test("only text-capable entries chat, and their modalities are read as the server computes them")
        func canChat() throws {
            func entry(_ json: String) throws -> [String: Any] {
                try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            }
            #expect(LlamaCppAdapter.canChat(try entry(#"{"id":"a"}"#)))
            #expect(LlamaCppAdapter.canChat(try entry(#"{"architecture":{"output_modalities":[]}}"#)))
            #expect(!LlamaCppAdapter.canChat(try entry(#"{"architecture":{"output_modalities":["audio"]}}"#)))
            #expect(LlamaCppAdapter.canChat(try entry(#"{"architecture":{"output_modalities":["audio","text"]}}"#)))
        }

        @Test("the catalog refreshes a llama.cpp provider with its own adapter and keeps what it knew")
        func catalog() async throws {
            let loaded = Locked(true)
            let stub = fetcher(
                models: list([modelEntry("m", nCtx: 8192, vision: true)]),
                props: { _ in loaded.value ? .json(props(nCtx: 8192, effort: true)) : .status(500) })
            let secrets = InMemorySecretStore()
            _ = try secrets.addKey(provider: llamaProvider, name: "Default", secret: "")
            let registry = ProviderRegistry(store: secrets)
            try await registry.load()
            await registry.setCustomProviders([
                CustomProviderConfig(name: "Llama", type: .llamacpp, endpoint: llamaRoot)
            ])
            let catalog = ModelCatalog(
                registry: registry, store: ModelCatalogStore(), fetcher: stub,
                metadata: StubMetadataSource(result: .failure(TestFailure())), clock: ManualClock())

            _ = await catalog.refreshAll()
            let id = ModelID(provider: llamaProvider, name: "m")
            let before = await catalog.model(id)?.capabilities
            #expect(before?.reasoning.supported == true)
            #expect(before?.imageInput == true)
            #expect(stub.requests.contains { $0.url.path == "/v1/models" })

            loaded.value = false
            _ = await catalog.refreshAll()
            #expect(await catalog.model(id)?.capabilities == before, "/props failing must not wipe the reasoning")
        }
    }
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
