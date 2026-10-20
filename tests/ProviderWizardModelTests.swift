import Foundation
import Testing

@testable import iCanHazAI

/// Records what the wizard model asked its injected closures to do.
private final class WizardProbe: @unchecked Sendable {
    struct Commit: Sendable {
        let key: NewProviderKey
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
    func makeModel(existing: [Provider: [String]] = [:], initialProvider: Provider? = nil) -> ProviderWizardModel {
        ProviderWizardModel(
            existingKeyNames: existing,
            initialProvider: initialProvider,
            validate: { [self] provider, key in
                lock.withLock { _validations.append((provider, key)) }
                return try await validateResult(provider, key)
            },
            commit: { [self] key, validation in
                if let commitError { throw commitError }
                lock.withLock {
                    _commits.append(
                        Commit(key: key, modelCount: validation.modelCount, seedCount: validation.seed.count))
                }
            })
    }
}

extension AllAppTests {
    @Suite("ProviderWizardModel")
    @MainActor
    struct ProviderWizardModelTests {
        @Test("the first provider without a key is preselected, but every provider stays selectable")
        func preselection() {
            let model = WizardProbe().makeModel(existing: [.openai: ["Default"], .anthropic: ["Default"]])
            #expect(model.selectedProvider == .deepseek)

            model.select(.openai)
            #expect(model.selectedProvider == .openai)
            model.select(.openrouter)
            #expect(model.selectedProvider == .openrouter)
        }

        @Test("with every provider added the first one is preselected and Next stays available")
        func allAdded() {
            let existing = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, ["Default"]) })
            let model = WizardProbe().makeModel(existing: existing)
            #expect(model.selectedProvider == Provider.allCases.first)
            #expect(model.canGoNext)
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
            #expect(probe.commits[0].key.provider == .openai)
            #expect(probe.commits[0].key.secret == "fake")
            #expect(probe.commits[0].modelCount == 7)
            #expect(model.committedKey == probe.commits[0].key)
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

        // MARK: - Key name and activation

        @Test("the first key of a provider is named Default and is always made active")
        func firstKey() async {
            let probe = WizardProbe()
            let model = probe.makeModel()
            #expect(model.isFirstKey)
            #expect(model.keyName == "Default")

            model.next()
            model.apiKey = "fake"
            model.makeActive = false
            model.next()
            await model.settle()
            model.next()
            await model.settle()

            #expect(probe.commits.map(\.key.name) == ["Default"])
            #expect(probe.commits.map(\.key.makeActive) == [true])
        }

        @Test("a further key starts with an empty name and Next needs one")
        func furtherKey() {
            let model = WizardProbe().makeModel(existing: [.openai: ["Default"]])
            model.select(.openai)
            #expect(!model.isFirstKey)
            #expect(model.keyName.isEmpty)
            #expect(model.makeActive)

            model.next()
            model.apiKey = "fake"
            #expect(!model.canGoNext)
            model.keyName = "   "
            #expect(!model.canGoNext)
            model.keyName = "Work"
            #expect(model.canGoNext)
        }

        @Test("the name is limited to 30 characters and trimmed when stored")
        func nameLimit() async {
            let probe = WizardProbe()
            let model = probe.makeModel()
            model.keyName = "  " + String(repeating: "x", count: 50)
            #expect(model.keyName.count == ProviderWizardModel.maxKeyNameLength)

            model.keyName = "  Work  "
            model.next()
            model.apiKey = "fake"
            model.next()
            await model.settle()
            model.next()
            await model.settle()
            #expect(probe.commits.map(\.key.name) == ["Work"])
        }

        @Test("with an initial provider the wizard starts on the key step and has no provider step to return to")
        func initialProvider() async {
            let probe = WizardProbe()
            let model = probe.makeModel(existing: [.openai: ["Default"]], initialProvider: .openai)
            #expect(model.step == .apiKey)
            #expect(model.selectedProvider == .openai)
            #expect(model.skipsProviderStep)
            #expect(model.steps == [.apiKey, .check, .summary])
            #expect(!model.canGoBack)
            #expect(!model.isFirstKey)
            #expect(model.keyName.isEmpty)
            #expect(model.makeActive)

            model.apiKey = "fake"
            model.keyName = "Work"
            model.next()
            await model.settle()
            #expect(model.step == .check)
            #expect(model.canGoBack)

            model.back()
            #expect(model.step == .apiKey)
            #expect(!model.canGoBack)

            model.next()
            await model.settle()
            model.next()
            await model.settle()
            #expect(model.step == .summary)
            #expect(
                probe.commits.map(\.key) == [
                    NewProviderKey(provider: .openai, name: "Work", secret: "fake", makeActive: true)
                ])
        }

        @Test("without an initial provider every step is shown, starting with the provider")
        func defaultSteps() {
            let model = WizardProbe().makeModel()
            #expect(!model.skipsProviderStep)
            #expect(model.steps == ProviderWizardModel.Step.allCases)
            #expect(model.step == .provider)
        }

        @Test("a name already used by the provider is refused, ignoring case")
        func duplicateName() {
            let model = WizardProbe().makeModel(existing: [.openai: ["Default", "Work"], .anthropic: ["Work"]])
            model.select(.openai)
            model.next()
            model.apiKey = "fake"
            model.keyName = "work"
            #expect(model.isKeyNameTaken)
            #expect(!model.canGoNext)

            model.keyName = "Personal"
            #expect(!model.isKeyNameTaken)
            #expect(model.canGoNext)
        }

        @Test("another provider may reuse a name")
        func sameNameOtherProvider() {
            let model = WizardProbe().makeModel(existing: [.openai: ["Default"]])
            model.select(.anthropic)
            #expect(model.keyName == "Default")
            #expect(!model.isKeyNameTaken)
        }

        @Test("the activation choice is passed on, and a provider switch resets the key fields")
        func activationChoice() async {
            let probe = WizardProbe()
            let model = probe.makeModel(existing: [.openai: ["Default"]])
            model.select(.openai)
            model.keyName = "Spare"
            model.makeActive = false

            model.select(.anthropic)
            #expect(model.keyName == "Default")
            #expect(model.makeActive)

            model.select(.openai)
            #expect(model.keyName.isEmpty)
            model.keyName = "Spare"
            model.makeActive = false
            model.next()
            model.apiKey = "fake"
            model.next()
            await model.settle()
            model.next()
            await model.settle()

            #expect(
                probe.commits.map(\.key) == [
                    NewProviderKey(provider: .openai, name: "Spare", secret: "fake", makeActive: false)
                ])
        }
    }
}
