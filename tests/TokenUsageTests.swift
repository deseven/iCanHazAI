import Foundation
import Testing
@testable import iCanHazAI

// Tests for provider-reported token usage parsing, including Anthropic's
// prompt-caching fields (cache_read_input_tokens, cache_creation_input_tokens)
// and OpenAI's prompt_tokens_details.cached_tokens.
extension AllAppTests {
    @Suite("Token usage parsing")
    struct TokenUsageTests {

        // MARK: - Anthropic

        @Test("Anthropic message_start extracts input, cached, and creation tokens")
        func anthropicMessageStartUsage() throws {
            let provider = AnthropicProvider()
            let acc = ToolCallAccumulator()
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "message_start",
                "message": [
                    "id": "msg_123",
                    "type": "message",
                    "role": "assistant",
                    "content": [],
                    "model": "claude-sonnet-4-6",
                    "stop_reason": NSNull(),
                    "usage": [
                        "input_tokens": 100,
                        "output_tokens": 50,
                        "cache_read_input_tokens": 947000,
                        "cache_creation_input_tokens": 323000,
                    ],
                ],
            ])
            let chunks = provider.parseStreamChunk(data, accumulator: acc)
            #expect(chunks.count == 1)
            guard case .usage(let usage) = chunks[0] else {
                Issue.record("Expected usage chunk")
                return
            }
            #expect(usage.tokensUsed == 947_150)
            #expect(usage.inputTokens == 100)
            #expect(usage.outputTokens == 50)
            #expect(usage.cachedInputTokens == 947_000)
            #expect(usage.cacheCreationTokens == 323_000)
        }

        @Test("Anthropic message_delta combines with message_start stashed tokens")
        func anthropicMessageDeltaUsage() throws {
            let provider = AnthropicProvider()
            let acc = ToolCallAccumulator()
            // Stash input tokens first (as message_start would do)
            acc.setInputTokens(100, cached: 947_000, creation: 323_000)
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "message_delta",
                "delta": [
                    "stop_reason": "end_turn",
                ],
                "usage": [
                    "output_tokens": 46_000,
                ],
            ])
            let chunks = provider.parseStreamChunk(data, accumulator: acc)
            #expect(chunks.count == 2) // finishReason + usage
            guard case .usage(let usage) = chunks[1] else {
                Issue.record("Expected usage chunk at index 1")
                return
            }
            #expect(usage.tokensUsed == 993_100)
            #expect(usage.inputTokens == 100)
            #expect(usage.outputTokens == 46_000)
            #expect(usage.cachedInputTokens == 947_000)
            #expect(usage.cacheCreationTokens == 323_000)
        }

        @Test("Anthropic message_start without caching fields defaults to zero")
        func anthropicNoCacheDefaults() throws {
            let provider = AnthropicProvider()
            let acc = ToolCallAccumulator()
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "message_start",
                "message": [
                    "id": "msg_456",
                    "type": "message",
                    "role": "assistant",
                    "content": [],
                    "model": "claude-sonnet-4-6",
                    "stop_reason": NSNull(),
                    "usage": [
                        "input_tokens": 200,
                        "output_tokens": 75,
                    ],
                ],
            ])
            let chunks = provider.parseStreamChunk(data, accumulator: acc)
            guard case .usage(let usage) = chunks[0] else {
                Issue.record("Expected usage chunk")
                return
            }
            #expect(usage.tokensUsed == 275)
            #expect(usage.inputTokens == 200)
            #expect(usage.outputTokens == 75)
            #expect(usage.cachedInputTokens == 0)
            #expect(usage.cacheCreationTokens == 0)
        }

        // MARK: - OpenAI

        @Test("OpenAI final chunk extracts total, prompt, and completion tokens")
        func openAIFinalChunkUsage() throws {
            let provider = OpenAIProvider()
            let data = try JSONSerialization.data(withJSONObject: [
                "id": "chatcmpl-123",
                "object": "chat.completion.chunk",
                "created": 1700000000,
                "model": "gpt-5",
                "choices": [],
                "usage": [
                    "prompt_tokens": 100,
                    "completion_tokens": 50,
                    "total_tokens": 150,
                ],
            ])
            let chunks = provider.parseStreamChunk(data, accumulator: ToolCallAccumulator())
            #expect(chunks.count == 1)
            guard case .usage(let usage) = chunks[0] else {
                Issue.record("Expected usage chunk")
                return
            }
            #expect(usage.tokensUsed == 150)
            #expect(usage.inputTokens == 100)
            #expect(usage.outputTokens == 50)
            #expect(usage.cachedInputTokens == 0)
            #expect(usage.cacheCreationTokens == 0)
        }

        @Test("OpenAI final chunk extracts cached prompt tokens")
        func openAICachedTokens() throws {
            let provider = OpenAIProvider()
            let data = try JSONSerialization.data(withJSONObject: [
                "id": "chatcmpl-456",
                "object": "chat.completion.chunk",
                "created": 1700000000,
                "model": "gpt-5",
                "choices": [],
                "usage": [
                    "prompt_tokens": 500,
                    "completion_tokens": 200,
                    "total_tokens": 700,
                    "prompt_tokens_details": [
                        "cached_tokens": 400,
                    ],
                ],
            ])
            let chunks = provider.parseStreamChunk(data, accumulator: ToolCallAccumulator())
            guard case .usage(let usage) = chunks[0] else {
                Issue.record("Expected usage chunk")
                return
            }
            #expect(usage.tokensUsed == 700)
            // inputTokens = prompt_tokens - cached_tokens = 500 - 400 = 100
            #expect(usage.inputTokens == 100)
            #expect(usage.outputTokens == 200)
            #expect(usage.cachedInputTokens == 400)
            #expect(usage.cacheCreationTokens == 0)
        }

        @Test("OpenAI non-usage chunk is parsed as content")
        func openAIContentChunk() throws {
            let provider = OpenAIProvider()
            let data = try JSONSerialization.data(withJSONObject: [
                "id": "chatcmpl-789",
                "object": "chat.completion.chunk",
                "created": 1700000000,
                "model": "gpt-5",
                "choices": [
                    [
                        "index": 0,
                        "delta": [
                            "content": "Hello",
                        ],
                        "finish_reason": NSNull(),
                    ],
                ],
            ])
            let chunks = provider.parseStreamChunk(data, accumulator: ToolCallAccumulator())
            #expect(chunks.count == 1)
            guard case .content(let text) = chunks[0] else {
                Issue.record("Expected content chunk")
                return
            }
            #expect(text == "Hello")
        }

        // MARK: - TokenUsage display string

        @Test("TokenUsage displayString shows all non-zero fields")
        func displayStringAllFields() {
            let usage = TokenUsage(
                tokensUsed: 947_150,
                inputTokens: 100,
                outputTokens: 46_000,
                cachedInputTokens: 947_000,
                cacheCreationTokens: 323_000
            )
            let display = usage.displayString
            #expect(display.contains("947150 total"))
            #expect(display.contains("100 input"))
            #expect(display.contains("46000 output"))
            #expect(display.contains("947000 cached input"))
        }

        @Test("TokenUsage displayString omits zero fields")
        func displayStringOmitsZeros() {
            let usage = TokenUsage(
                tokensUsed: 150,
                inputTokens: 100,
                outputTokens: 50,
                cachedInputTokens: 0,
                cacheCreationTokens: 0
            )
            let display = usage.displayString
            #expect(display.contains("150 total"))
            #expect(display.contains("100 input"))
            #expect(display.contains("50 output"))
            #expect(display.contains("0 cached input"))
        }
    }
}
