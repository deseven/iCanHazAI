import Foundation
import TOML
import Testing

@testable import iCanHazAI

// Backend of the Web Search setup wizard: the token check, the config
// transitions on setup, and the token display mask.
extension AllAppTests {
    @Suite("Web search setup")
    struct WebSearchSetupTests {

        // MARK: - Token check

        @Test("each provider's check is a read-only GET with the token in its own auth header")
        func probes() throws {
            let exa = try #require(WebSearchTokenValidator.probe(provider: .exa, token: "k"))
            #expect(exa.url.absoluteString == "https://api.exa.ai/monitors")
            #expect(exa.headers == ["x-api-key": "k"])

            let linkup = try #require(WebSearchTokenValidator.probe(provider: .linkup, token: "k"))
            #expect(linkup.url.absoluteString == "https://api.linkup.so/v1/credits/balance")
            #expect(linkup.headers == ["Authorization": "Bearer k"])

            let tavily = try #require(WebSearchTokenValidator.probe(provider: .tavily, token: "k"))
            #expect(tavily.url.absoluteString == "https://api.tavily.com/usage")
            #expect(tavily.headers == ["Authorization": "Bearer k"])

            #expect(WebSearchTokenValidator.probe(provider: .none, token: "k") == nil)
        }

        @Test("a 2xx response accepts the token and sends exactly one request")
        func accepted() async throws {
            for provider in WebSearchProviderKind.selectable {
                let fetcher = StubFetcher { _ in .json("{}") }
                try await WebSearchTokenValidator.validate(provider: provider, token: "tok", fetcher: fetcher)
                #expect(fetcher.requests.count == 1)
            }
        }

        @Test("the request carries the probe's URL and headers")
        func requestShape() async throws {
            let fetcher = StubFetcher { _ in .json("{}") }
            try await WebSearchTokenValidator.validate(provider: .exa, token: "tok", fetcher: fetcher)
            #expect(fetcher.requests.first?.url.absoluteString == "https://api.exa.ai/monitors")
            #expect(fetcher.requests.first?.headers["x-api-key"] == "tok")
        }

        @Test("401 and 403 mean the token was rejected")
        func rejected() async {
            for status in [401, 403] {
                let fetcher = StubFetcher { _ in .status(status) }
                await #expect {
                    try await WebSearchTokenValidator.validate(provider: .tavily, token: "bad", fetcher: fetcher)
                } throws: { error in
                    if case ProviderError.invalidKey = error { return true }
                    return false
                }
            }
        }

        @Test("other failures keep their status and message, and are not mistaken for a bad token")
        func otherFailures() async {
            let fetcher = StubFetcher { _ in .json(#"{"error":"overloaded"}"#, status: 503) }
            await #expect {
                try await WebSearchTokenValidator.validate(provider: .linkup, token: "t", fetcher: fetcher)
            } throws: { error in
                if case ProviderError.http(let status, let message) = error {
                    return status == 503 && message == "overloaded"
                }
                return false
            }
        }

        @Test("no provider cannot be checked")
        func noProvider() async {
            let fetcher = StubFetcher { _ in .json("{}") }
            await #expect {
                try await WebSearchTokenValidator.validate(provider: .none, token: "t", fetcher: fetcher)
            } throws: { error in
                if case ProviderError.notConfigured = error { return true }
                return false
            }
            #expect(fetcher.requests.isEmpty)
        }

        // MARK: - Config transitions

        private func configured(
            _ provider: String, linkup: Bool? = nil, tavily: Bool? = nil
        ) -> WebSearchConfig {
            WebSearchConfig(
                provider: provider, token: "t", linkupRenderJS: linkup, tavilyAdvancedExtraction: tavily)
        }

        @Test("setting up selects the provider and keeps only that provider's options")
        func settingUp() {
            let all = configured("none", linkup: true, tavily: true)

            let exa = all.settingUp(.exa)
            #expect(exa.provider == "exa")
            #expect(exa.linkupRenderJS == nil)
            #expect(exa.tavilyAdvancedExtraction == nil)

            let linkup = all.settingUp(.linkup)
            #expect(linkup.provider == "linkup")
            #expect(linkup.linkupRenderJS == true)
            #expect(linkup.tavilyAdvancedExtraction == nil)

            let tavily = all.settingUp(.tavily)
            #expect(tavily.provider == "tavily")
            #expect(tavily.linkupRenderJS == nil)
            #expect(tavily.tavilyAdvancedExtraction == true)
        }

        @Test("a fresh WebSearchConfig, what Disconnect leaves behind, is unconfigured and writes nothing")
        func resetState() throws {
            let reset = WebSearchConfig()
            #expect(reset.provider == nil)
            #expect(reset.token == nil)
            #expect(reset.linkupRenderJS == nil)
            #expect(reset.tavilyAdvancedExtraction == nil)
            #expect(reset.resolvedProvider == .none)
            #expect(!reset.isConfigured)

            var config = AppConfig()
            config.webSearch = configured("linkup", linkup: true).settingUp(.linkup)
            config.webSearch = WebSearchConfig()
            let encoder = TOMLEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let toml = String(data: try encoder.encode(config), encoding: .utf8) ?? ""
            #expect(!toml.contains("provider ="))
            #expect(!toml.contains("linkup_render_js"))
            #expect(!toml.contains("tavily_advanced_extraction"))
            #expect(!toml.contains("token"))

            let decoded = try ConfigValidation.decodeAppConfig(Data(toml.utf8))
            #expect(decoded.webSearch == WebSearchConfig())
        }

        // MARK: - Token mask

        @Test("a long token shows its first and last 4 characters")
        func mask() {
            #expect(WebSearchConfig.maskedToken("abcd1234efgh5678") == "abcd\u{2026}5678")
            #expect(WebSearchConfig.maskedToken("  tvly-dev-0123456789abcdefWXYZ \n") == "tvly\u{2026}WXYZ")
        }

        @Test("a short token is never partly revealed")
        func shortMask() {
            let bullets = String(repeating: "\u{2022}", count: 8)
            #expect(WebSearchConfig.maskedToken("") == bullets)
            #expect(WebSearchConfig.maskedToken("short") == bullets)
            #expect(WebSearchConfig.maskedToken("123456789012345") == bullets)
            #expect(WebSearchConfig.maskedToken("1234567890123456") == "1234\u{2026}3456")
        }
    }
}
