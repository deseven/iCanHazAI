import Foundation
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

    @Suite("Loader providers row")
    struct LoaderProvidersTests {
        @MainActor
        private func providersEntry() -> LoaderEntry? {
            LoaderController.shared.sections.first(where: { $0.id == "application" })?
                .entries.first(where: { $0.id == AppResource.providers.id })
        }

        /// Runs a startup pass to completion and waits for the loader to go idle.
        @MainActor
        private func settleToIdle() async -> Bool {
            let ctrl = LoaderController.shared
            ctrl.beginStartup()
            for r in AppResource.allCases { ctrl.markApplicationCompleted(r, loaded: 1) }
            if let mcpSection = ctrl.sections.first(where: { $0.id == "mcps" }) {
                let entries = mcpSection.entries.map {
                    MCPConfigurationEntry(name: $0.label, status: .success, toolCount: 1, errorMessage: nil)
                }
                ctrl.setMCPState(MCPConfigurationState(isConfiguring: false, entries: entries))
            }
            let deadline = Date().addingTimeInterval(4)
            while ctrl.mode != .idle && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return ctrl.mode == .idle
        }

        private func provider(_ p: Provider, count: Int?, refreshing: Bool = false, error: String? = nil)
            -> ConfiguredProvider
        {
            ConfiguredProvider(
                provider: p, modelCount: count, isRefreshing: refreshing, lastRefresh: nil, lastError: error)
        }

        @Test("startup seeds the Providers row with the configured count")
        @MainActor
        func seeding() {
            let ctrl = LoaderController.shared
            ctrl.beginStartup(providerCount: 2)
            #expect(providersEntry()?.label == "Providers")
            #expect(providersEntry()?.total == 2)
            #expect(providersEntry()?.detail == "2 providers")
            #expect(providersEntry()?.status == .pending)

            ctrl.beginStartup(providerCount: 1)
            #expect(providersEntry()?.detail == "1 provider")
            ctrl.beginStartup(providerCount: 0)
            #expect(providersEntry()?.detail == "0 providers")
        }

        @Test("a completion detail replaces the subtitle on success only")
        @MainActor
        func detailOverride() {
            let ctrl = LoaderController.shared
            ctrl.beginStartup(providerCount: 2)
            ctrl.markApplicationCompleted(.providers, loaded: 2, detail: "47 models")
            #expect(providersEntry()?.status == .success)
            #expect(providersEntry()?.detail == "47 models")

            ctrl.markApplicationCompleted(.providers, loaded: 1, detail: "47 models")
            #expect(providersEntry()?.status == .warning)
            #expect(providersEntry()?.detail == "1 failed")
        }

        @Test("provider state maps to success, warning and failed")
        @MainActor
        func derivation() {
            let ctrl = LoaderController.shared
            ctrl.beginStartup(providerCount: 2)
            ctrl.markProvidersCompleted([provider(.openai, count: 10), provider(.anthropic, count: 5)])
            #expect(providersEntry()?.status == .success)
            #expect(providersEntry()?.detail == "15 models")

            ctrl.beginStartup(providerCount: 2)
            ctrl.markProvidersCompleted([provider(.openai, count: 10), provider(.anthropic, count: nil, error: "x")])
            #expect(providersEntry()?.status == .warning)
            #expect(providersEntry()?.detail == "1 failed")

            ctrl.beginStartup(providerCount: 2)
            ctrl.markProvidersCompleted([
                provider(.openai, count: nil, error: "x"), provider(.anthropic, count: nil, error: "y"),
            ])
            #expect(providersEntry()?.status == .failed)
        }

        @Test("no providers completes with the plain subtitle")
        @MainActor
        func noProviders() {
            let ctrl = LoaderController.shared
            ctrl.beginStartup(providerCount: 0)
            ctrl.markProvidersCompleted([])
            #expect(providersEntry()?.status == .success)
            #expect(providersEntry()?.detail == "0 providers")
        }

        @Test("a manual refresh completes the row only once no provider is refreshing")
        @MainActor
        func usageWaitsForRefresh() async {
            #expect(await settleToIdle())
            let ctrl = LoaderController.shared
            ctrl.applicationStarted([.providers: 2])
            #expect(ctrl.mode == .usage)
            #expect(providersEntry()?.status == .inProgress)

            ctrl.markProvidersCompleted([
                provider(.openai, count: 10, refreshing: true), provider(.anthropic, count: 5),
            ])
            #expect(providersEntry()?.status == .inProgress)

            ctrl.markProvidersCompleted([provider(.openai, count: 12), provider(.anthropic, count: 5)])
            #expect(providersEntry()?.status == .success)
            #expect(providersEntry()?.detail == "17 models")
        }

        @Test("background refreshes don't touch an idle loader")
        @MainActor
        func idleIsNoOp() async {
            #expect(await settleToIdle())
            let ctrl = LoaderController.shared
            let before = ctrl.sections
            ctrl.markProvidersCompleted([provider(.openai, count: 10)])
            ctrl.markApplicationCompleted(.providers, loaded: 0, detail: "1 model")
            #expect(ctrl.sections == before)
            #expect(ctrl.mode == .idle)
        }
    }

    // `LoaderController` is a stateful singleton, so this suite relies on the
    // `.serialized` `AllAppTests` parent to run in isolation. It drives the
    // controller through its public startup API and verifies the
    // `startupReadyHandler` (which creates the main window after loading)
    // fires exactly once when every entry settles — and not before.
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

        @Test("startupHiddenHandler fires only after the loader hides")
        @MainActor
        func hiddenFiresAfterHide() async throws {
            let ctrl = LoaderController.shared
            var ready = 0
            var hidden = 0
            ctrl.startupReadyHandler = { ready += 1 }
            ctrl.startupHiddenHandler = { hidden += 1 }

            ctrl.beginStartup()
            for r in AppResource.allCases {
                ctrl.markApplicationCompleted(r, loaded: 1)
            }
            if let mcpSection = ctrl.sections.first(where: { $0.id == "mcps" }) {
                let entries = mcpSection.entries.map {
                    MCPConfigurationEntry(name: $0.label, status: .success, toolCount: 1, errorMessage: nil)
                }
                ctrl.setMCPState(MCPConfigurationState(isConfiguring: false, entries: entries))
            }

            // Settled → ready fires, but the loader is still in its 1-second
            // results-display delay, so "hidden" must not have fired yet.
            #expect(ready == 1)
            #expect(hidden == 0)
            #expect(ctrl.visible)

            // Once the display delay elapses the loader hides and the CLI
            // readiness signal (wired to startupHiddenHandler) may fire.
            try await Task.sleep(for: .milliseconds(1500))
            #expect(!ctrl.visible)
            #expect(hidden == 1)
        }
    }
}
