// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// The New Provider wizard sheet: pick a provider, enter its API key, check
/// it, and store it encrypted. All state lives in `ProviderWizardModel`.
struct ProviderWizardView: View {
    @StateObject private var model: ProviderWizardModel

    /// Called on Finish and Cancel. The owner decides what shows next (the
    /// onboarding sheet when it opened the wizard).
    let onClose: () -> Void

    @FocusState private var keyFocused: Bool

    init(addedProviders: Set<Provider>, onClose: @escaping () -> Void) {
        _model = StateObject(
            wrappedValue: ProviderWizardModel(
                addedProviders: addedProviders,
                validate: { provider, key in
                    try await ChatEngine.shared.validateProvider(provider, apiKey: key)
                },
                commit: { provider, key, validation in
                    try await ChatEngine.shared.addProvider(provider, apiKey: key, validation: validation)
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
                case .summary: summaryStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)

            Divider()

            navigationBar
                .padding(12)
        }
        .onChange(of: model.step) { (_: ProviderWizardModel.Step, newStep: ProviderWizardModel.Step) in
            debugLog("Wizard", "Provider wizard step → \(newStep.title)")
            keyFocused = newStep == .apiKey
        }
        .onDisappear { model.cancel() }
        .interactiveDismissDisabled()
        .frame(width: 560, height: 480)
    }

    // MARK: - Chrome

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(ProviderWizardModel.Step.allCases) { s in
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.step.rawValue >= s.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(s.title)
                        .font(.caption)
                        .foregroundStyle(model.step == s ? Color.primary : Color.secondary)
                        .fontWeight(model.step == s ? .semibold : .regular)
                }
                if s != ProviderWizardModel.Step.allCases.last {
                    Spacer()
                }
            }
        }
    }

    private var navigationBar: some View {
        HStack {
            if model.step != .summary {
                Button("Cancel") {
                    model.cancel()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }

            Spacer()

            if model.step == .summary {
                Button("Finish") { onClose() }
                    .keyboardShortcut(.defaultAction)
            } else {
                if model.canGoBack {
                    Button("Back") { model.back() }
                }
                if model.canRetry {
                    Button("Retry") { model.retry() }
                }
                Button("Next") { model.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canGoNext)
            }
        }
    }

    // MARK: - Steps

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.allProvidersAdded {
                Text("All supported providers are already added.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose the provider you want to add.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    providerRow(provider)
                }
            }

            Spacer()
        }
    }

    private func providerRow(_ provider: Provider) -> some View {
        let added = model.isAdded(provider)
        let selected = model.selectedProvider == provider
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .fontWeight(.medium)
                Text(added ? "Already added" : provider.summary)
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
        .opacity(added ? 0.4 : 1)
    }

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let provider = model.selectedProvider {
                Text("Enter your \(provider.displayName) API key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.headline)
                    Text(provider.apiKeyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("sk-...", text: $model.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .focused($keyFocused)
                        .onSubmit { model.next() }
                }

                Text("Stored encrypted and tied to this Mac, never in a config file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                    Text("Checking key…")
                }
            case .ok(let count):
                HStack(spacing: 8) {
                    if model.isCommitting {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Key accepted — \(loaderPluralized(count, singular: "model", plural: "models")) available")
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

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let provider = model.selectedProvider {
                Text("\(provider.displayName) added")
                    .font(.headline)
                if let count = model.modelCount {
                    summaryRow("Models", "\(loaderPluralized(count, singular: "model", plural: "models")) available")
                }
                summaryRow("Key name", "Default")
            }

            Spacer()

            Text("Models are picked per chat.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(label):")
                .fontWeight(.medium)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
