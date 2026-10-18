import Foundation
import Testing

@testable import iCanHazAI

// Anthropic request body defaults: automatic prompt caching and `max_tokens`.
extension AllAppTests {
    @Suite("Anthropic request body")
    struct AnthropicRequestTests {

        private func body(
            maxOutputTokens: Int? = nil, requestParameters: [String: LLMJSONValue]? = nil, stream: Bool = true
        ) -> [String: Any] {
            var capabilities = ModelCapabilities.safeDefaults
            capabilities.maxOutputTokens = maxOutputTokens
            let model = ResolvedModel(
                provider: .anthropic, modelID: "m", apiKey: "k", capabilities: capabilities,
                requestParameters: requestParameters)
            return AnthropicProvider().buildRequestBody(
                model: model, messages: [ChatMessage(role: .user, content: "hi")], chatFilename: "",
                tools: nil, stream: stream)
        }

        // MARK: - cache_control

        @Test("Every body carries automatic caching, streaming or not", arguments: [true, false])
        func cacheControlPresent(stream: Bool) {
            let cache = body(stream: stream)["cache_control"] as? [String: Any]
            #expect(cache?["type"] as? String == "ephemeral")
            #expect(cache?.count == 1)
        }

        @Test("cache_control from requestParameters replaces the default")
        func cacheControlOverride() {
            let override = LLMJSONValue.object(["type": .string("ephemeral"), "ttl": .string("1h")])
            let cache = body(requestParameters: ["cache_control": override])["cache_control"] as? [String: Any]
            #expect(cache?["ttl"] as? String == "1h")
        }

        // MARK: - max_tokens

        @Test("A model limit below the cap is used as is")
        func maxTokensBelowCap() {
            #expect(body(maxOutputTokens: 8192)["max_tokens"] as? Int == 8192)
        }

        @Test("A model limit above the cap is capped")
        func maxTokensAboveCap() {
            #expect(body(maxOutputTokens: 128_000)["max_tokens"] as? Int == AnthropicProvider.maxTokensCap)
            #expect(AnthropicProvider.maxTokensCap == 32_000)
        }

        @Test("An unknown limit falls back to 4096")
        func maxTokensUnknown() {
            #expect(body(maxOutputTokens: nil)["max_tokens"] as? Int == 4096)
        }

        @Test("max_tokens from requestParameters wins")
        func maxTokensOverride() {
            let params: [String: LLMJSONValue] = ["max_tokens": .number(100)]
            let value = body(maxOutputTokens: 8192, requestParameters: params)["max_tokens"] as? Double
            #expect(value == 100)
        }
    }
}
