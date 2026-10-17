import Testing

@testable import iCanHazAI

extension AllAppTests {
    @Suite("ConfigChange")
    struct ConfigChangeTests {

        @Test("changes map to the loader's Application resources")
        func appResources() {
            #expect(ConfigChange.config.appResource == .configuration)
            #expect(ConfigChange.connections.appResource == .connections)
            #expect(ConfigChange.roles.appResource == .roles)
            #expect(ConfigChange.role("x").appResource == .roles)
            #expect(ConfigChange.prompts.appResource == .prompts)
            #expect(ConfigChange.prompt("x").appResource == .prompts)
            #expect(ConfigChange.mcp("x").appResource == nil)
        }

        @Test("single-entity changes refresh one item, bulk changes refresh the total")
        func refreshCounts() {
            #expect(ConfigChange.role("x").refreshCount(total: 7) == 1)
            #expect(ConfigChange.prompt("x").refreshCount(total: 7) == 1)
            #expect(ConfigChange.mcp("x").refreshCount(total: 7) == 1)
            #expect(ConfigChange.config.refreshCount(total: 1) == 1)
            #expect(ConfigChange.roles.refreshCount(total: 7) == 7)
            #expect(ConfigChange.connections.refreshCount(total: 3) == 3)
        }
    }
}
