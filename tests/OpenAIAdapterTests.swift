import Foundation
import Testing

@testable import iCanHazAI

private let referenceNow = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15

private func makeAdapter() -> OpenAIAdapter {
    var adapter = OpenAIAdapter(baseUrl: "https://openai.test/v1")
    adapter.now = { referenceNow }
    return adapter
}

private func listing(
    _ ids: [String], shutdown: [String: String] = [:], metadata: ModelMetadataSource? = nil
) async throws -> ProviderListing {
    let source = try metadata ?? StubMetadataSource(result: .success(parseLiteLLMFixture()))
    let fetcher = StubFetcher { _ in .json(ProviderFixtures.openAIModels(ids, shutdown: shutdown)) }
    return try await makeAdapter().fetchListing(apiKey: "fake", fetcher: fetcher, metadata: source)
}

extension AllAppTests {
    @Suite("OpenAIAdapter")
    struct OpenAIAdapterTests {

        @Test("capabilities come from the LiteLLM entry")
        func capabilities() async throws {
            let result = try await listing(["gpt-5", "gpt-4o"])
            let gpt5 = try #require(result.models.first { $0.id.name == "gpt-5" })
            #expect(gpt5.displayName == nil)
            #expect(gpt5.capabilities.imageInput)
            #expect(gpt5.capabilities.contextWindow == 272_000)
            #expect(gpt5.capabilities.maxOutputTokens == 128_000)
            #expect(gpt5.capabilities.reasoning.supported)
            #expect(gpt5.capabilities.reasoning.levels == ["minimal", "low", "medium", "high"])

            let gpt4o = try #require(result.models.first { $0.id.name == "gpt-4o" })
            #expect(gpt4o.capabilities.reasoning == .unsupported)
            #expect(result.capabilitiesUnknown == false)
        }

        @Test("models past their shutdown_date are hidden, future ones kept")
        func shutdownDate() async throws {
            let result = try await listing(
                ["gpt-old", "gpt-future", "gpt-5"], shutdown: ["gpt-old": "2020-01-01", "gpt-future": "2999-01-01"])
            #expect(result.models.map(\.id.name) == ["gpt-5", "gpt-future"])
        }

        @Test("responses-only models are hidden")
        func responsesOnly() async throws {
            let result = try await listing(["gpt-5-codex", "gpt-responses-only-no-endpoints", "gpt-5"])
            #expect(result.models.map(\.id.name) == ["gpt-5"])
        }

        @Test("old chat models without supported_endpoints are kept")
        func noSupportedEndpoints() async throws {
            let result = try await listing(["gpt-4o"])
            #expect(result.models.map(\.id.name) == ["gpt-4o"])
        }

        @Test("audio, search, fine-tuned and non-chat modes are hidden")
        func hiddenByName() async throws {
            let result = try await listing(
                ["gpt-4o-audio-preview", "gpt-4o-search-preview", "ft:gpt-4o:acme", "babbage-002", "gpt-4o"])
            #expect(result.models.map(\.id.name) == ["gpt-4o"])
        }

        @Test("name rules apply to models LiteLLM doesn't know")
        func hiddenByNameWhenUnknown() async throws {
            let result = try await listing(
                ["gpt-realtime-9", "gpt-image-9", "gpt-9-tts", "gpt-9-transcribe", "gpt-9-instruct", "gpt-9"])
            #expect(result.models.map(\.id.name) == ["gpt-9"])
        }

        @Test("unknown gpt, o and chatgpt models are shown with safe defaults")
        func unknownChatModels() async throws {
            let result = try await listing(["gpt-9", "o9-mini", "chatgpt-next"])
            #expect(result.models.map(\.id.name) == ["chatgpt-next", "gpt-9", "o9-mini"])
            #expect(result.models.allSatisfy { $0.capabilities == .safeDefaults })
        }

        @Test("unknown models that don't look like chat models are hidden")
        func unknownNonChat() async throws {
            let result = try await listing(["whisper-1", "dall-e-3", "davinci-002", "omni-moderation-latest"])
            #expect(result.models.isEmpty)
        }

        @Test("dated snapshots are hidden when the alias exists")
        func snapshotWithAlias() async throws {
            let result = try await listing(["gpt-5", "gpt-5-2025-08-07", "gpt-4o", "gpt-4o-2024-05-13"])
            #expect(result.models.map(\.id.name) == ["gpt-4o", "gpt-5"])
        }

        @Test("dated snapshots stay when the alias is absent")
        func snapshotWithoutAlias() async throws {
            let result = try await listing(["gpt-5-2025-08-07", "gpt-lonely-2024-01-01"])
            #expect(result.models.map(\.id.name) == ["gpt-5-2025-08-07", "gpt-lonely-2024-01-01"])
        }

        @Test("the chatgpt/ prefixed entry is a fallback lookup")
        func chatgptFallback() async throws {
            let result = try await listing(["chatgpt-4o-latest"])
            let model = try #require(result.models.first)
            #expect(model.capabilities.contextWindow == 128_000)
            #expect(model.capabilities.imageInput)
        }

        @Test("reasoning levels are synthesized from flags, reasoning_effort_levels wins when present")
        func reasoningLevels() async throws {
            let result = try await listing(["gpt-5.2", "o4-custom"])
            #expect(
                result.models.first { $0.id.name == "gpt-5.2" }?.capabilities.reasoning.levels
                    == ["none", "low", "medium", "high", "xhigh"])
            #expect(
                result.models.first { $0.id.name == "o4-custom" }?.capabilities.reasoning.levels == ["low", "high"])
        }

        @Test("a LiteLLM failure falls back to heuristics and flags unknown capabilities")
        func metadataFailure() async throws {
            let result = try await listing(
                ["gpt-5", "gpt-5-codex", "gpt-4o-audio-preview", "whisper-1"],
                metadata: StubMetadataSource(result: .failure(TestFailure())))
            #expect(result.capabilitiesUnknown)
            #expect(result.models.map(\.id.name) == ["gpt-5", "gpt-5-codex"])
            #expect(result.models.allSatisfy { $0.capabilities == .safeDefaults })
        }

        @Test("validate counts the filtered models")
        func validateCount() async throws {
            let fetcher = StubFetcher { _ in
                .json(ProviderFixtures.openAIModels(["gpt-5", "gpt-4o", "whisper-1", "gpt-5-codex"]))
            }
            let source = try StubMetadataSource(result: .success(parseLiteLLMFixture()))
            let result = try await makeAdapter().validate(apiKey: "fake", fetcher: fetcher, metadata: source)
            #expect(result.modelCount == 2)
            #expect(result.seed.count == 2)
            #expect(fetcher.requests.first?.headers["Authorization"] == "Bearer fake")
        }

        @Test("an invalid key fails even when metadata is fine")
        func invalidKey() async throws {
            let fetcher = StubFetcher { _ in .status(401) }
            let source = try StubMetadataSource(result: .success(parseLiteLLMFixture()))
            do {
                _ = try await makeAdapter().fetchListing(apiKey: "bad", fetcher: fetcher, metadata: source)
                Issue.record("expected an error")
            } catch ProviderError.invalidKey {
            }
        }
    }
}
