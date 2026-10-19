import Foundation
import Testing

@testable import iCanHazAI

private let baseUrls: [Provider: String] = [
    .openai: "https://openai.test/v1",
    .anthropic: "https://anthropic.test/v1",
    .deepseek: "https://deepseek.test",
    .openrouter: "https://openrouter.test/api/v1",
]

private struct Harness {
    let catalog: ModelCatalog
    let store: ModelCatalogStore
    let registry: ProviderRegistry
    let fetcher: StubFetcher
    let clock: ManualClock

    func requests(to host: String) -> Int { fetcher.count { $0.host == host } }
}

private func makeHarness(
    providers: [Provider], metadata: ModelMetadataSource = StubMetadataSource(result: .failure(TestFailure())),
    store: ModelCatalogStore = ModelCatalogStore(), lookupTimeout: TimeInterval = 5,
    handler: @escaping StubFetcher.Handler
) async throws -> Harness {
    let secrets = InMemorySecretStore()
    for provider in providers { _ = try secrets.addKey(provider: provider, name: "Default", secret: "fake-key") }
    let registry = ProviderRegistry(store: secrets)
    try await registry.load()
    let fetcher = StubFetcher(handler)
    let clock = ManualClock()
    let catalog = ModelCatalog(
        registry: registry, store: store, fetcher: fetcher, metadata: metadata, baseUrls: baseUrls, clock: clock,
        lookupTimeout: lookupTimeout)
    return Harness(catalog: catalog, store: store, registry: registry, fetcher: fetcher, clock: clock)
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func names(_ models: [CatalogModel]) -> [String] { models.map(\.id.description) }

private func orID(_ name: String) -> ModelID { ModelID(provider: .openrouter, name: name) }

extension AllAppTests {
    @Suite("ModelCatalog")
    struct ModelCatalogTests {

        // MARK: - Full-list providers

        @Test("a successful refresh replaces the provider's entries")
        func fullListReplace() async throws {
            let body = Locked(ProviderFixtures.deepseekModels(["a", "b"]))
            let h = try await makeHarness(providers: [.deepseek]) { _ in .json(body.value) }

            let first = await h.catalog.refreshAll()
            #expect(try first.outcomes[.deepseek]?.get() == 2)
            #expect(names(await h.catalog.snapshot()) == ["deepseek:a", "deepseek:b"])

            body.value = ProviderFixtures.deepseekModels(["b", "c"])
            _ = await h.catalog.refreshAll()
            #expect(names(await h.catalog.snapshot()) == ["deepseek:b", "deepseek:c"])
            #expect(await h.catalog.refreshInfo(for: .deepseek)?.modelCount == 2)
        }

        @Test("a failed refresh changes nothing")
        func failureKeepsEverything() async throws {
            let response = Locked(StubResponse.json(ProviderFixtures.deepseekModels(["a", "b"])))
            let h = try await makeHarness(providers: [.deepseek]) { _ in response.value }
            _ = await h.catalog.refreshAll()
            let before = await h.catalog.snapshot()
            let infoBefore = await h.catalog.refreshInfo(for: .deepseek)

            for failing in [StubResponse.status(500), .status(401), .json("garbage")] {
                response.value = failing
                let summary = await h.catalog.refreshAll()
                if case .success = try #require(summary.outcomes[.deepseek]) { Issue.record("expected failure") }
            }
            #expect(await h.catalog.snapshot() == before)
            #expect(await h.catalog.refreshInfo(for: .deepseek) == infoBefore)
        }

        @Test("an empty list from a full-list provider is treated as a failure")
        func emptyListIgnored() async throws {
            let body = Locked(ProviderFixtures.deepseekModels(["a"]))
            let h = try await makeHarness(providers: [.deepseek]) { _ in .json(body.value) }
            _ = await h.catalog.refreshAll()
            body.value = #"{"data":[]}"#
            let summary = await h.catalog.refreshAll()
            if case .success = try #require(summary.outcomes[.deepseek]) { Issue.record("expected failure") }
            #expect(names(await h.catalog.snapshot()) == ["deepseek:a"])
        }

        @Test("only configured providers are refreshed")
        func onlyConfigured() async throws {
            let h = try await makeHarness(providers: [.deepseek]) { _ in
                .json(ProviderFixtures.deepseekModels(["a"]))
            }
            let summary = await h.catalog.refreshAll()
            #expect(Set(summary.outcomes.keys) == [.deepseek])
            #expect(h.requests(to: "openai.test") == 0)
        }

        @Test("single-flight: concurrent refreshes of a provider share one request")
        func singleFlight() async throws {
            let h = try await makeHarness(providers: [.deepseek]) { _ in
                try await Task.sleep(for: .milliseconds(200))
                return .json(ProviderFixtures.deepseekModels(["a"]))
            }
            async let first = h.catalog.refreshAll()
            async let second = h.catalog.refreshAll()
            _ = await (first, second)
            #expect(h.requests(to: "deepseek.test") == 1)
        }

        // MARK: - OpenAI metadata failure

        @Test("an OpenAI refresh survives a LiteLLM failure and keeps cached capabilities")
        func liteLLMFailurePreservesCache() async throws {
            let metadata = FlakyMetadataSource(.success(try parseLiteLLMFixture()))
            let h = try await makeHarness(providers: [.openai], metadata: metadata) { _ in
                .json(ProviderFixtures.openAIModels(["gpt-5", "gpt-brand-new"]))
            }
            _ = await h.catalog.refreshAll()
            let known = try #require(await h.catalog.model(ModelID(provider: .openai, name: "gpt-5")))
            #expect(known.capabilities.contextWindow == 272_000)

            metadata.set(.failure(TestFailure()))
            let summary = await h.catalog.refreshAll()
            #expect(try summary.outcomes[.openai]?.get() == 2)
            let kept = try #require(await h.catalog.model(ModelID(provider: .openai, name: "gpt-5")))
            #expect(kept.capabilities == known.capabilities)
            let added = try #require(await h.catalog.model(ModelID(provider: .openai, name: "gpt-brand-new")))
            #expect(added.capabilities == .safeDefaults)
        }

        @Test("new OpenAI models get safe defaults while LiteLLM is down")
        func liteLLMFailureNewModels() async throws {
            let h = try await makeHarness(providers: [.openai]) { _ in
                .json(ProviderFixtures.openAIModels(["gpt-9"]))
            }
            _ = await h.catalog.refreshAll()
            #expect(await h.catalog.model(ModelID(provider: .openai, name: "gpt-9"))?.capabilities == .safeDefaults)
        }

        // MARK: - OpenRouter eviction

        @Test("OpenRouter sweep: unused dropped, used re-verified, kept on failure, removed when gone")
        func openRouterEviction() async throws {
            let listing = Locked(
                ProviderFixtures.openRouterModels([("a", 1), ("b", 1), ("c", 1), ("d", 1), ("e", 1)]))
            let h = try await makeHarness(providers: [.openrouter]) { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                switch items.first(where: { $0.name == "q" })?.value {
                case nil: return .json(listing.value)
                case "b": return .json(ProviderFixtures.openRouterModels([("b", 999), ("b:batch", 5)]))
                case "c": return .json(ProviderFixtures.openRouterModels([("c:batch", 5)]))
                default: return .status(500)
                }
            }
            _ = await h.catalog.refreshAll()
            #expect(await h.catalog.snapshot().count == 5)
            for name in ["b", "c", "d"] { await h.catalog.markUsed(orID(name)) }

            listing.value = ProviderFixtures.openRouterModels([("a", 1)])
            _ = await h.catalog.refreshAll()

            let remaining = await h.catalog.snapshot()
            #expect(names(remaining) == ["openrouter:a", "openrouter:b", "openrouter:d"])
            #expect(remaining.first { $0.id.name == "b" }?.capabilities.contextWindow == 999)
            #expect(h.store.allModels().filter(\.isUsed).count == 2)
        }

        @Test("OpenRouter refresh reports total_count as the model count")
        func openRouterCount() async throws {
            let h = try await makeHarness(providers: [.openrouter]) { _ in .json(ProviderFixtures.openRouterTop) }
            let summary = await h.catalog.refreshAll()
            #expect(try summary.outcomes[.openrouter]?.get() == 471)
            #expect(await h.catalog.refreshInfo(for: .openrouter)?.modelCount == 471)
        }

        // MARK: - Timers

        @Test("the 24 h timer refreshes again and a manual refresh resets it")
        func timer() async throws {
            let h = try await makeHarness(providers: [.deepseek]) { _ in
                .json(ProviderFixtures.deepseekModels(["a"]))
            }
            _ = await h.catalog.refreshAll()
            #expect(h.requests(to: "deepseek.test") == 1)
            #expect(await waitUntil { h.clock.sleeperCount == 1 })

            h.clock.advance(by: 23 * 3600)
            _ = await h.catalog.refreshAll()
            #expect(h.requests(to: "deepseek.test") == 2)
            #expect(await waitUntil { h.clock.sleeperCount == 1 })

            // 25 h after the start, but only 2 h after the manual refresh.
            h.clock.advance(by: 2 * 3600)
            try await Task.sleep(for: .milliseconds(150))
            #expect(h.requests(to: "deepseek.test") == 2)

            h.clock.advance(by: 22 * 3600)
            #expect(await waitUntil { h.requests(to: "deepseek.test") == 3 })
            #expect(await waitUntil { h.clock.sleeperCount == 1 })
        }

        @Test("providerAdded with a validation result seeds the cache without a request and starts the schedule")
        func providerAddedSeeds() async throws {
            let h = try await makeHarness(providers: [.openrouter]) { _ in .json(ProviderFixtures.openRouterTop) }
            let validation = try await h.catalog.validate(provider: .openrouter, apiKey: "fake-key")
            #expect(validation.modelCount == 471)
            let requestsAfterValidate = h.fetcher.requests.count

            await h.catalog.providerAdded(.openrouter, validation: validation)
            #expect(h.fetcher.requests.count == requestsAfterValidate)
            #expect(await h.catalog.snapshot().count == 3)
            #expect(await h.catalog.refreshInfo(for: .openrouter)?.modelCount == 471)
            #expect(await waitUntil { h.clock.sleeperCount == 1 })

            h.clock.advance(by: 24 * 3600)
            #expect(await waitUntil { h.fetcher.requests.count > requestsAfterValidate })
        }

        @Test("providerAdded without a validation result refreshes")
        func providerAddedRefreshes() async throws {
            let h = try await makeHarness(providers: [.deepseek]) { _ in
                .json(ProviderFixtures.deepseekModels(["a"]))
            }
            await h.catalog.providerAdded(.deepseek, validation: nil)
            #expect(names(await h.catalog.snapshot()) == ["deepseek:a"])
        }

        // MARK: - Startup

        @Test("start serves the cache immediately and refreshes in the background")
        func startLoadsCacheThenRefreshes() async throws {
            let store = ModelCatalogStore()
            let cached = CatalogModel(
                id: ModelID(provider: .deepseek, name: "cached"), displayName: nil, capabilities: .safeDefaults)
            store.upsert([cached], now: Date())
            let gate = Locked(false)
            let h = try await makeHarness(providers: [.deepseek], store: store) { _ in
                while !gate.value { try await Task.sleep(for: .milliseconds(5)) }
                return .json(ProviderFixtures.deepseekModels(["fresh"]))
            }
            await h.catalog.start()
            #expect(names(await h.catalog.snapshot()) == ["deepseek:cached"])

            gate.value = true
            #expect(await waitUntil { await names(h.catalog.snapshot()) == ["deepseek:fresh"] })
        }

        @Test("start drops the cache and refresh state of providers without a key")
        func startPurgesUnconfigured() async throws {
            let store = ModelCatalogStore()
            let stale = CatalogModel(
                id: ModelID(provider: .openrouter, name: "a/b"), displayName: nil, capabilities: .safeDefaults)
            store.upsert([stale], now: Date())
            store.recordSuccess(for: .openrouter, at: Date(), modelCount: 471)
            let h = try await makeHarness(providers: [.deepseek], store: store) { _ in
                .json(ProviderFixtures.deepseekModels(["fresh"]))
            }
            await h.catalog.start()

            #expect(await h.catalog.snapshot().allSatisfy { $0.id.provider != .openrouter })
            #expect(store.allModels().allSatisfy { $0.model.id.provider != .openrouter })
            #expect(store.refreshInfo(for: .openrouter) == nil)
        }

        // MARK: - ensureModel

        @Test("ensureModel returns cached models without a request")
        func ensureCached() async throws {
            let h = try await makeHarness(providers: [.deepseek]) { _ in
                .json(ProviderFixtures.deepseekModels(["a"]))
            }
            _ = await h.catalog.refreshAll()
            let requests = h.fetcher.requests.count
            guard case .found(let model) = await h.catalog.ensureModel(ModelID(provider: .deepseek, name: "a")) else {
                Issue.record("expected found")
                return
            }
            #expect(model.id.name == "a")
            #expect(h.fetcher.requests.count == requests)
        }

        @Test("ensureModel looks OpenRouter models up by exact id and caches them")
        func ensureOpenRouterLookup() async throws {
            let h = try await makeHarness(providers: [.openrouter]) { _ in .json(ProviderFixtures.openRouterLookup) }
            guard case .found(let model) = await h.catalog.ensureModel(orID("foo/bar")) else {
                Issue.record("expected found")
                return
            }
            #expect(model.capabilities.contextWindow == 2000)
            #expect(await h.catalog.model(orID("foo/bar")) != nil)

            let requests = h.fetcher.requests.count
            _ = await h.catalog.ensureModel(orID("foo/bar"))
            #expect(h.fetcher.requests.count == requests)
        }

        @Test("ensureModel reports a confirmed-missing OpenRouter model as missing")
        func ensureOpenRouterMissing() async throws {
            let h = try await makeHarness(providers: [.openrouter]) { _ in .json(ProviderFixtures.openRouterLookup) }
            guard case .missing = await h.catalog.ensureModel(orID("foo/gone")) else {
                Issue.record("expected missing")
                return
            }
        }

        @Test("ensureModel can't look up models of providers without a full list")
        func ensureOtherProviders() async throws {
            let h = try await makeHarness(providers: [.deepseek]) { _ in .status(500) }
            guard case .missing = await h.catalog.ensureModel(ModelID(provider: .deepseek, name: "x")) else {
                Issue.record("expected missing")
                return
            }
        }

        @Test("ensureModel reports a timeout or network failure as unavailable")
        func ensureUnavailable() async throws {
            let slow = try await makeHarness(providers: [.openrouter], lookupTimeout: 0.1) { _ in
                try await Task.sleep(for: .seconds(10))
                return .json(ProviderFixtures.openRouterLookup)
            }
            guard case .unavailable = await slow.catalog.ensureModel(orID("foo/bar")) else {
                Issue.record("expected unavailable after the timeout")
                return
            }

            let broken = try await makeHarness(providers: [.openrouter]) { _ in .status(503) }
            guard case .unavailable = await broken.catalog.ensureModel(orID("foo/bar")) else {
                Issue.record("expected unavailable after an http failure")
                return
            }
        }

        // MARK: - Usage and events

        @Test("markUsed is persisted in the store")
        func markUsed() async throws {
            let h = try await makeHarness(providers: [.openrouter]) { _ in .json(ProviderFixtures.openRouterTop) }
            _ = await h.catalog.refreshAll()
            await h.catalog.markUsed(orID("plain/model"))
            #expect(h.store.allModels().filter(\.isUsed).map(\.model.id.name) == ["plain/model"])
        }

        @Test("refreshes emit started, finished and changed events")
        func events() async throws {
            let h = try await makeHarness(providers: [.deepseek]) { _ in
                .json(ProviderFixtures.deepseekModels(["a"]))
            }
            var iterator = await h.catalog.events.makeAsyncIterator()
            _ = await h.catalog.refreshAll()

            guard case .refreshStarted(.deepseek)? = await iterator.next() else {
                Issue.record("expected refreshStarted")
                return
            }
            guard case .modelsChanged? = await iterator.next() else {
                Issue.record("expected modelsChanged")
                return
            }
            guard case .refreshFinished(.deepseek, .success(1))? = await iterator.next() else {
                Issue.record("expected refreshFinished")
                return
            }
        }

        @Test("snapshot is grouped by provider and sorted by name")
        func snapshotOrder() async throws {
            let h = try await makeHarness(providers: [.deepseek, .openrouter]) { url in
                url.host == "deepseek.test"
                    ? .json(ProviderFixtures.deepseekModels(["zeta", "alpha"])) : .json(ProviderFixtures.openRouterTop)
            }
            _ = await h.catalog.refreshAll()
            #expect(
                names(await h.catalog.snapshot()) == [
                    "deepseek:alpha", "deepseek:zeta", "openrouter:anthropic/claude-x", "openrouter:foo/bar:free",
                    "openrouter:plain/model",
                ])
        }
    }
}
