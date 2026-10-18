import Foundation
import Testing

@testable import iCanHazAI

/// Records what the wizard model asked its injected closures to do.
private final class WizardProbe: @unchecked Sendable {
    struct Commit: Sendable {
        let provider: Provider
        let key: String
        let modelCount: Int
        let seedCount: Int
    }

    private let lock = NSLock()
    private var _validations: [(Provider, String)] = []
    private var _commits: [Commit] = []
    var validateResult: @Sendable (Provider, String) async throws -> ValidationResult = { _, _ in
        ValidationResult(modelCount: 3, seed: [])
    }
    var commitError: Error?

    var validations: [(Provider, String)] { lock.withLock { _validations } }
    var commits: [Commit] { lock.withLock { _commits } }

    @MainActor
    func makeModel(added: Set<Provider> = []) -> ProviderWizardModel {
        ProviderWizardModel(
            addedProviders: added,
            validate: { [self] provider, key in
                lock.withLock { _validations.append((provider, key)) }
                return try await validateResult(provider, key)
            },
            commit: { [self] provider, key, validation in
                if let commitError { throw commitError }
                lock.withLock {
                    _commits.append(
                        Commit(
                            provider: provider, key: key, modelCount: validation.modelCount,
                            seedCount: validation.seed.count))
                }
            })
    }
}

extension AllAppTests {
    @Suite("ProviderWizardModel")
    @MainActor
    struct ProviderWizardModelTests {
        @Test("already-added providers are not selectable and the first free one is preselected")
        func preselection() {
            let model = WizardProbe().makeModel(added: [.openai, .anthropic])
            #expect(model.selectedProvider == .deepseek)
            #expect(model.availableProviders == [.deepseek, .openrouter])
            #expect(model.isAdded(.openai))

            model.select(.openai)
            #expect(model.selectedProvider == .deepseek)
            model.select(.openrouter)
            #expect(model.selectedProvider == .openrouter)
        }

        @Test("with every provider added nothing is selected and Next is disabled")
        func allAdded() {
            let model = WizardProbe().makeModel(added: Set(Provider.allCases))
            #expect(model.allProvidersAdded)
            #expect(model.selectedProvider == nil)
            #expect(!model.canGoNext)
        }

        @Test("steps progress provider -> key -> check -> summary, with no Back from the summary")
        func progression() async {
            let probe = WizardProbe()
            let model = probe.makeModel()
            #expect(model.step == .provider)
            #expect(!model.canGoBack)

            model.next()
            #expect(model.step == .apiKey)
            #expect(model.canGoBack)
            #expect(!model.canGoNext)

            model.apiKey = "  fake-key \n"
            #expect(model.canGoNext)
            model.next()
            #expect(model.step == .check)
            await model.settle()
            #expect(model.checkState == .ok(modelCount: 3))
            #expect(model.canGoBack)
            #expect(probe.validations.count == 1)
            #expect(probe.validations[0].1 == "fake-key")
            #expect(probe.commits.isEmpty)

            model.next()
            await model.settle()
            #expect(model.step == .summary)
            #expect(!model.canGoBack)
            #expect(!model.canGoNext)
        }

        @Test("an invalid key keeps Next disabled and offers retry")
        func invalidKey() async {
            let probe = WizardProbe()
            probe.validateResult = { _, _ in throw ProviderError.invalidKey }
            let model = probe.makeModel()
            model.next()
            model.apiKey = "bad"
            model.next()
            await model.settle()

            #expect(model.checkState == .failed("The provider rejected this key."))
            #expect(!model.canGoNext)
            #expect(model.canRetry)
            #expect(model.canGoBack)

            probe.validateResult = { _, _ in ValidationResult(modelCount: 5, seed: []) }
            model.retry()
            await model.settle()
            #expect(model.checkState == .ok(modelCount: 5))
            #expect(model.canGoNext)
        }

        @Test("other errors show their underlying message")
        func otherErrors() async {
            let probe = WizardProbe()
            probe.validateResult = { _, _ in throw ProviderError.http(status: 500, message: "boom") }
            let model = probe.makeModel()
            model.next()
            model.apiKey = "k"
            model.next()
            await model.settle()
            #expect(model.checkState == .failed("HTTP 500: boom"))
        }

        @Test("going back clears the validation, so a changed key is re-checked")
        func changedKeyResets() async {
            let probe = WizardProbe()
            let model = probe.makeModel()
            model.next()
            model.apiKey = "one"
            model.next()
            await model.settle()
            #expect(model.canGoNext)

            model.back()
            #expect(model.step == .apiKey)
            #expect(model.checkState == .idle)

            model.apiKey = "two"
            model.next()
            await model.settle()
            #expect(probe.validations.map(\.1) == ["one", "two"])
        }

        @Test("switching provider drops the typed key and the validation")
        func switchingProvider() async {
            let model = WizardProbe().makeModel()
            model.next()
            model.apiKey = "one"
            model.next()
            await model.settle()
            model.back()
            model.back()
            #expect(model.step == .provider)
            model.select(.anthropic)
            #expect(model.apiKey.isEmpty)
            #expect(model.checkState == .idle)
        }

        @Test("commit is called exactly once with the validated key and result")
        func commitOnce() async {
            let probe = WizardProbe()
            probe.validateResult = { _, _ in ValidationResult(modelCount: 7, seed: []) }
            let model = probe.makeModel()
            model.next()
            model.apiKey = "fake"
            model.next()
            await model.settle()
            model.next()
            model.next()
            await model.settle()

            #expect(probe.commits.count == 1)
            #expect(probe.commits[0].provider == .openai)
            #expect(probe.commits[0].key == "fake")
            #expect(probe.commits[0].modelCount == 7)
        }

        @Test("a commit failure stays on the check step with the message")
        func commitFailure() async {
            struct SaveError: LocalizedError { var errorDescription: String? { "keychain is locked" } }
            let probe = WizardProbe()
            probe.commitError = SaveError()
            let model = probe.makeModel()
            model.next()
            model.apiKey = "fake"
            model.next()
            await model.settle()
            model.next()
            await model.settle()

            #expect(model.step == .check)
            #expect(model.checkState == .failed("keychain is locked"))
            #expect(!model.canGoNext)
            #expect(model.canRetry)
        }

        @Test("cancelling during the check stores nothing")
        func cancelDuringCheck() async {
            let probe = WizardProbe()
            probe.validateResult = { _, _ in
                try await Task.sleep(for: .milliseconds(200))
                return ValidationResult(modelCount: 1, seed: [])
            }
            let model = probe.makeModel()
            model.next()
            model.apiKey = "fake"
            model.next()
            #expect(model.checkState == .checking)

            model.cancel()
            await model.settle()
            #expect(model.checkState == .idle)
            #expect(!model.canGoNext)
            #expect(probe.commits.isEmpty)
        }
    }
}
