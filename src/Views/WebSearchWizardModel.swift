// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

extension WebSearchProviderKind {
    /// The providers the wizard offers, in display order.
    static let selectable: [WebSearchProviderKind] = [.exa, .linkup, .tavily]

    var displayName: String {
        switch self {
        case .none: return "None"
        case .exa: return "Exa"
        case .linkup: return "Linkup"
        case .tavily: return "Tavily"
        }
    }

    /// One line shown on the provider step.
    var summary: String {
        switch self {
        case .none: return ""
        case .exa: return "AI-native search that returns page text with the results"
        case .linkup: return "Web search and page fetching, with optional JavaScript rendering"
        case .tavily: return "Search and extraction built for AI agents, with an advanced extraction mode"
        }
    }

    /// Where to create an API key, shown on the key step.
    var apiKeyHint: String {
        switch self {
        case .none: return ""
        case .exa: return "Create a key at dashboard.exa.ai/api-keys."
        case .linkup: return "Create a key at app.linkup.so."
        case .tavily: return "Create a key at app.tavily.com/home."
        }
    }
}

/// State and transitions of the Web Search setup wizard. The view is a thin
/// skin over it. Nothing is stored until the final step succeeds.
@MainActor
final class WebSearchWizardModel: ObservableObject {

    enum Step: Int, CaseIterable, Identifiable {
        case provider
        case apiKey
        case check

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .provider: return "Provider"
            case .apiKey: return "API Key"
            case .check: return "Check"
            }
        }

        var back: Step? { Step(rawValue: rawValue - 1) }
    }

    enum CheckState: Equatable {
        case idle
        case checking
        case ok
        case failed(String)
    }

    typealias Validate = @Sendable (WebSearchProviderKind, String) async throws -> Void
    typealias Commit = @Sendable (WebSearchProviderKind, String) async throws -> Void

    @Published private(set) var step: Step = .provider
    @Published private(set) var selectedProvider: WebSearchProviderKind
    @Published private(set) var checkState: CheckState = .idle
    @Published private(set) var isCommitting = false
    /// True once the checked key has been stored; the view closes the wizard.
    @Published private(set) var isCommitted = false
    @Published var apiKey: String = "" {
        didSet {
            if apiKey != oldValue { invalidateCheck() }
        }
    }

    private let validate: Validate
    private let commit: Commit
    private var validatedKey: String?
    private var checkGeneration = 0
    private(set) var checkTask: Task<Void, Never>?
    private(set) var commitTask: Task<Void, Never>?

    /// `initialProvider` preselects a provider that was already chosen
    /// (e.g. set in `config.toml` without a key); otherwise the first is used.
    init(
        initialProvider: WebSearchProviderKind = .none, validate: @escaping Validate, commit: @escaping Commit
    ) {
        self.selectedProvider =
            WebSearchProviderKind.selectable.contains(initialProvider) ? initialProvider : .exa
        self.validate = validate
        self.commit = commit
    }

    var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canGoNext: Bool {
        switch step {
        case .provider: return true
        case .apiKey: return !trimmedKey.isEmpty
        case .check:
            if case .ok = checkState { return !isCommitting && !isCommitted }
            return false
        }
    }

    var canGoBack: Bool { step != .provider && !isCommitting && !isCommitted }

    var canRetry: Bool {
        if case .failed = checkState { return step == .check && !isCommitting }
        return false
    }

    /// Switching providers drops the typed key, which belongs to the previous one.
    func select(_ provider: WebSearchProviderKind) {
        guard provider != selectedProvider, WebSearchProviderKind.selectable.contains(provider) else { return }
        selectedProvider = provider
        apiKey = ""
        invalidateCheck()
    }

    /// Advances; on the check step this stores the checked key (Finish).
    func next() {
        guard canGoNext else { return }
        switch step {
        case .provider:
            step = .apiKey
        case .apiKey:
            step = .check
            startCheck()
        case .check:
            startCommit()
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

    /// Stops an in-flight check. Nothing is stored before the check succeeds.
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
        validatedKey = nil
        if !isCommitting && !isCommitted { checkState = .idle }
    }

    private func startCheck() {
        let provider = selectedProvider
        let key = trimmedKey
        checkGeneration += 1
        let generation = checkGeneration
        validatedKey = nil
        checkState = .checking
        let validate = self.validate
        checkTask = Task { [weak self] in
            let outcome: Result<Void, Error>
            do {
                try await validate(provider, key)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled, self.checkGeneration == generation else { return }
            switch outcome {
            case .success:
                self.validatedKey = key
                self.checkState = .ok
            case .failure(let error):
                self.checkState = .failed(Self.message(for: error, provider: provider))
            }
        }
    }

    /// The key is stored on the way out of the check step.
    private func startCommit() {
        guard !isCommitting, case .ok = checkState, let secret = validatedKey else { return }
        let provider = selectedProvider
        isCommitting = true
        let commit = self.commit
        commitTask = Task { [weak self] in
            do {
                try await commit(provider, secret)
                guard let self else { return }
                self.isCommitting = false
                self.isCommitted = true
            } catch {
                guard let self else { return }
                self.isCommitting = false
                self.validatedKey = nil
                self.checkState = .failed("Couldn't save the API key: \(error.localizedDescription)")
            }
        }
    }

    static func message(for error: Error, provider: WebSearchProviderKind) -> String {
        if case ProviderError.invalidKey = error { return "\(provider.displayName) rejected this API key." }
        return error.localizedDescription
    }
}
