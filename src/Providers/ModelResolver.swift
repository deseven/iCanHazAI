// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum ModelResolution: Equatable, Sendable {
    case ok(ResolvedModel, CatalogModel)
    /// Unparsable, provider unknown or not configured, or the model is not in a loaded list.
    case invalid
    /// Can't tell right now (offline OpenRouter lookup, catalog not loaded yet).
    case unavailable
}

/// Turns a stored `provider:model-id` string into a `ResolvedModel` the
/// transport can use. Recomputed per request because keys and the catalog
/// change over time.
struct ModelResolver: Sendable {
    let registry: ProviderRegistry
    let catalog: ModelCatalog
    /// Per-provider base URL replacements. Empty in production; tests and mock
    /// servers set it.
    var endpointOverrides: [Provider: String] = [:]

    func resolve(_ modelString: String?) async -> ModelResolution {
        guard let modelString, let id = ModelID(parsing: modelString) else { return .invalid }
        guard await registry.isConfigured(id.provider), let apiKey = await registry.apiKey(for: id.provider) else {
            return .invalid
        }
        let model: CatalogModel
        if let cached = await catalog.model(id) {
            model = cached
        } else if id.provider == .openrouter {
            switch await catalog.ensureModel(id) {
            case .found(let found): model = found
            case .missing: return .invalid
            case .unavailable: return .unavailable
            }
        } else {
            // An empty list means the first refresh hasn't completed and the
            // cache was empty: the model may well exist.
            return await catalog.hasModels(for: id.provider) ? .invalid : .unavailable
        }
        let custom = await registry.customProvider(for: id.provider)
        let resolved = ResolvedModel(
            provider: id.provider, customType: custom?.type, modelID: id.name, apiKey: apiKey,
            baseUrl: endpointOverrides[id.provider] ?? custom?.endpoint, capabilities: model.capabilities)
        return .ok(resolved, model)
    }
}
