import Testing
@testable import iCanHazAI

// Tests for the loader subtitle / pluralization helpers backing the startup
// and usage loader cards.
extension AllAppTests {
    @Suite("Loader subtitles")
    struct LoaderSubtitleTests {
        @Test("loaderPluralized picks singular vs plural")
        func pluralization() {
            #expect(loaderPluralized(0, singular: "entry", plural: "entries") == "0 entries")
            #expect(loaderPluralized(1, singular: "entry", plural: "entries") == "1 entry")
            #expect(loaderPluralized(2, singular: "entry", plural: "entries") == "2 entries")
            #expect(loaderPluralized(9, singular: "entry", plural: "entries") == "9 entries")

            #expect(loaderPluralized(0, singular: "tool", plural: "tools") == "0 tools")
            #expect(loaderPluralized(1, singular: "tool", plural: "tools") == "1 tool")
            #expect(loaderPluralized(7, singular: "tool", plural: "tools") == "7 tools")
        }
    }

    // `LoaderController` is a stateful singleton, so this suite relies on the
    // `.serialized` `AllAppTests` parent to run in isolation. It drives the
    // controller through its public startup API and verifies the
    // `startupReadyHandler` (which gates main-window reveal) fires exactly once
    // when every entry settles — and not before.
    @Suite("Loader startup readiness")
    struct LoaderStartupReadyTests {
        @Test("startupReadyHandler fires once everything settles, not before")
        @MainActor
        func readyFiresWhenSettled() {
            let ctrl = LoaderController.shared
            var fires = 0
            ctrl.startupReadyHandler = { fires += 1 }

            ctrl.beginStartup()
            // Seeded with pending entries → not ready yet.
            #expect(fires == 0)

            // Complete every Application resource.
            for r in AppResource.allCases {
                ctrl.markApplicationCompleted(r, loaded: 1)
            }
            // Settle every seeded MCP (success). No-op when none were seeded.
            if let mcpSection = ctrl.sections.first(where: { $0.id == "mcps" }) {
                let entries = mcpSection.entries.map {
                    MCPConfigurationEntry(name: $0.label, status: .success, toolCount: 1, errorMessage: nil)
                }
                ctrl.setMCPState(MCPConfigurationState(isConfiguring: false, entries: entries))
            }

            #expect(fires == 1)

            // Further settling must not re-fire (guarded by startupReadyFired).
            ctrl.markApplicationCompleted(.configuration, loaded: 1)
            #expect(fires == 1)
        }
    }
}
