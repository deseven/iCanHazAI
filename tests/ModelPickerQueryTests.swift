import Foundation
import Testing

@testable import iCanHazAI

private func model(_ provider: Provider, _ name: String, display: String? = nil) -> CatalogModel {
    CatalogModel(id: ModelID(provider: provider, name: name), displayName: display, capabilities: .safeDefaults)
}

private let sample = [
    model(.openai, "gpt-5"),
    model(.anthropic, "claude-sonnet-5-5", display: "Claude Sonnet 5.5"),
    model(.deepseek, "deepseek-flash"),
    model(.openrouter, "anthropic/claude-sonnet-5.5"),
    model(.openrouter, "meta/llama-4:free"),
]

extension AllAppTests {
    @Suite("Model picker query")
    struct ModelPickerQueryTests {

        @Test("a leading provider prefix scopes the query, case-insensitively")
        func prefixParsing() {
            let q = ModelPickerQuery("OpenRouter:llama")
            #expect(q.provider == .openrouter)
            #expect(q.text == "llama")
            #expect(ModelPickerQuery("anthropic:").text == "")
            #expect(ModelPickerQuery("anthropic:").provider == .anthropic)
        }

        @Test("only the first colon splits; unknown prefixes are plain text")
        func plainText() {
            let q = ModelPickerQuery("openrouter:meta/llama-4:free")
            #expect(q.provider == .openrouter)
            #expect(q.text == "meta/llama-4:free")
            #expect(ModelPickerQuery("mistral:large").provider == nil)
            #expect(ModelPickerQuery("mistral:large").text == "mistral:large")
            #expect(ModelPickerQuery("gpt").provider == nil)
        }

        @Test("a bare prefix lists every cached model of that provider")
        func bareProviderPrefix() {
            let result = ModelPickerQuery("openrouter:").filter(sample)
            #expect(result.map(\.id.provider) == [.openrouter, .openrouter])
        }

        @Test("an empty query keeps everything")
        func emptyQuery() {
            #expect(ModelPickerQuery("").filter(sample) == sample)
            #expect(ModelPickerQuery("  ").filter(sample) == sample)
        }

        @Test("the remainder is searched within the provider only")
        func searchWithinProvider() {
            let result = ModelPickerQuery("openrouter:claude").filter(sample)
            #expect(result.map(\.id.description) == ["openrouter:anthropic/claude-sonnet-5.5"])
            let all = ModelPickerQuery("claude").filter(sample)
            #expect(all.contains { $0.id.provider == .anthropic })
            #expect(all.contains { $0.id.provider == .openrouter })
        }

        @Test("display names are searchable")
        func displayNameMatch() {
            let result = ModelPickerQuery("Sonnet 5.5").filter(sample)
            #expect(result.contains { $0.id.name == "claude-sonnet-5-5" })
        }

        @Test("aliases and dots work like the full name and the colon")
        func aliases() {
            for prefix in ["or.", "OR.", "openrouter.", "or:", "openrouter:"] {
                let q = ModelPickerQuery(prefix + "llama")
                #expect(q.provider == .openrouter, "\(prefix)")
                #expect(q.text == "llama", "\(prefix)")
            }
            #expect(ModelPickerQuery("oa.gpt").provider == .openai)
            #expect(ModelPickerQuery("an.claude").provider == .anthropic)
            #expect(ModelPickerQuery("ds.flash").provider == .deepseek)
            #expect(ModelPickerQuery("deepseek.flash").provider == .deepseek)
        }

        @Test("the prefix only pre-filters and never takes part in the text search")
        func prefixIsNotSearched() {
            let result = ModelPickerQuery("an.claude").filter(sample)
            #expect(result.map(\.id.description) == ["anthropic:claude-sonnet-5-5"])
            #expect(ModelPickerQuery("or.").filter(sample).count == 2)
        }

        @Test("search is a case-insensitive substring match; every word must match")
        func substringWords() {
            #expect(ModelPickerQuery("SONNET").filter(sample).count == 2)
            #expect(ModelPickerQuery("sonnet 5.5").filter(sample).count == 2)
            #expect(ModelPickerQuery("sonnet llama").filter(sample).isEmpty)
        }

        @Test("an in-order subsequence matches only when no substring does")
        func subsequenceFallback() {
            #expect(ModelPickerQuery("gpt5").filter(sample).map(\.id.name) == ["gpt-5"])
            #expect(ModelPickerQuery("gpt5").filter(sample + [model(.openai, "gpt5")]).map(\.id.name) == ["gpt5"])
        }

        @Test("a dot inside a model name is not a provider prefix")
        func dotsInNames() {
            for text in ["gpt-5.2", "claude-3.5", "x.llama", "orx.llama"] {
                let q = ModelPickerQuery(text)
                #expect(q.provider == nil, "\(text)")
                #expect(q.text == text, "\(text)")
            }
        }

        @Test("the pinned default model goes first when it survives the filtering")
        func pinnedDefault() {
            let pinned = ModelID(provider: .deepseek, name: "deepseek-flash")
            #expect(ModelPickerQuery("").filter(sample, pinning: pinned).first?.id == pinned)
            #expect(ModelPickerQuery("").filter(sample, pinning: pinned).count == sample.count)
            // The remaining models keep their order.
            #expect(
                ModelPickerQuery("").filter(sample, pinning: pinned).dropFirst().map(\.id.name)
                    == ["gpt-5", "claude-sonnet-5-5", "anthropic/claude-sonnet-5.5", "meta/llama-4:free"])
            // Ranking is overridden: the pin stays on top of a better match.
            let sonnetPin = ModelID(provider: .openrouter, name: "anthropic/claude-sonnet-5.5")
            let ranked = ModelPickerQuery("sonnet").filter(sample, pinning: sonnetPin)
            #expect(ranked.first?.id == sonnetPin)
            #expect(ranked.count == 2)
        }

        @Test("a pinned model that is filtered out, unknown or nil changes nothing")
        func pinnedDefaultFilteredOut() {
            let pinned = ModelID(provider: .deepseek, name: "deepseek-flash")
            #expect(ModelPickerQuery("an.").filter(sample, pinning: pinned) == ModelPickerQuery("an.").filter(sample))
            #expect(ModelPickerQuery("llama").filter(sample, pinning: pinned).count == 1)
            let unknown = ModelID(provider: .openai, name: "gone")
            #expect(ModelPickerQuery("").filter(sample, pinning: unknown) == sample)
            #expect(ModelPickerQuery("").filter(sample, pinning: nil) == sample)
        }

        @Test("OpenRouter `~vendor/model-latest` aliases are found with and without the prefix")
        func latestAliases() {
            let models = sample + [model(.openrouter, "~deepseek/deepseek-v4-flash-latest")]
            for text in [
                "~deepseek/deepseek-v4-flash-latest", "or.~deepseek/deepseek-v4-flash-latest", "or.flash-latest",
            ] {
                let result = ModelPickerQuery(text).filter(models)
                #expect(result.first?.id.name == "~deepseek/deepseek-v4-flash-latest", "\(text)")
            }
        }
    }
}
