// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The HTTP seam for everything that talks to a provider's model endpoints.
/// Tests inject a stub; production uses `URLSessionFetcher`.
protocol HTTPFetching: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse)
}

/// Catalog traffic is independent of chat traffic, so it has its own session.
/// No retries: a failed refresh just keeps the cache and tries again later.
struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        return (data, http)
    }
}

enum ProviderError: Error, LocalizedError {
    case invalidKey
    case network(Error)
    case badResponse
    case http(status: Int, message: String?)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "The provider rejected this key"
        case .network(let error):
            return error.localizedDescription
        case .badResponse:
            return "The provider returned an unexpected response"
        case .http(let status, let message):
            if let message, !message.isEmpty { return "HTTP \(status): \(message)" }
            return "HTTP \(status)"
        case .notConfigured:
            return "The provider has no API key"
        }
    }
}

/// Shared request plumbing for the adapters.
enum ProviderHTTP {
    /// Fetches and maps every failure to a `ProviderError`: 401/403 become
    /// `.invalidKey`, other non-2xx statuses `.http`, transport errors `.network`.
    static func get(_ url: URL, headers: [String: String], fetcher: HTTPFetching) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await fetcher.get(url, headers: headers)
        } catch let error as ProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError.network(error)
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw ProviderError.invalidKey
        default: throw ProviderError.http(status: response.statusCode, message: errorMessage(in: data))
        }
    }

    static func getJSON(_ url: URL, headers: [String: String], fetcher: HTTPFetching) async throws -> [String: Any] {
        let data = try await get(url, headers: headers, fetcher: fetcher)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse
        }
        return object
    }

    static func endpoint(_ baseUrl: String, _ path: String, query: [URLQueryItem] = []) throws -> URL {
        let trimmed = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        guard var components = URLComponents(string: trimmed + path) else { throw ProviderError.badResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ProviderError.badResponse }
        return url
    }

    private static func errorMessage(in data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["error"] as? String { return message }
            if let message = object["message"] as? String { return message }
        }
        let text = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

enum ReasoningLevels {
    static let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// Orders known levels low to high; unknown ones keep their relative order at the end.
    static func sorted(_ levels: [String]) -> [String] {
        var seen = Set<String>()
        let unique = levels.filter { seen.insert($0).inserted }
        let known = order.filter(unique.contains)
        return known + unique.filter { !order.contains($0) }
    }
}
