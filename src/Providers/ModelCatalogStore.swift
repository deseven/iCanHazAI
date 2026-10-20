// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SwiftData

@Model
final class ModelCacheEntry {
    /// `provider:name`.
    @Attribute(.unique) var key: String
    var provider: String
    var name: String
    var displayName: String?
    var imageInput: Bool
    var contextWindow: Int
    var maxOutputTokens: Int?
    var reasoningSupported: Bool
    var reasoningLevels: [String]
    var reasoningDefault: String?
    var reasoningCanDisable: Bool = false
    var reasoningBudgetOnly: Bool = false
    /// The user picked the model, or a chat using it was loaded. Protects the
    /// entry from OpenRouter's sweep of models that dropped out of the top list.
    var isUsed: Bool
    var fetchedAt: Date

    init(model: CatalogModel, isUsed: Bool, fetchedAt: Date) {
        key = model.id.description
        provider = model.id.provider.rawValue
        name = model.id.name
        displayName = model.displayName
        imageInput = model.capabilities.imageInput
        contextWindow = model.capabilities.contextWindow
        maxOutputTokens = model.capabilities.maxOutputTokens
        reasoningSupported = model.capabilities.reasoning.supported
        reasoningLevels = model.capabilities.reasoning.levels
        reasoningDefault = model.capabilities.reasoning.defaultLevel
        reasoningCanDisable = model.capabilities.reasoning.canDisable
        reasoningBudgetOnly = model.capabilities.reasoning.budgetOnly
        self.isUsed = isUsed
        self.fetchedAt = fetchedAt
    }

    func apply(_ model: CatalogModel, fetchedAt: Date) {
        displayName = model.displayName
        imageInput = model.capabilities.imageInput
        contextWindow = model.capabilities.contextWindow
        maxOutputTokens = model.capabilities.maxOutputTokens
        reasoningSupported = model.capabilities.reasoning.supported
        reasoningLevels = model.capabilities.reasoning.levels
        reasoningDefault = model.capabilities.reasoning.defaultLevel
        reasoningCanDisable = model.capabilities.reasoning.canDisable
        reasoningBudgetOnly = model.capabilities.reasoning.budgetOnly
        self.fetchedAt = fetchedAt
    }

    var catalogModel: CatalogModel? {
        guard let provider = Provider(rawValue: provider) else { return nil }
        return CatalogModel(
            id: ModelID(provider: provider, name: name),
            displayName: displayName,
            capabilities: ModelCapabilities(
                imageInput: imageInput,
                contextWindow: contextWindow,
                maxOutputTokens: maxOutputTokens,
                reasoning: ReasoningCapability(
                    supported: reasoningSupported, levels: reasoningLevels, defaultLevel: reasoningDefault,
                    canDisable: reasoningCanDisable, budgetOnly: reasoningBudgetOnly)))
    }
}

@Model
final class ProviderRefreshState {
    @Attribute(.unique) var provider: String
    var lastSuccess: Date?
    /// The count shown in the wizard and the startup loader.
    var modelCount: Int?

    init(provider: String, lastSuccess: Date?, modelCount: Int?) {
        self.provider = provider
        self.lastSuccess = lastSuccess
        self.modelCount = modelCount
    }
}

struct StoredModel: Sendable, Equatable {
    var model: CatalogModel
    var isUsed: Bool
}

struct ProviderRefreshInfo: Sendable, Equatable {
    var lastSuccess: Date?
    var modelCount: Int?
}

/// Persistent model cache at `.cache/models.cache`, separate from the chat
/// metadata cache so a schema change in one never rebuilds the other. All
/// SwiftData access is serialized on a private queue, like `ChatStore`.
final class ModelCatalogStore: @unchecked Sendable {
    private let container: ModelContainer
    private let queue = DispatchQueue(label: "iCanHazAI.modelCatalogStore")
    private var _context: ModelContext?

    private var context: ModelContext {
        if let ctx = _context { return ctx }
        let ctx = ModelContext(container)
        _context = ctx
        return ctx
    }

