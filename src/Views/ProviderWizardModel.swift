// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

extension Provider {
    /// Where to create an API key, shown on the key step of the wizard.
    var apiKeyHint: String {
        switch self {
        case .openai: return "Create a key at platform.openai.com/api-keys."
        case .anthropic: return "Create a key at console.anthropic.com/settings/keys."
        case .deepseek: return "Create a key at platform.deepseek.com/api_keys."
        case .openrouter: return "Create a key at openrouter.ai/keys."
        }
    }
}

/// What the wizard hands over to be stored once the key has been checked.
struct NewProviderKey: Sendable, Equatable {
    let provider: Provider
    let name: String
    let secret: String
    /// Whether new requests should use this key right away. Always true for
    /// the first key of a provider.
    let makeActive: Bool
}

/// State and transitions of the New Provider wizard. The view is a thin skin
/// over it.
@MainActor
final class ProviderWizardModel: ObservableObject {

    enum Step: Int, CaseIterable, Identifiable {
        case provider
        case apiKey
        case check
        case summary

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .provider: return "Provider"
            case .apiKey: return "API Key"
            case .check: return "Check"
            case .summary: return "Summary"
            }
        }

        var next: Step? { Step(rawValue: rawValue + 1) }
        var back: Step? { Step(rawValue: rawValue - 1) }
    }

    enum CheckState: Equatable {
        case idle
        case checking
        case ok(modelCount: Int)
        case failed(String)
    }

    typealias Validate = @Sendable (Provider, String) async throws -> ValidationResult
    typealias Commit = @Sendable (NewProviderKey, ValidationResult) async throws -> Void

    static let maxKeyNameLength = 30
    static let defaultKeyName = "Default"

    /// Names of the keys each provider already has.
    let existingKeyNames: [Provider: [String]]
    /// The provider was fixed up front (adding a key from Manage Keys), so the
    /// wizard starts on the key step and has no provider step to return to.
    let skipsProviderStep: Bool
    @Published private(set) var step: Step = .provider
    @Published private(set) var selectedProvider: Provider?
    @Published private(set) var checkState: CheckState = .idle
    @Published var apiKey: String = "" {
        didSet {
            if apiKey != oldValue { invalidateCheck() }
        }
    }
    @Published var keyName: String = "" {
        didSet {
            if keyName.count > Self.maxKeyNameLength { keyName = String(keyName.prefix(Self.maxKeyNameLength)) }
        }
    }
    /// Only offered for a provider that already has keys.
    @Published var makeActive = true
    /// What was stored, for the summary.
    @Published private(set) var committedKey: NewProviderKey?

    private let validate: Validate
    private let commit: Commit
    private var validation: ValidationResult?
    private var validatedKey: String?
    private var checkGeneration = 0
    @Published private(set) var isCommitting = false
    private(set) var checkTask: Task<Void, Never>?
    private(set) var commitTask: Task<Void, Never>?

    init(
        existingKeyNames: [Provider: [String]], initialProvider: Provider? = nil, validate: @escaping Validate,
        commit: @escaping Commit
    ) {
        self.existingKeyNames = existingKeyNames
        self.skipsProviderStep = initialProvider != nil
        self.validate = validate
        self.commit = commit
        let provider =
            initialProvider ?? Provider.allCases.first { existingKeyNames[$0, default: []].isEmpty }
            ?? Provider.allCases.first
        self.selectedProvider = provider
        if initialProvider != nil { step = .apiKey }
        resetKeyFields()
    }

    /// The steps the wizard goes through, for the progress indicator.
    var steps: [Step] {
        skipsProviderStep ? Step.allCases.filter { $0 != .provider } : Step.allCases
    }

    func isAdded(_ provider: Provider) -> Bool { !existingKeyNames[provider, default: []].isEmpty }

    /// True when the selected provider has no key yet, which makes the new one active no matter what.
    var isFirstKey: Bool {
        guard let selectedProvider else { return true }
        return !isAdded(selectedProvider)
    }

    var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedKeyName: String { keyName.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Two keys of one provider can't share a name (ignoring case), since the
    /// menu tells them apart by it.
    var isKeyNameTaken: Bool {
        guard let selectedProvider else { return false }
        let name = trimmedKeyName
        return existingKeyNames[selectedProvider, default: []].contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
        }
    }

    var canGoNext: Bool {
        switch step {
        case .provider: return selectedProvider != nil
        case .apiKey: return !trimmedKey.isEmpty && !trimmedKeyName.isEmpty && !isKeyNameTaken
        case .check:
            if case .ok = checkState { return !isCommitting }
            return false
        case .summary: return false
        }
    }

    var canGoBack: Bool { ((step == .apiKey && !skipsProviderStep) || step == .check) && !isCommitting }

    var canRetry: Bool {
        if case .failed = checkState { return step == .check && !isCommitting }
        return false
    }

    var modelCount: Int? {
        if case .ok(let count) = checkState { return count }
        return nil
    }

    /// Switching providers drops the typed key, which belongs to the previous
    /// one, and restarts the key name and activation choice.
    func select(_ provider: Provider) {
        guard provider != selectedProvider else { return }
        selectedProvider = provider
        apiKey = ""
        resetKeyFields()
        invalidateCheck()
    }

    func next() {
        guard canGoNext, let target = step.next else { return }
        switch step {
        case .provider:
            step = target
        case .apiKey:
            step = target
            startCheck()
        case .check:
            startCommit()
        case .summary:
            break
        }
    }

    func back() {
        guard canGoBack, let target = step.back else { return }
        invalidateCheck()
        step = target
    }

    func retry() {
        guard canRetry else { return }
        startCheck()
    }

    /// Stops an in-flight check. Nothing is stored before the summary step.
    func cancel() {
        invalidateCheck()
    }

    /// Waits for the background work started by the last transition.
    func settle() async {
        await checkTask?.value
        await commitTask?.value
    }

    /// The first key is named `Default`; later ones are left for the user to name.
    private func resetKeyFields() {
        keyName = isFirstKey ? Self.defaultKeyName : ""
        makeActive = true
    }

    private func invalidateCheck() {
        checkGeneration += 1
        checkTask?.cancel()
        checkTask = nil
        validation = nil
        validatedKey = nil
        if step != .summary { checkState = .idle }
    }

    private func startCheck() {
        guard let provider = selectedProvider else { return }
        let key = trimmedKey
        checkGeneration += 1
        let generation = checkGeneration
        validation = nil
        checkState = .checking
        let validate = self.validate
        checkTask = Task { [weak self] in
            let outcome: Result<ValidationResult, Error>
            do {
                outcome = .success(try await validate(provider, key))
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled, self.checkGeneration == generation else { return }
            switch outcome {
            case .success(let result):
                self.validation = result
                self.validatedKey = key
                self.checkState = .ok(modelCount: result.modelCount)
            case .failure(let error):
                self.checkState = .failed(Self.message(for: error))
            }
        }
    }

    /// The key is saved on the way from the check to the summary.
    private func startCommit() {
        guard !isCommitting, let provider = selectedProvider, let validation, let secret = validatedKey else { return }
        isCommitting = true
        let newKey = NewProviderKey(
            provider: provider, name: trimmedKeyName, secret: secret, makeActive: isFirstKey || makeActive)
        let commit = self.commit
        commitTask = Task { [weak self] in
            do {
                try await commit(newKey, validation)
                guard let self else { return }
                self.isCommitting = false
                self.committedKey = newKey
                self.step = .summary
            } catch {
                guard let self else { return }
                self.isCommitting = false
                self.validation = nil
                self.validatedKey = nil
                self.checkState = .failed(Self.message(for: error))
            }
        }
    }

    private static func message(for error: Error) -> String {
        if case ProviderError.invalidKey = error { return "The provider rejected this key." }
        return error.localizedDescription
    }
}
