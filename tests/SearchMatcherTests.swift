import Foundation
import Testing

@testable import iCanHazAI

extension AllAppTests {

    @Suite("SearchMatcher")
    struct SearchMatcherTests {

        private func rank(_ items: [String], _ query: String) -> [String] {
            SearchMatcher.rank(items, query: query) { [$0] }
        }

        @Test("empty or whitespace query returns the items unchanged")
        func emptyQuery() {
            #expect(rank(["b", "a"], "") == ["b", "a"])
            #expect(rank(["b", "a"], "  ") == ["b", "a"])
        }

        @Test("substring match is case-insensitive and drops non-matches")
        func substring() {
            #expect(rank(["Developer", "Architect", "Assistant"], "DEV") == ["Developer"])
        }

        @Test("ranks whole key, prefix, word start, then elsewhere")
        func tiers() {
            let items = ["xwebx", "my-web", "website", "web"]
            #expect(rank(items, "web") == ["web", "website", "my-web", "xwebx"])
        }

        @Test("ties keep the input order")
        func stableTies() {
            #expect(rank(["b-x", "a-x", "c-x"], "x") == ["b-x", "a-x", "c-x"])
        }

        @Test("every word must match, in any order")
        func words() {
            let items = ["claude-sonnet-5.5", "claude-haiku-5.5", "gpt-5"]
            #expect(rank(items, "sonnet claude") == ["claude-sonnet-5.5"])
            #expect(rank(items, "claude 5.5") == ["claude-sonnet-5.5", "claude-haiku-5.5"])
            #expect(rank(items, "claude gpt").isEmpty)
        }

        @Test("words may match different keys of the same item")
        func multiKey() {
            struct Item: Equatable {
                let name: String
                let desc: String
            }
            let items = [
                Item(name: "Configurator", desc: "Manages configuration files"),
                Item(name: "Assistant", desc: "General help, no tools"),
            ]
            let ranked = SearchMatcher.rank(items, query: "configurator files") { [$0.name, $0.desc] }
            #expect(ranked.map(\.name) == ["Configurator"])
        }

        @Test("a subsequence matches only when nothing matches as a substring")
        func subsequenceFallback() {
            #expect(rank(["Deploy scripts", "Grocery list"], "dpl") == ["Deploy scripts"])
            #expect(rank(["Deploy scripts", "dpl notes", "Grocery list"], "dpl") == ["dpl notes"])
        }

        @Test("non-ASCII text is matched")
        func unicode() {
            #expect(rank(["Résumé helper", "Other"], "RÉSUMÉ") == ["Résumé helper"])
            #expect(rank(["Café", "Other"], "cfé") == ["Café"])
        }

        @Test("stays fast on a large catalog")
        func performance() {
            let items = (0..<5000).map { "provider:vendor-\($0 % 50)/model-name-\($0)-instruct-preview" }
            let start = Date()
            _ = rank(items, "model 42 instruct")
            #expect(Date().timeIntervalSince(start) < 1.0)
        }
    }
}
