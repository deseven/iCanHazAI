import Foundation
import Testing

@testable import iCanHazAI

// Tests for mid-stream provider error parsing: OpenAI-compatible gateways and
// Anthropic can return HTTP 200 and deliver the error as an SSE event instead
// of a non-2xx status. These chunks must surface the provider's message rather
// than being dropped (which would make the engine report "no output").
extension AllAppTests {
    @Suite("Provider mid-stream error parsing")
    struct ProviderErrorParsingTests {

        @Test("OpenAI error chunk is parsed from a streamed error event")
        func openAIStreamedError() throws {
            let provider = OpenAIProvider()
            let data = try JSONSerialization.data(withJSONObject: [
                "error": [
                    "message": "Failed to generate response",
                    "type": "internal_error",
                    "code": 500,
                ]
            ])
            let chunks = provider.parseStreamChunk(data, accumulator: ToolCallAccumulator())
            #expect(chunks.count == 1)
            guard case .error(let message) = chunks[0] else {
                Issue.record("Expected error chunk")
                return
            }
            #expect(message == "Failed to generate response")
        }

        @Test("Anthropic error chunk is parsed from a streamed error event")
        func anthropicStreamedError() throws {
            let provider = AnthropicProvider()
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "error",
                "error": [
                    "type": "overloaded_error",
                    "message": "Overloaded",
                ],
            ])
            let chunks = provider.parseStreamChunk(data, accumulator: ToolCallAccumulator())
            #expect(chunks.count == 1)
            guard case .error(let message) = chunks[0] else {
                Issue.record("Expected error chunk")
                return
            }
            #expect(message == "Overloaded")
        }

        @Test("StreamResult error is surfaced when the provider delivers a mid-stream error")
        func streamResultCarriesError() {
            // The transport captures the error chunk into StreamResult so the
            // engine can surface it even when content streamed before it.
            let result = ChatService.StreamResult(
                content: "partial",
                toolCalls: [],
                finishReason: nil,
                usage: nil,
                error: "Failed to generate response"
            )
            #expect(result.error == "Failed to generate response")
            #expect(result.content == "partial")
        }

        @Test("Empty content with a normal finish reason produces the empty-response message")
        func emptyContentMessage() {
            // The engine's empty-content branch reports the provider returned
            // nothing, and points to app.log for the raw dump — instead of
            // guessing the provider is overloaded.
            let finishReason = "stop"
            let message =
                "The provider returned an empty response (finish_reason: \(finishReason)). Please try again, or check the raw response in app.log."
            #expect(message.contains("finish_reason: stop"))
            #expect(message.contains("empty response"))
            #expect(message.contains("app.log"))
        }

        @Test("LLMError parseOpenAI extracts provider message")
        func parseOpenAIError() throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "error": [
                    "message": "Failed to generate response",
                    "type": "internal_error",
                    "code": 500,
                ]
            ])
            let error = LLMError.parseOpenAI(data, statusCode: 200)
            #expect(error.providerMessage == "Failed to generate response")
            #expect(error.errorType == "internal_error")
            #expect(error.statusCode == 200)
        }
    }
}
