// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The request/response dialect a provider speaks. Keys the strategies in
/// [`LLMProvider`](src/LLM/LLMProvider.swift).
enum LLMWire: String, Sendable {
    case openai
    case anthropic
}

extension Provider {
    var wire: LLMWire {
        switch self {
        case .openai, .deepseek, .openrouter: return .openai
        case .anthropic: return .anthropic
        }
    }
}

/// Everything the transport needs to send one request: where to, with which
/// key, which model, and the per-request knobs. Internal value, not a config
/// entity.
struct ResolvedModel: Hashable, Sendable {
    let provider: Provider
    /// The model-name part of the model id; goes into the request's `model` field.
    let modelID: String
    let apiKey: String
    /// nil → `provider.defaultBaseUrl`. Also the seam for pointing a provider
    /// at a mock server.
    let baseUrl: String?
    let capabilities: ModelCapabilities
    /// The effective reasoning setting for this request: `off`, `on`, an effort
    /// level, or nil to leave the provider's own default untouched. See
    /// [`ReasoningSetting`](src/Providers/ModelCapabilities.swift).
    let reasoning: String?
    /// Extra parameters inserted into every request body's root. They win over
    /// the strategy's defaults.
    let requestParameters: [String: LLMJSONValue]?
    /// Custom HTTP headers applied **last** over the strategy's defaults, so
    /// any header can be overridden (including auth and `User-Agent`). An
    /// empty-string value removes the header entirely. May carry secrets.
    let headers: [String: String]?
    /// Abort the request if **no data at all** arrives for this many seconds —
    /// response headers, SSE lines, and keep-alive comments all count. Catches
    /// dead connections: offline network, blackholed connects, dropped
    /// sockets, unresponsive servers. `nil` applies the 30 s default; `≤ 0`
    /// disables this layer.
    let readTimeout: Double?
    /// Abort the request if no **useful output** arrives for this many
    /// seconds. Only content, thinking, tool-call deltas, finish reasons, and
    /// usage refresh it — bare keep-alives do not. Catches providers that keep
    /// the connection alive while producing nothing. `nil` applies the 60 s
    /// default; `≤ 0` disables this layer.
    let progressTimeout: Double?
    /// Hard cap on a single request attempt (connect + headers + entire
    /// stream), regardless of activity. Each retry attempt gets a fresh
    /// budget. `nil` applies the 3600 s default; `≤ 0` disables this layer.
    let transportTimeout: Double?
    /// How many times to retry a failed request before surfacing the error.
    /// `nil` defaults to 1. Retries are only attempted when no output has been
    /// emitted yet, and offline-class failures (no network, DNS failure, HTTP
    /// 4xx) are surfaced without retrying.
    let numRetries: Int?

    init(
        provider: Provider,
        modelID: String,
        apiKey: String,
        baseUrl: String? = nil,
        capabilities: ModelCapabilities = .safeDefaults,
        reasoning: String? = nil,
        requestParameters: [String: LLMJSONValue]? = nil,
        headers: [String: String]? = nil,
        readTimeout: Double? = nil,
        progressTimeout: Double? = nil,
        transportTimeout: Double? = nil,
        numRetries: Int? = nil
    ) {
        self.provider = provider
        self.modelID = modelID
        self.apiKey = apiKey
        self.baseUrl = baseUrl
        self.capabilities = capabilities
        self.reasoning = reasoning
        self.requestParameters = requestParameters
        self.headers = headers
        self.readTimeout = readTimeout
        self.progressTimeout = progressTimeout
        self.transportTimeout = transportTimeout
        self.numRetries = numRetries
    }

    func withReasoning(_ reasoning: String?) -> ResolvedModel {
        ResolvedModel(
            provider: provider, modelID: modelID, apiKey: apiKey, baseUrl: baseUrl, capabilities: capabilities,
            reasoning: reasoning, requestParameters: requestParameters, headers: headers,
            readTimeout: readTimeout, progressTimeout: progressTimeout, transportTimeout: transportTimeout,
            numRetries: numRetries)
    }

    /// `provider:modelID`, used in logs.
    var id: String { "\(provider.rawValue):\(modelID)" }
    var wire: LLMWire { provider.wire }
    var imageInput: Bool { capabilities.imageInput }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
