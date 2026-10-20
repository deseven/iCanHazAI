import Foundation
import Testing

@testable import iCanHazAI

extension AllAppTests {
    @Suite("ModelID")
    struct ModelIDTests {
        @Test("parses provider and name")
        func parses() {
            let id = ModelID(parsing: "openrouter:anthropic/claude-sonnet-5.5")
            #expect(id?.provider == .openrouter)
            #expect(id?.name == "anthropic/claude-sonnet-5.5")
        }

        @Test("splits on the first colon only")
        func firstColon() {
            let id = ModelID(parsing: "openrouter:foo:free")
            #expect(id?.provider == .openrouter)
            #expect(id?.name == "foo:free")
        }

        @Test("rejects invalid input")
        func rejects() {
            #expect(ModelID(parsing: "openai:") == nil)
            #expect(ModelID(parsing: "gpt-5") == nil)
            #expect(ModelID(parsing: "") == nil)
            #expect(ModelID(parsing: ":gpt-5") == nil)
        }

        @Test("any provider that isn't a built-in one is a custom provider, named exactly")
        func customProvider() {
            let id = ModelID(parsing: "My Server:llama3:8b")
            #expect(id?.provider == .custom("My Server"))
            #expect(id?.name == "llama3:8b")
            #expect(id?.description == "My Server:llama3:8b")
            // The built-in ids are lowercase and case-sensitive.
            #expect(ModelID(parsing: "OpenAI:gpt-5")?.provider == .custom("OpenAI"))
            #expect(ModelID(parsing: "mistral:large")?.provider == .custom("mistral"))
        }

        @Test("description round trips through parsing")
        func roundTrip() {
            let id = ModelID(provider: .openrouter, name: "x/y:free")
            #expect(id.description == "openrouter:x/y:free")
            #expect(ModelID(parsing: id.description) == id)
        }

        @Test("Codable uses the string form")
        func codable() throws {
            let id = ModelID(provider: .anthropic, name: "claude-opus")
            let data = try JSONEncoder().encode([id])
            #expect(String(data: data, encoding: .utf8) == "[\"anthropic:claude-opus\"]")
            #expect(try JSONDecoder().decode([ModelID].self, from: data) == [id])
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode([ModelID].self, from: Data("[\":x\"]".utf8))
            }
            let custom = ModelID(provider: .custom("Ollama"), name: "llama3")
            let customData = try JSONEncoder().encode([custom])
            #expect(String(data: customData, encoding: .utf8) == "[\"Ollama:llama3\"]")
            #expect(try JSONDecoder().decode([ModelID].self, from: customData) == [custom])
        }

        @Test("provider base URLs")
        func baseUrls() {
            #expect(Provider.deepseek.defaultBaseUrl == "https://api.deepseek.com")
            #expect(Provider.allCases.allSatisfy { URL(string: $0.defaultBaseUrl) != nil })
        }
    }
}
