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

        @Test("the remainder is fuzzy-matched within the provider only")
        func fuzzyWithinProvider() {
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

        @Test("the prefix only pre-filters and never takes part in the fuzzy match")
        func prefixIsNotFuzzy() {
            let result = ModelPickerQuery("an.claude").filter(sample)
            #expect(result.map(\.id.description) == ["anthropic:claude-sonnet-5-5"])
            #expect(ModelPickerQuery("or.").filter(sample).count == 2)
        }

        @Test("a dot inside a model name is not a provider prefix")
        func dotsInNames() {
            for text in ["gpt-5.2", "claude-3.5", "x.llama", "orx.llama"] {
                let q = ModelPickerQuery(text)
                #expect(q.provider == nil, "\(text)")
                #expect(q.text == text, "\(text)")
            }
        }

        @Test("server search works through an alias too")
        func aliasServerSearch() {
            #expect(ModelPickerQuery("or.ll").openRouterSearchText == "ll")
            #expect(ModelPickerQuery("or.l").openRouterSearchText == nil)
            #expect(ModelPickerQuery("an.claude").openRouterSearchText == nil)
        }

        @Test("server search starts for openrouter: with at least two characters")
        func serverSearchTrigger() {
            #expect(ModelPickerQuery("openrouter:ll").openRouterSearchText == "ll")
            #expect(ModelPickerQuery("openrouter:l").openRouterSearchText == nil)
            #expect(ModelPickerQuery("openrouter:").openRouterSearchText == nil)
            #expect(ModelPickerQuery("openai:gpt").openRouterSearchText == nil)
            #expect(ModelPickerQuery("llama").openRouterSearchText == nil)
        }

        @Test("server results are appended without duplicating cached rows")
        func mergeDedupes() {
            let server = [model(.openrouter, "meta/llama-4:free"), model(.openrouter, "meta/llama-4-scout")]
            let result = ModelPickerQuery("openrouter:llama").merged(sample, serverResults: server)
            #expect(
                result.map(\.id.name) == ["meta/llama-4:free", "meta/llama-4-scout"])
        }
    }
}
