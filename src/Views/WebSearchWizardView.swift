// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The Web Search setup wizard sheet: pick a provider, enter its API key, and
/// check it. The key is stored only when the check succeeds and Finish is
/// pressed. All state lives in `WebSearchWizardModel`.
struct WebSearchWizardView: View {
    @StateObject private var model: WebSearchWizardModel

    /// Called on Finish and Cancel; the owner returns to Preferences.
    let onClose: () -> Void

    @FocusState private var keyFocused: Bool

    init(initialProvider: WebSearchProviderKind, onClose: @escaping () -> Void) {
        _model = StateObject(
            wrappedValue: WebSearchWizardModel(
                initialProvider: initialProvider,
                validate: { provider, token in
                    try await WebSearchTokenValidator.validate(provider: provider, token: token)
                },
                commit: { provider, token in
                    try await ConfigManager.shared.setUpWebSearch(provider: provider, token: token)
                }))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            Group {
                switch model.step {
                case .provider: providerStep
                case .apiKey: apiKeyStep
                case .check: checkStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)

            Divider()

            navigationBar
                .padding(12)
        }
        .onChange(of: model.step) { (_: WebSearchWizardModel.Step, newStep: WebSearchWizardModel.Step) in
            debugLog("Wizard", "Web search wizard step → \(newStep.title)")
            keyFocused = newStep == .apiKey
        }
        .onChange(of: model.isCommitted) { (_: Bool, committed: Bool) in
            if committed { onClose() }
        }
        .onDisappear { model.cancel() }
        .interactiveDismissDisabled()
        .frame(width: 560, height: 400)
    }

    // MARK: - Chrome

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(WebSearchWizardModel.Step.allCases) { s in
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.step.rawValue >= s.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(s.title)
                        .font(.caption)
                        .foregroundStyle(model.step == s ? Color.primary : Color.secondary)
                        .fontWeight(model.step == s ? .semibold : .regular)
                }
                if s != WebSearchWizardModel.Step.allCases.last {
                    Spacer()
                }
            }
        }
    }

    private var navigationBar: some View {
        HStack {
            Button("Cancel") {
                model.cancel()
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isCommitting)

            Spacer()

            if model.canGoBack {
                Button("Back") { model.back() }
            }
            if model.canRetry {
                Button("Retry") { model.retry() }
            }
            Button(model.step == .check ? "Finish" : "Next") { model.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canGoNext)
        }
    }

    // MARK: - Steps

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the provider that will power web search and page extraction.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(WebSearchProviderKind.selectable, id: \.self) { provider in
                    providerRow(provider)
                }
            }

            Spacer()
        }
    }

    private func providerRow(_ provider: WebSearchProviderKind) -> some View {
        let selected = model.selectedProvider == provider
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .fontWeight(.medium)
                Text(provider.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(provider) }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
    }

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter your \(model.selectedProvider.displayName) API key.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("API Key")
                    .font(.headline)
                Text(model.selectedProvider.apiKeyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("API key", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFocused)
                    .onSubmit { model.next() }
            }

            Text("Stored encrypted and tied to this Mac, never in a config file.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .onAppear { keyFocused = true }
    }

    private var checkStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.checkState {
            case .idle, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking API key…")
                }
            case .ok:
                HStack(spacing: 8) {
                    if model.isCommitting || model.isCommitted {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("\(model.selectedProvider.displayName) accepted the API key")
                    }
                }
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
    }
}
