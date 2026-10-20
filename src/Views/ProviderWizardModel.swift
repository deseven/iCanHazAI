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
        case .custom: return ""
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
    /// The definition of the custom provider this key creates. Nil for a
    /// built-in provider and for another key of an existing custom one.
    var custom: CustomProviderConfig? = nil
}

/// State and transitions of the New Provider wizard. The view is a thin skin
/// over it.
///
/// The wizard adds providers: one that already has a key can't be picked, and
/// more keys for it are added from Manage Keys, which opens the wizard on a
/// fixed provider (`initialProvider`) and skips straight to the key step.
@MainActor
final class ProviderWizardModel: ObservableObject {

    enum Step: Int, CaseIterable, Identifiable {
        case provider
        /// Name, endpoint and color of a new custom provider.
        case details
        case apiKey
        case check
        case summary

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .provider: return "Provider"
            case .details: return "Details"
            case .apiKey: return "API Key"
            case .check: return "Check"
            case .summary: return "Summary"
            }
        }
    }

    enum CheckState: Equatable {
        case idle
        case checking
        case ok(modelCount: Int)
        case failed(String)
    }

    /// Checks the key (an empty one for a custom provider that needs none). A
    /// custom provider that doesn't exist yet comes with its definition.
    typealias Validate = @Sendable (Provider, CustomProviderConfig?, String) async throws -> ValidationResult
    typealias Commit = @Sendable (NewProviderKey, ValidationResult) async throws -> Void

    static let maxKeyNameLength = 30
    static let defaultKeyName = "Default"

    /// Names of the keys each provider already has.
    let existingKeyNames: [Provider: [String]]
    /// The provider was fixed up front (adding a key from Manage Keys), so the
    /// wizard starts on the key step and has no provider step to return to.
    let skipsProviderStep: Bool
    @Published private(set) var step: Step = .provider
    /// The built-in provider picked in the list, or the fixed one. Nil while
    /// the custom provider entry is picked.
    @Published private(set) var selectedProvider: Provider?
    /// The "Custom Provider" entry is picked: a new custom provider is being defined.
    @Published private(set) var isCustomChosen = false
    @Published var customName: String = "" {
        didSet {
            if customName.count > CustomProviderConfig.maxNameLength {
                customName = String(customName.prefix(CustomProviderConfig.maxNameLength))
            }
            if customName != oldValue { invalidateCheck() }
        }
    }
    @Published var customEndpoint: String = "" {
        didSet {
            if customEndpoint != oldValue { invalidateCheck() }
        }
    }
    @Published var customColor: ProviderColor = .default
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
        if let initialProvider {
            selectedProvider = initialProvider
            step = .apiKey
        } else if let free = Provider.allCases.first(where: { existingKeyNames[$0, default: []].isEmpty }) {
            selectedProvider = free
        } else {
            isCustomChosen = true
        }
        resetKeyFields()
    }

    /// The steps the wizard goes through, for the progress indicator.
    var steps: [Step] {
        Step.allCases.filter { step in
            switch step {
            case .provider: return !skipsProviderStep
            case .details: return isCustomChosen
            default: return true
            }
        }
    }

    func isAdded(_ provider: Provider) -> Bool { !existingKeyNames[provider, default: []].isEmpty }

    /// The provider the key goes to. For a new custom provider, once its name is usable.
    var targetProvider: Provider? {
        guard isCustomChosen else { return selectedProvider }
        return customNameProblem == nil ? .custom(trimmedCustomName) : nil
    }

    /// Whether the provider is a custom one, new or existing.
    var isCustomProvider: Bool { isCustomChosen || (selectedProvider?.isCustom ?? false) }

    /// True when the target provider has no key yet, which makes the new one active no matter what.
    var isFirstKey: Bool {
        guard let targetProvider else { return true }
        return !isAdded(targetProvider)
    }

    var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedKeyName: String { keyName.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// An endpoint that needs no key is fine, so a new custom provider may have none.
    var isKeyOptional: Bool { isCustomChosen }

    // MARK: - Custom provider

    var trimmedCustomName: String { customName.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Names are unique among custom providers (ignoring case) and can't be a built-in one.
    var customNameProblem: CustomProviderConfig.NameProblem? {
        let existing = existingKeyNames.keys.filter(\.isCustom).map(\.rawValue)
        return CustomProviderConfig.problem(withName: customName, existing: existing)
    }

    /// The endpoint as it will be used: trimmed, without trailing slashes. Nil
    /// when it isn't an http(s) URL.
    var normalizedCustomEndpoint: String? { CustomProviderConfig.normalizedEndpoint(customEndpoint) }

    /// The custom provider being defined, once its name and endpoint are usable.
    var newCustomProvider: CustomProviderConfig? {
        guard isCustomChosen, customNameProblem == nil, let endpoint = normalizedCustomEndpoint else { return nil }
        return CustomProviderConfig(name: trimmedCustomName, endpoint: endpoint, color: customColor.rawValue)
    }

    // MARK: - Navigation

    /// Two keys of one provider can't share a name (ignoring case), since the
    /// menu tells them apart by it.
    var isKeyNameTaken: Bool {
        guard let targetProvider else { return false }
        let name = trimmedKeyName
        return existingKeyNames[targetProvider, default: []].contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
        }
    }

    var canGoNext: Bool {
        switch step {
        case .provider: return isCustomChosen || (selectedProvider.map { !isAdded($0) } ?? false)
        case .details: return newCustomProvider != nil
        case .apiKey:
            return (isKeyOptional || !trimmedKey.isEmpty) && !trimmedKeyName.isEmpty && !isKeyNameTaken
        case .check:
            if case .ok = checkState { return !isCommitting }
            return false
        case .summary: return false
        }
    }

    var canGoBack: Bool {
        (step == .details || (step == .apiKey && !skipsProviderStep) || step == .check) && !isCommitting
    }

    var canRetry: Bool {
        if case .failed = checkState { return step == .check && !isCommitting }
        return false
    }

    var modelCount: Int? {
        if case .ok(let count) = checkState { return count }
        return nil
    }

    /// Picks a built-in provider. One that already has a key can't be picked:
    /// its keys are managed from the Provider menu.
    func select(_ provider: Provider) {
        guard !skipsProviderStep, !provider.isCustom, !isAdded(provider),
            isCustomChosen || provider != selectedProvider
        else { return }
        isCustomChosen = false
        selectedProvider = provider
        restartKeyEntry()
    }

    /// Picks the "Custom Provider" entry.
    func selectCustom() {
        guard !skipsProviderStep, !isCustomChosen else { return }
        isCustomChosen = true
        selectedProvider = nil
        restartKeyEntry()
    }

    func next() {
        guard canGoNext, let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        let target = steps[index + 1]
        switch step {
        case .provider, .details:
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
        guard canGoBack, let index = steps.firstIndex(of: step), index > 0 else { return }
        invalidateCheck()
        step = steps[index - 1]
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

    /// Switching providers drops the typed key, which belongs to the previous
    /// one, and restarts the key name and activation choice.
    private func restartKeyEntry() {
        apiKey = ""
        resetKeyFields()
        invalidateCheck()
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
        guard let provider = targetProvider else { return }
        let key = trimmedKey
        let custom = newCustomProvider
        checkGeneration += 1
        let generation = checkGeneration
        validation = nil
        checkState = .checking
        let validate = self.validate
        checkTask = Task { [weak self] in
            let outcome: Result<ValidationResult, Error>
            do {
                outcome = .success(try await validate(provider, custom, key))
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
        guard !isCommitting, let provider = targetProvider, let validation, let secret = validatedKey else { return }
        isCommitting = true
        let newKey = NewProviderKey(
            provider: provider, name: trimmedKeyName, secret: secret, makeActive: isFirstKey || makeActive,
            custom: newCustomProvider)
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
