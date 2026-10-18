import Foundation
import Testing

@testable import iCanHazAI

extension AllAppTests {
    @Suite("ModelCapabilities")
    struct ModelCapabilitiesTests {
        @Test("safe defaults")
        func safeDefaults() {
            let caps = ModelCapabilities.safeDefaults
            #expect(caps.imageInput == false)
            #expect(caps.contextWindow == 1_000_000)
            #expect(caps.maxOutputTokens == nil)
            #expect(caps.reasoning.supported == false)
            #expect(caps.reasoning.levels.isEmpty)
            #expect(caps.reasoning.defaultLevel == nil)
        }

        @Test("Codable round trip")
        func codable() throws {
            let caps = ModelCapabilities(
                imageInput: true,
                contextWindow: 200_000,
                maxOutputTokens: 64_000,
                reasoning: ReasoningCapability(supported: true, levels: ["low", "high"], defaultLevel: "high")
            )
            let data = try JSONEncoder().encode(caps)
            #expect(try JSONDecoder().decode(ModelCapabilities.self, from: data) == caps)
        }
    }
}
