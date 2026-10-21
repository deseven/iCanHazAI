// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// The New Provider wizard sheet: pick a provider (or define a custom one:
/// OpenAI-compatible, Ollama or llama.cpp), enter its API key, check it, and
/// store it encrypted. All state lives in `ProviderWizardModel`. A provider that
/// is already added can't be picked; with an `initialProvider` (adding a key from
/// Manage Keys) the provider step is skipped.
struct ProviderWizardView: View {
    @StateObject private var model: ProviderWizardModel

    /// Called on Finish and Cancel. The owner decides what shows next (the
    /// onboarding sheet when it opened the wizard).
    let onClose: () -> Void

    @FocusState private var keyFocused: Bool
    @FocusState private var nameFocused: Bool

    init(existingKeyNames: [Provider: [String]], initialProvider: Provider? = nil, onClose: @escaping () -> Void) {
        self.init(
            model: ProviderWizardModel(
                existingKeyNames: existingKeyNames,
                initialProvider: initialProvider,
                validate: { provider, custom, key in
                    try await ChatEngine.shared.validateProvider(provider, custom: custom, apiKey: key)
                },
                commit: { newKey, validation in
                    try await ChatEngine.shared.addProvider(
                        newKey.provider, custom: newKey.custom, keyName: newKey.name, apiKey: newKey.secret,
                        makeActive: newKey.makeActive, validation: validation)
                }),
            onClose: onClose)
    }

    init(model: @autoclosure @escaping () -> ProviderWizardModel, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model())
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
                case .type: typeStep
                case .details: detailsStep
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
            nameFocused = newStep == .details
        }
        .onDisappear { model.cancel() }
        .interactiveDismissDisabled()
        .frame(width: 560, height: 480)
    }

    // MARK: - Chrome

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(model.steps) { s in
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.step.rawValue >= s.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(s.title)
                        .font(.caption)
                        .foregroundStyle(model.step == s ? Color.primary : Color.secondary)
                        .fontWeight(model.step == s ? .semibold : .regular)
                }
                if s != model.steps.last {
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
            Text("Choose the provider you want to add.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    providerRow(provider)
                }
                customProviderRow
            }

            Spacer()
        }
    }

    private func providerRow(_ provider: Provider) -> some View {
        let added = model.isAdded(provider)
        return choiceRow(
            title: provider.displayName,
            subtitle: added
                ? "Already added. To add another key, use Provider → Manage Keys…"
                : provider.summary,
            isSelected: !model.isCustomChosen && model.selectedProvider == provider,
            isEnabled: !added,
            onSelect: { model.select(provider) })
    }

    private var customProviderRow: some View {
        choiceRow(
            title: "Custom Provider",
            subtitle: Provider.custom("").summary,
            isSelected: model.isCustomChosen,
            isEnabled: true,
            onSelect: { model.selectCustom() })
    }

    private var typeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What kind of server is it?")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(CustomProviderType.allCases, id: \.self) { type in
                    choiceRow(
                        title: type.displayName,
                        subtitle: type.summary,
                        isSelected: model.customType == type,
                        isEnabled: true,
                        onSelect: { model.selectType(type) })
                }
            }

            Spacer()
        }
    }

    private func choiceRow(
        title: String, subtitle: String, isSelected: Bool, isEnabled: Bool, onSelect: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { onSelect() } }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Describe the \(model.customType.displayName) server you want to connect.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.headline)
                Text(
                    "Tells the provider apart in the model picker and the Provider menu (up to \(CustomProviderConfig.maxNameLength) characters). It must be unique."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                TextField("e.g. Ollama", text: $model.customName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { model.next() }
                if let problem = model.customNameProblem, problem != .empty {
                    Text(problem.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Endpoint")
                    .font(.headline)
                Text(model.customType.endpointHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(model.customType.endpointPlaceholder, text: $model.customEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.next() }
                if !model.customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    model.normalizedCustomEndpoint == nil
                {
                    Text("Enter a valid http:// or https:// URL.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let adjusted = model.adjustedEndpointNote {
                    Text("It will be used as \(adjusted): the app adds the API paths itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Color")
                    .font(.headline)
                Text("Used for the provider's label.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    colorSwatches
                    Spacer()
                    ProviderTag(
                        provider: .custom(model.trimmedCustomName.isEmpty ? "Provider" : model.trimmedCustomName),
                        color: model.customColor)
                }
            }

            Spacer()
        }
        .onAppear { nameFocused = true }
    }

    private var colorSwatches: some View {
        HStack(spacing: 7) {
            ForEach(ProviderColor.allCases, id: \.self) { color in
                Button {
                    model.customColor = color
                } label: {
                    ZStack {
                        Circle()
                            .fill(color.color)
                            .frame(width: 20, height: 20)
                        if model.customColor == color {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(color.textColor)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(color.displayName)
                .accessibilityLabel(color.displayName)
                .accessibilityAddTraits(model.customColor == color ? .isSelected : [])
            }
        }
    }

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let provider = model.targetProvider {
                Text(
                    model.isKeyOptional
                        ? "Enter the API key of \(provider.displayName), if it needs one."
                        : "Enter your \(provider.displayName) API key."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isKeyOptional ? "API Key (optional)" : "API Key")
                        .font(.headline)
                    Text(apiKeyHint(for: provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField(model.isKeyOptional ? "Leave empty for none" : "sk-...", text: $model.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .focused($keyFocused)
                        .onSubmit { model.next() }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Key name")
                        .font(.headline)
                    Text(
                        "Tells this provider's keys apart in the Provider menu (up to \(ProviderWizardModel.maxKeyNameLength) characters)."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    TextField("e.g. Work", text: $model.keyName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.next() }
                    if model.isKeyNameTaken {
                        Text("\(provider.displayName) already has a key with this name.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !model.isFirstKey {
                    Toggle("Use this key for new requests", isOn: $model.makeActive)
                }

                Text("Stored encrypted and tied to this Mac, never in a config file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .onAppear { keyFocused = true }
    }

    private func apiKeyHint(for provider: Provider) -> String {
        guard provider.isCustom else { return provider.apiKeyHint }
        guard model.isKeyOptional else { return "The key this endpoint expects." }
        switch model.customType {
        case .ollama:
            return "Only Ollama's cloud (ollama.com) needs one. Leave it empty for a local server."
        case .llamacpp:
            return "Only needed if llama-server was started with --api-key. Leave it empty otherwise."
        case .openai:
            return "Leave it empty if the endpoint doesn't need one."
        }
    }

    private var checkStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.checkState {
            case .idle, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.isCustomProvider ? "Checking endpoint…" : "Checking key…")
                }
            case .ok(let count):
                HStack(spacing: 8) {
                    if model.isCommitting {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(
                            "\(model.isCustomProvider ? "Connected" : "Key accepted") — \(loaderPluralized(count, singular: "model", plural: "models")) available"
                        )
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
            if let provider = model.targetProvider, let key = model.committedKey {
                Text(model.isFirstKey ? "\(provider.displayName) added" : "\(provider.displayName) key added")
                    .font(.headline)
                if let count = model.modelCount {
                    summaryRow("Models", "\(loaderPluralized(count, singular: "model", plural: "models")) available")
                }
                if let custom = key.custom {
                    summaryRow("Type", custom.type.displayName)
                    summaryRow("Endpoint", custom.endpoint)
                }
                summaryRow("Key name", key.name)
                summaryRow("Active", key.makeActive ? "Yes" : "No — switch to it in the Provider menu")
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
