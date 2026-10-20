import Foundation
import Testing

@testable import iCanHazAI

/// Records what the wizard model asked its injected closures to do.
private final class WizardProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _validations: [(WebSearchProviderKind, String)] = []
    private var _commits: [(WebSearchProviderKind, String)] = []
    var validateError: Error?
    var commitError: Error?
    var validateDelay: Duration?

    var validations: [(WebSearchProviderKind, String)] { lock.withLock { _validations } }
    var commits: [(WebSearchProviderKind, String)] { lock.withLock { _commits } }

    @MainActor
    func makeModel(initial: WebSearchProviderKind = .none) -> WebSearchWizardModel {
        WebSearchWizardModel(
            initialProvider: initial,
            validate: { [self] provider, key in
                lock.withLock { _validations.append((provider, key)) }
                if let validateDelay { try await Task.sleep(for: validateDelay) }
                if let validateError { throw validateError }
            },
            commit: { [self] provider, key in
                if let commitError { throw commitError }
                lock.withLock { _commits.append((provider, key)) }
            })
    }
}

extension AllAppTests {
    @Suite("WebSearchWizardModel")
    @MainActor
    struct WebSearchWizardModelTests {

        /// Walks a fresh model to the check step with `key` entered.
        private func toCheck(_ model: WebSearchWizardModel, key: String = "fake-key") async {
            model.next()
            model.apiKey = key
            model.next()
            await model.settle()
        }

        @Test("Exa is preselected unless the config already names one of the offered providers")
        func preselection() {
            #expect(WizardProbe().makeModel().selectedProvider == .exa)
            #expect(WizardProbe().makeModel(initial: .none).selectedProvider == .exa)
            #expect(WizardProbe().makeModel(initial: .tavily).selectedProvider == .tavily)
            #expect(WizardProbe().makeModel(initial: .linkup).selectedProvider == .linkup)
        }

        @Test("exactly Exa, Linkup and Tavily are offered")
        func offeredProviders() {
            #expect(WebSearchProviderKind.selectable == [.exa, .linkup, .tavily])
            let model = WizardProbe().makeModel()
            model.select(.none)
            #expect(model.selectedProvider == .exa)
        }

        @Test("steps progress provider -> key -> check, and Finish stores the key")
        func progression() async {
            let probe = WizardProbe()
            let model = probe.makeModel()
            #expect(model.step == .provider)
            #expect(!model.canGoBack)
            #expect(model.canGoNext)

            model.next()
            #expect(model.step == .apiKey)
            #expect(model.canGoBack)
            #expect(!model.canGoNext)

            model.apiKey = "  fake-key \n"
            #expect(model.canGoNext)
            model.next()
            #expect(model.step == .check)
            await model.settle()
            #expect(model.checkState == .ok)
            #expect(model.canGoBack)
            #expect(model.canGoNext)
            #expect(probe.validations.map(\.1) == ["fake-key"])
            #expect(probe.commits.isEmpty)
            #expect(!model.isCommitted)

            model.next()
            await model.settle()
            #expect(model.isCommitted)
            #expect(!model.canGoBack)
            #expect(!model.canGoNext)
        }

        @Test("the check and the stored key use the selected provider and the trimmed key")
        func providerAndKeyPassedOn() async {
            let probe = WizardProbe()
            let model = probe.makeModel()
            model.select(.linkup)
            await toCheck(model, key: "  lk-123  ")
            model.next()
            await model.settle()

            #expect(probe.validations.map(\.0) == [.linkup])
            #expect(probe.commits.map(\.0) == [.linkup])
            #expect(probe.commits.map(\.1) == ["lk-123"])
        }

        @Test("an invalid key keeps Finish disabled and offers retry")
        func invalidKey() async {
            let probe = WizardProbe()
            probe.validateError = ProviderError.invalidKey
            let model = probe.makeModel()
            await toCheck(model, key: "bad")

            #expect(model.checkState == .failed("Exa rejected this API key."))
            #expect(!model.canGoNext)
            #expect(model.canRetry)
            #expect(model.canGoBack)

            probe.validateError = nil
            model.retry()
            await model.settle()
            #expect(model.checkState == .ok)
            #expect(model.canGoNext)
        }

        @Test("the rejection names the selected provider")
        func rejectionNamesProvider() async {
            let probe = WizardProbe()
            probe.validateError = ProviderError.invalidKey
            let model = probe.makeModel(initial: .tavily)
            await toCheck(model)
            #expect(model.checkState == .failed("Tavily rejected this API key."))
        }