    init?(env: EnvironmentManager) {
        let cacheDir = env.rootURL.appendingPathComponent(".cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let storeURL = cacheDir.appendingPathComponent("models.cache")
        let config = ModelConfiguration(url: storeURL)
        let schema = Schema([ModelCacheEntry.self, ProviderRefreshState.self])
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // The cache is disposable: on an incompatible schema drop it and start empty.
            debugLog("ModelCatalogStore", "⚠️ cache incompatible with model (\(error)); recreating")
            let base = storeURL.lastPathComponent
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("\(base)\(suffix)"))
            }
            do {
                container = try ModelContainer(for: schema, configurations: config)
            } catch {
                debugLog("ModelCatalogStore", "failed to create ModelContainer after cache reset: \(error)")
                return nil
            }
        }
    }

    /// A store that is not persisted, used when the on-disk one can't be opened.
    init() {
        let schema = Schema([ModelCacheEntry.self, ProviderRefreshState.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }

    // MARK: - Models

    func allModels() -> [StoredModel] {
        queue.sync {
            entries().compactMap { entry in
                entry.catalogModel.map { StoredModel(model: $0, isUsed: entry.isUsed) }
            }
        }
    }

    /// Every provider that has cached models or a refresh state.
    func cachedProviders() -> Set<Provider> {
        queue.sync {
            let states = (try? context.fetch(FetchDescriptor<ProviderRefreshState>())) ?? []
            let names = entries().map(\.provider) + states.map(\.provider)
            return Set(names.compactMap { Provider(rawValue: $0) })
        }
    }

    /// Inserts or updates entries. Existing entries keep their `isUsed` flag.
    func upsert(_ models: [CatalogModel], now: Date) {
        queue.sync {
            var existing = Dictionary(uniqueKeysWithValues: entries().map { ($0.key, $0) })
            for model in models {
                let key = model.id.description
                if let entry = existing[key] {
                    entry.apply(model, fetchedAt: now)
                } else {
                    let entry = ModelCacheEntry(model: model, isUsed: false, fetchedAt: now)
                    context.insert(entry)
                    existing[key] = entry
                }
            }
            save()
        }
    }

    /// Upserts `models` and deletes every other entry of the provider.
    func replace(provider: Provider, with models: [CatalogModel], now: Date) {
        upsert(models, now: now)
        let keep = Set(models.map(\.id.description))
        queue.sync {
            for entry in entries(provider: provider) where !keep.contains(entry.key) { context.delete(entry) }
            save()
        }
    }

    /// Deletes the provider's entries that nobody used and that aren't in `keeping`.
    func evictUnused(provider: Provider, keeping: Set<ModelID>) {
        let keep = Set(keeping.map(\.description))
        queue.sync {
            for entry in entries(provider: provider) where !entry.isUsed && !keep.contains(entry.key) {
                context.delete(entry)
            }
            save()
        }
    }

    func delete(_ ids: [ModelID]) {
        let keys = Set(ids.map(\.description))
        queue.sync {
            for entry in entries() where keys.contains(entry.key) { context.delete(entry) }
            save()
        }
    }

    /// Drops the provider's models and its refresh state.
    func deleteAll(provider: Provider) {
        queue.sync {
            for entry in entries(provider: provider) { context.delete(entry) }
            if let state = state(provider) { context.delete(state) }
            save()
        }
    }

    /// Returns false when the model isn't cached.
    @discardableResult
    func markUsed(_ id: ModelID) -> Bool {
        queue.sync {
            guard let entry = entries().first(where: { $0.key == id.description }) else { return false }
            if !entry.isUsed {
                entry.isUsed = true
                save()
            }
            return true
        }
    }

    // MARK: - Refresh state

    func refreshInfo(for provider: Provider) -> ProviderRefreshInfo? {
        queue.sync {
            state(provider).map { ProviderRefreshInfo(lastSuccess: $0.lastSuccess, modelCount: $0.modelCount) }
        }
    }

    func recordSuccess(for provider: Provider, at date: Date, modelCount: Int) {
        queue.sync {
            if let existing = state(provider) {
                existing.lastSuccess = date
                existing.modelCount = modelCount
            } else {
                context.insert(
                    ProviderRefreshState(provider: provider.rawValue, lastSuccess: date, modelCount: modelCount))
            }
            save()
        }
    }

    // MARK: - Queue-confined helpers

    private func entries(provider: Provider? = nil) -> [ModelCacheEntry] {
        let all = (try? context.fetch(FetchDescriptor<ModelCacheEntry>())) ?? []
        guard let provider else { return all }
        return all.filter { $0.provider == provider.rawValue }
    }

    private func state(_ provider: Provider) -> ProviderRefreshState? {
        let all = (try? context.fetch(FetchDescriptor<ProviderRefreshState>())) ?? []
        return all.first { $0.provider == provider.rawValue }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            debugLog("ModelCatalogStore", "⚠️ context.save FAILED: \(error)")
        }
    }
}
