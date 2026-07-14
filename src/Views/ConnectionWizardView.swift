// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import AppKit

/// A multi-step wizard for creating a new connection. Runs in its own window
/// and walks the user through provider selection, credentials, model selection,
/// a connection test, naming, and a final summary.
struct ConnectionWizardView: View {

    /// Called after the wizard finishes (connection saved + optional default
    /// prompts handled). The view model uses this to refresh its state.
    var onFinish: (() -> Void)?

    /// When true, cancelling the wizard (Cancel button or window close
    /// button) terminates the app. Used in the clean-state flow where there
    /// are no connections to work with, so dismissing the wizard is pointless.
    var closeAppOnCancel: Bool = false

    /// The wizard steps, in order.
    private enum Step: Int, CaseIterable, Identifiable, Comparable {
        case provider
        case credentials
        case model
        case test
        case name
        case finish

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .provider:    return "Select LLM Provider"
            case .credentials: return "Connection Credentials"
            case .model:       return "Model Selection"
            case .test:        return "Connection Test"
            case .name:        return "Connection Name"
            case .finish:      return "Finish"
            }
        }

        var index: Int { rawValue }
        var isFirst: Bool { self == .provider }
        var isLast: Bool { self == .finish }
        var next: Step? { Step(rawValue: rawValue + 1) }
        var back: Step? { Step(rawValue: rawValue - 1) }

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    // MARK: - Wizard state

    /// Currently visible step.
    @State private var step: Step = .provider

    // Step 1 — provider
    /// The provider preset chosen by the user.
    @State private var providerPreset: ProviderPreset = .openai

    // Step 2 — credentials
    @State private var endpoint: String = ""
    @State private var token: String = ""
    /// Error shown under the credentials form when model-list fetch fails.
    @State private var credentialsError: String?
    /// Whether a model-list request is in flight (disables Next).
    @State private var isFetchingModels: Bool = false

    // Step 3 — model
    /// Models returned by the provider, with capability info where reported.
    @State private var availableModels: [ModelInfo] = []
    /// The selected model id.
    @State private var selectedModel: String = ""
    /// Search text for the model dropdown.
    @State private var modelSearch: String = ""
    /// Whether the selected model supports image input. Auto-set from the
    /// provider's reported capability when available; user-editable otherwise.
    @State private var imageInput: Bool = false

    // Step 4 — test
    /// Whether the "say hi" test request is in flight.
    @State private var isTesting: Bool = false
    /// The response text from the test, once it completes.
    @State private var testResponse: String?
    /// The error from the test, if it failed.
    @State private var testError: String?

    // Step 5 — name
    @State private var connectionName: String = ""

    // Step 6 — finish
    /// The URL of the saved connection file, set when we write it on entering
    /// the finish step.
    @State private var savedFileURL: URL?

    // MARK: - Focus state

    /// Identifies a focusable field in the wizard. Used with `@FocusState`
    /// so that switching steps auto-focuses the primary input.
    private enum Field: Hashable {
        case endpoint
        case token
        case modelSearch
        case modelText
        case connectionName
    }

    @FocusState private var focusedField: Field?

    // MARK: - Provider presets

    /// The provider presets offered in step 1. Only Anthropic maps to the
    /// `anthropic` connection type; everything else is OpenAI-compatible.
    enum ProviderPreset: String, CaseIterable, Identifiable {
        case openai
        case anthropic
        case openrouter
        case deepseek
        case other

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openai:     return "OpenAI"
            case .anthropic:  return "Anthropic"
            case .openrouter: return "OpenRouter"
            case .deepseek:   return "DeepSeek"
            case .other:      return "Other (OpenAI-compatible)"
            }
        }

        var summary: String {
            switch self {
            case .openai:     return "The official OpenAI API (api.openai.com)."
            case .anthropic:  return "The official Anthropic API (api.anthropic.com). Uses the Anthropic connection type."
            case .openrouter: return "A gateway to many models via openrouter.ai/api/v1."
            case .deepseek:   return "The DeepSeek API (api.deepseek.com), OpenAI-compatible."
            case .other:      return "Any OpenAI-compatible endpoint. You provide the base URL."
            }
        }

        /// The connection provider type this preset maps to.
        var connectionProvider: ConnectionProvider {
            self == .anthropic ? .anthropic : .openai
        }

        /// The default endpoint for this preset, or nil when the endpoint is
        /// hidden (uses the provider's default base URL).
        var defaultEndpoint: String? {
            switch self {
            case .openai:     return nil
            case .anthropic:  return nil
            case .openrouter: return "https://openrouter.ai/api/v1"
            case .deepseek:   return "https://api.deepseek.com/v1"
            case .other:      return ""
            }
        }

        /// Whether the endpoint field should be shown for this preset.
        var showsEndpoint: Bool { self == .other }

        /// Short label used when generating the default connection name.
        /// Keeps the provider's display capitalization (e.g. "OpenRouter").
        var namePrefix: String {
            switch self {
            case .openai:     return "OpenAI"
            case .anthropic:  return "Anthropic"
            case .openrouter: return "OpenRouter"
            case .deepseek:   return "DeepSeek"
            case .other:      return "Custom"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            Group {
                switch step {
                case .provider:    providerStep
                case .credentials: credentialsStep
                case .model:       modelStep
                case .test:        testStep
                case .name:        nameStep
                case .finish:      finishStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)

            Divider()

            navigationBar
                .padding(12)
        }
        .onChange(of: step) { (_: Step, newStep: Step) in
            debugLog("Wizard", "Connection wizard step → \(newStep.title)")
            switch newStep {
            case .credentials:
                if providerPreset.showsEndpoint {
                    focusedField = .endpoint
                } else {
                    focusedField = .token
                }
            case .model:
                if useFreeTextModel {
                    focusedField = .modelText
                } else {
                    focusedField = .modelSearch
                }
            case .name:
                focusedField = .connectionName
            default:
                focusedField = nil
            }
        }
        .frame(width: 560, height: 480)
    }

    // MARK: - Step indicator

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases) { s in
                HStack(spacing: 6) {
                    Circle()
                        .fill(step >= s ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(s.title)
                        .font(.caption)
                        .foregroundStyle(step == s ? Color.primary : Color.secondary)
                        .fontWeight(step == s ? .semibold : .regular)
                }
                if s != Step.allCases.last {
                    Spacer()
                }
            }
        }
    }

    // MARK: - Navigation bar

    private var navigationBar: some View {
        HStack {
            Button("Cancel") {
                handleCancel()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            // No going back once the connection file has been written to disk
            // (the finish step), since that would leave a stale file behind.
            if !step.isFirst && !step.isLast {
                Button("Back") {
                    if let b = step.back {
                        resetState(after: b)
                        step = b
                    }
                }
            }

            if step.isLast {
                Button("Finish") {
                    onFinish?()
                    closeWindow()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button(step == .credentials ? "Next" : "Next") {
                    goNext()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canProceed)
            }
        }
    }

    /// Whether the current step allows moving forward.
    private var canProceed: Bool {
        switch step {
        case .provider:
            return true
        case .credentials:
            if providerPreset.showsEndpoint && endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            if providerPreset != .other && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            return !isFetchingModels
        case .model:
            return !selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .test:
            // The test must complete successfully (non-empty response, no
            // provider error) before the user can move on.
            return !isTesting && testResponse != nil && testError == nil
        case .name:
            return !connectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .finish:
            return true
        }
    }

    // MARK: - Step transitions

    private func goNext() {
        guard let n = step.next else { return }
        switch step {
        case .credentials:
            fetchModelsThenAdvance()
        case .model:
            resetTestState()
            step = n
        case .name:
            saveConnection()
            step = n
        default:
            step = n
        }
    }

    /// Clears the connection test results so the test re-runs from scratch
    /// the next time the test step appears. This ensures that going back,
    /// changing the model (or credentials), and pressing Next again repeats
    /// the validation exactly as the first time.
    private func resetTestState() {
        isTesting = false
        testResponse = nil
        testError = nil
    }

    /// Resets all wizard state that belongs to steps after the given step.
    /// Called when the user presses Back, so that changing an earlier choice
    /// (e.g. switching providers) doesn't leave stale data in later steps
    /// (e.g. a model from the previous provider still selected).
    private func resetState(after step: Step) {
        // Steps are ordered: provider(0) < credentials(1) < model(2) < test(3) < name(4) < finish(5)
        if step < .credentials {
            endpoint = ""
            token = ""
            credentialsError = nil
            isFetchingModels = false
        }
        if step < .model {
            availableModels = []
            selectedModel = ""
            modelSearch = ""
            imageInput = false
        }
        if step < .test {
            resetTestState()
        }
        if step < .name {
            connectionName = ""
        }
        if step < .finish {
            savedFileURL = nil
        }
    }

    private func closeWindow() {
        NSApp.windows.first(where: { $0.identifier?.rawValue == "connection-wizard" })?.close()
    }

    /// Handles the Cancel button and window-close button. In the clean-state
    /// flow (`closeAppOnCancel`) there's no connection to work with, so
    /// cancelling terminates the app instead of just closing the window.
    private func handleCancel() {
        if closeAppOnCancel {
            NSApp.terminate(nil)
        } else {
            closeWindow()
        }
    }

    // MARK: - Step 1: Provider

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the LLM provider you want to connect to.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(ProviderPreset.allCases) { preset in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: providerPreset == preset ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(providerPreset == preset ? Color.accentColor : Color.secondary)
                            .onTapGesture { providerPreset = preset }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.displayName)
                                .fontWeight(.medium)
                            Text(preset.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { providerPreset = preset }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(providerPreset == preset ? Color.accentColor.opacity(0.1) : Color.clear)
                    )
                }
            }

            Spacer()
        }
    }

    // MARK: - Step 2: Credentials

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter the credentials for \(providerPreset.displayName).")
                .font(.callout)
                .foregroundStyle(.secondary)

            if providerPreset.showsEndpoint {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Endpoint")
                        .font(.headline)
                    Text("The base URL of the OpenAI-compatible API, e.g. https://my-provider.com/v1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .endpoint)
                        .onSubmit { goNext() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(providerPreset == .other ? "API Key (optional)" : "API Key")
                    .font(.headline)
                Text(apiKeyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("sk-...", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .token)
                    .onSubmit { goNext() }
            }

            if let err = credentialsError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isFetchingModels {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching available models…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    /// Fetches the model list and advances to the model step on success. On
    /// failure, stays on the credentials step and shows the error in red.
    private func fetchModelsThenAdvance() {
        credentialsError = nil
        isFetchingModels = true

        let preset = providerPreset
        let endpointValue = preset.showsEndpoint ? endpoint : (preset.defaultEndpoint ?? "")
        let tokenValue = token
        let provider = preset.connectionProvider

        Task {
            do {
                let models = try await ChatService.shared.listModels(provider: provider, baseUrl: endpointValue, apiKey: tokenValue)
                await MainActor.run {
                    self.availableModels = models
                    self.selectedModel = models.first?.id ?? ""
                    // Auto-set imageInput from the first model's reported
                    // capability, if the provider reports one.
                    if let cap = models.first?.imageInput {
                        self.imageInput = cap
                    }
                    self.isFetchingModels = false
                    self.step = .model
                }
            } catch {
                await MainActor.run {
                    self.credentialsError = "Failed to fetch models: \(error.localizedDescription)"
                    self.isFetchingModels = false
                }
            }
        }
    }

    // MARK: - Step 3: Model

    private var filteredModels: [ModelInfo] {
        let q = modelSearch.lowercased()
        guard !q.isEmpty else { return availableModels }
        return availableModels.filter { $0.id.lowercased().contains(q) }
    }

    /// Whether the model list returned by the provider is empty, in which
    /// case we fall back to a free-text model field.
    private var useFreeTextModel: Bool { availableModels.isEmpty }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if useFreeTextModel {
                Text("Enter the model id to use (e.g. claude-3-5-sonnet-latest).")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.headline)
                    TextField("model-id", text: $selectedModel)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .modelText)
                        .onSubmit { goNext() }
                }
            } else {
                Text("Select a model from the list returned by the provider. You can search to filter.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.headline)
                    TextField("Search models…", text: $modelSearch)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .modelSearch)
                        .onSubmit { goNext() }
                        .padding(.bottom, 2)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredModels, id: \.id) { model in
                                HStack(spacing: 8) {
                                    Image(systemName: selectedModel == model.id ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(selectedModel == model.id ? Color.accentColor : Color.secondary)
                                    Text(model.id)
                                        .font(.callout)
                                    Spacer()
                                }
                                .padding(.vertical, 5)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedModel = model.id
                                    if let cap = model.imageInput { imageInput = cap }
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(selectedModel == model.id ? Color.accentColor.opacity(0.1) : Color.clear)
                                )
                            }
                            if filteredModels.isEmpty {
                                Text("No models match “\(modelSearch)”.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2))
                    )
                }
            }

            Toggle("The model supports image input", isOn: $imageInput)
                .padding(.top, 4)

            Spacer()
        }
    }

    // MARK: - Step 4: Test

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("We'll send a non-streaming “say hi” request to verify the connection works. The test must succeed before you can continue.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Test Request: ")
                        .fontWeight(.medium)
                    Text("say hi")
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Test Response: ")
                        .fontWeight(.medium)
                    if isTesting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                        }
                    } else if let err = testError {
                        Text(err)
                            .foregroundStyle(.red)
                    } else if let resp = testResponse {
                        Text(resp)
                            .textSelection(.enabled)
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { runTestIfNeeded() }

            Spacer()
        }
    }

    /// Runs the "say hi" test once when the step appears.
    private func runTestIfNeeded() {
        guard !isTesting && testResponse == nil && testError == nil else { return }
        runTest()
    }

    /// Sends the non-streaming "say hi" request and records either the
    /// response text (success) or an error message (failure). An empty
    /// response is treated as a failure: it usually means the request was
    /// rejected (e.g. invalid API key or unavailable model) but the provider
    /// returned 200 with no content.
    private func runTest() {
        isTesting = true

        let conn = buildConnection(name: "wizard-test")
        Task {
            do {
                let reply = try await ChatService.shared.complete(
                    connection: conn,
                    messages: [ChatMessage(role: .user, content: "say hi")]
                )
                await MainActor.run {
                    if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.testError = "The model returned an empty response. This usually means the API key is invalid or the selected model is unavailable."
                    } else {
                        self.testResponse = reply
                    }
                    self.isTesting = false
                }
            } catch {
                await MainActor.run {
                    self.testError = error.localizedDescription
                    self.isTesting = false
                }
            }
        }
    }

    // MARK: - Step 5: Name

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a name for this connection. It determines the connection file name on disk.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Connection Name")
                    .font(.headline)
                TextField("my-connection", text: $connectionName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .connectionName)
                    .onSubmit { goNext() }
                Text("File: connections/\(providerPreset.connectionProvider.rawValue)/\(sanitizedFilename(connectionName)).jsonc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .onAppear {
            if connectionName.isEmpty {
                connectionName = defaultConnectionName()
            }
        }
    }

    // MARK: - Step 6: Finish

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection created. Here's a summary:")
                .font(.callout)
                .foregroundStyle(.secondary)

            summaryRow("Provider", providerPreset.displayName)
            summaryRow("Model", selectedModel)
            summaryRow("Name", connectionName)
            summaryRow("Image input", imageInput ? "Yes" : "No")
            if providerPreset.showsEndpoint {
                summaryRow("Endpoint", endpoint)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("For advanced configuration you can manually edit the connection file:")
                    .font(.callout)
                if let url = savedFileURL {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
    }

    @ViewBuilder
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

    // MARK: - Helpers

    /// Builds a transient `Connection` from the current wizard state.
    private func buildConnection(name: String) -> Connection {
        Connection(
            provider: providerPreset.connectionProvider,
            name: name,
            baseUrl: effectiveBaseUrl,
            apiKey: token.isEmpty ? nil : token,
            model: selectedModel,
            imageInput: imageInput,
            requestParameters: nil
        )
    }

    /// The base URL to store, or nil when the provider uses its default.
    private var effectiveBaseUrl: String? {
        switch providerPreset {
        case .openai, .anthropic:
            return nil
        case .openrouter, .deepseek:
            return providerPreset.defaultEndpoint
        case .other:
            return endpoint
        }
    }

    /// Default name: "{provider}-{model}" with filesystem-unsafe chars replaced.
    private func defaultConnectionName() -> String {
        let raw = "\(providerPreset.namePrefix)-\(selectedModel)"
        return sanitizedFilename(raw)
    }

    /// Description text for the API key field, depending on the provider.
    private var apiKeyDescription: String {
        if providerPreset == .other {
            return "Your API key for this provider. Some local servers don't require one."
        }
        return "Your API key for \(providerPreset.displayName). Required."
    }

    /// Replaces characters that are unsafe in a filename.
    private func sanitizedFilename(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return trimmed
            .components(separatedBy: invalid)
            .joined(separator: "-")
    }

    /// Writes the connection JSONC file (with commented-out optional parameters)
    /// and records the saved URL for the "Reveal in Finder" link.
    private func saveConnection() {
        let name = sanitizedFilename(connectionName)
        let provider = providerPreset.connectionProvider
        let dir: URL
        switch provider {
        case .openai:
            dir = EnvironmentManager.shared.openaiConnectionsURL
        case .anthropic:
            dir = EnvironmentManager.shared.anthropicConnectionsURL
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let jsonc = ConnectionFileWriter.generateJSONC(
            provider: provider,
            baseUrl: effectiveBaseUrl,
            apiKey: token.isEmpty ? nil : token,
            model: selectedModel,
            imageInput: imageInput
        )

        let url = dir.appendingPathComponent("\(name).jsonc")
        try? jsonc.data(using: .utf8)?.write(to: url, options: .atomic)
        savedFileURL = url
    }
}

// MARK: - Window helper

extension ConnectionWizardView {
    /// Creates or brings to front the connection wizard window.
    ///
    /// - Parameter closeAppOnCancel: When true (clean-state flow with no
    ///   connections), cancelling the wizard or closing its window terminates
    ///   the app — there's nothing to work with without a connection.
    @MainActor
    static func show(closeAppOnCancel: Bool = false, onFinish: (() -> Void)? = nil) {
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "connection-wizard" }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let wizard = ConnectionWizardView(onFinish: onFinish, closeAppOnCancel: closeAppOnCancel)
        let hosting = NSHostingController(rootView: wizard)
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("connection-wizard")
        window.title = "New Connection"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 480))
        window.center()
        // Intercept the window-close button (red dot) so it follows the same
        // cancel semantics as the Cancel button in the clean-state flow.
        let delegate = WizardWindowDelegate(closeAppOnCancel: closeAppOnCancel)
        objc_setAssociatedObject(window, "wizardDelegate", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        window.delegate = delegate
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Window delegate for the connection wizard. In the clean-state flow it
/// terminates the app when the window is closed (via the red close button),
/// matching the Cancel button's behavior.
@MainActor
private final class WizardWindowDelegate: NSObject, NSWindowDelegate {
    private let closeAppOnCancel: Bool

    init(closeAppOnCancel: Bool) {
        self.closeAppOnCancel = closeAppOnCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeAppOnCancel {
            NSApp.terminate(nil)
            return false
        }
        return true
    }
}
