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

        @Test("compact counts are whole numbers and move up a tier at 1000")
        func compactCount() {
            let cases: [(Int, String)] = [
                (0, "0"), (999, "999"), (1000, "1k"), (8192, "8k"), (128_000, "128k"),
                (131_072, "131k"), (200_000, "200k"), (999_499, "999k"), (999_500, "1kk"),
                (1_000_000, "1kk"), (1_048_576, "1kk"), (2_000_000, "2kk"), (10_000_000, "10kk"),
                (1_000_000_000, "1kkk"), (-5, "0"),
            ]
            for (count, expected) in cases {
                #expect(ModelCapabilities.compactCount(count) == expected, "\(count)")
            }
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
