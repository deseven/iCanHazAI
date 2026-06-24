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

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: return "General"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
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
            .frame(width: 160)
            .padding(.vertical, 8)

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .general:
                    GeneralTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .frame(width: 600, height: 380)
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @EnvironmentObject var store: AppViewModel

    /// Fixed label column width so all pickers start at the same x position.
    private let labelWidth: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            prefRow(
                label: "Default Connection:",
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

            prefRow(
                label: "Default Role:",
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

            prefRow(
                label: "Utility Connection:",
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
        .padding(.top, 8)
    }

    @ViewBuilder
    private func prefRow<C: View>(label: String, description: String, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(label)
                    .frame(width: labelWidth, alignment: .trailing)
                    .padding(.trailing, 8)
                control()
                Spacer(minLength: 0)
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, labelWidth + 8)
        }
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
        window.setContentSize(NSSize(width: 600, height: 380))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
