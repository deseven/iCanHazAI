// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Preferences window with vertical tabs. Accessible from the app menu (⌘,).
struct PreferencesView: View {
    @EnvironmentObject var store: AppViewModel

    /// Currently selected tab identifier.
    @State private var selectedTab: Tab = .general

    // MARK: - Tab enumeration

    private enum Tab: String, CaseIterable, Identifiable {
        case general
        case chatBehaviour
        case chatFeatures
        case debug

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: return "General"
            case .chatBehaviour: return "Chat Behaviour"
            case .chatFeatures: return "Chat Features"
            case .debug: return "Debug"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .chatBehaviour: return "rectangle.expand.vertical"
            case .chatFeatures: return "text.bubble"
            case .debug: return "ladybug"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // Vertical tab list
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Tab.allCases) { tab in
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

            // Tab content
            Group {
                switch selectedTab {
                case .general:
                    GeneralTab()
                case .chatBehaviour:
                    ChatBehaviourTab()
                case .chatFeatures:
                    ChatFeaturesTab()
                case .debug:
                    DebugTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .frame(width: 610, height: 380)
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
                title: "Default Connection",
                description: "A connection used by default for new chats"
            ) {
                Picker("", selection: store.bindingDefaultConnection) {
                    Text("None").tag(String?.none)
                    ForEach(store.connections) { conn in
                        Text(conn.displayName).tag(String?.some(conn.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

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
                title: "Utility Connection",
                description: "A connection used for utility tasks such as chat name generation"
            ) {
                Picker("", selection: store.bindingUtilityConnection) {
                    Text("None").tag(String?.none)
                    ForEach(store.connections) { conn in
                        Text(conn.displayName).tag(String?.some(conn.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - Chat behaviour tab

private struct ChatBehaviourTab: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PrefRow(
                title: "Expand Thinking",
                description: "Controls whether the Thinking blocks will be expanded by default"
            ) {
                Toggle("", isOn: store.bindingExpandThinking)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PrefRow(
                title: "Expand Tool Use",
                description: "Controls whether the Tool Use blocks will be expanded by default"
            ) {
                Toggle("", isOn: store.bindingExpandToolUse)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - Chat features tab

private struct ChatFeaturesTab: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PrefRow(
                title: "Mermaid",
                description: "Render Mermaid diagrams from fenced `mermaid` code blocks."
            ) {
                Toggle("", isOn: store.bindingMermaidEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PrefRow(
                title: "KaTeX",
                description: "Render LaTeX math using `$...$` for inline and `$$...$$` for block equations."
            ) {
                Toggle("", isOn: store.bindingKatexEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - Debug tab

private struct DebugTab: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PrefRow(
                title: "Chat Renderer Debug",
                description: "Show an on-screen debug overlay in the chat renderer with timestamps for message loads, edits, deletions, and streaming events."
            ) {
                Toggle("", isOn: store.bindingChatRendererDebugEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - Window helper

extension PreferencesView {
    /// Creates or brings to front the preferences window.
    @MainActor
    static func show() {
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "preferences" }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let store = AppViewModel.shared else { return }

        let prefsView = PreferencesView()
            .environmentObject(store)

        let hosting = NSHostingController(rootView: prefsView)
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("preferences")
        window.title = "Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        // Explicitly set the content size so the window is fully sized
        // before center() is called — NSWindow.center() places the window
        // at Apple's "golden ratio" position (slightly above true center),
        // but only works correctly once the frame is known.
        window.setContentSize(NSSize(width: 610, height: 380))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
