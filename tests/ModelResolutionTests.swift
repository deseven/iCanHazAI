import Foundation
import Testing

@testable import iCanHazAI

private struct Resolution {
    let resolver: ModelResolver
    let catalog: ModelCatalog
    let fetcher: StubFetcher
}

private func makeResolution(
    providers: [Provider], overrides: [Provider: String] = [:], lookupTimeout: TimeInterval = 5,
    handler: @escaping StubFetcher.Handler = { _ in .status(500) }
) async throws -> Resolution {
    let secrets = InMemorySecretStore()
    for provider in providers {
        _ = try secrets.addKey(provider: provider, name: "Default", secret: "fake-\(provider)")
    }
    let registry = ProviderRegistry(store: secrets)
    try await registry.load()
    let fetcher = StubFetcher(handler)
    let catalog = ModelCatalog(
        registry: registry, store: ModelCatalogStore(), fetcher: fetcher,
        metadata: StubMetadataSource(result: .failure(TestFailure())),
        baseUrls: [
            .deepseek: "https://deepseek.test", .openrouter: "https://openrouter.test/api/v1",
        ], lookupTimeout: lookupTimeout)
    let resolver = ModelResolver(registry: registry, catalog: catalog, endpointOverrides: overrides)
    return Resolution(resolver: resolver, catalog: catalog, fetcher: fetcher)
}

private func isOK(_ resolution: ModelResolution) -> (ResolvedModel, CatalogModel)? {
    if case .ok(let resolved, let model) = resolution { return (resolved, model) }
    return nil
}

extension AllAppTests {
    @Suite("Model resolution")
    struct ModelResolutionTests {

        @Test("a missing, unparsable or unknown-provider model is invalid")
        func unparsable() async throws {
            let r = try await makeResolution(providers: [.deepseek])
            #expect(await r.resolver.resolve(nil) == .invalid)
            #expect(await r.resolver.resolve("") == .invalid)
            #expect(await r.resolver.resolve("deepseek") == .invalid)
            #expect(await r.resolver.resolve("deepseek:") == .invalid)
            #expect(await r.resolver.resolve("mistral:large") == .invalid)
        }

        @Test("a provider without a key is invalid, even when its model is cached")
        func providerNotConfigured() async throws {
            let r = try await makeResolution(providers: [.deepseek]) { _ in
                .json(ProviderFixtures.deepseekModels(["a"]))
            }
            _ = await r.catalog.refreshAll()
            #expect(await r.resolver.resolve("openai:gpt-5") == .invalid)
            #expect(await r.resolver.resolve("deepseek:a") != .invalid)
        }

        @Test("a cached model resolves with the key, the wire's provider and its capabilities")
        func cachedHit() async throws {
            let r = try await makeResolution(providers: [.deepseek]) { _ in
                .json(ProviderFixtures.deepseekModels(["a"]))
            }
            _ = await r.catalog.refreshAll()
            let (resolved, model) = try #require(isOK(await r.resolver.resolve("deepseek:a")))
            #expect(resolved.provider == .deepseek)
            #expect(resolved.modelID == "a")
            #expect(resolved.apiKey == "fake-deepseek")
            #expect(resolved.baseUrl == nil)
            #expect(resolved.wire == .openai)
            #expect(resolved.capabilities == model.capabilities)
            #expect(resolved.requestParameters == nil)
            #expect(resolved.headers == nil)
        }

        @Test("endpoint overrides become the resolved base URL")
        func endpointOverride() async throws {
            let r = try await makeResolution(providers: [.deepseek], overrides: [.deepseek: "http://127.0.0.1:9"]) {
                _ in .json(ProviderFixtures.deepseekModels(["a"]))
            }
            _ = await r.catalog.refreshAll()
            let (resolved, _) = try #require(isOK(await r.resolver.resolve("deepseek:a")))
            #expect(resolved.baseUrl == "http://127.0.0.1:9")
        }

        @Test("OpenRouter ids keep their colons and are looked up when not cached")
        func openRouterLookupHit() async throws {
            let r = try await makeResolution(providers: [.openrouter]) { _ in
                .json(ProviderFixtures.openRouterLookup)
            }
            let (resolved, model) = try #require(isOK(await r.resolver.resolve("openrouter:foo/bar")))
            #expect(resolved.modelID == "foo/bar")
            #expect(model.capabilities.imageInput)
            #expect(await r.catalog.model(ModelID(provider: .openrouter, name: "foo/bar")) != nil)
        }

        @Test("an OpenRouter model the server doesn't know is invalid")
        func openRouterGone() async throws {
            let r = try await makeResolution(providers: [.openrouter]) { _ in
                .json(ProviderFixtures.openRouterLookup)
            }
            #expect(await r.resolver.resolve("openrouter:foo/gone") == .invalid)
        }

        @Test("an OpenRouter lookup that fails or times out is unavailable, not invalid")
        func openRouterOffline() async throws {
            let down = try await makeResolution(providers: [.openrouter]) { _ in .status(503) }
            #expect(await down.resolver.resolve("openrouter:foo/bar") == .unavailable)

            let slow = try await makeResolution(providers: [.openrouter], lookupTimeout: 0.1) { _ in
                try await Task.sleep(for: .seconds(10))
                return .json(ProviderFixtures.openRouterLookup)
            }
            #expect(await slow.resolver.resolve("openrouter:foo/bar") == .unavailable)
        }

        @Test("a miss in a loaded list is invalid; with a cold cache it is unavailable")
        func otherProviderMiss() async throws {
            let r = try await makeResolution(providers: [.deepseek]) { _ in
                .json(ProviderFixtures.deepseekModels(["a"]))
            }
            #expect(await r.resolver.resolve("deepseek:a") == .unavailable)
            _ = await r.catalog.refreshAll()
            #expect(await r.resolver.resolve("deepseek:gone") == .invalid)
            #expect(await r.resolver.resolve("deepseek:a") != .unavailable)
        }
    }
}
