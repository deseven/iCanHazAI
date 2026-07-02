// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import AppKit

/// A multi-step wizard for creating a new MCP server config. Runs in its own
/// window and walks the user through transport selection, parameters, a
/// connection test (listTools), naming, and a final summary.
///
/// MCP management mirrors the connections pattern: this wizard creates the
/// config file; all further editing/deletion is done by the user manually on
/// the TOML files, picked up live via `EnvironmentWatcher`/FSEvents. There is
/// no in-app edit or delete.
struct MCPWizardView: View {

    /// Called after the wizard finishes (server saved). The view model uses
    /// this to refresh its state (the FSEvent also triggers a reload).
    var onFinish: (() -> Void)?

    /// The wizard steps, in order.
    private enum Step: Int, CaseIterable, Identifiable, Comparable {
        case type
        case parameters
        case tools
        case name
        case finish

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .type:       return "Transport"
            case .parameters: return "Parameters"
            case .tools:      return "Tools"
            case .name:       return "Name"
            case .finish:     return "Finish"
            }
        }

        var index: Int { rawValue }
        var isFirst: Bool { self == .type }
        var isLast: Bool { self == .finish }
        var next: Step? { Step(rawValue: rawValue + 1) }
        var back: Step? { Step(rawValue: rawValue - 1) }

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    // MARK: - Wizard state

    /// Currently visible step.
    @State private var step: Step = .type

    // Step 1 — type
    @State private var transport: MCPTransport = .stdio

    // Step 2 — parameters
    /// When the server process is started/stopped.
    @State private var runPolicy: MCPRunPolicy = .alwaysOn
    /// stdio: the executable command (e.g. "python3" or "npx").
    @State private var command: String = ""
    /// stdio: arguments as a single space-separated string; split on save.
    @State private var args: String = ""
    /// http: the streamable HTTP endpoint URL.
    @State private var endpoint: String = ""
    /// http: optional bearer token.
    @State private var token: String = ""

    // Step 3 — tools
    /// Whether the listTools request is in flight.
    @State private var isTesting: Bool = false
    /// The in-flight test `Task`, tracked so it can be cancelled when the
    /// wizard is closed mid-test (otherwise the spawned stdio subprocess would
    /// be orphaned, since `testConnection` would still be awaiting a handshake
    /// that never completes).
    @State private var testTask: Task<Void, Never>?
    /// Tools returned by the server, once the connection test completes.
    @State private var testTools: [MCPTool]?
    /// The error from the test, if it failed.
    @State private var testError: String?
    /// The server name reported by the MCP server in its `initialize`
    /// response (`serverInfo.name`). Used to pre-fill the Name step. Nil if
    /// the test hasn't completed or the server didn't report a name.
    @State private var reportedServerName: String?
    /// The set of tool names the user has selected. Independent of the filter:
    /// filtering only affects what's visible, not what's selected. An empty
    /// set means "no selection yet" (the user can't proceed); once saved, an
    /// all-selected state is serialized as an empty array (allow all).
    @State private var selectedTools: Set<String> = []
    /// The current filter text for the tools list. Matches against tool name
    /// and description (case-insensitive).
    @State private var toolFilter: String = ""

    // Step 4 — name
    @State private var serverName: String = ""
    /// Lowercase-alphanumeric prefix used to namespace this server's tools
    /// for the LLM (e.g. `gdocs_search`). Required, unique across servers.
    @State private var prefix: String = ""

    // Step 5 — finish
    /// The URL of the saved server file, set when we write it on entering the
    /// finish step.
    @State private var savedFileURL: URL?

    // MARK: - Focus state

    private enum Field: Hashable {
        case command
        case args
        case endpoint
        case token
        case serverName
        case prefix
        case toolFilter
    }

    @FocusState private var focusedField: Field?

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
                case .type:       typeStep
                case .parameters: parametersStep
                case .tools:      toolsStep
                case .name:       nameStep
                case .finish:     finishStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)

            Divider()

            navigationBar
                .padding(12)
        }
        .onChange(of: step) { (_: Step, newStep: Step) in
            debugLog("Wizard", "MCP wizard step → \(newStep.title)")
            switch newStep {
            case .parameters:
                focusedField = transport == .stdio ? .command : .endpoint
            case .tools:
                focusedField = .toolFilter
            case .name:
                focusedField = .serverName
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
                closeWindow()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

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
                Button("Next") {
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
        case .type:
            return true
        case .parameters:
            return parametersValid
        case .tools:
            // Can't proceed while the connection test is in flight, and at
            // least one tool must be selected.
            if isTesting { return false }
            if testError != nil { return false }
            guard let tools = testTools, !tools.isEmpty else { return false }
            return !selectedTools.isEmpty
        case .name:
            return nameValid && prefixValid
        case .finish:
            return true
        }
    }

    /// Whether the parameters step has the required fields filled.
    private var parametersValid: Bool {
        switch transport {
        case .stdio:
            return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .http:
            return !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Whether the chosen name is non-empty, filesystem-safe, and unique.
    private var nameValid: Bool {
        let name = sanitizedFilename(serverName)
        guard !name.isEmpty else { return false }
        let url = EnvironmentManager.shared.mcpsURL.appendingPathComponent("\(name).toml")
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// Whether the prefix is non-empty, lowercase-alphanumeric, and unique
    /// across existing servers. The prefix namespaces tool names sent to the
    /// LLM, so it must match `^[a-z0-9]+$` and not collide with another server.
    private var prefixValid: Bool {
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        return prefixError == nil
    }

    /// Validation error for the current prefix, or nil if it's valid/empty.
    private var prefixError: String? {
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        if !p.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return "Use only lowercase letters and digits (a–z, 0–9)."
        }
        let existing = EnvironmentManager.shared.loadMCPs()
        if existing.contains(where: { $0.prefix == p }) {
            return "Another server already uses this prefix."
        }
        return nil
    }

    // MARK: - Step transitions

    private func goNext() {
        guard let n = step.next else { return }
        switch step {
        case .parameters:
            resetTestState()
            step = n
        case .name:
            saveServer()
            step = n
        default:
            step = n
        }
    }

    /// Clears the connection test results so the test re-runs from scratch.
    /// Cancels any in-flight test task first so we don't leave a dangling
    /// subprocess.
    private func resetTestState() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
        testTools = nil
        testError = nil
        reportedServerName = nil
        selectedTools.removeAll()
        toolFilter = ""
    }

    /// Resets all wizard state that belongs to steps after the given step.
    private func resetState(after step: Step) {
        if step < .parameters {
            command = ""
            args = ""
            endpoint = ""
            token = ""
        }
        if step < .tools {
            resetTestState()
        }
        if step < .name {
            serverName = ""
            prefix = ""
        }
        if step < .finish {
            savedFileURL = nil
        }
    }

    private func closeWindow() {
        // Cancel any in-flight test so the spawned subprocess is torn down
        // (testConnection's race will throw CancellationError, and the cleanup
        // in connectAndListTools kills the process). Then disconnect any
        // transient connection that may have been left behind.
        testTask?.cancel()
        Task { await MCPManager.shared.disconnect(name: tempServerName) }
        NSApp.windows.first(where: { $0.identifier?.rawValue == "mcp-wizard" })?.close()
    }

    // MARK: - Step 1: Type

    private var typeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose how this MCP server communicates.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach([MCPTransport.stdio, .http], id: \.self) { option in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: transport == option ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(transport == option ? Color.accentColor : Color.secondary)
                            .onTapGesture { transport = option }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option == .stdio ? "stdio" : "Streamable HTTP")
                                .fontWeight(.medium)
                            Text(option == .stdio
                                 ? "A local subprocess spawned by the app. Provide a command and arguments."
                                 : "A remote server reachable over HTTP. Provide an endpoint URL and optional bearer token.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { transport = option }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(transport == option ? Color.accentColor.opacity(0.1) : Color.clear)
                    )
                }
            }

            Spacer()
        }
    }

    // MARK: - Step 2: Parameters

    private var parametersStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(transport == .stdio
                 ? "Enter the command that launches the MCP server subprocess."
                 : "Enter the streamable HTTP endpoint of the MCP server.")
                .font(.callout)
                .foregroundStyle(.secondary)

            switch transport {
            case .stdio:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(.headline)
                    Text("The executable to run, e.g. python3, npx, or an absolute path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("python3", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .command)
                        .onSubmit { goNext() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arguments")
                        .font(.headline)
                    Text("Space-separated arguments passed to the command.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("/path/to/server.py", text: $args)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .args)
                        .onSubmit { goNext() }
                }
            case .http:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Endpoint")
                        .font(.headline)
                    Text("The streamable HTTP URL of the MCP server, e.g. https://example.com/mcp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .endpoint)
                        .onSubmit { goNext() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bearer Token (optional)")
                        .font(.headline)
                    Text("Sent as the Authorization header. Leave empty for unauthenticated servers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("token", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .token)
                        .onSubmit { goNext() }
                }
            }

            // Run Policy — only meaningful for stdio servers, where we own the
            // subprocess lifecycle. HTTP servers are remote and stateless from
            // our perspective, so the policy is fixed to "always on".
            if transport == .stdio {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run Policy")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach([MCPRunPolicy.alwaysOn, .onDemand], id: \.self) { option in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: runPolicy == option ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(runPolicy == option ? Color.accentColor : Color.secondary)
                                    .onTapGesture { runPolicy = option }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option == .alwaysOn ? "Always on" : "On-demand")
                                        .fontWeight(.medium)
                                    Text(option == .alwaysOn
                                         ? "The server is started on app launch (or when this config is created), reloaded when its config changes, and stopped when its config is deleted."
                                         : "The server is started only when a chat that has it active sends a request, and shut down after 600 seconds of inactivity. Reloaded on config change.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { runPolicy = option }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(runPolicy == option ? Color.accentColor.opacity(0.1) : Color.clear)
                            )
                        }
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - Step 3: Tools

    /// The tools that match the current filter text. Matching is
    /// case-insensitive against both the tool name and its description.
    /// Filtering does not affect `selectedTools` — only what's visible.
    private var filteredTools: [MCPTool] {
        guard let tools = testTools else { return [] }
        let q = toolFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return tools }
        return tools.filter { tool in
            if tool.name.lowercased().contains(q) { return true }
            if let desc = tool.description, desc.lowercased().contains(q) { return true }
            return false
        }
    }

    /// Whether all currently-known tools are selected.
    private var allSelected: Bool {
        guard let tools = testTools, !tools.isEmpty else { return false }
        return tools.allSatisfy { selectedTools.contains($0.name) }
    }

    private var toolsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("We'll connect to the server and list its tools. Select which tools the model is allowed to use.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Server: ")
                        .fontWeight(.medium)
                    Text(transport == .stdio ? "stdio" : "streamable http")
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Tools: ")
                        .fontWeight(.medium)
                    if isTesting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Connecting…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let tools = testTools {
                        Text("\(tools.count) available")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }

                if let err = testError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .padding(.top, 2)
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.08))
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let tools = testTools, !tools.isEmpty {
                HStack(spacing: 8) {
                    TextField("Filter tools…", text: $toolFilter)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .toolFilter)
                    Button(allSelected ? "Select None" : "Select All") {
                        if allSelected {
                            selectedTools.removeAll()
                        } else {
                            for t in tools { selectedTools.insert(t.name) }
                        }
                    }
                    .buttonStyle(.bordered)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredTools.enumerated()), id: \.offset) { _, tool in
                            let isSelected = selectedTools.contains(tool.name)
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool.name)
                                        .font(.callout)
                                        .fontWeight(.medium)
                                    if let desc = tool.description, !desc.isEmpty {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSelected {
                                    selectedTools.remove(tool.name)
                                } else {
                                    selectedTools.insert(tool.name)
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
                            )
                        }
                        if filteredTools.isEmpty {
                            Text("No tools match “\(toolFilter)”.")
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

                Text("Selected \(selectedTools.count) tool\(selectedTools.count == 1 ? "" : "s") out of \(tools.count).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .onAppear { runTestIfNeeded() }
    }

    /// The transient name used for the test connection in `MCPManager`. It is
    /// disconnected after the test (and on cancel) so it never lingers.
    private var tempServerName: String { "__wizard_test__" }

    /// Builds an `MCPServer` from the current wizard state. `runPolicy` is
    /// only set for stdio servers; http servers have no run policy.
    ///
    /// `includeTools` controls whether the selected-tool allowlist is attached.
    /// The transient test connection is built without it (so all tools are
    /// listed during the test); the saved server carries the user's selection.
    /// Per spec, an all-selected state is serialized as an empty array (allow
    /// all), and a partial selection is the list of chosen tool names.
    private func buildServer(name: String, includeTools: Bool = false) -> MCPServer {
        var tools: [String]? = nil
        if includeTools, let available = testTools, !available.isEmpty {
            if selectedTools.count == available.count {
                tools = []
            } else {
                tools = available
                    .map { $0.name }
                    .filter { selectedTools.contains($0) }
            }
        }
        return MCPServer(
            name: name,
            prefix: prefix.trimmingCharacters(in: .whitespacesAndNewlines),
            transport: transport,
            runPolicy: transport == .stdio ? runPolicy : nil,
            command: transport == .stdio ? command : nil,
            args: transport == .stdio ? splitArgs(args) : nil,
            endpoint: transport == .http ? endpoint : nil,
            token: transport == .http && !token.isEmpty ? token : nil,
            tools: tools
        )
    }

    /// Runs the listTools test once when the step appears. The in-flight task
    /// is stored in `testTask` so it can be cancelled if the wizard is closed
    /// mid-test (preventing an orphaned subprocess).
    private func runTestIfNeeded() {
        guard !isTesting && testTools == nil && testError == nil else { return }
        isTesting = true

        let server = buildServer(name: tempServerName)
        testTask = Task {
            do {
                let result = try await MCPManager.shared.testConnection(server)
                await MainActor.run {
                    self.testTools = result.tools
                    self.reportedServerName = result.serverName
                    self.isTesting = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isTesting = false
                }
            } catch {
                await MainActor.run {
                    self.testError = error.localizedDescription
                    self.isTesting = false
                }
            }
            await MCPManager.shared.disconnect(name: tempServerName)
            await MainActor.run {
                self.testTask = nil
            }
        }
    }

    // MARK: - Step 4: Name

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a name and a tool prefix for this MCP server.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Server Name")
                    .font(.headline)
                TextField("my-mcp-server", text: $serverName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .serverName)
                    .onSubmit { goNext() }
                Text("File: mcp/\(sanitizedFilename(serverName)).toml")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !serverName.isEmpty && !nameValid {
                    Text("A server with this name already exists. Choose a different name.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tool Prefix")
                    .font(.headline)
                TextField("gdocs", text: $prefix)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .prefix)
                    .onSubmit { goNext() }
                    .autocorrectionDisabled()
                let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                Text("Tools are exposed to the model as \(p.isEmpty ? "prefix" : p)_<tool>.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !prefix.isEmpty, let err = prefixError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()
        }
        .onAppear {
            if serverName.isEmpty {
                serverName = defaultServerName()
            }
            if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prefix = defaultPrefix()
            }
        }
    }

    // MARK: - Step 5: Finish

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MCP server created. Here's a summary:")
                .font(.callout)
                .foregroundStyle(.secondary)

            summaryRow("Transport", transport == .stdio ? "stdio" : "streamable http")
            summaryRow("Name", sanitizedFilename(serverName))
            summaryRow("Prefix", prefix.trimmingCharacters(in: .whitespacesAndNewlines))
            switch transport {
            case .stdio:
                summaryRow("Command", command)
                if !args.isEmpty {
                    summaryRow("Arguments", args)
                }
                summaryRow("Run Policy", runPolicy == .alwaysOn ? "Always on" : "On-demand")
            case .http:
                summaryRow("Endpoint", endpoint)
                summaryRow("Token", token.isEmpty ? "none" : "set")
            }
            if let available = testTools, !available.isEmpty {
                if selectedTools.count == available.count {
                    summaryRow("Tools", "all (\(available.count))")
                } else {
                    summaryRow("Tools", "\(selectedTools.count) of \(available.count)")
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("For advanced configuration you can manually edit the server file:")
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
                .frame(width: 130, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Helpers

    /// Splits a space-separated argument string into an array, honoring
    /// double-quoted segments.
    private func splitArgs(_ s: String) -> [String] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var args: [String] = []
        var current = ""
        var inQuotes = false
        for ch in trimmed {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == " " && !inQuotes {
                if !current.isEmpty { args.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    /// Default name derived from the server's reported name (preferred, from
    /// the MCP `initialize` response's `serverInfo.name`), falling back to the
    /// command name or endpoint host. The result is sanitized for filesystem use.
    private func defaultServerName() -> String {
        if let reported = reportedServerName, !reported.isEmpty {
            let sanitized = sanitizedFilename(reported)
            if !sanitized.isEmpty { return sanitized }
        }
        switch transport {
        case .stdio:
            let base = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { return "mcp-server" }
            let last = base.contains("/") ? (base as NSString).lastPathComponent : base
            return sanitizedFilename(last)
        case .http:
            if let url = URL(string: endpoint), let host = url.host {
                return sanitizedFilename(host)
            }
            return "mcp-server"
        }
    }

    /// Default prefix derived from the server's reported name, command, or
    /// endpoint host — lowercased and stripped to `[a-z0-9]`. Falls back to
    /// "mcp" if nothing usable remains. The user can still edit it.
    private func defaultPrefix() -> String {
        func slugify(_ s: String) -> String {
            s.lowercased().unicodeScalars
                .filter("abcdefghijklmnopqrstuvwxyz0123456789".contains)
                .map(String.init)
                .joined()
        }
        if let reported = reportedServerName, !reported.isEmpty {
            let slug = slugify(reported)
            if !slug.isEmpty { return slug }
        }
        switch transport {
        case .stdio:
            let base = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { return "mcp" }
            let last = base.contains("/") ? (base as NSString).lastPathComponent : base
            let slug = slugify(last)
            return slug.isEmpty ? "mcp" : slug
        case .http:
            if let url = URL(string: endpoint), let host = url.host {
                let slug = slugify(host)
                return slug.isEmpty ? "mcp" : slug
            }
            return "mcp"
        }
    }

    /// Replaces characters that are unsafe in a filename.
    private func sanitizedFilename(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return trimmed
            .components(separatedBy: invalid)
            .joined(separator: "-")
    }

    /// Writes the server TOML file via `EnvironmentManager.saveMCP` and records
    /// the saved URL for the "Reveal in Finder" link. The `EnvironmentWatcher`
    /// FSEvent triggers `MCPManager`/`ChatEngine` reload — no manual refresh.
    private func saveServer() {
        let name = sanitizedFilename(serverName)
        let server = buildServer(name: name, includeTools: true)
        EnvironmentManager.shared.saveMCP(server)
        savedFileURL = EnvironmentManager.shared.mcpsURL.appendingPathComponent("\(name).toml")
    }
}

// MARK: - Window helper

extension MCPWizardView {
    /// Creates or brings to front the MCP wizard window.
    @MainActor
    static func show(onFinish: (() -> Void)? = nil) {
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "mcp-wizard" }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let wizard = MCPWizardView(onFinish: onFinish)
        let hosting = NSHostingController(rootView: wizard)
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("mcp-wizard")
        window.title = "New MCP Server"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 480))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
