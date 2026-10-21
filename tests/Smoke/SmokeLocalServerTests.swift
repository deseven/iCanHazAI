import Foundation
import Testing

@testable import iCanHazAI

// What is specific to the two local-server types: Ollama through its native API and llama.cpp's llama-server
// (single-model and router mode). The shared behaviour (streams, tools, errors) runs for them in the
// provider-parameterised suites; these are the requests and discovery that only they make.
extension AllSmokeTests {
    @Suite("Local servers")
    struct SmokeLocalServerTests {

        private func models(_ fx: SmokeFixture, _ sp: SmokeProvider) async -> [String: ModelCapabilities] {
            let listed = await fx.engine.models.filter { $0.id.provider == sp.provider }
            return Dictionary(uniqueKeysWithValues: listed.map { ($0.id.name, $0.capabilities) })
        }

        // MARK: - Ollama

        @Test("Ollama is asked for its models, then for each one's details, and for what is loaded")
        func ollamaDiscovery() async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(.ollama)

                let requests = try await fx.mock.requests(.ollama)
                let tags = try #require(requests.first { $0.path == "/ollama/api/tags" })
                #expect(tags.method == "GET")
                #expect(tags.status == 200)
                #expect(requests.contains { $0.path == "/ollama/api/ps" })
                let shown = requests.filter { $0.path == "/ollama/api/show" }
                #expect(
                    Set(shown.compactMap { $0.json["model"] as? String }).isSuperset(
                        of: SmokeProvider.ollama.expectedModels))
                #expect(shown.allSatisfy { $0.method == "POST" && $0.status == 200 })
                // Nothing goes to the OpenAI layer.
                #expect(!requests.contains { $0.path.contains("/v1/") })
            }
        }

        @Test("the type is saved with the provider in the config")
        func typeIsPersisted() async throws {
            try await SmokeFixture.run { fx in
                for sp in [SmokeProvider.ollama, .llamaCpp] {
                    try await fx.addProvider(sp)
                }
                let saved = await ConfigManager.shared.getCustomProviders()
                #expect(saved.first { $0.name == "ollama" }?.type == .ollama)
                #expect(saved.first { $0.name == "llama-cpp" }?.type == .llamacpp)
                #expect(saved.first { $0.name == "ollama" }?.endpoint == SmokeProvider.ollama.baseURL)
            }
        }

        @Test("an address pasted the OpenAI way works: /v1 is dropped and the native API is used")
        func ollamaPastedOpenAIUrl() async throws {
            try await SmokeFixture.run { fx in
                let root = SmokeProvider.ollama.baseURL
                let pasted = CustomProviderConfig(
                    name: "ollama", type: .ollama,
                    endpoint: CustomProviderConfig.normalizedEndpoint(root + "/v1/", type: .ollama) ?? "")
                #expect(pasted.endpoint == root)
                let validation = try await fx.engine.validateProvider(
                    SmokeProvider.ollama.provider, custom: pasted, apiKey: "")
                #expect(Set(validation.seed.map(\.id.name)) == SmokeProvider.ollama.expectedModels)
                #expect(try await fx.mock.requests(.ollama).contains { $0.path == "/ollama/api/tags" })
            }
        }

        @Test("a thinking level is sent as `think`, and no context is chosen for the model")
        func ollamaThinkLevel() async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(.ollama)
                try await fx.installRole()
                let chat = await fx.newChat(.ollama, model: "gpt-oss:20b")
                await fx.engine.setReasoning(filename: chat, setting: "high")
                try await fx.mock.enqueue(.ollama, .thinking("hm"), .text("done"))

                await fx.send(chat, "think hard")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                let request = try #require(try await fx.mock.chatRequests(.ollama).first)
                #expect(request.json["think"] as? String == "high")
                #expect(request.json["options"] == nil)
                #expect(record.chat?.activeMessages.last?.thinking == "hm")
            }
        }

        @Test("a thinking on/off switch is sent as a boolean")
        func ollamaThinkSwitch() async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(.ollama)
                try await fx.installRole()
                let chat = await fx.newChat(.ollama, model: "qwen3-vl:8b")
                await fx.engine.setReasoning(filename: chat, setting: ReasoningSetting.off)
                try await fx.mock.enqueue(.ollama, .text("quick"))

                await fx.send(chat, "no thinking please")
                _ = try await fx.waitUntilIdle(chat)

                let request = try #require(try await fx.mock.chatRequests(.ollama).first)
                #expect(request.json["think"] as? Bool == false)
            }
        }

        @Test("a model that doesn't think is never sent `think`, even if the chat remembers a setting")
        func ollamaNoThinkForPlainModel() async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(.ollama)
                try await fx.installRole()
                let chat = await fx.newChat(.ollama)
                await fx.engine.setReasoning(filename: chat, setting: "high")
                try await fx.mock.enqueue(.ollama, .text("ok"))

                await fx.send(chat, "hi")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                let request = try #require(try await fx.mock.chatRequests(.ollama).first)
                #expect(request.json["think"] == nil)
            }
        }

        @Test("two tool calls in one turn are executed and answered in the order they were made")
        func ollamaParallelTools() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(.ollama, tools: .calcAutoAllow)
                try await fx.mock.enqueue(
                    .ollama, .toolCall(name: "calc", arguments: Calc.call("1+1")),
                    .toolCall(name: "calc", arguments: Calc.call("2+2")))
                try await fx.mock.enqueue(.ollama, .text("2 and 4"))

                await fx.send(chat, "two sums")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                let messages = try #require(record.chat).activeMessages
                let calls = try #require(messages.first { $0.role == .assistant }?.toolCalls)
                #expect(calls.count == 2)
                #expect(Set(calls.map(\.id)).count == 2, "calls without ids still get distinct ones")
                #expect(messages.last?.content == "2 and 4")

                let history = try #require(try await fx.mock.chatRequests(.ollama).last).messages
                #expect(history.compactMap { $0["tool_name"] as? String } == ["calc", "calc"])
                let answers = history.filter { $0["role"] as? String == "tool" }.compactMap { $0["content"] as? String }
                #expect(answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } == ["2", "4"])
            }
        }

        @Test("a server that fails for one model's details still offers it, with assumptions")
        func ollamaShowFailure() async throws {
            try await SmokeFixture.run { fx in
                try await fx.mock.configure(.ollama, ["show_failures": ["gpt-oss:20b"]])
                try await fx.addProvider(.ollama)

                let caps = await models(fx, .ollama)
                #expect(Set(caps.keys) == SmokeProvider.ollama.expectedModels)
                #expect(caps["gpt-oss:20b"]?.reasoning.supported == false)
                #expect(caps["gpt-oss:20b"]?.contextWindow == 32_768, "the loaded context is still known")
                #expect(caps["qwen3-vl:8b"]?.imageInput == true)
            }
        }

        @Test("without /api/ps the listing still works and the context falls back to the default")
        func ollamaPsFailure() async throws {
            try await SmokeFixture.run { fx in
                try await fx.mock.configure(.ollama, ["ps_status": 500])
                try await fx.addProvider(.ollama)

                let caps = await models(fx, .ollama)
                #expect(caps["gpt-oss:20b"]?.contextWindow == OllamaAdapter.defaultContextWindow)
                #expect(caps["qwen3-vl:8b"]?.contextWindow == 8192)
            }
        }

        @Test("an Ollama error comes back as the plain message the server sent")
        func ollamaErrorMessage() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(.ollama)
                try await fx.mock.enqueue(.ollama, .httpError(500, message: "model runner has unexpectedly stopped"))
                try await fx.mock.enqueue(.ollama, .httpError(500, message: "model runner has unexpectedly stopped"))

                await fx.send(chat, "hello")
                let record = try await fx.waitUntilIdle(chat)

                // Labelled with the provider's own name, like any other provider's error.
                let error = try #require(record.lastError)
                #expect(error == "ollama API error (500): model runner has unexpectedly stopped")
            }
        }

        @Test("a stopped Ollama stream is noticed by the server and keeps the text that arrived")
        func ollamaStop() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(.ollama)
                // Long enough to be flushed on its own: the stream coalescer holds shorter text back.
                let partial = "Partial answer"
                try await fx.mock.enqueue(.ollama, .text(partial), .gate("hold"), .text(" and more"))

                await fx.send(chat, "go")
                let request = try await fx.mock.waitForChatRequest(.ollama, index: 0, atGate: "hold")
                try await fx.waitForAnswer(chat, partial)
                await fx.engine.stopStreaming(filename: chat)
                let record = try await fx.waitUntilIdle(chat)
                try await fx.mock.waitForDisconnect(seq: request.seq)

                #expect(record.chat?.activeMessages.last?.content == partial)
            }
        }

        // MARK: - llama.cpp

        @Test("llama-server is asked for its models under /v1 and for /props at the root")
        func llamaCppDiscovery() async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(.llamaCpp)
                let requests = try await fx.mock.requests(.llamaCpp)
                #expect(requests.map(\.path) == ["/llama-cpp/v1/models", "/llama-cpp/props"])
                #expect(requests.allSatisfy { $0.status == 200 && $0.header("authorization") == "Bearer mock-key" })
            }
        }

        @Test("llama.cpp reasoning: off is reasoning_effort none, on is the template's own switch")
        func llamaCppReasoning() async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(.llamaCpp)
                try await fx.installRole()
                let chat = await fx.newChat(.llamaCpp)

                await fx.engine.setReasoning(filename: chat, setting: ReasoningSetting.off)
                try await fx.mock.enqueue(.llamaCpp, .text("one"))
                await fx.send(chat, "first")
                try await fx.waitUntilIdle(chat)

                await fx.engine.setReasoning(filename: chat, setting: ReasoningSetting.on)
                try await fx.mock.enqueue(.llamaCpp, .text("two"))
                await fx.send(chat, "second")
                try await fx.waitUntilIdle(chat)

                let requests = try await fx.mock.chatRequests(.llamaCpp)
                #expect(requests.count == 2)
                #expect(requests[0].json["reasoning_effort"] as? String == "none")
                #expect(requests[0].json["chat_template_kwargs"] == nil)
                #expect(requests[1].json["reasoning_effort"] == nil)
                #expect(
                    (requests[1].json["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true)
            }
        }

        @Test("a template that takes an effort level offers the levels, and the chosen one is sent")
        func llamaCppEffort() async throws {
            try await SmokeFixture.run { fx in
                try await fx.mock.configure(
                    .llamaCpp,
                    [
                        "props": [
                            "chat_template": "reasoning_effort {{ messages }}",
                            "chat_template_caps": ["supports_reasoning_effort": true],
                        ]
                    ])
                try await fx.addProvider(.llamaCpp)
                #expect(await models(fx, .llamaCpp)["qwen3-8b"]?.reasoning.options == ["low", "medium", "high"])

                try await fx.installRole()
                let chat = await fx.newChat(.llamaCpp)
                await fx.engine.setReasoning(filename: chat, setting: "low")
                try await fx.mock.enqueue(.llamaCpp, .text("ok"))
                await fx.send(chat, "hi")
                try await fx.waitUntilIdle(chat)

                let request = try #require(try await fx.mock.chatRequests(.llamaCpp).first)
                #expect(request.json["reasoning_effort"] as? String == "low")
            }
        }

        @Test("a router lists all its models, tells vision from the files, and routes the chat by model name")
        func llamaCppRouter() async throws {
            try await SmokeFixture.run { fx in
                try await fx.mock.configure(.llamaCpp, ["router": true])
                try await fx.addProvider(.llamaCpp)

                let caps = await models(fx, .llamaCpp)
                #expect(Set(caps.keys) == ["qwen3-8b", "gemma-3-4b-it"])
                #expect(caps["qwen3-8b"]?.contextWindow == 8192, "loaded: its own context")
                #expect(caps["gemma-3-4b-it"]?.imageInput == true, "unloaded, but the modalities are known")
                #expect(caps["gemma-3-4b-it"]?.contextWindow == LlamaCppAdapter.defaultContextWindow)

                // Only the loaded model is asked about, by name.
                let props = try await fx.mock.requests(.llamaCpp).filter { $0.path == "/llama-cpp/props" }
                #expect(props.map { $0.query["model"] } == ["qwen3-8b"])

                try await fx.installRole()
                let chat = await fx.newChat(.llamaCpp, model: "gemma-3-4b-it")
                try await fx.mock.enqueue(.llamaCpp, .text("hello from the router"))
                await fx.send(chat, "hi")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                #expect(record.chat?.activeMessages.last?.content == "hello from the router")
                let request = try #require(try await fx.mock.chatRequests(.llamaCpp).first)
                #expect(request.json["model"] as? String == "gemma-3-4b-it")
            }
        }

        @Test("a server that doesn't answer /props still gets its models listed")
        func llamaCppNoProps() async throws {
            try await SmokeFixture.run { fx in
                try await fx.mock.configure(.llamaCpp, ["props_status": 404])
                try await fx.addProvider(.llamaCpp)

                let qwen = try #require(await models(fx, .llamaCpp)["qwen3-8b"])
                #expect(qwen.contextWindow == 32_768, "from /v1/models")
                #expect(!qwen.reasoning.supported)
            }
        }

        @Test("a prompt over the context is reported with the sizes llama-server gives")
        func llamaCppContextOverflow() async throws {
            try await SmokeFixture.run { fx in
                let chat = try await fx.start(.llamaCpp)
                try await fx.mock.enqueue(
                    .llamaCpp,
                    .httpError(
                        400, message: "the request exceeds the available context size",
                        type: "exceed_context_size_error"))

                await fx.send(chat, "a very long prompt")
                let record = try await fx.waitUntilIdle(chat)

                let error = try #require(record.lastError)
                #expect(error.contains("the request exceeds the available context size"))
                #expect(error.contains("9000") && error.contains("4096"))
                #expect(try await fx.mock.chatRequests(.llamaCpp).count == 1, "a 4xx isn't retried")
            }
        }
    }
}
