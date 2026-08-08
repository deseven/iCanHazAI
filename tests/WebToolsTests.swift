import Foundation
import Testing
import TOML
@testable import iCanHazAI

// Tests for the built-in web tool group: provider request building, unified
// response parsing/formatting, the [web_search] config section, and the
// [web] role group.
extension AllAppTests {
    @Suite("Web tools")
    struct WebToolsTests {

        // MARK: - Helpers

        private func config(_ provider: String, token: String = "tok", linkupRenderJS: Bool? = nil, tavilyAdvancedExtraction: Bool? = nil) -> WebSearchConfig {
            WebSearchConfig(provider: provider, token: token, linkupRenderJS: linkupRenderJS, tavilyAdvancedExtraction: tavilyAdvancedExtraction)
        }

        private func body(of request: URLRequest) throws -> [String: Any] {
            let data = try #require(request.httpBody)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        // MARK: - Search request building

        @Test("Exa search request uses x-api-key, numResults, ISO datetimes and text contents")
        func exaSearchRequest() throws {
            let req = try BuiltinToolsWeb.searchRequest(
                config: config("exa"),
                params: .init(query: "q", numResults: 5, dateStart: "2026-01-01", dateEnd: "2026-02-02")
            )
            #expect(req.url?.absoluteString == "https://api.exa.ai/search")
            #expect(req.value(forHTTPHeaderField: "x-api-key") == "tok")
            #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(req.value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent)
            let body = try body(of: req)
            #expect(body["query"] as? String == "q")
            #expect(body["numResults"] as? Int == 5)
            #expect(body["startPublishedDate"] as? String == "2026-01-01T00:00:00.000Z")
            #expect(body["endPublishedDate"] as? String == "2026-02-02T23:59:59.999Z")
            #expect(body["contents"] != nil)
        }

        @Test("Linkup search request uses Bearer auth, fast depth and searchResults output")
        func linkupSearchRequest() throws {
            let req = try BuiltinToolsWeb.searchRequest(
                config: config("linkup"),
                params: .init(query: "q", numResults: 10, dateStart: "2026-01-01", dateEnd: nil)
            )
            #expect(req.url?.absoluteString == "https://api.linkup.so/v1/search")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            let body = try body(of: req)
            #expect(body["q"] as? String == "q")
            #expect(body["depth"] as? String == "fast")
            #expect(body["outputType"] as? String == "searchResults")
            #expect(body["maxResults"] as? Int == 10)
            #expect(body["fromDate"] as? String == "2026-01-01")
            #expect(body["toDate"] == nil)
        }

        @Test("Tavily search request uses Bearer auth and snake_case date fields")
        func tavilySearchRequest() throws {
            let req = try BuiltinToolsWeb.searchRequest(
                config: config("tavily"),
                params: .init(query: "q", numResults: 20, dateStart: nil, dateEnd: "2026-03-03")
            )
            #expect(req.url?.absoluteString == "https://api.tavily.com/search")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            let body = try body(of: req)
            #expect(body["query"] as? String == "q")
            #expect(body["max_results"] as? Int == 20)
            #expect(body["start_date"] == nil)
            #expect(body["end_date"] as? String == "2026-03-03")
        }

        @Test("Search request throws for the none provider")
        func searchRequestNoneProvider() {
            #expect(throws: BuiltinToolError.self) {
                _ = try BuiltinToolsWeb.searchRequest(
                    config: config("none"),
                    params: .init(query: "q", numResults: 10, dateStart: nil, dateEnd: nil)
                )
            }
        }

        // MARK: - Extract request building

        @Test("Linkup extract request follows linkup_render_js")
        func linkupExtractRequest() throws {
            let off = try body(of: BuiltinToolsWeb.extractRequest(config: config("linkup"), url: "https://example.com"))
            #expect(off["url"] as? String == "https://example.com")
            #expect(off["renderJs"] as? Bool == false)
            let on = try body(of: BuiltinToolsWeb.extractRequest(config: config("linkup", linkupRenderJS: true), url: "https://example.com"))
            #expect(on["renderJs"] as? Bool == true)
        }

