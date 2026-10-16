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
            // Input includes cache writes (fresh input): 100 + 323 000.
            #expect(usage.tokensUsed == 1_270_150)
            #expect(usage.inputTokens == 323_100)
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
                    "stop_reason": "end_turn"
                ],
                "usage": [
                    "output_tokens": 46_000
                ],
            ])
            let chunks = provider.parseStreamChunk(data, accumulator: acc)
            #expect(chunks.count == 2)  // finishReason + usage
            guard case .usage(let usage) = chunks[1] else {
                Issue.record("Expected usage chunk at index 1")
                return
            }
            #expect(usage.tokensUsed == 1_316_100)
            #expect(usage.inputTokens == 323_100)
            #expect(usage.outputTokens == 46_000)
            #expect(usage.cachedInputTokens == 947_000)
            #expect(usage.cacheCreationTokens == 323_000)
        }

        @Test("Anthropic message_delta input usage overrides smaller message_start values")
        func anthropicMessageDeltaInputOverride() throws {
            let provider = AnthropicProvider()
            let acc = ToolCallAccumulator()
            acc.setInputTokens(10, cached: 0, creation: 0)
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "message_delta",
                "delta": ["stop_reason": "end_turn"],
                "usage": [
                    "input_tokens": 20,
                    "cache_read_input_tokens": 5_000,
                    "cache_creation_input_tokens": 1_000,
                    "output_tokens": 300,
                ],
            ])
            let chunks = provider.parseStreamChunk(data, accumulator: acc)
            guard case .usage(let usage) = chunks[1] else {
                Issue.record("Expected usage chunk at index 1")
                return
            }
            #expect(usage.inputTokens == 1_020)
            #expect(usage.cachedInputTokens == 5_000)
            #expect(usage.outputTokens == 300)
            #expect(usage.tokensUsed == 6_320)
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
                "created": 1_700_000_000,
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
                "created": 1_700_000_000,
                "model": "gpt-5",
                "choices": [],
                "usage": [
                    "prompt_tokens": 500,
                    "completion_tokens": 200,
                    "total_tokens": 700,
                    "prompt_tokens_details": [
                        "cached_tokens": 400
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

        @Test("OpenAI final chunk with usage also yields the finish reason and tool-call deltas")
        func openAIFinalChunkCombined() throws {
            // Real-world shape (CrofAI/GLM): `stream_options.include_usage`
            // puts usage in the same final chunk that carries the finish
            // reason and the last tool-call delta. The usage branch must not
            // shadow the choices parsing.
            let provider = OpenAIProvider()
            let acc = ToolCallAccumulator()
            let data = try JSONSerialization.data(withJSONObject: [
                "id": "chatcmpl-789",
                "object": "chat.completion.chunk",
                "created": 1_700_000_000,
                "model": "glm-5.3-flash",
                "choices": [
                    [
                        "index": 0,
                        "delta": [
                            "content": "",
                            "tool_calls": [
                                [
                                    "index": 0,
                                    "id": nil,
                                    "function": [
                                        "arguments": "{}",
                                        "name": nil,
                                    ],
                                    "type": nil,
                                ]
                            ],
                        ],
                        "finish_reason": "tool_calls",
                    ]
                ],
                "usage": [
                    "prompt_tokens": 1032,
                    "completion_tokens": 76,
                    "total_tokens": 1108,
                ],
            ])
            let chunks = provider.parseStreamChunk(data, accumulator: acc)
            let kinds = chunks.map { chunk -> String in
                switch chunk {
                case .usage: return "usage"
                case .finishReason: return "finishReason"
                case .toolCallDelta: return "toolCallDelta"
                default: return "other"
                }
            }
            #expect(kinds.contains("usage"))
            #expect(kinds.contains("finishReason"))
            #expect(kinds.contains("toolCallDelta"))
            guard
                case .finishReason(let reason) = chunks.first(where: {
                    if case .finishReason = $0 { return true }
                    return false
                })
            else {
                Issue.record("Expected finish reason chunk")
                return
            }
            #expect(reason == "tool_calls")
            let calls = acc.materialize()
            #expect(calls.count == 1)
            #expect(calls[0].arguments == "{}")
        }

        @Test("OpenAI non-usage chunk is parsed as content")
        func openAIContentChunk() throws {
            let provider = OpenAIProvider()
            let data = try JSONSerialization.data(withJSONObject: [
                "id": "chatcmpl-789",
                "object": "chat.completion.chunk",
                "created": 1_700_000_000,
                "model": "gpt-5",
                "choices": [
                    [
                        "index": 0,
                        "delta": [
                            "content": "Hello"
                        ],
                        "finish_reason": NSNull(),
                    ]
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

// MARK: - Number formatting

@Test("formatCount follows the display ladder")
func formatCountLadder() {
    let cases: [(Int, String)] = [
        (1, "1"),
        (10, "10"),
        (100, "100"),
        (999, "999"),
        (1_000, "1 000"),
        (10_000, "10 000"),
        (99_999, "99 999"),
        (100_000, "100.0k"),
        (999_499, "999.5k"),
        (1_000_000, "1.00kk"),
        (10_000_000, "10.00kk"),
        (100_000_000, "100.00kk"),
        (1_000_000_000, "1.00kkk"),
        (10_000_000_000, "10.00kkk"),
    ]
    for (count, expected) in cases {
        #expect(TokenUsage.formatCount(count) == expected, "formatCount(\(count))")
    }
}

@Test("formatCount falls through to the next tier on rounding overflow")
func formatCountTierOverflow() {
    // 999_999 rounds to 1000.0k, which must display as 1.00kk, not 1000.0k
    #expect(TokenUsage.formatCount(999_999) == "1.00kk")
    // 999_999_999 rounds to 1000.00kk, which must display as 1.00kkk
    #expect(TokenUsage.formatCount(999_999_999) == "1.00kkk")
}

@Test("breakdown lists only non-zero counters in Input/Cached/Output order")
func breakdownComponentsOrder() {
    let usage = TokenUsage(
        tokensUsed: 500,
        inputTokens: 100,
        outputTokens: 50,
        cachedInputTokens: 947_000,
        cacheCreationTokens: 323_000
    )
    #expect(usage.breakdownComponents.map(\.label) == ["Input", "Cached", "Output"])
    #expect(usage.breakdownTitle == "Input / Cached / Output")
    #expect(usage.breakdownValue == "100 / 947.0k / 50")

    let noCache = TokenUsage(tokensUsed: 150, inputTokens: 100, outputTokens: 50)
    #expect(noCache.breakdownTitle == "Input / Output")
    #expect(noCache.breakdownValue == "100 / 50")

    let outputOnly = TokenUsage(tokensUsed: 50, outputTokens: 50)
    #expect(outputOnly.breakdownTitle == "Output")
    #expect(outputOnly.breakdownValue == "50")
}

// MARK: - Context size

@Test("context size uses the last reported usage plus an estimate for later messages")
func contextSizeReportedPlusTail() {
    let usage = TokenUsage(tokensUsed: 1_150, inputTokens: 100, outputTokens: 50, cachedInputTokens: 1_000)
    let messages = [
        ChatMessage(role: .user, content: "hello"),  // 5
        ChatMessage(role: .assistant, content: "world!", tokenUsage: usage),  // 6
        ChatMessage(role: .user, content: String(repeating: "a", count: 40)),  // 40
    ]
    let ctx = ChatContextSize(messages: messages)
    #expect(ctx?.tokens == 1_160)  // 1150 reported + 40 / 4 estimated
    #expect(ctx?.isEstimated == true)
    #expect(ctx?.displayValue == "~1 160")
}

@Test("context size is exact when the last message carries reported usage")
func contextSizeReportedOnly() {
    let usage = TokenUsage(tokensUsed: 150, inputTokens: 100, outputTokens: 50)
    let messages = [
        ChatMessage(role: .user, content: "hi"),
        ChatMessage(role: .assistant, content: "yo", tokenUsage: usage),
    ]
    let ctx = ChatContextSize(messages: messages)
    #expect(ctx?.tokens == 150)
    #expect(ctx?.isEstimated == false)
    #expect(ctx?.displayValue == "150")
}

@Test("context size is fully estimated without usage and nil for empty chats")
func contextSizeEstimatedAndEmpty() {
    let ctx = ChatContextSize(messages: [ChatMessage(role: .user, content: String(repeating: "x", count: 10))])
    #expect(ctx?.tokens == 3)
    #expect(ctx?.isEstimated == true)
    #expect(ChatContextSize(messages: []) == nil)
}