        @Test("other errors show their underlying message")
        func otherErrors() async {
            let probe = WizardProbe()
            probe.validateError = ProviderError.http(status: 500, message: "boom")
            let model = probe.makeModel()
            await toCheck(model)
            #expect(model.checkState == .failed("HTTP 500: boom"))
        }

        @Test("going back clears the check, so a changed key is re-checked")
        func changedKeyResets() async {
            let probe = WizardProbe()
            let model = probe.makeModel()
            await toCheck(model, key: "one")
            #expect(model.canGoNext)

            model.back()
            #expect(model.step == .apiKey)
            #expect(model.checkState == .idle)

            model.apiKey = "two"
            model.next()
            await model.settle()
            #expect(probe.validations.map(\.1) == ["one", "two"])
        }

        @Test("switching provider drops the typed key and the check")
        func switchingProvider() async {
            let model = WizardProbe().makeModel()
            await toCheck(model, key: "one")
            model.back()
            model.back()
            #expect(model.step == .provider)
            model.select(.tavily)
            #expect(model.apiKey.isEmpty)
            #expect(model.checkState == .idle)
            #expect(model.selectedProvider == .tavily)
        }

        @Test("the key is stored exactly once, even if Finish is pressed again")
        func commitOnce() async {
            let probe = WizardProbe()
            let model = probe.makeModel()
            await toCheck(model)
            model.next()
            model.next()
            await model.settle()
            model.next()
            await model.settle()

            #expect(probe.commits.count == 1)
            #expect(probe.commits[0].0 == .exa)
            #expect(probe.commits[0].1 == "fake-key")
        }

        @Test("a save failure stays on the check step with the message and allows a retry")
        func commitFailure() async {
            struct SaveError: LocalizedError { var errorDescription: String? { "keychain is locked" } }
            let probe = WizardProbe()
            probe.commitError = SaveError()
            let model = probe.makeModel()
            await toCheck(model)
            model.next()
            await model.settle()

            #expect(model.step == .check)
            #expect(!model.isCommitted)
            #expect(model.checkState == .failed("Couldn't save the API key: keychain is locked"))
            #expect(!model.canGoNext)
            #expect(model.canRetry)

            probe.commitError = nil
            model.retry()
            await model.settle()
            model.next()
            await model.settle()
            #expect(model.isCommitted)
            #expect(probe.commits.count == 1)
        }

        @Test("cancelling during the check stores nothing")
        func cancelDuringCheck() async {
            let probe = WizardProbe()
            probe.validateDelay = .milliseconds(100)
            let model = probe.makeModel()
            model.next()
            model.apiKey = "fake"
            model.next()
            #expect(model.checkState == .checking)
            #expect(!model.canGoNext)

            model.cancel()
            try? await Task.sleep(for: .milliseconds(350))
            #expect(model.checkState == .idle)
            #expect(!model.canGoNext)
            #expect(probe.commits.isEmpty)
        }

        @Test("a check that finishes after the key changed is ignored")
        func staleCheckIgnored() async {
            let probe = WizardProbe()
            probe.validateDelay = .milliseconds(100)
            let model = probe.makeModel()
            model.next()
            model.apiKey = "one"
            model.next()
            model.back()
            model.apiKey = "two"
            // The first check is still sleeping; let it finish and be dropped.
            try? await Task.sleep(for: .milliseconds(350))
            #expect(model.step == .apiKey)
            #expect(model.checkState == .idle)
            #expect(probe.commits.isEmpty)
        }
    }

    @Suite("Web search sheets")
    struct WebSearchSheetTests {

        @Test("Preferences is one sheet whatever tab it is opened on")
        func preferencesIdentity() {
            #expect(MainSheet.preferences().id == MainSheet.preferences(.webSearch).id)
            #expect(MainSheet.preferences() == .preferences(.general))
            #expect(MainSheet.preferences(.webSearch) != .preferences(.general))
        }

        @Test("the wizard is an app-level sheet of its own, outside the onboarding flow")
        func wizardSheet() {
            #expect(MainSheet.webSearchWizard.isAppLevel)
            #expect(MainSheet.webSearchWizard.id != MainSheet.preferences().id)
            #expect(!MainSheet.webSearchWizard.isOnboardingFlow)
        }
    }
}
