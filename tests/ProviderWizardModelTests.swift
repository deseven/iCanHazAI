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

    struct Validation: Sendable {
        let provider: Provider
        let custom: CustomProviderConfig?
        let key: String
    }

    private let lock = NSLock()
    private var _validations: [Validation] = []
    private var _commits: [Commit] = []
    var validateResult: @Sendable (Provider, CustomProviderConfig?, String) async throws -> ValidationResult = {
        _, _, _ in
        ValidationResult(modelCount: 3, seed: [])
    }
    var commitError: Error?

    var validations: [Validation] { lock.withLock { _validations } }
    var commits: [Commit] { lock.withLock { _commits } }

    @MainActor
    func makeModel(existing: [Provider: [String]] = [:], initialProvider: Provider? = nil) -> ProviderWizardModel {
        ProviderWizardModel(
            existingKeyNames: existing,
            initialProvider: initialProvider,
            validate: { [self] provider, custom, key in
                lock.withLock { _validations.append(Validation(provider: provider, custom: custom, key: key)) }
                return try await validateResult(provider, custom, key)
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
        @Test("the first provider without a key is preselected")
        func preselection() {
            let model = WizardProbe().makeModel(existing: [.openai: ["Default"], .anthropic: ["Default"]])
            #expect(model.selectedProvider == .deepseek)
            #expect(!model.isCustomChosen)

            model.select(.openrouter)
            #expect(model.selectedProvider == .openrouter)
        }

        @Test("a provider that already has a key can't be picked")
        func addedProvidersCannotBePicked() {
            let model = WizardProbe().makeModel(existing: [.openai: ["Default"], .anthropic: ["Default"]])
            #expect(model.isAdded(.openai))
            #expect(!model.isAdded(.deepseek))

            model.select(.openai)
            model.select(.anthropic)
            #expect(model.selectedProvider == .deepseek)

            model.selectCustom()
            model.select(.openai)
            #expect(model.isCustomChosen)
            #expect(model.selectedProvider == nil)
        }

        @Test("with every built-in provider added the custom provider is preselected")
        func allAdded() {
            let existing = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, ["Default"]) })
            let model = WizardProbe().makeModel(existing: existing)
            #expect(model.isCustomChosen)
            #expect(model.selectedProvider == nil)
            #expect(model.canGoNext)
        }

        @Test("Next on the provider step works for a free built-in provider and for the custom one")
        func providerStepNext() {
            let model = WizardProbe().makeModel(existing: [.openai: ["Default"]])
            #expect(model.selectedProvider == .anthropic)
            #expect(model.canGoNext)
            model.selectCustom()
            #expect(model.canGoNext)
            model.select(.deepseek)
            #expect(model.canGoNext)
        }

        @Test("steps progress provider -> key -> check -> summary, with no Back from the summary")
        func progression() async {
            let probe = WizardProbe()
            let model = probe.makeModel()
            #expect(model.step == .provider)
            #expect(model.steps == [.provider, .apiKey, .check, .summary])
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
            #expect(probe.validations[0].key == "fake-key")
            #expect(probe.validations[0].custom == nil)
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
            probe.validateResult = { _, _, _ in throw ProviderError.invalidKey }
            let model = probe.makeModel()
            model.next()
            model.apiKey = "bad"
            model.next()
            await model.settle()

            #expect(model.checkState == .failed("The provider rejected this key."))
            #expect(!model.canGoNext)
            #expect(model.canRetry)
            #expect(model.canGoBack)

            probe.validateResult = { _, _, _ in ValidationResult(modelCount: 5, seed: []) }
            model.retry()
            await model.settle()
            #expect(model.checkState == .ok(modelCount: 5))
            #expect(model.canGoNext)
        }

        @Test("other errors show their underlying message")
        func otherErrors() async {
            let probe = WizardProbe()
            probe.validateResult = { _, _, _ in throw ProviderError.http(status: 500, message: "boom") }
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
            #expect(probe.validations.map(\.key) == ["one", "two"])
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
            probe.validateResult = { _, _, _ in ValidationResult(modelCount: 7, seed: []) }
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
            #expect(probe.commits[0].key.custom == nil)
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
            probe.validateResult = { _, _, _ in
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
            let model = WizardProbe().makeModel(existing: [.openai: ["Default"]], initialProvider: .openai)
            #expect(!model.isFirstKey)
            #expect(model.keyName.isEmpty)
            #expect(model.makeActive)

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

        @Test("the provider can't be changed once it is fixed")
        func fixedProvider() {
            let model = WizardProbe().makeModel(existing: [.openai: ["Default"]], initialProvider: .openai)
            model.select(.anthropic)
            model.selectCustom()
            #expect(model.selectedProvider == .openai)
            #expect(!model.isCustomChosen)
        }

        @Test("without an initial provider every step but the custom ones is shown, starting with the provider")
        func defaultSteps() {
            let model = WizardProbe().makeModel()
            #expect(!model.skipsProviderStep)
            #expect(model.steps == [.provider, .apiKey, .check, .summary])
            #expect(model.step == .provider)
        }

        @Test("a name already used by the provider is refused, ignoring case")
        func duplicateName() {
            let model = WizardProbe().makeModel(
                existing: [.openai: ["Default", "Work"], .anthropic: ["Work"]], initialProvider: .openai)
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
            let spare = probe.makeModel(existing: [.openai: ["Default"]], initialProvider: .openai)
            spare.keyName = "Spare"
            spare.makeActive = false
            spare.apiKey = "fake"
            spare.next()
            await spare.settle()
            spare.next()
            await spare.settle()
            #expect(
                probe.commits.map(\.key) == [
                    NewProviderKey(provider: .openai, name: "Spare", secret: "fake", makeActive: false)
                ])

            let model = probe.makeModel()
            model.keyName = "Spare"
            model.makeActive = false
            model.select(.anthropic)
            #expect(model.keyName == "Default")
            #expect(model.makeActive)
        }

        // MARK: - Custom provider

        /// A model with the custom provider picked and the wizard on the type step, which
        /// the OpenAI-compatible default type lets through to the details with one `next()`.
        private func customModel(
            _ probe: WizardProbe = WizardProbe(), existing: [Provider: [String]] = [:]
        ) -> ProviderWizardModel {
            let model = probe.makeModel(existing: existing)
            model.selectCustom()
            model.next()
            return model
        }

        @Test("picking the custom provider adds the type and details steps")
        func customSteps() {
            let model = WizardProbe().makeModel()
            #expect(!model.steps.contains(.details))
            #expect(!model.steps.contains(.type))
            model.selectCustom()
            #expect(model.isCustomChosen)
            #expect(model.selectedProvider == nil)
            #expect(model.steps == [.provider, .type, .details, .apiKey, .check, .summary])
            #expect(model.isCustomProvider)
            #expect(model.isKeyOptional)

            model.select(.openai)
            #expect(!model.isCustomChosen)
            #expect(!model.steps.contains(.details))
            #expect(!model.steps.contains(.type))
            #expect(!model.isKeyOptional)
        }

        @Test("the type is asked first, defaults to OpenAI-compatible, and Back returns to the provider")
        func typeStep() {
            let model = WizardProbe().makeModel()
            model.selectCustom()
            model.next()
            #expect(model.step == .type)
            #expect(model.customType == .openai)
            #expect(model.canGoNext)
            #expect(model.canGoBack)

            model.selectType(.llamacpp)
            #expect(model.customType == .llamacpp)
            model.back()
            #expect(model.step == .provider)
            #expect(!model.canGoBack)
            model.next()
            #expect(model.customType == .llamacpp, "the choice survives going back")
            model.next()
            #expect(model.step == .details)
        }

        @Test("the type is part of the custom provider and decides how its endpoint is read")
        func typeDecidesEndpoint() {
            let model = customModel()
            model.customName = "Local"
            model.customEndpoint = "http://localhost:11434/v1/"
            #expect(model.normalizedCustomEndpoint == "http://localhost:11434/v1")
            #expect(model.newCustomProvider?.type == .openai)
            #expect(model.adjustedEndpointNote == nil)

            model.selectType(.ollama)
            #expect(model.normalizedCustomEndpoint == "http://localhost:11434")
            #expect(
                model.newCustomProvider
                    == CustomProviderConfig(
                        name: "Local", type: .ollama, endpoint: "http://localhost:11434", color: "teal"))
            #expect(model.adjustedEndpointNote == "http://localhost:11434")

            model.customEndpoint = "http://localhost:11434/"
            #expect(model.adjustedEndpointNote == nil, "a trailing slash alone isn't worth a note")

            model.selectType(.llamacpp)
            model.customEndpoint = "http://127.0.0.1:9931/v1"
            #expect(model.newCustomProvider?.endpoint == "http://127.0.0.1:9931")
            #expect(model.newCustomProvider?.type == .llamacpp)
        }

        @Test("a type changed after a check is checked again, with the new type")
        func typeChangeIsChecked() async {
            let probe = WizardProbe()
            let model = customModel(probe)
            model.next()
            model.customName = "Local"
            model.customEndpoint = "http://localhost:11434"
            model.next()
            model.next()
            await model.settle()
            #expect(model.canGoNext)

            model.back()
            model.back()
            model.back()
            #expect(model.step == .type)
            model.selectType(.ollama)
            #expect(model.checkState == .idle)
            model.next()
            model.next()
            model.next()
            await model.settle()
            #expect(probe.validations.map { $0.custom?.type } == [.openai, .ollama])
            #expect(
                probe.validations.map { $0.custom?.endpoint } == ["http://localhost:11434", "http://localhost:11434"])
        }

        @Test("the type can only be picked while a custom provider is being defined")
        func typeNeedsCustom() {
            let model = WizardProbe().makeModel()
            model.selectType(.ollama)
            #expect(model.customType == .openai)
        }

        @Test("the details need a usable name and endpoint")
        func customDetailsGate() {
            let model = customModel()
            model.next()
            #expect(model.step == .details)
            #expect(model.canGoBack)
            #expect(!model.canGoNext)

            model.customName = "Ollama"
            #expect(!model.canGoNext)
            model.customEndpoint = "localhost:11434"
            #expect(!model.canGoNext)
            model.customEndpoint = "http://localhost:11434/v1"
            #expect(model.canGoNext)
            #expect(model.targetProvider == .custom("Ollama"))
        }

        @Test("custom names must be unique, not built-in, and fit the model id format")
        func customNameValidation() {
            let model = customModel(existing: [.custom("Ollama"): ["Default"]])
            #expect(model.customNameProblem == .empty)

            for reserved in ["openai", "OpenAI", " DeepSeek ", "OPENROUTER", "Anthropic"] {
                model.customName = reserved
                #expect(model.customNameProblem == .reserved, "\(reserved)")
            }
            model.customName = "ollama"
            #expect(model.customNameProblem == .taken)
            model.customName = "My:Server"
            #expect(model.customNameProblem == .containsColon)
            model.customName = "Line\nBreak"
            #expect(model.customNameProblem == .containsControlCharacters)
            model.customName = "   "
            #expect(model.customNameProblem == .empty)

            model.customName = "LM Studio"
            #expect(model.customNameProblem == nil)
            model.customName = String(repeating: "x", count: 50)
            #expect(model.customName.count == CustomProviderConfig.maxNameLength)
            #expect(model.customNameProblem == nil)
        }

        @Test("a taken name keeps the details from being accepted")
        func takenNameBlocksNext() {
            let model = customModel(existing: [.custom("Ollama"): ["Default"]])
            model.next()
            model.customName = "Ollama"
            model.customEndpoint = "http://localhost:11434/v1"
            #expect(!model.canGoNext)
            model.customName = "Ollama 2"
            #expect(model.canGoNext)
        }

        @Test("the endpoint must be an http(s) URL and loses surrounding space and trailing slashes")
        func customEndpointValidation() {
            let model = customModel()
            for bad in ["", "localhost:11434", "ftp://example.com", "http://", "not a url", "/v1"] {
                model.customEndpoint = bad
                #expect(model.normalizedCustomEndpoint == nil, "\(bad)")
            }
            model.customEndpoint = "  https://api.example.com/v1//  "
            #expect(model.normalizedCustomEndpoint == "https://api.example.com/v1")
            model.customEndpoint = "http://localhost:1234"
            #expect(model.normalizedCustomEndpoint == "http://localhost:1234")
        }

        @Test("a custom provider is checked at its endpoint, without a key, and created on commit")
        func customFlow() async {
            let probe = WizardProbe()
            probe.validateResult = { _, _, _ in ValidationResult(modelCount: 4, seed: []) }
            let model = customModel(probe)
            model.next()
            model.customName = "  Ollama "
            model.customEndpoint = " http://localhost:11434/v1/ "
            model.customColor = .orange
            model.next()
            #expect(model.step == .apiKey)
            #expect(model.keyName == "Default")
            #expect(model.canGoNext)

            model.next()
            #expect(model.step == .check)
            await model.settle()
            #expect(model.checkState == .ok(modelCount: 4))
            let expected = CustomProviderConfig(name: "Ollama", endpoint: "http://localhost:11434/v1", color: "orange")
            #expect(probe.validations.count == 1)
            #expect(probe.validations[0].provider == .custom("Ollama"))
            #expect(probe.validations[0].custom == expected)
            #expect(probe.validations[0].key.isEmpty)

            model.next()
            await model.settle()
            #expect(model.step == .summary)
            #expect(
                probe.commits.map(\.key) == [
                    NewProviderKey(
                        provider: .custom("Ollama"), name: "Default", secret: "", makeActive: true, custom: expected)
                ])
        }

        @Test("a custom provider may be given an API key")
        func customWithKey() async {
            let probe = WizardProbe()
            let model = customModel(probe)
            model.next()
            model.customName = "Together"
            model.customEndpoint = "https://api.together.xyz/v1"
            model.next()
            model.apiKey = " secret \n"
            model.next()
            await model.settle()
            model.next()
            await model.settle()
            #expect(probe.validations.map(\.key) == ["secret"])
            #expect(probe.commits.map(\.key.secret) == ["secret"])
            #expect(probe.commits.map(\.key.custom?.color) == ["teal"])
        }

        @Test("a built-in provider still needs a key")
        func builtInKeyRequired() {
            let model = WizardProbe().makeModel()
            model.next()
            #expect(!model.isKeyOptional)
            #expect(!model.canGoNext)
        }

        @Test("Back from the key step returns to the details, then to the type, then to the provider")
        func customBack() {
            let model = customModel()
            model.next()
            model.customName = "Ollama"
            model.customEndpoint = "http://localhost:11434/v1"
            model.next()
            #expect(model.step == .apiKey)

            model.back()
            #expect(model.step == .details)
            #expect(model.customName == "Ollama")
            model.back()
            #expect(model.step == .type)
            model.back()
            #expect(model.step == .provider)
            #expect(!model.canGoBack)
        }

        @Test("changing the endpoint after a check discards the validation")
        func endpointChangeInvalidatesCheck() async {
            let probe = WizardProbe()
            let model = customModel(probe)
            model.next()
            model.customName = "Ollama"
            model.customEndpoint = "http://localhost:11434/v1"
            model.next()
            model.next()
            await model.settle()
            #expect(model.canGoNext)

            model.back()
            model.back()
            model.customEndpoint = "http://localhost:11435/v1"
            #expect(model.checkState == .idle)
            model.next()
            model.next()
            await model.settle()
            #expect(
                probe.validations.map { $0.custom?.endpoint } == [
                    "http://localhost:11434/v1", "http://localhost:11435/v1",
                ])
        }

        @Test("another key of an existing custom provider needs a key and creates nothing")
        func extraKeyForCustomProvider() async {
            let probe = WizardProbe()
            let ollama = Provider.custom("Ollama")
            let model = probe.makeModel(existing: [ollama: ["Default"]], initialProvider: ollama)
            #expect(model.step == .apiKey)
            #expect(model.steps == [.apiKey, .check, .summary])
            #expect(model.isCustomProvider)
            #expect(!model.isCustomChosen)
            #expect(!model.isKeyOptional)
            #expect(!model.isFirstKey)
            #expect(!model.canGoNext)

            model.apiKey = "second"
            model.keyName = "Work"
            model.next()
            await model.settle()
            model.next()
            await model.settle()
            #expect(probe.validations.map(\.provider) == [ollama])
            #expect(probe.validations.map(\.custom) == [nil])
            #expect(
                probe.commits.map(\.key) == [
                    NewProviderKey(provider: ollama, name: "Work", secret: "second", makeActive: true)
                ])
        }
    }
}
