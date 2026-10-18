import Foundation
import Testing

@testable import iCanHazAI

// Per-wire request headers (defaults preserved, override wins, empty-string
// removes, auth override) and base URL resolution on `ResolvedModel`.
extension AllAppTests {
    @Suite("Request headers")
    struct RequestHeadersTests {

        private func model(
            _ provider: Provider, headers: [String: String]? = nil, baseUrl: String? = nil
        ) -> ResolvedModel {
            ResolvedModel(
                provider: provider, modelID: "m", apiKey: "sk-x", baseUrl: baseUrl, headers: headers)
        }

        // MARK: - Anthropic wire

        @Test("Anthropic defaults are preserved without custom headers")
        func anthropicDefaultsPreserved() {
            let headers = AnthropicProvider().buildHeaders(model: model(.anthropic))
            #expect(headers["Content-Type"] == "application/json")
            #expect(headers["Accept"] == "text/event-stream")
            #expect(headers["anthropic-version"] == "2023-06-01")
            #expect(headers["User-Agent"] == AppInfo.userAgent)
            #expect(headers["x-api-key"] == "sk-x")
        }

        @Test("Anthropic custom header overrides User-Agent")
        func anthropicOverridesUserAgent() {
            let headers = AnthropicProvider().buildHeaders(
                model: model(.anthropic, headers: ["User-Agent": "claude-cli/2.0.30 (external, cli)"]))
            #expect(headers["User-Agent"] == "claude-cli/2.0.30 (external, cli)")
            #expect(headers["anthropic-version"] == "2023-06-01")
            #expect(headers["x-api-key"] == "sk-x")
        }

        @Test("Anthropic custom header overrides auth (x-api-key)")
        func anthropicOverridesAuth() {
            let headers = AnthropicProvider().buildHeaders(
                model: model(.anthropic, headers: ["x-api-key": "custom-key"]))
            #expect(headers["x-api-key"] == "custom-key")
        }

        @Test("Anthropic empty-string value removes a default header")
        func anthropicEmptyStringRemoves() {
            let headers = AnthropicProvider().buildHeaders(
                model: model(.anthropic, headers: ["User-Agent": ""]))
            #expect(headers["User-Agent"] == nil)
            #expect(headers["x-api-key"] == "sk-x")
        }

        @Test("Anthropic adds a brand-new header")
        func anthropicAddsNewHeader() {
            let headers = AnthropicProvider().buildHeaders(
                model: model(.anthropic, headers: ["X-Custom": "yes"]))
            #expect(headers["X-Custom"] == "yes")
        }

        @Test("Anthropic omits the auth header for an empty key")
        func anthropicEmptyKey() {
            let keyless = ResolvedModel(provider: .anthropic, modelID: "m", apiKey: "")
            #expect(AnthropicProvider().buildHeaders(model: keyless)["x-api-key"] == nil)
        }

        // MARK: - OpenAI wire

        @Test("OpenAI defaults are preserved without custom headers")
        func openaiDefaultsPreserved() {
            let headers = OpenAIProvider().buildHeaders(model: model(.openai))
            #expect(headers["Content-Type"] == "application/json")
            #expect(headers["Accept"] == "text/event-stream")
            #expect(headers["User-Agent"] == AppInfo.userAgent)
            #expect(headers["Authorization"] == "Bearer sk-x")
        }

        @Test("OpenAI custom header overrides User-Agent")
        func openaiOverridesUserAgent() {
            let headers = OpenAIProvider().buildHeaders(
                model: model(.openai, headers: ["User-Agent": "codex_cli_rs/0.1"]))
            #expect(headers["User-Agent"] == "codex_cli_rs/0.1")
            #expect(headers["Authorization"] == "Bearer sk-x")
        }

        @Test("OpenAI custom header overrides auth (Authorization)")
        func openaiOverridesAuth() {
            let headers = OpenAIProvider().buildHeaders(
                model: model(.openai, headers: ["Authorization": "ApiKey custom"]))
            #expect(headers["Authorization"] == "ApiKey custom")
        }

        @Test("OpenAI empty-string value removes a default header")
        func openaiEmptyStringRemoves() {
            let headers = OpenAIProvider().buildHeaders(
                model: model(.openai, headers: ["Authorization": ""]))
            #expect(headers["Authorization"] == nil)
            #expect(headers["User-Agent"] == AppInfo.userAgent)
        }

        // MARK: - Wire and base URL

        @Test("Providers map to their wire")
        func providerWires() {
            #expect(Provider.openai.wire == .openai)
            #expect(Provider.deepseek.wire == .openai)
            #expect(Provider.openrouter.wire == .openai)
            #expect(Provider.anthropic.wire == .anthropic)
        }

        @Test("Strategy is picked by the model's wire")
        func strategyByWire() {
            #expect(LLMTransport.provider(for: model(.deepseek)).wire == .openai)
            #expect(LLMTransport.provider(for: model(.anthropic)).wire == .anthropic)
        }

        @Test("An explicit base URL wins over the provider default")
        func explicitBaseUrlWins() {
            let m = model(.openai, baseUrl: "http://127.0.0.1:9999/v1")
            #expect(LLMTransport.resolveBaseUrl(model: m) == "http://127.0.0.1:9999/v1")
        }

        @Test("An empty base URL falls back to the provider default")
        func emptyBaseUrlFallsBack() {
            #expect(LLMTransport.resolveBaseUrl(model: model(.openai, baseUrl: "")) == Provider.openai.defaultBaseUrl)
        }

        @Test("Each provider resolves to its own base URL")
        func providerDefaultBaseUrls() {
            for provider in Provider.allCases {
                #expect(LLMTransport.resolveBaseUrl(model: model(provider)) == provider.defaultBaseUrl)
            }
            #expect(LLMTransport.resolveBaseUrl(model: model(.deepseek)) == "https://api.deepseek.com")
            #expect(LLMTransport.resolveBaseUrl(model: model(.openrouter)) == "https://openrouter.ai/api/v1")
        }

        @Test("Requests are built against the resolved URL and chat path")
        func requestUrl() throws {
            let msgs = [ChatMessage(role: .user, content: "hi")]
            let deepseek = try LLMTransport.buildRequest(
                model: model(.deepseek), messages: msgs, chatFilename: "", tools: nil, stream: true)
            #expect(deepseek.url?.absoluteString == "https://api.deepseek.com/chat/completions")
            let anthropic = try LLMTransport.buildRequest(
                model: model(.anthropic), messages: msgs, chatFilename: "", tools: nil, stream: true)
            #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        }
    }
}
