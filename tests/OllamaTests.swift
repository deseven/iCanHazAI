import Foundation
import Testing

@testable import iCanHazAI

private let ollamaProvider = Provider.custom("Local")
private let ollamaRoot = "http://ollama.test:11434"

private func resolvedOllama(
    reasoning: String? = nil, capability: ReasoningCapability = .unsupported, imageInput: Bool = false,
    apiKey: String = "", requestParameters: [String: LLMJSONValue]? = nil
) -> ResolvedModel {
    var caps = ModelCapabilities.safeDefaults
    caps.reasoning = capability
    caps.imageInput = imageInput
    return ResolvedModel(
        provider: ollamaProvider, customType: .ollama, modelID: "qwen3:8b", apiKey: apiKey, baseUrl: ollamaRoot,
        capabilities: caps, reasoning: reasoning, requestParameters: requestParameters)
}

private func ollamaBody(
    _ messages: [ChatMessage], model: ResolvedModel = resolvedOllama(), tools: [ToolDefinition]? = nil,
    stream: Bool = true
) -> [String: Any] {
    OllamaProvider().buildRequestBody(
        model: model, messages: messages, chatFilename: "chat", tools: tools, stream: stream)
}

private func ollamaMessages(_ messages: [ChatMessage], imageInput: Bool = false) -> [[String: Any]] {
    OllamaProvider.ollamaMessages(messages, chatFilename: "chat", imageInput: imageInput)
}

private func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }

private func assistant(_ text: String = "", calls: [ToolCall] = []) -> ChatMessage {
    ChatMessage(role: .assistant, content: text, toolCalls: calls.isEmpty ? nil : calls)
}

private func toolResult(_ callID: String, _ content: String, image: ToolResultImage? = nil) -> ChatMessage {
    ChatMessage(
        role: .tool, content: "",
        toolResults: [ToolResult(callID: callID, content: content, isError: false, image: image)])
}

private func call(_ id: String, _ name: String, _ arguments: String = "{}") -> ToolCall {
    ToolCall(id: id, name: name, arguments: arguments)
}

private func chunks(_ lines: [String], accumulator: ToolCallAccumulator = ToolCallAccumulator()) -> [StreamChunk] {
    lines.flatMap { OllamaProvider().parseStreamChunk(Data($0.utf8), accumulator: accumulator) }
}