        @Test("Tavily extract request follows tavily_advanced_extraction")
        func tavilyExtractRequest() throws {
            let basic = try body(of: BuiltinToolsWeb.extractRequest(config: config("tavily"), url: "https://example.com"))
            #expect(basic["urls"] as? [String] == ["https://example.com"])
            #expect(basic["extract_depth"] as? String == "basic")
            let advanced = try body(of: BuiltinToolsWeb.extractRequest(config: config("tavily", tavilyAdvancedExtraction: true), url: "https://example.com"))
            #expect(advanced["extract_depth"] as? String == "advanced")
        }

        @Test("Exa extract request posts urls with text enabled")
        func exaExtractRequest() throws {
            let req = try BuiltinToolsWeb.extractRequest(config: config("exa"), url: "https://example.com")
            #expect(req.url?.absoluteString == "https://api.exa.ai/contents")
            #expect(req.value(forHTTPHeaderField: "x-api-key") == "tok")
            let body = try body(of: req)
            #expect(body["urls"] as? [String] == ["https://example.com"])
            #expect(body["text"] as? Bool == true)
        }

        // MARK: - Search response parsing and formatting

        @Test("Exa search hits map title/url/publishedDate/author/text")
        func exaSearchParsing() throws {
            let json = """
            {"results": [{"title": "T", "url": "https://a.example", "publishedDate": "2023-11-16T01:36:32.547Z", "author": "Ann", "text": "snippet"}]}
            """
            let hits = try BuiltinToolsWeb.parseSearchHits(provider: .exa, data: Data(json.utf8))
            #expect(hits == [.init(title: "T", url: "https://a.example", published: "2023-11-16", author: "Ann", snippet: "snippet")])
        }

        @Test("Linkup search hits map name/url/content")
        func linkupSearchParsing() throws {
            let json = """
            {"results": [{"type": "text", "name": "T", "url": "https://a.example", "content": "snippet"}]}
            """
            let hits = try BuiltinToolsWeb.parseSearchHits(provider: .linkup, data: Data(json.utf8))
            #expect(hits == [.init(title: "T", url: "https://a.example", published: nil, author: nil, snippet: "snippet")])
        }

        @Test("Tavily search hits map title/url/published_date/content")
        func tavilySearchParsing() throws {
            let json = """
            {"results": [{"title": "T", "url": "https://a.example", "content": "snippet", "score": 0.9, "published_date": "2026-01-01"}]}
            """
            let hits = try BuiltinToolsWeb.parseSearchHits(provider: .tavily, data: Data(json.utf8))
            #expect(hits == [.init(title: "T", url: "https://a.example", published: "2026-01-01", author: nil, snippet: "snippet")])
        }

        @Test("Unified search output is provider-agnostic")
        func unifiedSearchOutput() {
            let out = BuiltinToolsWeb.formatSearchOutput(query: "q", hits: [
                .init(title: "T", url: "https://a.example", published: "2026-01-01", author: "Ann", snippet: "snippet"),
                .init(title: "U", url: "https://b.example", published: nil, author: nil, snippet: nil),
            ])
            #expect(out.hasPrefix("query: q\nresults: 2\n"))
            #expect(out.contains("[1] T\nURL: https://a.example\nPublished: 2026-01-01\nAuthor: Ann\nsnippet"))
            #expect(out.contains("[2] U\nURL: https://b.example\n"))
        }

        // MARK: - Extract response parsing

        @Test("Exa extract maps the first result and surfaces failed statuses")
        func exaExtractParsing() throws {
            let ok = """
            {"results": [{"title": "T", "url": "https://a.example", "publishedDate": "2023-11-16T00:00:00Z", "author": "Ann", "text": "body"}], "statuses": [{"id": "x", "status": "success"}]}
            """
            let page = try BuiltinToolsWeb.parseExtractedPage(provider: .exa, data: Data(ok.utf8), url: "https://a.example")
            #expect(page == .init(url: "https://a.example", title: "T", published: "2023-11-16", author: "Ann", content: "body"))

            let failed = """
            {"results": [], "statuses": [{"id": "x", "status": "error", "error": {"httpStatusCode": 404}}]}
            """
            #expect(throws: BuiltinToolError.self) {
                _ = try BuiltinToolsWeb.parseExtractedPage(provider: .exa, data: Data(failed.utf8), url: "https://a.example")
            }
        }

