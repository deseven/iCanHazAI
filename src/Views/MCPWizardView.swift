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
        case test
        case name
        case finish

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .type:       return "Transport"
            case .parameters: return "Parameters"
            case .test:       return "Test"
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
    /// stdio: the executable command (e.g. "python3" or "npx").
    @State private var command: String = ""
    /// stdio: arguments as a single space-separated string; split on save.
    @State private var args: String = ""
    /// http: the streamable HTTP endpoint URL.
    @State private var endpoint: String = ""
    /// http: optional bearer token.
    @State private var token: String = ""
    /// Whether this server is enabled for new chats by default.
    @State private var defaultForNewChats: Bool = false

    // Step 3 — test
    /// Whether the listTools test request is in flight.
    @State private var isTesting: Bool = false
    /// Tools returned by the server, once the test completes.
    @State private var testTools: [MCPTool]?
    /// The error from the test, if it failed.
    @State private var testError: String?

    // Step 4 — name
    @State private var serverName: String = ""

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
                case .test:       testStep
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
        .onChange(of: step) { _, newStep in
            switch newStep {
            case .parameters:
                focusedField = transport == .stdio ? .command : .endpoint
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
        case .test:
            // Allow moving on regardless of test result, but not while in flight.
            return !isTesting
        case .name:
            return nameValid
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

    // MARK: - Step transitions

    private func goNext() {
        guard let n = step.next else { return }
        switch step {
        case .parameters:
            // Reset the test state so it re-runs with the current params.
            resetTestState()
            step = n
        case .name:
            // Save the server file before showing the finish step.
            saveServer()
            step = n
        default:
            step = n
        }
    }

    /// Clears the connection test results so the test re-runs from scratch.
    private func resetTestState() {
        isTesting = false
        testTools = nil
        testError = nil
    }

    /// Resets all wizard state that belongs to steps after the given step.
    private func resetState(after step: Step) {
        if step < .parameters {
            command = ""
            args = ""
            endpoint = ""
            token = ""
            defaultForNewChats = false
        }
        if step < .test {
            resetTestState()
        }
        if step < .name {
            serverName = ""
        }
        if step < .finish {
            savedFileURL = nil
        }
    }

    private func closeWindow() {
        // Best-effort cleanup of a transient test connection left behind if the
        // user cancels mid-test.
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

            Toggle("Enabled for new chats by default", isOn: $defaultForNewChats)
                .padding(.top, 4)

            Spacer()
        }
    }

    // MARK: - Step 3: Test

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("We'll connect to the server and list its tools. You can continue regardless of the result.")
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
                    } else if let err = testError {
                        Text(err)
                            .foregroundStyle(.red)
                    } else if let tools = testTools {
                        Text("\(tools.count) available")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let tools = testTools, !tools.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
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
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
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

            Spacer()
        }
        .onAppear { runTestIfNeeded() }
    }

    /// The transient name used for the test connection in `MCPManager`. It is
    /// disconnected after the test (and on cancel) so it never lingers.
    private var tempServerName: String { "__wizard_test__" }

    /// Builds an `MCPServer` from the current wizard state.
    private func buildServer(name: String) -> MCPServer {
        MCPServer(
            name: name,
            transport: transport,
            command: transport == .stdio ? command : nil,
            args: transport == .stdio ? splitArgs(args) : nil,
            endpoint: transport == .http ? endpoint : nil,
            token: transport == .http && !token.isEmpty ? token : nil,
            defaultForNewChats: defaultForNewChats
        )
    }

    /// Runs the listTools test once when the step appears.
    private func runTestIfNeeded() {
        guard !isTesting && testTools == nil && testError == nil else { return }
        isTesting = true

        let server = buildServer(name: tempServerName)
        Task {
            // Tear down any leftover transient connection from a previous run,
            // then (re)connect and list tools.
            await MCPManager.shared.disconnect(name: tempServerName)
            await MCPManager.shared.connect(server)
            do {
                let tools = try await MCPManager.shared.listTools(for: tempServerName)
                await MainActor.run {
                    self.testTools = tools
                    self.isTesting = false
                }
            } catch {
                await MainActor.run {
                    self.testError = error.localizedDescription
                    self.isTesting = false
                }
            }
            // Clean up the transient connection so it doesn't linger.
            await MCPManager.shared.disconnect(name: tempServerName)
        }
    }

    // MARK: - Step 4: Name

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a name for this MCP server. It determines the config file name on disk.")
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

            Spacer()
        }
        .onAppear {
            if serverName.isEmpty {
                serverName = defaultServerName()
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
            summaryRow("Default for new chats", defaultForNewChats ? "Yes" : "No")
            switch transport {
            case .stdio:
                summaryRow("Command", command)
                if !args.isEmpty {
                    summaryRow("Arguments", args)
                }
            case .http:
                summaryRow("Endpoint", endpoint)
                summaryRow("Token", token.isEmpty ? "none" : "set")
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
        // Simple shell-like split: respect double quotes, no escape handling.
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

    /// Default name derived from the command or endpoint host.
    private func defaultServerName() -> String {
        switch transport {
        case .stdio:
            let base = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { return "mcp-server" }
            // Use the last path component of an absolute path, or the bare name.
            let last = base.contains("/") ? (base as NSString).lastPathComponent : base
            return sanitizedFilename(last)
        case .http:
            if let url = URL(string: endpoint), let host = url.host {
                return sanitizedFilename(host)
            }
            return "mcp-server"
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
        let server = buildServer(name: name)
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
