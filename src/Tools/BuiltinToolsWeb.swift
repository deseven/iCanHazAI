// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Built-in `web` tool group: `web_search` / `web_extract` (backed by the
/// provider selected in `[web_search]`, one of Exa/Linkup/Tavily) and
/// `web_fetch` (a raw, curl-like download that needs no provider).
///
/// The provider APIs are deliberately different (endpoints, auth headers,
/// field names, date formats), so each request is built per provider while
/// the tool interface and the returned text format stay identical. Request
/// builders and response formatters are pure functions so tests can exercise
/// them without network access.
enum BuiltinToolsWeb {

    static let searchToolName = "web_search"
    static let extractToolName = "web_extract"
    static let fetchToolName = "web_fetch"

    /// Tools that require a configured provider. They're advertised even
    /// without one (a `[SYSTEM NOTICE]` in the system prompt explains the
    /// situation) but fail at call time. `web_fetch` always works.
    static let providerToolNames: Set<String> = [searchToolName, extractToolName]

    /// The notice appended to the system prompt when the role can call
    /// provider-backed tools but no provider is configured; nil otherwise.
    /// `webGroupToolsFilter` is the role's `tools` allowlist for the web
    /// group (empty = all tools), nil when the group isn't enabled.
    static func providerMissingNotice(webGroupToolsFilter: [String]?, isConfigured: Bool) -> String? {
        guard let filter = webGroupToolsFilter, !isConfigured else { return nil }
        let allowed = { (name: String) in filter.isEmpty || filter.contains(name) }
        let providerTools = [searchToolName, extractToolName].filter(allowed)
        guard !providerTools.isEmpty else { return nil }
        let list = providerTools.map { "`\($0)`" }.joined(separator: " and ")
        let plural = providerTools.count > 1
        var notice = """
            [SYSTEM NOTICE]
            The user hasn't set up a web access provider yet. The \(list) tool\(plural ? "s" : "") \
            \(plural ? "are" : "is") available to you, but calling \(plural ? "them" : "it") will fail. \
            If you need \(plural ? "them" : "it") to complete your task, nudge the user to set up \
            the provider in the app's Preferences > Web Search, or to ask the Configurator role for help.
            """
        if allowed(fetchToolName) {
            notice += "\nThe `web_fetch` tool works without a provider."
        }
        return notice
    }

