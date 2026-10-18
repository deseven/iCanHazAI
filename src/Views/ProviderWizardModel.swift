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
    typealias Commit = @Sendable (Provider, String, ValidationResult) async throws -> Void

    let addedProviders: Set<Provider>
    @Published private(set) var step: Step = .provider
    @Published private(set) var selectedProvider: Provider?
    @Published private(set) var checkState: CheckState = .idle
    @Published var apiKey: String = "" {
        didSet {
            if apiKey != oldValue { invalidateCheck() }
        }
    }

    private let validate: Validate
    private let commit: Commit
    private var validation: ValidationResult?
    private var validatedKey: String?
    private var checkGeneration = 0
    @Published private(set) var isCommitting = false
    private(set) var checkTask: Task<Void, Never>?
    private(set) var commitTask: Task<Void, Never>?

    init(addedProviders: Set<Provider>, validate: @escaping Validate, commit: @escaping Commit) {
        self.addedProviders = addedProviders
        self.validate = validate
        self.commit = commit
        self.selectedProvider = Provider.allCases.first { !addedProviders.contains($0) }
    }

    var availableProviders: [Provider] { Provider.allCases.filter { !isAdded($0) } }
    var allProvidersAdded: Bool { availableProviders.isEmpty }

    func isAdded(_ provider: Provider) -> Bool { addedProviders.contains(provider) }

    var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canGoNext: Bool {
        switch step {
        case .provider: return selectedProvider != nil
        case .apiKey: return !trimmedKey.isEmpty
        case .check:
            if case .ok = checkState { return !isCommitting }
            return false
        case .summary: return false
        }
    }

    var canGoBack: Bool { (step == .apiKey || step == .check) && !isCommitting }

    var canRetry: Bool {
        if case .failed = checkState { return step == .check && !isCommitting }
        return false
    }

    var modelCount: Int? {
        if case .ok(let count) = checkState { return count }
        return nil
    }

    /// Ignored for providers that are already added. Switching providers
    /// drops the typed key, which belongs to the previous one.
    func select(_ provider: Provider) {
        guard !isAdded(provider), provider != selectedProvider else { return }
        selectedProvider = provider
        apiKey = ""
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
        guard !isCommitting, let provider = selectedProvider, let validation, let key = validatedKey else { return }
        isCommitting = true
        let commit = self.commit
        commitTask = Task { [weak self] in
            do {
                try await commit(provider, key, validation)
                guard let self else { return }
                self.isCommitting = false
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