private func tool(_ name: String, schema: String = #"{"type":"object","properties":{"a":{"type":"string"}}}"#)
    -> ToolDefinition
{
    ToolDefinition(serverName: "s", prefix: "", name: name, description: "Does \(name)", inputSchema: schema)
}

extension AllAppTests {

    // MARK: - Strategy

    @Suite("Ollama request")
    struct OllamaRequestTests {
        @Test("the body asks for a stream and carries nothing OpenAI-specific")
        func plainBody() {
            let body = ollamaBody([ChatMessage(role: .system, content: "be brief"), user("hi")])
            #expect(body["model"] as? String == "qwen3:8b")
            #expect(body["stream"] as? Bool == true)
            #expect(body["stream_options"] == nil)
            #expect(body["options"] == nil, "nothing is sent for the context or the sampling")
            #expect(body["think"] == nil)
            #expect(body["tools"] == nil)
            let messages = body["messages"] as? [[String: Any]]
            #expect(messages?.map { $0["role"] as? String } == ["system", "user"])
            #expect(messages?.map { $0["content"] as? String } == ["be brief", "hi"])
        }

        @Test("a non-streaming body says so")
        func nonStreaming() {
            #expect(ollamaBody([user("hi")], stream: false)["stream"] as? Bool == false)
        }

        @Test("tools are sent as function definitions, and a missing schema becomes an empty object schema")
        func tools() throws {
            let body = ollamaBody([user("hi")], tools: [tool("read"), tool("bare", schema: "not json")])
            let tools = try #require(body["tools"] as? [[String: Any]])
            #expect(tools.count == 2)
            #expect(tools[0]["type"] as? String == "function")
            let function = try #require(tools[0]["function"] as? [String: Any])
            #expect(function["name"] as? String == "read")
            #expect(function["description"] as? String == "Does read")
            #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")
            let bare = try #require(tools[1]["function"] as? [String: Any])
            #expect((bare["parameters"] as? [String: Any])?["type"] as? String == "object")
        }

        @Test("reasoning becomes `think`: off, on, or a level; nothing for a model that doesn't think")
        func thinking() {
            let levels = ReasoningCapability(supported: true, levels: ["low", "medium", "high"], defaultLevel: nil)
            let toggle = ReasoningCapability(supported: true, levels: [], defaultLevel: nil, canDisable: true)
            func think(_ setting: String?, _ capability: ReasoningCapability) -> Any? {
                ollamaBody([user("hi")], model: resolvedOllama(reasoning: setting, capability: capability))["think"]
            }
            #expect(think("high", levels) as? String == "high")
            #expect(think(ReasoningSetting.off, toggle) as? Bool == false)
            #expect(think(ReasoningSetting.on, toggle) as? Bool == true)
            #expect(think(nil, levels) == nil)
            #expect(think("high", .unsupported) == nil)
        }

        @Test("request parameters are merged into the root and win")
        func requestParameters() {
            let model = resolvedOllama(requestParameters: [
                "keep_alive": .string("10m"), "options": .object(["num_ctx": .number(16384)]),
            ])
            let body = ollamaBody([user("hi")], model: model)
            #expect(body["keep_alive"] as? String == "10m")
            #expect((body["options"] as? [String: Any])?["num_ctx"] as? Double == 16384)
        }

        @Test("the key goes in a bearer header only when there is one, and the response is NDJSON")
        func headers() {
            let local = OllamaProvider().buildHeaders(model: resolvedOllama())
            #expect(local["Authorization"] == nil)
            #expect(local["Accept"] == "application/x-ndjson")
            #expect(local["Content-Type"] == "application/json")
            let cloud = OllamaProvider().buildHeaders(model: resolvedOllama(apiKey: "secret"))
            #expect(cloud["Authorization"] == "Bearer secret")
        }
    }

    @Suite("Ollama messages")
    struct OllamaMessageTests {
        @Test("tool calls go back with object arguments, and results are paired by name")
        func toolRoundTrip() throws {
            let messages = ollamaMessages([
                user("weather?"),
                assistant("", calls: [call("call_0", "get_temperature", #"{"city":"Paris","days":2}"#)]),
                toolResult("call_0", "22°C"),
            ])
            #expect(messages.count == 3)
            let assistantMessage = messages[1]
            #expect(assistantMessage["role"] as? String == "assistant")
            let calls = try #require(assistantMessage["tool_calls"] as? [[String: Any]])
            let function = try #require(calls.first?["function"] as? [String: Any])
            #expect(function["name"] as? String == "get_temperature")
            #expect(function["index"] as? Int == 0)
            let arguments = try #require(function["arguments"] as? [String: Any])
            #expect(arguments["city"] as? String == "Paris")
            #expect(arguments["days"] as? Int == 2)
            #expect(calls.first?["id"] == nil, "an id of ours would mean nothing to the server")

            let result = messages[2]
            #expect(result["role"] as? String == "tool")
            #expect(result["tool_name"] as? String == "get_temperature")
            #expect(result["content"] as? String == "22°C")
            #expect(result["tool_call_id"] == nil)
        }

        @Test("unusable arguments become an empty object, never a string")
        func badArguments() throws {
            for arguments in ["", "not json", "[1,2]", "\"text\""] {
                let messages = ollamaMessages([assistant("", calls: [call("a", "f", arguments)]), toolResult("a", "x")])
                let calls = try #require(messages[0]["tool_calls"] as? [[String: Any]])
                let function = try #require(calls[0]["function"] as? [String: Any])
                #expect((function["arguments"] as? [String: Any])?.isEmpty == true, "\(arguments)")
            }
        }

        @Test("results follow the order of the calls, whatever order they were stored in")
        func resultOrder() {
            let messages = ollamaMessages([
                assistant("", calls: [call("a", "first"), call("b", "second"), call("c", "first")]),
                toolResult("c", "third answer"),
                toolResult("a", "first answer"),
                toolResult("b", "second answer"),
                user("thanks"),
            ])
            let results = messages.dropFirst().prefix(3)
            #expect(results.map { $0["tool_name"] as? String } == ["first", "second", "first"])
            #expect(results.map { $0["content"] as? String } == ["first answer", "second answer", "third answer"])
            #expect(messages.last?["role"] as? String == "user")
        }

        @Test("each turn's results stay with their own calls")
        func twoTurns() {
            let messages = ollamaMessages([
                assistant("", calls: [call("a", "read")]), toolResult("a", "one"),
                assistant("", calls: [call("b", "write")]), toolResult("b", "two"),
            ])
            #expect(messages.map { $0["role"] as? String } == ["assistant", "tool", "assistant", "tool"])
            #expect(messages.compactMap { $0["tool_name"] as? String } == ["read", "write"])
        }

        @Test("an assistant message keeps its text next to the calls")
        func assistantText() {
            let messages = ollamaMessages([
                assistant("Let me check.", calls: [call("a", "read")]), toolResult("a", "x"),
            ])
            #expect(messages[0]["content"] as? String == "Let me check.")
        }

        @Test("a result whose call isn't in the history still goes out, under a placeholder name")
        func orphanResult() {
            let messages = ollamaMessages([user("hi"), toolResult("gone", "late")])
            #expect(messages[1]["role"] as? String == "tool")
            #expect(messages[1]["tool_name"] as? String == "tool")
        }

        @Test("a tool result image goes along on a model that can see, as text on one that can't")
        func resultImages() {
            let image = ToolResultImage(data: "QUJD", mimeType: "image/png", fallback: "a cat, OCR: meow")
            let history = [assistant("", calls: [call("a", "read_file")]), toolResult("a", "", image: image)]

            let seeing = ollamaMessages(history, imageInput: true)[1]
            #expect(seeing["images"] as? [String] == ["QUJD"])
            #expect(seeing["content"] as? String == "a cat, OCR: meow")

            let blind = ollamaMessages(history, imageInput: false)[1]
            #expect(blind["images"] == nil)
            #expect(blind["content"] as? String == "a cat, OCR: meow")
        }

        @Test("text and document attachments are appended to the content as text")
        func textAttachments() {
            let note = Attachment(kind: .text, ext: "txt", originalName: "note.txt", text: "remember the milk")
            let message = ChatMessage(role: .user, content: "see attached", attachments: [note])
            let sent = ollamaMessages([message])[0]
            let content = sent["content"] as? String ?? ""
            #expect(content.hasPrefix("see attached\n\n"))
            #expect(content.contains("remember the milk"))
            #expect(sent["images"] == nil)
        }

        @Test("an image attachment is described in text on a model that can't see")
        func imageFallback() {
            let picture = Attachment(kind: .image, ext: "png", originalName: "p.png", text: "a red square")
            let message = ChatMessage(role: .user, content: "what is it?", attachments: [picture])
            let sent = ollamaMessages([message], imageInput: false)[0]
            #expect(sent["content"] as? String == "what is it?\n\na red square")
            #expect(sent["images"] == nil)
        }
    }

    @Suite("Ollama stream")
    struct OllamaStreamTests {
        private func event(
            content: String = "", thinking: String? = nil, toolCalls: String? = nil, done: Bool = false,
            extra: String = ""
        ) -> String {
            var message = #"{"role":"assistant","content":\#(Self.quoted(content))"#
            if let thinking { message += #","thinking":\#(Self.quoted(thinking))"# }
            if let toolCalls { message += #","tool_calls":\#(toolCalls)"# }
            message += "}"
            return
                #"{"model":"m","created_at":"2026-10-21T10:00:00Z","message":\#(message),"done":\#(done)\#(extra)}"#
        }

        private static func quoted(_ text: String) -> String {
            (try? JSONEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }

        private func callEvent(_ name: String, arguments: String = "{}", id: String? = nil) -> String {
            let idField = id.map { #""id":"\#($0)","# } ?? ""
            return event(
                toolCalls: #"[{\#(idField)"function":{"index":0,"name":"\#(name)","arguments":\#(arguments)}}]"#)
        }

        @Test("text and thinking arrive as deltas, empty fields are skipped")
        func textAndThinking() {
            let result = chunks([
                event(thinking: "Let me"),
                event(content: "Hel"),
                event(content: "lo"),
                event(),
            ])
            #expect(result.count == 3)
            guard case .thinking("Let me") = result[0], case .content("Hel") = result[1],
                case .content("lo") = result[2]
            else {
                Issue.record("unexpected chunks \(result)")
                return
            }
        }

        @Test("the last event brings the usage (cached tokens are a part of the prompt) and the stop reason")
        func doneEvent() throws {
            let result = chunks([
                event(
                    done: true,
                    extra:
                        #","done_reason":"stop","prompt_eval_count":100,"prompt_eval_cached_count":60,"eval_count":20"#)
            ])
            guard case .usage(let usage) = result[0], case .finishReason("stop") = result[1] else {
                Issue.record("unexpected chunks \(result)")
                return
            }
            #expect(usage.tokensUsed == 120)
            #expect(usage.inputTokens == 40)
            #expect(usage.cachedInputTokens == 60)
            #expect(usage.outputTokens == 20)
        }

        @Test("a server that doesn't report cached tokens has none, and an impossible count is clamped")
        func cachedCount() {
            let none = chunks([event(done: true, extra: #","prompt_eval_count":10,"eval_count":5"#)])
            guard case .usage(let plain) = none[0] else {
                Issue.record("no usage")
                return
            }
            #expect(plain.cachedInputTokens == 0)
            #expect(plain.inputTokens == 10)

            let clamped = chunks([
                event(done: true, extra: #","prompt_eval_count":10,"prompt_eval_cached_count":99,"eval_count":5"#)
            ])
            guard case .usage(let usage) = clamped[0] else {
                Issue.record("no usage")
                return
            }
            #expect(usage.cachedInputTokens == 10)
            #expect(usage.inputTokens == 0)
        }

        @Test("a final event without metrics has no usage; `length` is passed on")
        func noMetrics() {
            let result = chunks([event(done: true, extra: #","done_reason":"length""#)])
            #expect(result.count == 1)
            guard case .finishReason("length") = result[0] else {
                Issue.record("unexpected \(result)")
                return
            }
        }

        @Test("a tool call arrives whole: one delta with all its arguments, an id made up for it")
        func toolCall() {
            let accumulator = ToolCallAccumulator()
            let result = chunks(
                [callEvent("get_temperature", arguments: #"{"unit":"c","city":"Paris"}"#)], accumulator: accumulator)
            guard case .toolCallDelta(let index, let id, let name, let arguments) = result[0] else {
                Issue.record("unexpected \(result)")
                return
            }
            #expect(index == 0)
            #expect(id == "call_0")
            #expect(name == "get_temperature")
            #expect(arguments == #"{"city":"Paris","unit":"c"}"#, "compact, with the keys in a stable order")

            #expect(
                accumulator.materialize() == [
                    ToolCall(id: "call_0", name: "get_temperature", arguments: #"{"city":"Paris","unit":"c"}"#)
                ])
        }

        @Test("slashes in arguments are not escaped")
        func slashes() {
            let accumulator = ToolCallAccumulator()
            _ = chunks([callEvent("read", arguments: #"{"path":"src/main.swift"}"#)], accumulator: accumulator)
            #expect(accumulator.materialize().first?.arguments == #"{"path":"src/main.swift"}"#)
        }

        @Test("calls are numbered as they come, even when the server numbers each event from 0")
        func toolCallNumbering() {
            let accumulator = ToolCallAccumulator()
            _ = chunks(
                [
                    callEvent("a"),
                    callEvent("b", arguments: #"{"x":1}"#),
                    event(
                        toolCalls:
                            #"[{"function":{"index":0,"name":"c","arguments":{}}},{"function":{"index":1,"name":"d","arguments":{}}}]"#
                    ),
                ], accumulator: accumulator)
            let calls = accumulator.materialize()
            #expect(calls.map(\.name) == ["a", "b", "c", "d"])
            #expect(calls.map(\.id) == ["call_0", "call_1", "call_2", "call_3"])
            #expect(calls[1].arguments == #"{"x":1}"#)
        }

        @Test("an id the server does send is kept")
        func serverId() {
            let accumulator = ToolCallAccumulator()
            _ = chunks([callEvent("a", id: "srv_1")], accumulator: accumulator)
            #expect(accumulator.materialize().map(\.id) == ["srv_1"])
        }

        @Test("a nameless call is ignored, arguments of any shape never crash")
        func malformedCalls() {
            let accumulator = ToolCallAccumulator()
            let result = chunks(
                [
                    event(
                        toolCalls: #"[{"function":{"arguments":{"x":1}}},{"function":{"name":"","arguments":{}}}]"#),
                    event(toolCalls: #"[{"function":{"name":"ok"}}]"#),
                    event(toolCalls: #"[{"function":{"name":"str","arguments":"{\"a\":1}"}}]"#),
                ], accumulator: accumulator)
            #expect(result.count == 2)
            #expect(accumulator.materialize().map(\.name) == ["ok", "str"])
            #expect(accumulator.materialize().map(\.arguments) == ["{}", #"{"a":1}"#])
        }

        @Test("a turn that called tools finishes as `tool_calls`, since Ollama says `stop`")
        func toolCallFinish() {
            let accumulator = ToolCallAccumulator()
            let result = chunks(
                [
                    callEvent("a"),
                    event(done: true, extra: #","done_reason":"stop","prompt_eval_count":5,"eval_count":2"#),
                ], accumulator: accumulator)
            guard case .finishReason(let reason)? = result.last else {
                Issue.record("unexpected \(result)")
                return
            }
            #expect(reason == "tool_calls")
        }

        @Test("a call in the very last event is counted before the finish reason is chosen")
        func callInLastEvent() {
            let accumulator = ToolCallAccumulator()
            let result = chunks(
                [
                    event(
                        toolCalls: #"[{"function":{"name":"a","arguments":{}}}]"#, done: true,
                        extra: #","done_reason":"stop""#)
                ], accumulator: accumulator)
            guard case .finishReason(let reason)? = result.last else {
                Issue.record("unexpected \(result)")
                return
            }
            #expect(reason == "tool_calls")
        }

        @Test("an error line ends the stream with the server's message")
        func errorLine() {
            let result = chunks([#"{"error":"an error was encountered while running the model"}"#])
            guard case .error(let message) = result[0] else {
                Issue.record("unexpected \(result)")
                return
            }
            #expect(message == "an error was encountered while running the model")

            let nested = chunks([#"{"error":{"message":"proxy says no"}}"#])
            guard case .error("proxy says no") = nested[0] else {
                Issue.record("unexpected \(nested)")
                return
            }
        }

        @Test("lines that aren't events are skipped")
        func garbage() {
            #expect(chunks(["not json", "[1,2]", "{}", #"{"message":"text"}"#]).isEmpty)
        }
    }

    @Suite("Ollama framing and errors")
    struct OllamaFramingTests {
        @Test("NDJSON takes a line as it is and skips blank ones; SSE keeps its rules")
        func framing() {
            #expect(StreamFraming.ndjson.payload(from: #"{"a":1}"#) == .data(#"{"a":1}"#))
            #expect(StreamFraming.ndjson.payload(from: "  {\"a\":1}\r") == .data(#"{"a":1}"#))
            #expect(StreamFraming.ndjson.payload(from: "") == nil)
            #expect(StreamFraming.ndjson.payload(from: "   ") == nil)
            // `data:` isn't an NDJSON prefix, and no sentinel ends the stream.
            #expect(StreamFraming.ndjson.payload(from: "[DONE]") == .data("[DONE]"))

            #expect(StreamFraming.sse.payload(from: #"data: {"a":1}"#) == .data(#"{"a":1}"#))
            #expect(StreamFraming.sse.payload(from: "data: [DONE]") == .done)
            #expect(StreamFraming.sse.payload(from: #"{"a":1}"#) == nil)
            #expect(OllamaProvider().framing == .ndjson)
            #expect(OpenAIProvider().framing == .sse)
            #expect(AnthropicProvider().framing == .sse)
        }

        @Test("the transport picks the Ollama strategy for an Ollama provider")
        func strategy() {
            #expect(LLMTransport.provider(for: resolvedOllama()) is OllamaProvider)
            let llama = ResolvedModel(provider: ollamaProvider, customType: .llamacpp, modelID: "m", apiKey: "")
            #expect(LLMTransport.provider(for: llama) is OpenAIProvider)
        }

        @Test("the error body is a plain string, and the API says who answered")
        func errors() {
            let missing = OllamaProvider().parseError(Data(#"{"error":"model 'x' not found"}"#.utf8), statusCode: 404)
            #expect(missing.providerMessage == "model 'x' not found")
            #expect(missing.statusCode == 404)
            #expect(missing.wire == .ollama)
            #expect(missing.errorDescription == "Ollama API error (404): model 'x' not found")

            let nested = OllamaProvider().parseError(Data(#"{"error":{"message":"nope"}}"#.utf8), statusCode: 400)
            #expect(nested.providerMessage == "nope")

            let html = OllamaProvider().parseError(Data("<html>bad gateway</html>".utf8), statusCode: 502)
            #expect(html.providerMessage == nil)
            #expect(html.errorDescription?.contains("bad gateway") == true)
        }
    }

    // MARK: - Adapter

    @Suite("OllamaAdapter")
    struct OllamaAdapterTests {
        private let tags = """
            {"models":[
              {"name":"llama3.2:latest","model":"llama3.2:latest"},
              {"name":"qwen3-vl:8b","model":"qwen3-vl:8b"},
              {"name":"gpt-oss:20b","model":"gpt-oss:20b"},
              {"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest"}
            ]}
            """

        private let shows: [String: String] = [
            "llama3.2:latest": """
            {"capabilities":["completion","tools"],"parameters":"",
             "model_info":{"general.architecture":"llama","llama.context_length":131072}}
            """,
            "qwen3-vl:8b": """
            {"capabilities":["completion","vision","tools","thinking"],
             "thinking":{"values":[false,true],"default":true},
             "parameters":"temperature 0.7\\nnum_ctx 8192",
             "model_info":{"general.architecture":"qwen3vl","qwen3vl.context_length":262144}}
            """,
            "gpt-oss:20b": """
            {"capabilities":["completion","tools","thinking"],
             "thinking":{"values":["high","low","medium"],"default":"medium"},
             "model_info":{"general.architecture":"gptoss","gptoss.context_length":131072}}
            """,
            "nomic-embed-text:latest": """
            {"capabilities":["embedding"],
             "model_info":{"general.architecture":"nomic-bert","nomic-bert.context_length":2048}}
            """,
        ]

        private let loaded = #"{"models":[{"name":"gpt-oss:20b","context_length":32768}]}"#

        private func adapter() -> OllamaAdapter { OllamaAdapter(provider: ollamaProvider, baseUrl: ollamaRoot) }

        private func fetcher(
            tags: String? = nil, tagsResponse: StubResponse? = nil, ps: StubResponse? = nil,
            show: [String: StubResponse] = [:]
        ) -> StubFetcher {
            let tagsAnswer = tagsResponse ?? .json(tags ?? self.tags)
            let shows = self.shows
            let psResponse = ps ?? .json(loaded)
            return StubFetcher.serving({ request in
                switch request.url.path {
                case "/api/tags": return tagsAnswer
                case "/api/ps": return psResponse
                case "/api/show":
                    let name = request.json?["model"] as? String ?? ""
                    if let override = show[name] { return override }
                    return shows[name].map { .json($0) }
                        ?? .json(#"{"error":"model '\#(name)' not found"}"#, status: 404)
                default: return .status(404)
                }
            })
        }

        private func describe(
            _ fetcher: StubFetcher, apiKey: String = ""
        ) async throws -> (listing: ProviderListing, byName: [String: CatalogModel]) {
            let metadata = StubMetadataSource(result: .failure(TestFailure()))
            let listing = try await adapter().fetchListing(apiKey: apiKey, fetcher: fetcher, metadata: metadata)
            return (listing, Dictionary(uniqueKeysWithValues: listing.models.map { ($0.id.name, $0) }))
        }

        @Test("the listing is what Ollama reports for each model, and a model that can't chat is left out")
        func capabilities() async throws {
            let (listing, byName) = try await describe(fetcher())
            #expect(listing.models.map(\.id.name) == ["gpt-oss:20b", "llama3.2:latest", "qwen3-vl:8b"])
            #expect(listing.models.allSatisfy { $0.id.provider == ollamaProvider })
            #expect(listing.modelCount == 3)
            #expect(!listing.capabilitiesUnknown)
            #expect(listing.unknownCapabilities.isEmpty)

            let llama = try #require(byName["llama3.2:latest"]?.capabilities)
            #expect(!llama.imageInput)
            #expect(!llama.reasoning.supported)
            #expect(llama.contextWindow == 4096, "neither a Modelfile value nor a loaded model: Ollama's default")

            let vision = try #require(byName["qwen3-vl:8b"]?.capabilities)
            #expect(vision.imageInput)
            #expect(vision.contextWindow == 8192, "the Modelfile's num_ctx")
            #expect(vision.reasoning.supported)
            #expect(vision.reasoning.levels.isEmpty)
            #expect(vision.reasoning.canDisable)
            #expect(vision.reasoning.options == [ReasoningSetting.off, ReasoningSetting.on])

            let oss = try #require(byName["gpt-oss:20b"]?.capabilities)
            #expect(oss.contextWindow == 32768, "the context of the loaded model")
            #expect(oss.reasoning.levels == ["low", "medium", "high"], "in the order of effort")
            #expect(oss.reasoning.defaultLevel == "medium")
            #expect(!oss.reasoning.canDisable)
            #expect(oss.reasoning.options == ["low", "medium", "high"])
        }

        @Test("the requests: tags with the key, one show per model by name, and ps")
        func requests() async throws {
            let stub = fetcher()
            _ = try await describe(stub, apiKey: "secret")
            let requests = stub.requests
            #expect(requests.first?.url.absoluteString == "http://ollama.test:11434/api/tags")
            #expect(requests.first?.method == "GET")
            #expect(requests.allSatisfy { $0.headers["Authorization"] == "Bearer secret" })
            let shown = requests.filter { $0.url.path == "/api/show" }
            #expect(shown.allSatisfy { $0.method == "POST" })
            #expect(Set(shown.compactMap { $0.json?["model"] as? String }) == Set(shows.keys))
            #expect(requests.contains { $0.url.path == "/api/ps" })

            let keyless = fetcher()
            _ = try await describe(keyless)
            #expect(keyless.requests.allSatisfy { $0.headers["Authorization"] == nil })
        }

        @Test("a model removed between the listing and its details is dropped")
        func modelGone() async throws {
            let (_, byName) = try await describe(
                fetcher(show: ["qwen3-vl:8b": .json(#"{"error":"model not found"}"#, status: 404)]))
            #expect(Set(byName.keys) == ["llama3.2:latest", "gpt-oss:20b"])
        }

        @Test("a model whose details fail is kept with assumptions and marked as unknown")
        func showFails() async throws {
            let (listing, byName) = try await describe(fetcher(show: ["gpt-oss:20b": .status(500)]))
            #expect(Set(byName.keys) == ["llama3.2:latest", "qwen3-vl:8b", "gpt-oss:20b"])
            #expect(listing.unknownCapabilities == [ModelID(provider: ollamaProvider, name: "gpt-oss:20b")])
            let oss = try #require(byName["gpt-oss:20b"]?.capabilities)
            #expect(oss.contextWindow == 32768, "what ps said is still true")
            #expect(!oss.reasoning.supported)
            #expect(!oss.imageInput)
        }

        @Test("a failing ps costs nothing but the loaded contexts")
        func psFails() async throws {
            for broken in [StubResponse.status(500), .json("nope"), .status(404)] {
                let (_, byName) = try await describe(fetcher(ps: broken))
                #expect(byName["gpt-oss:20b"]?.capabilities.contextWindow == 4096)
                #expect(byName["qwen3-vl:8b"]?.capabilities.contextWindow == 8192)
            }
        }

        @Test("a rejected key fails the listing, whether tags or show says so")
        func rejectedKey() async {
            for stub in [fetcher(tagsResponse: .status(401)), fetcher(show: ["llama3.2:latest": .status(401)])] {
                do {
                    _ = try await describe(stub)
                    Issue.record("expected a failure")
                } catch ProviderError.invalidKey {
                } catch {
                    Issue.record("expected invalidKey, got \(error)")
                }
            }
        }

        @Test("an unreachable or malformed server fails the listing")
        func failures() async {
            func failure(_ response: StubResponse) async -> ProviderError? {
                do {
                    _ = try await describe(fetcher(tagsResponse: response))
                    return nil
                } catch { return error as? ProviderError }
            }
            if case .http(let status, _)? = await failure(.status(503)) {
                #expect(status == 503)
            } else {
                Issue.record("http")
            }
            if case .badResponse? = await failure(.json("nope")) {} else { Issue.record("badResponse") }
            if case .badResponse? = await failure(.json(#"{"data":[]}"#)) {} else { Issue.record("badResponse") }
        }

        @Test("a server without models is reachable, and nothing else is asked")
        func emptyList() async throws {
            let stub = fetcher(tags: #"{"models":[]}"#)
            let (listing, _) = try await describe(stub)
            #expect(listing.models.isEmpty)
            #expect(listing.modelCount == 0)
            #expect(stub.requests.filter { $0.url.path == "/api/show" }.isEmpty)
            let validation = try await adapter().validate(
                apiKey: "", fetcher: stub, metadata: StubMetadataSource(result: .failure(TestFailure())))
            #expect(validation.modelCount == 0)
        }

        @Test("duplicate and nameless entries are ignored; `model` stands in for a missing `name`")
        func odds() async throws {
            let (listing, _) = try await describe(
                fetcher(
                    tags:
                        #"{"models":[{"name":"llama3.2:latest"},{"name":"llama3.2:latest"},{"name":""},{"model":"gpt-oss:20b"},{}]}"#
                ))
            #expect(listing.models.map(\.id.name) == ["gpt-oss:20b", "llama3.2:latest"])
        }

        @Test("many models are all described, whatever the concurrency")
        func manyModels() async throws {
            let names = (0..<25).map { "model-\($0):latest" }
            let list = names.map { #"{"name":"\#($0)"}"# }.joined(separator: ",")
            let stub = StubFetcher.serving({ request in
                switch request.url.path {
                case "/api/tags": return .json(#"{"models":[\#(list)]}"#)
                case "/api/ps": return .json(#"{"models":[]}"#)
                default: return .json(#"{"capabilities":["completion"]}"#)
                }
            })
            let (listing, _) = try await describe(stub)
            #expect(listing.models.count == 25)
        }

        // MARK: capability parsing

        @Test("a server that predates `capabilities` has plain chat models")
        func oldServer() throws {
            let caps = try #require(OllamaAdapter.capabilities(show: ["parameters": ""], loadedContext: nil))
            #expect(!caps.imageInput)
            #expect(!caps.reasoning.supported)
            #expect(caps.contextWindow == 4096)
        }

        @Test("`thinking.values` says whether and how a model thinks")
        func thinkingValues() {
            func reasoning(_ json: String, listed: [String] = ["completion", "thinking"]) -> ReasoningCapability {
                let thinking = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                return OllamaAdapter.reasoning(show: thinking.map { ["thinking": $0] } ?? [:], listed: listed)
            }
            #expect(reasoning(#"{"values":[false],"default":false}"#) == .unsupported)
            #expect(reasoning(#"{"values":[false,true],"default":true}"#).canDisable)
            #expect(reasoning(#"{"values":[true],"default":true}"#).canDisable == false)
            #expect(reasoning(#"{"values":[true],"default":true}"#).options.isEmpty, "nothing to choose")

            let levels = reasoning(#"{"values":["low","medium","high"],"default":"medium"}"#)
            #expect(levels.levels == ["low", "medium", "high"])
            #expect(levels.defaultLevel == "medium")
            #expect(!levels.canDisable)

            let both = reasoning(#"{"values":[false,"low","high"],"default":"low"}"#)
            #expect(both.canDisable)
            #expect(both.options == [ReasoningSetting.off, "low", "high"])

            // Named levels the app knows nothing about are kept, after the known ones.
            #expect(reasoning(#"{"values":["deep","low"]}"#).levels == ["low", "deep"])

            // No metadata: the capability list is all there is, and it makes an on/off switch.
            let coarse = OllamaAdapter.reasoning(show: [:], listed: ["completion", "thinking"])
            #expect(coarse.supported && coarse.canDisable && coarse.levels.isEmpty)
            #expect(OllamaAdapter.reasoning(show: [:], listed: ["completion"]) == .unsupported)
        }

        @Test(
            "the context is the Modelfile's, else the loaded one, else the default, never above what the model supports"
        )
        func contextWindow() {
            func context(parameters: String?, loaded: Int?, supported: Int?) -> Int {
                var show: [String: Any] = [:]
                if let parameters { show["parameters"] = parameters }
                if let supported {
                    show["model_info"] = ["general.architecture": "x", "x.context_length": supported]
                }
                return OllamaAdapter.contextWindow(show: show, loadedContext: loaded)
            }
            #expect(context(parameters: "num_ctx 8192", loaded: 32768, supported: 131072) == 8192)
            #expect(context(parameters: nil, loaded: 32768, supported: 131072) == 32768)
            #expect(context(parameters: "", loaded: nil, supported: 131072) == 4096)
            #expect(context(parameters: nil, loaded: nil, supported: nil) == 4096)
            #expect(context(parameters: nil, loaded: nil, supported: 2048) == 2048, "a small model can't have more")
            #expect(context(parameters: "num_ctx 500000", loaded: nil, supported: 131072) == 131072)
            #expect(context(parameters: nil, loaded: 262144, supported: 131072) == 131072)
        }

        @Test("`num_ctx` is found among other Modelfile parameters, and only when it holds a number")
        func modelfileContext() {
            #expect(OllamaAdapter.modelfileContext("temperature 0.7\nnum_ctx 16384\nstop \"<|end|>\"") == 16384)
            #expect(OllamaAdapter.modelfileContext("num_ctx\t4096") == 4096)
            #expect(OllamaAdapter.modelfileContext("num_ctx   2048  ") == 2048)
            #expect(OllamaAdapter.modelfileContext("num_ctx abc") == nil)
            #expect(OllamaAdapter.modelfileContext("num_ctx 0") == nil)
            #expect(OllamaAdapter.modelfileContext("num_ctx_extra 99") == nil)
            #expect(OllamaAdapter.modelfileContext("temperature 0.7") == nil)
            #expect(OllamaAdapter.modelfileContext(nil) == nil)
        }

        @Test("the trained context is read by architecture, or from any `.context_length` key")
        func trainedContext() {
            #expect(
                OllamaAdapter.trainedContext([
                    "general.architecture": "llama", "llama.context_length": 131072, "other.context_length": 5,
                ]) == 131072)
            #expect(OllamaAdapter.trainedContext(["foo.context_length": 4096, "bar.context_length": 8192]) == 4096)
            #expect(OllamaAdapter.trainedContext(["general.architecture": "llama"]) == nil)
            #expect(OllamaAdapter.trainedContext(nil) == nil)
        }
    }

    // MARK: - Catalog

    @Suite("Ollama in the catalog")
    struct OllamaCatalogTests {
        private func setup(fetcher: StubFetcher) async throws -> (catalog: ModelCatalog, registry: ProviderRegistry) {
            let secrets = InMemorySecretStore()
            _ = try secrets.addKey(provider: ollamaProvider, name: "Default", secret: "")
            let registry = ProviderRegistry(store: secrets)
            try await registry.load()
            await registry.setCustomProviders([
                CustomProviderConfig(name: "Local", type: .ollama, endpoint: ollamaRoot)
            ])
            let catalog = ModelCatalog(
                registry: registry, store: ModelCatalogStore(), fetcher: fetcher,
                metadata: StubMetadataSource(result: .failure(TestFailure())), clock: ManualClock())
            return (catalog, registry)
        }

        private func serving(
            show: @escaping @Sendable (String) -> StubResponse, ps: String = #"{"models":[]}"#
        ) -> StubFetcher {
            StubFetcher.serving({ request in
                switch request.url.path {
                case "/api/tags": return .json(#"{"models":[{"name":"a"},{"name":"b"}]}"#)
                case "/api/ps": return .json(ps)
                default: return show(request.json?["model"] as? String ?? "")
                }
            })
        }

        @Test("the provider's type decides the adapter a refresh uses")
        func refreshUsesNativeApi() async throws {
            let stub = serving(show: { _ in .json(#"{"capabilities":["completion","vision"]}"#) })
            let (catalog, _) = try await setup(fetcher: stub)
            let summary = await catalog.refreshAll()
            #expect(try summary.outcomes[ollamaProvider]?.get() == 2)
            #expect(stub.requests.contains { $0.url.path == "/api/tags" })
            #expect(!stub.requests.contains { $0.url.path.hasSuffix("/models") })
            #expect(await catalog.snapshot().map(\.capabilities.imageInput) == [true, true])
        }

        @Test("capabilities that couldn't be read this time keep what the catalog already had")
        func transientFailureKeepsCache() async throws {
            let failing = Locked(false)
            let stub = serving(show: { name in
                if failing.value && name == "a" { return .status(500) }
                return .json(#"{"capabilities":["completion","vision"],"parameters":"num_ctx 16384"}"#)
            })
            let (catalog, _) = try await setup(fetcher: stub)
            _ = await catalog.refreshAll()
            let before = await catalog.model(ModelID(provider: ollamaProvider, name: "a"))?.capabilities
            #expect(before?.imageInput == true)
            #expect(before?.contextWindow == 16384)

            failing.value = true
            let summary = await catalog.refreshAll()
            #expect(try summary.outcomes[ollamaProvider]?.get() == 2)
            #expect(await catalog.model(ModelID(provider: ollamaProvider, name: "a"))?.capabilities == before)
        }

        @Test("a model that was never described gets the assumptions when its details fail")
        func firstFailure() async throws {
            let stub = serving(show: { _ in .status(500) })
            let (catalog, _) = try await setup(fetcher: stub)
            _ = await catalog.refreshAll()
            let caps = await catalog.model(ModelID(provider: ollamaProvider, name: "a"))?.capabilities
            #expect(caps == OllamaAdapter.fallbackCapabilities(loaded: nil))
        }

        @Test("a chat resolves to an Ollama request: the type and the endpoint travel with the model")
        func resolution() async throws {
            let stub = serving(show: { _ in .json(#"{"capabilities":["completion"]}"#) })
            let (catalog, registry) = try await setup(fetcher: stub)
            _ = await catalog.refreshAll()
            let resolution = await ModelResolver(registry: registry, catalog: catalog).resolve("Local:a")
            guard case .ok(let resolved, _) = resolution else {
                Issue.record("unexpected \(resolution)")
                return
            }
            #expect(resolved.customType == .ollama)
            #expect(resolved.wire == .ollama)
            #expect(resolved.baseUrl == ollamaRoot)
            #expect(LLMTransport.resolveBaseUrl(model: resolved) == "http://ollama.test:11434/api")
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