    static let toolDefs: [BuiltinToolDef] = [
        BuiltinToolDef(name: searchToolName,
            description: "Search the web. Returns a numbered list of results with title, URL and a text snippet; publication date and author are included when available.",
            schema: #"{"type":"object","properties":{"query":{"type":"string","description":"The search query."},"num_results":{"type":"integer","description":"Number of results to return (1-50). Default 10."},"date_start":{"type":"string","description":"Only include results published on or after this date (YYYY-MM-DD)."},"date_end":{"type":"string","description":"Only include results published on or before this date (YYYY-MM-DD)."}},"required":["query"]}"#),
        BuiltinToolDef(name: extractToolName,
            description: "Extract the readable content of a web page. Prefer this over web_fetch for reading articles and documentation pages.",
            schema: #"{"type":"object","properties":{"url":{"type":"string","description":"The URL of the page to extract."}},"required":["url"]}"#),
        BuiltinToolDef(name: fetchToolName,
            description: "Download the raw contents of a URL directly (like curl), without any extraction or rendering. Returns the final HTTP status code and the body as text. Fails on binary content or bodies larger than 256KB.",
            schema: #"{"type":"object","properties":{"url":{"type":"string","description":"The http(s) URL to download."}},"required":["url"]}"#),
    ]

    /// Bodies larger than this are rejected by `web_fetch`.
    static let maxFetchBytes = 256 * 1024

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    // MARK: - Tool entry points

    static func search(_ args: [String: Any]) async throws -> ToolOutput {
        let config = try await configured()
        let params = SearchParams(
            query: try BuiltinTools.requireString(args, "query"),
            numResults: min(max(BuiltinTools.optionalInt(args, "num_results") ?? 10, 1), 50),
            dateStart: try validatedDate(BuiltinTools.optionalString(args, "date_start"), key: "date_start"),
            dateEnd: try validatedDate(BuiltinTools.optionalString(args, "date_end"), key: "date_end")
        )
        let data = try await post(searchRequest(config: config, params: params))
        return ToolOutput(content: formatSearchOutput(query: params.query, hits: try parseSearchHits(provider: config.resolvedProvider, data: data)), isError: false)
    }

    static func extract(_ args: [String: Any]) async throws -> ToolOutput {
        let config = try await configured()
        let url = try BuiltinTools.requireString(args, "url")
        let data = try await post(extractRequest(config: config, url: url))
        let page = try parseExtractedPage(provider: config.resolvedProvider, data: data, url: url)
        return ToolOutput(content: formatExtractOutput(page: page), isError: false)
    }

    /// Raw download. Redirects are followed by URLSession; the reported code
    /// is the final one. The body is streamed with a hard cap so an oversized
    /// response is rejected without being fully downloaded.
    static func fetch(_ args: [String: Any]) async throws -> ToolOutput {
        let urlString = try BuiltinTools.requireString(args, "url")
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else {
            throw BuiltinToolError("invalid argument 'url': expected a valid http(s) URL")
        }
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if response.expectedContentLength > Int64(maxFetchBytes) {
                return ToolOutput(content: fetchOutput(httpCode: httpCode, content: "Error: content is larger than 256KB"), isError: true)
            }
            var data = Data()
            data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), maxFetchBytes))
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxFetchBytes {
                    return ToolOutput(content: fetchOutput(httpCode: httpCode, content: "Error: content is larger than 256KB"), isError: true)
                }
            }
            guard BuiltinTools.isText(data), let text = String(data: data, encoding: .utf8) else {
                return ToolOutput(content: fetchOutput(httpCode: httpCode, content: "Error: content is binary"), isError: true)
            }
            return ToolOutput(content: fetchOutput(httpCode: httpCode, content: text), isError: httpCode >= 400)
        } catch {
            return ToolOutput(content: fetchOutput(httpCode: 0, content: "Error: \(error.localizedDescription)"), isError: true)
        }
    }

    /// `web_fetch` output shape: the final status code on the first line
    /// (0 when the request never got a response), then the content.
    static func fetchOutput(httpCode: Int, content: String) -> String {
        "http_code: \(httpCode)\n\n\(content)"
    }

    // MARK: - Search: unified params and per-provider requests

    struct SearchParams: Equatable {
        let query: String
        let numResults: Int
        /// YYYY-MM-DD or nil.
        let dateStart: String?
        let dateEnd: String?
    }

    static func searchRequest(config: WebSearchConfig, params: SearchParams) throws -> URLRequest {
        let token = config.token ?? ""
        switch config.resolvedProvider {
        case .exa:
            var body: [String: Any] = [
                "query": params.query,
                "numResults": params.numResults,
                "contents": ["text": ["maxCharacters": 1000]],
            ]
            if let start = params.dateStart { body["startPublishedDate"] = start + "T00:00:00.000Z" }
            if let end = params.dateEnd { body["endPublishedDate"] = end + "T23:59:59.999Z" }
            return try jsonPostRequest(url: "https://api.exa.ai/search", token: token, bearer: false, body: body)
        case .linkup:
            var body: [String: Any] = [
                "q": params.query,
                "depth": "fast",
                "outputType": "searchResults",
                "maxResults": params.numResults,
            ]
            if let start = params.dateStart { body["fromDate"] = start }
            if let end = params.dateEnd { body["toDate"] = end }
            return try jsonPostRequest(url: "https://api.linkup.so/v1/search", token: token, bearer: true, body: body)
        case .tavily:
            var body: [String: Any] = [
                "query": params.query,
                "max_results": params.numResults,
            ]
            if let start = params.dateStart { body["start_date"] = start }
            if let end = params.dateEnd { body["end_date"] = end }
            return try jsonPostRequest(url: "https://api.tavily.com/search", token: token, bearer: true, body: body)
        case .none:
            throw notConfiguredError
        }
    }

    // MARK: - Extract: per-provider requests

    static func extractRequest(config: WebSearchConfig, url: String) throws -> URLRequest {
        let token = config.token ?? ""
        switch config.resolvedProvider {
        case .exa:
            return try jsonPostRequest(url: "https://api.exa.ai/contents", token: token, bearer: false, body: [
                "urls": [url],
                "text": true,
            ])
        case .linkup:
            return try jsonPostRequest(url: "https://api.linkup.so/v1/fetch", token: token, bearer: true, body: [
                "url": url,
                "renderJs": config.linkupRenderJS ?? false,
            ])
        case .tavily:
            return try jsonPostRequest(url: "https://api.tavily.com/extract", token: token, bearer: true, body: [
                "urls": [url],
                "extract_depth": (config.tavilyAdvancedExtraction ?? false) ? "advanced" : "basic",
            ])
        case .none:
            throw notConfiguredError
        }
    }

    // MARK: - Unified result model and formatting

    struct SearchHit: Equatable {
        var title: String
        var url: String
        /// YYYY-MM-DD or nil.
        var published: String?
        var author: String?
        var snippet: String?
    }

    struct ExtractedPage: Equatable {
        var url: String
        var title: String?
        var published: String?
        var author: String?
        var content: String
    }

    static func formatSearchOutput(query: String, hits: [SearchHit]) -> String {
        var out = "query: \(query)\nresults: \(hits.count)\n"
        for (index, hit) in hits.enumerated() {
            out += "\n[\(index + 1)] \(hit.title.isEmpty ? hit.url : hit.title)\n"
            out += "URL: \(hit.url)\n"
            if let published = hit.published, !published.isEmpty { out += "Published: \(published)\n" }
            if let author = hit.author, !author.isEmpty { out += "Author: \(author)\n" }
            if let snippet = hit.snippet, !snippet.isEmpty { out += snippet + "\n" }
        }
        return out
    }

    static func formatExtractOutput(page: ExtractedPage) -> String {
        var out = "URL: \(page.url)\n"
        if let title = page.title, !title.isEmpty { out += "Title: \(title)\n" }
        if let published = page.published, !published.isEmpty { out += "Published: \(published)\n" }
        if let author = page.author, !author.isEmpty { out += "Author: \(author)\n" }
        return out + "\n" + page.content
    }

    // MARK: - Response parsing (per provider)

    static func parseSearchHits(provider: WebSearchProviderKind, data: Data) throws -> [SearchHit] {
        let obj = try jsonObject(data)
        let results = obj["results"] as? [[String: Any]] ?? []
        switch provider {
        case .exa:
            return results.map { r in
                SearchHit(
                    title: r["title"] as? String ?? "",
                    url: r["url"] as? String ?? "",
                    published: dateOnly(r["publishedDate"] as? String),
                    author: r["author"] as? String,
                    snippet: r["text"] as? String
                )
            }
        case .linkup:
            return results.map { r in
                SearchHit(
                    title: r["name"] as? String ?? "",
                    url: r["url"] as? String ?? "",
                    published: nil,
                    author: nil,
                    snippet: r["content"] as? String
                )
            }
        case .tavily:
            return results.map { r in
                SearchHit(
                    title: r["title"] as? String ?? "",
                    url: r["url"] as? String ?? "",
                    published: dateOnly(r["published_date"] as? String),
                    author: nil,
                    snippet: r["content"] as? String
                )
            }
        case .none:
            throw notConfiguredError
        }
    }

    static func parseExtractedPage(provider: WebSearchProviderKind, data: Data, url: String) throws -> ExtractedPage {
        let obj = try jsonObject(data)
        switch provider {
        case .exa:
            // A failed crawl shows up in `statuses` with no matching result.
            if let statuses = obj["statuses"] as? [[String: Any]],
               let first = statuses.first, (first["status"] as? String) != "success" {
                let reason = (first["error"] as? [String: Any])?["httpStatusCode"].map { "HTTP \($0)" } ?? (first["status"] as? String ?? "unknown error")
                throw BuiltinToolError("extraction failed: \(reason)")
            }
            guard let r = (obj["results"] as? [[String: Any]])?.first else {
                throw BuiltinToolError("provider returned no content for this URL")
            }
            return ExtractedPage(
                url: r["url"] as? String ?? url,
                title: r["title"] as? String,
                published: dateOnly(r["publishedDate"] as? String),
                author: r["author"] as? String,
                content: r["text"] as? String ?? ""
            )
        case .linkup:
            guard let markdown = obj["markdown"] as? String else {
                throw BuiltinToolError("provider returned no content for this URL")
            }
            return ExtractedPage(url: url, title: nil, published: nil, author: nil, content: markdown)
        case .tavily:
            if let failed = (obj["failed_results"] as? [[String: Any]])?.first,
               let error = failed["error"] as? String {
                throw BuiltinToolError("extraction failed: \(error)")
            }
            guard let r = (obj["results"] as? [[String: Any]])?.first,
                  let content = r["raw_content"] as? String else {
                throw BuiltinToolError("provider returned no content for this URL")
            }
            return ExtractedPage(url: r["url"] as? String ?? url, title: nil, published: nil, author: nil, content: content)
        case .none:
            throw notConfiguredError
        }
    }

    // MARK: - Helpers

    /// Provider tools are advertised even while unconfigured (a system-prompt
    /// notice explains the situation), so a call can legitimately arrive
    /// here; the setting can also flip between gathering tools and executing.
    private static let notConfiguredError = BuiltinToolError(
        "no web search provider configured — ask the user to set one up in Preferences > Web Search")

    private static func configured() async throws -> WebSearchConfig {
        let config = await ConfigManager.shared.getWebSearchConfig()
        guard config.isConfigured else { throw notConfiguredError }
        return config
    }

    /// Dates travel through the unified interface as YYYY-MM-DD; providers
    /// that want full ISO 8601 datetimes get them synthesized by the caller.
    private static func validatedDate(_ value: String?, key: String) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        let digits = value.filter { $0.isNumber }
        guard value.count == 10, digits.count == 8, value[value.index(value.startIndex, offsetBy: 4)] == "-" else {
            throw BuiltinToolError("invalid argument '\(key)': expected YYYY-MM-DD")
        }
        return value
    }

    /// Truncates an ISO 8601 datetime to its date component.
    private static func dateOnly(_ iso: String?) -> String? {
        guard let iso else { return nil }
        return String(iso.prefix(10))
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BuiltinToolError("invalid response from provider (not a JSON object)")
        }
        return obj
    }

    private static func jsonPostRequest(url: String, token: String, bearer: Bool, body: [String: Any]) throws -> URLRequest {
        guard let endpoint = URL(string: url) else {
            throw BuiltinToolError("invalid provider endpoint \"\(url)\"")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if bearer {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(token, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// POSTs and returns the body, surfacing the provider's own error string
    /// on HTTP errors. Network failures become their URLError description.
    private static func post(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BuiltinToolError(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code < 400 else {
            throw BuiltinToolError("HTTP \(code): \(providerErrorMessage(from: data))")
        }
        return data
    }

    /// Best-effort extraction of a human-readable error from a provider's
    /// error body (`error`/`message`/`detail` keys, falling back to the raw
    /// body text, capped).
    static func providerErrorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = obj["error"] as? String { return s }
            if let s = obj["message"] as? String { return s }
            if let detail = obj["detail"] {
                if let s = detail as? String { return s }
                if let d = detail as? [String: Any] {
                    if let s = d["error"] as? String { return s }
                    if let s = d["message"] as? String { return s }
                }
            }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return "no details" }
        return String(text.prefix(1000))
    }
}
