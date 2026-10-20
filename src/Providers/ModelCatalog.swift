// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum CatalogEvent: Sendable {
    case refreshStarted(Provider)
    case refreshFinished(Provider, Result<Int, ProviderError>)
    case modelsChanged
}

struct RefreshSummary: Sendable {
    var outcomes: [Provider: Result<Int, ProviderError>]
}

enum EnsureModelResult: Sendable {
    case found(CatalogModel)
    /// The provider confirmed the model doesn't exist (or it can't be looked up).
    case missing
    /// The lookup failed or timed out, so we can't tell whether the model exists.
    case unavailable
}

/// Time source for the refresh timers, injectable so tests can fast-forward.
protocol CatalogClock: Sendable {
    func now() -> Date
    func sleep(until deadline: Date) async throws
}

struct SystemCatalogClock: CatalogClock {
    func now() -> Date { Date() }

    func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        if interval > 0 { try await Task.sleep(for: .seconds(interval)) }
    }
}

/// Fetches, normalizes, caches and refreshes the model lists of every
/// configured provider. The registry must be loaded before `start()`.
actor ModelCatalog {
    static let shared = ModelCatalog(
        registry: .shared,
        store: ModelCatalogStore(env: EnvironmentManager.shared) ?? ModelCatalogStore(),
        fetcher: URLSessionFetcher(),
        metadata: LiteLLMMetadataSource(fetcher: URLSessionFetcher()))

    static let refreshInterval: TimeInterval = 24 * 60 * 60
    private static let reverifyConcurrency = 4

    private let registry: ProviderRegistry
    private let store: ModelCatalogStore
    private let fetcher: HTTPFetching
    private let metadata: ModelMetadataSource
    private let baseUrls: [Provider: String]
    private let clock: CatalogClock
    private let lookupTimeout: TimeInterval

    private var models: [ModelID: CatalogModel] = [:]
    private var inFlight: [Provider: Task<Result<Int, ProviderError>, Never>] = [:]
    private var timers: [Provider: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<CatalogEvent>.Continuation] = [:]

    init(
        registry: ProviderRegistry, store: ModelCatalogStore, fetcher: HTTPFetching, metadata: ModelMetadataSource,
        baseUrls: [Provider: String] = [:], clock: CatalogClock = SystemCatalogClock(), lookupTimeout: TimeInterval = 5
    ) {
        self.registry = registry
        self.store = store
        self.fetcher = fetcher
        self.metadata = metadata
        self.baseUrls = baseUrls
        self.clock = clock
        self.lookupTimeout = lookupTimeout
    }

    // MARK: - Public API

    /// Loads the cache into memory, then refreshes in the background. Never
    /// waits for the network. A provider without a usable key (removed, or
    /// undecryptable) loses its cached models, so it can't look usable.
    func start() async {
        let configured = Set(await registry.configuredProviders)
        for provider in Provider.allCases where !configured.contains(provider) {
            store.deleteAll(provider: provider)
        }
        reloadFromStore()
        Task { _ = await self.refreshAll() }
    }

    /// All cached models, grouped by provider and sorted by name.
    func snapshot() -> [CatalogModel] {
        models.values.sorted { lhs, rhs in
            if lhs.id.provider != rhs.id.provider {
                return Provider.allCases.firstIndex(of: lhs.id.provider)!
                    < Provider.allCases.firstIndex(of: rhs.id.provider)!
            }
            return (lhs.displayName ?? lhs.id.name).localizedCaseInsensitiveCompare(rhs.displayName ?? rhs.id.name)
                == .orderedAscending
        }
    }

    func model(_ id: ModelID) -> CatalogModel? { models[id] }

    func hasModels(for provider: Provider) -> Bool {
        models.keys.contains { $0.provider == provider }
    }

    func refreshInfo(for provider: Provider) -> ProviderRefreshInfo? { store.refreshInfo(for: provider) }

    /// The cached model, or for OpenRouter an exact lookup (for a model newer
    /// than the last listing) that is cached on success.
    func ensureModel(_ id: ModelID) async -> EnsureModelResult {
        if let cached = models[id] { return .found(cached) }
        guard id.provider == .openrouter, await registry.isConfigured(.openrouter) else { return .missing }
        let adapter = openRouterAdapter
        let fetcher = self.fetcher
        do {
            let found = try await Self.withTimeout(lookupTimeout) {
                try await adapter.lookup(id.name, fetcher: fetcher)
            }
            guard let found else { return .missing }
            cache([found])
            return .found(found)
        } catch {
            return .unavailable
        }
    }

    func validate(provider: Provider, apiKey: String) async throws -> ValidationResult {
        do {
            return try await adapter(for: provider).validate(apiKey: apiKey, fetcher: fetcher, metadata: metadata)
        } catch {
            throw Self.wrap(error)
        }
    }

    /// Stores what validation already fetched (or refreshes when there is
    /// nothing) and starts the 24 h schedule. The key must already be in the registry.
    func providerAdded(_ provider: Provider, validation: ValidationResult?) async {
        guard let validation else {
            _ = await refresh(provider)
            return
        }
        let listing = ProviderListing(
            models: validation.seed, totalCount: validation.modelCount,
            capabilitiesUnknown: validation.capabilitiesUnknown)
        await apply(listing, to: provider)
        scheduleTimer(provider)
    }

    func refreshAll() async -> RefreshSummary {
        let providers = await registry.configuredProviders
        var outcomes: [Provider: Result<Int, ProviderError>] = [:]
        await withTaskGroup(of: (Provider, Result<Int, ProviderError>).self) { group in
            for provider in providers {
                group.addTask { (provider, await self.refresh(provider)) }
            }
            for await (provider, result) in group { outcomes[provider] = result }
        }
        return RefreshSummary(outcomes: outcomes)
    }

    /// Re-fetches one provider's models after its active key changed, since
    /// another key may expose a different set. A refresh already running was
    /// started with the previous key, so this one waits for it and goes again.
    func refreshAfterKeyChange(_ provider: Provider) async {
        if let running = inFlight[provider] { _ = await running.value }
        _ = await refresh(provider)
    }

    func markUsed(_ id: ModelID) {
        store.markUsed(id)
    }

    var events: AsyncStream<CatalogEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CatalogEvent.self)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    // MARK: - Refresh

    /// Concurrent refreshes of one provider coalesce into a single request.
    private func refresh(_ provider: Provider) async -> Result<Int, ProviderError> {
        if let running = inFlight[provider] { return await running.value }
        let task = Task { () -> Result<Int, ProviderError> in
            let result = await self.performRefresh(provider)
            self.finishRefresh(provider, result)
            return result
        }
        inFlight[provider] = task
        return await task.value
    }

    private func finishRefresh(_ provider: Provider, _ result: Result<Int, ProviderError>) {
        inFlight[provider] = nil
        if case .failure(.notConfigured) = result { return }
        scheduleTimer(provider)
    }

    private func performRefresh(_ provider: Provider) async -> Result<Int, ProviderError> {
        guard let key = await registry.apiKey(for: provider) else { return .failure(.notConfigured) }
        emit(.refreshStarted(provider))
        let result: Result<Int, ProviderError>
        do {
            let listing = try await adapter(for: provider).fetchListing(
                apiKey: key, fetcher: fetcher, metadata: metadata)
            // An empty list is a glitch, not "no models": applying it would wipe the cache.
            if listing.models.isEmpty { throw ProviderError.badResponse }
            await apply(listing, to: provider)
            result = .success(listing.modelCount)
        } catch {
            result = .failure(Self.wrap(error))
        }
        emit(.refreshFinished(provider, result))
        return result
    }

    /// Full-list providers replace their entries. OpenRouter keeps entries the
    /// user picked (or a chat uses) that dropped out of the listing, such as
    /// ones found by `ensureModel`, and re-verifies them individually.
    private func apply(_ listing: ProviderListing, to provider: Provider) async {
        var fetched = listing.models
        if listing.capabilitiesUnknown {
            fetched = fetched.map { model in
                guard let cached = models[model.id] else { return model }
                var kept = model
                kept.capabilities = cached.capabilities
                return kept
            }
        }
        let now = clock.now()
        if provider == .openrouter {
            let listed = Set(fetched.map(\.id))
            store.upsert(fetched, now: now)
            store.evictUnused(provider: provider, keeping: listed)
            let stale = store.allModels()
                .filter { $0.isUsed && $0.model.id.provider == provider && !listed.contains($0.model.id) }
                .map(\.model.id)
            await reverify(stale)
        } else {
            store.replace(provider: provider, with: fetched, now: now)
        }
        store.recordSuccess(for: provider, at: now, modelCount: listing.modelCount)
        reloadFromStore()
        emit(.modelsChanged)
    }

    /// A found model is updated, a confirmed-missing one deleted, and a failed
    /// request keeps the entry as it is.
    private func reverify(_ ids: [ModelID]) async {
        guard !ids.isEmpty else { return }
        enum Outcome: Sendable {
            case found(CatalogModel)
            case missing(ModelID)
            case failed
        }
        let adapter = openRouterAdapter
        let fetcher = self.fetcher
        var found: [CatalogModel] = []
        var missing: [ModelID] = []
        await withTaskGroup(of: Outcome.self) { group in
            var next = 0
            func addNext() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask {
                    do {
                        if let model = try await adapter.lookup(id.name, fetcher: fetcher) { return .found(model) }
                        return .missing(id)
                    } catch {
                        return .failed
                    }
                }
            }
            for _ in 0..<Self.reverifyConcurrency { addNext() }
            for await outcome in group {
                switch outcome {
                case .found(let model): found.append(model)
                case .missing(let id): missing.append(id)
                case .failed: break
                }
                addNext()
            }
        }
        store.upsert(found, now: clock.now())
        store.delete(missing)
    }

    // MARK: - Timers

    private func scheduleTimer(_ provider: Provider) {
        timers[provider]?.cancel()
        let deadline = clock.now().addingTimeInterval(Self.refreshInterval)
        let clock = self.clock
        timers[provider] = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self else { return }
            _ = await self.refresh(provider)
        }
    }

    // MARK: - Helpers

    private func adapter(for provider: Provider) -> ProviderAdapter {
        ProviderAdapters.make(provider, baseUrl: baseUrls[provider])
    }

    private var openRouterAdapter: OpenRouterAdapter {
        OpenRouterAdapter(baseUrl: baseUrls[.openrouter] ?? Provider.openrouter.defaultBaseUrl)
    }

    private func cache(_ found: [CatalogModel]) {
        guard !found.isEmpty else { return }
        store.upsert(found, now: clock.now())
        reloadFromStore()
        emit(.modelsChanged)
    }

    private func reloadFromStore() {
        models = Dictionary(
            store.allModels().map { ($0.model.id, $0.model) }, uniquingKeysWith: { first, _ in first })
    }

    private func emit(_ event: CatalogEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private static func wrap(_ error: Error) -> ProviderError {
        (error as? ProviderError) ?? .network(error)
    }

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ProviderError.network(URLError(.timedOut))
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ProviderError.badResponse }
            return first
        }
    }
}
