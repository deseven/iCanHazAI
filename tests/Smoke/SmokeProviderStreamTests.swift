import Foundation
import Testing

@testable import iCanHazAI

// A chat through the whole engine against each provider's wire format: what the app sends, and what ends up
// in the chat once the mock's stream has been parsed.
extension AllSmokeTests {
    @Suite("Provider streams")
    struct SmokeProviderStreamTests {

        private func text(_ message: [String: Any]?) -> String? { message?["content"] as? String }

        @Test(
            "a plain answer streams into the chat and the request has the provider's shape",
            arguments: SmokeProvider.allCases)
        func plainAnswer(_ sp: SmokeProvider) async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(sp)
                try await fx.installRole()
                let chat = await fx.newChat(sp)
                try await fx.mock.enqueue(
                    sp.channel, .text("Hel"), .text("lo "), .text("world"), .usage(input: 11, output: 3, cached: 2))

                await fx.send(chat, "hi there")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant])
                #expect(messages[0].content == "hi there")
                #expect(messages[1].content == "Hello world")
                #expect(messages[1].model == sp.modelString)
                let usage = try #require(messages[1].tokenUsage)
                #expect(usage.inputTokens == 11)
                #expect(usage.cachedInputTokens == 2)
                #expect(usage.outputTokens == 3)
                #expect(usage.tokensUsed == 16)

                let saved = try fx.persisted(chat)
                #expect(saved.activeMessages.map(\.content) == ["hi there", "Hello world"])
                #expect(saved.activeMessages[1].tokenUsage == usage)

                let requests = try await fx.mock.chatRequests(sp.channel)
                #expect(requests.count == 1)
                let request = try #require(requests.first)
                #expect(request.path == sp.chatPath)
                sp.expectAuth(request)
                #expect(request.json["model"] as? String == sp.modelName)
                #expect(request.json["stream"] as? Bool == true)
                if sp.isAnthropic {
                    #expect(request.json["system"] as? String == SmokeFixture.systemPrompt)
                    #expect(request.json["max_tokens"] as? Int == AnthropicProvider.maxTokensCap)
                    #expect(request.messages.count == 1)
                } else {
                    if sp.isOllamaNative {
                        // Ollama's own shape: no OpenAI leftovers, and the context is left to the server.
                        #expect(request.json["stream_options"] == nil)
                        #expect(request.json["options"] == nil)
                    } else {
                        let options = request.json["stream_options"] as? [String: Any]
                        #expect(options?["include_usage"] as? Bool == true)
                    }
                    #expect(request.messages.count == 2)
                    #expect(request.messages.first?["role"] as? String == "system")
                    #expect(text(request.messages.first) == SmokeFixture.systemPrompt)
                }
                #expect(request.messages.last?["role"] as? String == "user")
                #expect(text(request.messages.last) == "hi there")
            }
        }

        @Test("reasoning text lands in the thinking field", arguments: SmokeProvider.allCases.filter(\.streamsThinking))
        func thinking(_ sp: SmokeProvider) async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(sp)
                try await fx.installRole()
                let chat = await fx.newChat(sp)
                try await fx.mock.enqueue(sp.channel, .thinking("Let me "), .thinking("think"), .text("Answer"))

                await fx.send(chat, "question")
                let record = try await fx.waitUntilIdle(chat)

                let chatData = try #require(record.chat)
                let answer = try #require(chatData.activeMessages.last)
                #expect(answer.thinking == "Let me think")
                #expect(answer.content == "Answer")
                #expect(answer.thinkingDuration != nil)
            }
        }

        @Test(
            "a tool call is executed and its result goes back in the provider's own encoding",
            arguments: SmokeProvider.allCases)
        func toolRoundTrip(_ sp: SmokeProvider) async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(sp)
                try await fx.installRole(tools: .calcAutoAllow)
                let chat = await fx.newChat(sp)
                let arguments = #"{"expression":"2+2"}"#
                try await fx.mock.enqueue(
                    sp.channel, .text("Let me compute."),
                    .toolCall(name: "calc", arguments: arguments, id: "call_calc_1", split: 3))
                try await fx.mock.enqueue(sp.channel, .text("The answer is 4"))

                await fx.send(chat, "what is 2+2?")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError == nil)
                let messages = try #require(record.chat).activeMessages
                #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant])
                let call = try #require(messages[1].toolCalls?.first)
                #expect(call.id == "call_calc_1")
                #expect(call.name == "calc")
                #expect(call.arguments == arguments)
                let result = try #require(messages[2].toolResults?.first)
                #expect(result.callID == "call_calc_1")
                #expect(result.content.trimmingCharacters(in: .whitespacesAndNewlines) == "4")
                #expect(!result.isError)
                #expect(messages[3].content == "The answer is 4")

                let requests = try await fx.mock.chatRequests(sp.channel)
                #expect(requests.count == 2)
                let first = try #require(requests.first)
                let tools = try #require(first.json["tools"] as? [[String: Any]])
                if sp.isAnthropic {
                    #expect(tools.first?["name"] as? String == "calc")
                    #expect(tools.first?["input_schema"] != nil)
                } else {
                    let function = tools.first?["function"] as? [String: Any]
                    #expect(function?["name"] as? String == "calc")
                    #expect(function?["parameters"] != nil)
                }

                let history = try #require(requests.last).messages
                if sp.isOllamaNative {
                    // Whole calls with object arguments, and no ids on the wire: the result names its function.
                    #expect(history.count == 4)
                    #expect(history[2]["role"] as? String == "assistant")
                    #expect(text(history[2]) == "Let me compute.")
                    let calls = try #require(history[2]["tool_calls"] as? [[String: Any]])
                    #expect(calls.count == 1)
                    #expect(calls.first?["id"] == nil)
                    let function = try #require(calls.first?["function"] as? [String: Any])
                    #expect(function["name"] as? String == "calc")
                    #expect((function["arguments"] as? [String: Any])?["expression"] as? String == "2+2")
                    #expect(history[3]["role"] as? String == "tool")
                    #expect(history[3]["tool_name"] as? String == "calc")
                    #expect(history[3]["tool_call_id"] == nil)
                    #expect(text(history[3])?.trimmingCharacters(in: .whitespacesAndNewlines) == "4")
                } else if sp.isAnthropic {
                    #expect(history.count == 3)
                    #expect(history[1]["role"] as? String == "assistant")
                    let blocks = try #require(history[1]["content"] as? [[String: Any]])
                    #expect(blocks.first?["type"] as? String == "text")
                    #expect(blocks.first?["text"] as? String == "Let me compute.")
                    let assistant = try #require(blocks.first { $0["type"] as? String == "tool_use" })
                    #expect(assistant["id"] as? String == "call_calc_1")
                    #expect(assistant["name"] as? String == "calc")
                    #expect((assistant["input"] as? [String: Any])?["expression"] as? String == "2+2")
                    let toolResult = try #require((history[2]["content"] as? [[String: Any]])?.first)
                    #expect(history[2]["role"] as? String == "user")
                    #expect(toolResult["type"] as? String == "tool_result")
                    #expect(toolResult["tool_use_id"] as? String == "call_calc_1")
                    #expect((toolResult["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "4")
                } else {
                    #expect(history.count == 4)
                    #expect(history[2]["role"] as? String == "assistant")
                    let calls = try #require(history[2]["tool_calls"] as? [[String: Any]])
                    #expect(calls.first?["id"] as? String == "call_calc_1")
                    let function = calls.first?["function"] as? [String: Any]
                    #expect(function?["name"] as? String == "calc")
                    #expect(function?["arguments"] as? String == arguments)
                    #expect(history[3]["role"] as? String == "tool")
                    #expect(history[3]["tool_call_id"] as? String == "call_calc_1")
                    #expect(text(history[3])?.trimmingCharacters(in: .whitespacesAndNewlines) == "4")
                }
            }
        }

        @Test(
            "an HTTP error surfaces with the provider's message and is not retried",
            arguments: SmokeProvider.allCases, [401, 429])
        func httpError(_ sp: SmokeProvider, _ status: Int) async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(sp)
                try await fx.installRole()
                let chat = await fx.newChat(sp)
                try await fx.mock.enqueue(sp.channel, .httpError(status, message: "mock failure \(status)"))

                await fx.send(chat, "hello")
                let record = try await fx.waitUntilIdle(chat)

                let error = try #require(record.lastError)
                #expect(error.contains("\(status)"))
                #expect(error.contains("mock failure \(status)"))
                let assistant = try #require(record.chat?.activeMessages.last)
                #expect(assistant.role == .assistant)
                #expect(assistant.error == error)
                #expect(try fx.persisted(chat).activeMessages.last?.error == error)
                #expect(try await fx.mock.chatRequests(sp.channel).count == 1)
            }
        }

        @Test(
            "an error event inside a 200 stream keeps the partial answer and reports the error",
            arguments: SmokeProvider.allCases)
        func midStreamError(_ sp: SmokeProvider) async throws {
            try await SmokeFixture.run { fx in
                try await fx.addProvider(sp)
                try await fx.installRole()
                let chat = await fx.newChat(sp)
                try await fx.mock.enqueue(sp.channel, .text("partial"), .sseError("Upstream exploded"))

                await fx.send(chat, "hello")
                let record = try await fx.waitUntilIdle(chat)

                #expect(record.lastError?.contains("Upstream exploded") == true)
                let assistant = try #require(record.chat?.activeMessages.last)
                #expect(assistant.content == "partial")
                #expect(assistant.error?.contains("Upstream exploded") == true)
            }
        }
    }
}
