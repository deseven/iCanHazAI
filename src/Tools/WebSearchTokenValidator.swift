// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Checks a web search token before the setup wizard stores it. Each provider
/// gets a read-only call that spends no credits:
///
/// - Exa: `GET /monitors` (an empty list on a fresh account). Exa's Websets
///   team endpoint is not used: it rejected a valid free-tier key.
/// - Linkup: `GET /v1/credits/balance`
/// - Tavily: `GET /usage`
///
/// Any 2xx means the token works; 401/403 surface as `ProviderError.invalidKey`.
enum WebSearchTokenValidator {

    struct Probe: Equatable {
        let url: URL
        let headers: [String: String]
    }

    /// The request that checks `token`; nil for `.none`.
    static func probe(provider: WebSearchProviderKind, token: String) -> Probe? {
        switch provider {
        case .exa:
            return Probe(url: URL(string: "https://api.exa.ai/monitors")!, headers: ["x-api-key": token])
        case .linkup:
            return Probe(
                url: URL(string: "https://api.linkup.so/v1/credits/balance")!,
                headers: ["Authorization": "Bearer \(token)"])
        case .tavily:
            return Probe(
                url: URL(string: "https://api.tavily.com/usage")!,
                headers: ["Authorization": "Bearer \(token)"])
        case .none:
            return nil
        }
    }

    static func validate(
        provider: WebSearchProviderKind, token: String, fetcher: HTTPFetching = URLSessionFetcher()
    ) async throws {
        guard let probe = probe(provider: provider, token: token) else { throw ProviderError.notConfigured }
        _ = try await ProviderHTTP.get(probe.url, headers: probe.headers, fetcher: fetcher)
    }
}
