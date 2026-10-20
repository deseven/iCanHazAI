// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The tabs of the Preferences sheet.
enum PreferencesTab: String, CaseIterable, Identifiable, Equatable {
    case general
    case chat
    case webSearch
    case debug

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .chat: return "Chat"
        case .webSearch: return "Web Search"
        case .debug: return "Debug"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .chat: return "text.bubble"
        case .webSearch: return "globe"
        case .debug: return "ladybug"
        }
    }
}

/// Preferences sheet with vertical tabs. Opened from the app menu (⌘,).
struct PreferencesView: View {
    @EnvironmentObject var store: AppViewModel
    @Environment(\.dismiss) private var dismiss

    /// Currently selected tab.
    @State private var selectedTab: PreferencesTab

    init(initialTab: PreferencesTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            tabs
                .frame(width: 610, height: 380)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(PreferencesTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .frame(width: 20)
                            Text(tab.label)
                                .font(.body)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                    .fontWeight(selectedTab == tab ? .medium : .regular)
                }
                Spacer()
            }
            .frame(width: 170)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    GeneralTab()
                case .chat:
                    ChatTab()
                case .webSearch:
                    WebSearchTab()
                case .debug:
                    DebugTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
    }
}

// MARK: - Shared preference row

/// A reusable preference row layout:
///
/// ```
/// [ title ] [ description ]
/// [ control ]
/// ```
///
/// The title and description sit on the first line; the control (picker,
/// toggle, etc.) is placed on the line below, left-aligned.
private struct PrefRow<Control: View>: View {
    let title: String
    let description: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body)
            control()
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PrefRow(
                title: "Default Role",
                description: "A role used by default for new chats"
            ) {
                Picker("", selection: store.bindingDefaultRole) {
                    ForEach(store.roles) { role in
                        Text(role.name).tag(String?.some(role.name))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            PrefRow(
                title: "Default Model",
                description: "A model preselected for new chats. A role's preferred_model takes precedence."
            ) {
                ModelSettingButton(setting: .defaultModel)
            }

            PrefRow(
                title: "Utility Model",
                description:
                    "A model used for background tasks, such as generating chat names. A fast and cheap model is preferred."
            ) {
                ModelSettingButton(setting: .utilityModel)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

/// The model status block for a general model setting. Clicking it closes
/// Preferences and opens the model picker; Preferences returns afterwards.
private struct ModelSettingButton: View {
    @EnvironmentObject var store: AppViewModel
    let setting: ModelSetting

    var body: some View {
        let model = store.preferencesModel(for: setting)
        let parts = store.modelParts(for: model)
        Button {
            store.pickSettingsModel(setting)
        } label: {
            ModelStatusLabel(
                provider: parts.provider, color: store.tagColor(for: parts.provider), label: parts.name,
                hasModel: model != nil)
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

// MARK: - Chat tab

private struct ChatTab: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PrefRow(
                title: "Expand Tool Use",
                description: "Controls whether the Tool Use blocks will be expanded by default"
            ) {
                Toggle("", isOn: store.bindingExpandToolUse)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PrefRow(
                title: "Smooth Streaming",
                description: "Fades in new text and eases the chat down while a reply is being written"
            ) {
                Toggle("", isOn: store.bindingSmoothStreaming)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PrefRow(
                title: "Interface Scale",
                description: "Adjust the size of the chat interface. 100% is the default."
            ) {
                HStack(spacing: 10) {
                    Text("70%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: store.bindingInterfaceScale,
                        in: ChatConfig.interfaceScaleRange,
                        step: 1
                    )
                    Text("200%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(store.preferencesInterfaceScale.rounded()))%")
                        .font(.body.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
                .frame(width: 360)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - Web search tab

private struct WebSearchTab: View {
    @EnvironmentObject var store: AppViewModel

    private var providerName: String {
        WebSearchProviderKind(rawValue: store.preferencesWebSearchProvider)?.displayName ?? "None"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if store.preferencesWebSearchConfigured {
                connected
            } else {
                notSetUp
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - Not set up

    private var notSetUp: some View {
        PrefRow(
            title: "Web Search",
            description:
                "Lets models search the web and read pages through Exa, Linkup, or Tavily, using your own API key. Without it the web_search and web_extract tools are unavailable; only the raw web_fetch tool works."
        ) {
            Button("Set up Web Search…") { store.presentWebSearchWizard() }
        }
    }

    // MARK: - Set up

    @ViewBuilder
    private var connected: some View {
        PrefRow(
            title: "Provider",
            description: "The backend used by the web_search and web_extract tools."
        ) {
            Text(providerName)
                .fontWeight(.medium)
        }

        PrefRow(
            title: "API Key",
            description: "Stored encrypted and tied to this Mac, never in a config file."
        ) {
            Text(store.preferencesWebSearchTokenMask)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }

        providerOptions

        VStack(alignment: .leading, spacing: 6) {
            Button("Disconnect", role: .destructive) { store.disconnectWebSearch() }
            if let error = store.preferencesWebSearchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var providerOptions: some View {
        if store.preferencesWebSearchProvider == "linkup" {
            PrefRow(
                title: "Render JS for Extraction",
                description: "Render the page's JavaScript before extracting its content."
            ) {
                Toggle("", isOn: store.bindingLinkupRenderJS)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }

        if store.preferencesWebSearchProvider == "tavily" {
            PrefRow(
                title: "Advanced Extraction",
                description:
                    "Retrieve more data, including tables and embedded content, at higher latency and cost."
            ) {
                Toggle("", isOn: store.bindingTavilyAdvancedExtraction)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}

// MARK: - Debug tab

private struct DebugTab: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PrefRow(
                title: "App Debug",
                description:
                    "Mirror timestamped debug logs to stdout for app startup, config loading, FSEvents, wizards, LLM requests, streaming, MCP servers, and tool calls. Logs are always written to ~/iCanHazAI/app.log regardless."
            ) {
                Toggle("", isOn: store.bindingAppDebugEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}