        @Test("Linkup extract maps markdown")
        func linkupExtractParsing() throws {
            let page = try BuiltinToolsWeb.parseExtractedPage(provider: .linkup, data: Data(#"{"markdown": "body"}"#.utf8), url: "https://a.example")
            #expect(page.content == "body")
            #expect(page.title == nil)
        }

        @Test("Tavily extract maps raw_content and surfaces failed_results errors")
        func tavilyExtractParsing() throws {
            let ok = """
            {"results": [{"url": "https://a.example", "raw_content": "body"}], "failed_results": []}
            """
            let page = try BuiltinToolsWeb.parseExtractedPage(provider: .tavily, data: Data(ok.utf8), url: "https://a.example")
            #expect(page.content == "body")

            let failed = """
            {"results": [], "failed_results": [{"url": "https://a.example", "error": "Usage limit reached"}]}
            """
            do {
                _ = try BuiltinToolsWeb.parseExtractedPage(provider: .tavily, data: Data(failed.utf8), url: "https://a.example")
                Issue.record("expected an error")
            } catch let error as BuiltinToolError {
                #expect(error.description.contains("Usage limit reached"))
            }
        }

        @Test("Unified extract output carries the metadata header")
        func unifiedExtractOutput() {
            let out = BuiltinToolsWeb.formatExtractOutput(page: .init(
                url: "https://a.example", title: "T", published: "2026-01-01", author: nil, content: "body"
            ))
            #expect(out == "URL: https://a.example\nTitle: T\nPublished: 2026-01-01\n\nbody")
        }

        // MARK: - Result summaries

        @Test("web_search result summary reports the hit count")
        func searchResultSummary() {
            let content = BuiltinToolsWeb.formatSearchOutput(query: "q", hits: [
                .init(title: "T", url: "https://a.example", published: nil, author: nil, snippet: nil),
            ])
            let status = ToolSummary.resultStatus(name: "web_search", result: ToolResult(callID: "1", content: content, isError: false))
            #expect(status?.description == "1 result.")
        }

        @Test("web_extract result summary reports the extracted character count")
        func extractResultSummary() {
            let content = BuiltinToolsWeb.formatExtractOutput(page: .init(
                url: "https://a.example", title: nil, published: nil, author: nil, content: "body"
            ))
            let status = ToolSummary.resultStatus(name: "web_extract", result: ToolResult(callID: "1", content: content, isError: false))
            #expect(status?.description == "Extracted 4 characters.")
        }

        // MARK: - Error message extraction

        @Test("Provider error strings are extracted from common shapes")
        func providerErrorMessages() {
            #expect(BuiltinToolsWeb.providerErrorMessage(from: Data(#"{"error": "bad key"}"#.utf8)) == "bad key")
            #expect(BuiltinToolsWeb.providerErrorMessage(from: Data(#"{"message": "nope"}"#.utf8)) == "nope")
            #expect(BuiltinToolsWeb.providerErrorMessage(from: Data(#"{"detail": {"error": "limit"}}"#.utf8)) == "limit")
            #expect(BuiltinToolsWeb.providerErrorMessage(from: Data(#"{"detail": "plain"}"#.utf8)) == "plain")
            #expect(BuiltinToolsWeb.providerErrorMessage(from: Data("not json".utf8)) == "not json")
            #expect(BuiltinToolsWeb.providerErrorMessage(from: Data()) == "no details")
        }

        // MARK: - web_fetch

        @Test("web_fetch rejects non-http(s) URLs before any network access")
        func fetchRejectsBadSchemes() async {
            for url in ["ftp://example.com", "file:///etc/passwd", "not a url"] {
                await #expect(throws: BuiltinToolError.self) {
                    _ = try await BuiltinToolsWeb.fetch(["url": url])
                }
            }
        }

        @Test("web_fetch output format puts the status code on the first line")
        func fetchOutputFormat() {
            #expect(BuiltinToolsWeb.fetchOutput(httpCode: 200, content: "hi") == "http_code: 200\n\nhi")
            #expect(BuiltinToolsWeb.fetchOutput(httpCode: 0, content: "Error: boom") == "http_code: 0\n\nError: boom")
        }

        // MARK: - [web_search] config section

        @Test("AppConfig decodes the web_search section with all keys")
        func decodesWebSearchSection() throws {
            let toml = """
            [web_search]
            provider = "linkup"
            token = "secret"
            linkup_render_js = true
            """
            let config = try ConfigValidation.decodeAppConfig(Data(toml.utf8))
            #expect(config.webSearch.provider == "linkup")
            #expect(config.webSearch.token == "secret")
            #expect(config.webSearch.linkupRenderJS == true)
            #expect(config.webSearch.resolvedProvider == .linkup)
            #expect(config.webSearch.isConfigured)
        }

        @Test("Missing web_search section falls back to defaults and is not configured")
        func defaultsWhenMissing() throws {
            let config = try ConfigValidation.decodeAppConfig(Data("".utf8))
            #expect(config.webSearch.resolvedProvider == .none)
            #expect(!config.webSearch.isConfigured)
            // A token without a provider is not "configured" either.
            #expect(!WebSearchConfig(provider: "none", token: "x", linkupRenderJS: nil, tavilyAdvancedExtraction: nil).isConfigured)
        }

        @Test("An unknown provider string degrades to none instead of failing the decode")
        func unknownProviderDegrades() throws {
            let toml = """
            [web_search]
            provider = "bing"
            token = "secret"
            """
            let config = try ConfigValidation.decodeAppConfig(Data(toml.utf8))
            #expect(config.webSearch.resolvedProvider == .none)
            #expect(!config.webSearch.isConfigured)
        }

        private func encode(_ config: AppConfig) throws -> String {
            let encoder = TOMLEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return String(data: try encoder.encode(config), encoding: .utf8) ?? ""
        }

        @Test("Provider-specific keys are only saved for their provider; token is dropped for none")
        func conditionalEncoding() throws {
            var config = AppConfig()

            config.webSearch = WebSearchConfig(provider: "linkup", token: "t", linkupRenderJS: true, tavilyAdvancedExtraction: true)
            var toml = try encode(config)
            #expect(toml.contains("linkup_render_js = true"))
            #expect(!toml.contains("tavily_advanced_extraction"))

            config.webSearch = WebSearchConfig(provider: "tavily", token: "t", linkupRenderJS: true, tavilyAdvancedExtraction: true)
            toml = try encode(config)
            #expect(!toml.contains("linkup_render_js"))
            #expect(toml.contains("tavily_advanced_extraction = true"))

            config.webSearch = WebSearchConfig(provider: "exa", token: "t", linkupRenderJS: true, tavilyAdvancedExtraction: true)
            toml = try encode(config)
            #expect(toml.contains("token = \"t\""))
            #expect(!toml.contains("linkup_render_js"))
            #expect(!toml.contains("tavily_advanced_extraction"))

            config.webSearch = WebSearchConfig(provider: "none", token: "t", linkupRenderJS: true, tavilyAdvancedExtraction: true)
            toml = try encode(config)
            #expect(toml.contains("provider = \"none\""))
            #expect(!toml.contains("token"))
        }

        // MARK: - [web] role group

        @Test("A [web] table enables the Web group with all its tools")
        func roleWebGroup() throws {
            let toml = """
            prompt = "Assistant"

            [web]
            """
            let config = try ConfigValidation.decodeRole(Data(toml.utf8))
            let role = Role(name: "Assistant", config: config)
            #expect(role.enabledGroups == [BuiltinTools.webGroup])
            #expect(role.groupConfig(BuiltinTools.webGroup) != nil)
            #expect(BuiltinTools.tools(for: BuiltinTools.webGroup).map(\.name) == ["web_search", "web_extract", "web_fetch"])
            // Web is not workdir-related.
            #expect(!role.hasWorkdirCapableMCP)
            #expect(!role.hasDirectoryRelevantTools)
        }

        @Test("directory_isolation on the web group is a validation error")
        func webGroupIsolationRejected() throws {
            let toml = """
            prompt = "Assistant"

            [web]
            directory_isolation = true
            """
            #expect(throws: ConfigValidationError.self) {
                _ = try ConfigValidation.decodeRole(Data(toml.utf8))
            }
        }
    }
}
