// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The main window content: chat list | chat | (optional) chat info.
///
/// The three-pane layout lives in
/// [`MainSplitView`](src/Views/MainSplitView.swift) (AppKit `NSSplitView`) —
/// see its doc comment for why this isn't a `NavigationSplitView` (collapsible
/// sidebar) or a pure-SwiftUI HStack (jittery drag, 1pt grab zone).
struct MainWindow: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        MainSplitView()
            .navigationTitle(store.selectedChatItem?.displayTitle ?? "")
            .toolbar {
                // Warning button in the top-right of the title bar. Shown only
                // while there is at least one configuration error; hidden entirely
                // once everything loads cleanly again.
                ToolbarItem(placement: .primaryAction) {
                    if !store.configErrors.isEmpty {
                        Button {
                            store.showConfigErrors = true
                        } label: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.yellow)
                        }
                        .help("Configuration problems")
                    }
                }
            }
            .overlay {
                LoaderOverlay()
            }
            .sheet(isPresented: $store.showConfigErrors) {
                ConfigErrorsSheet(
                    errors: store.configErrors,
                    onAcknowledge: { store.showConfigErrors = false },
                    onFix: { store.fixWithConfigurator() }
                )
            }
            .sheet(isPresented: $store.showRolePicker) {
               RolePickerView(
                   mode: store.rolePickerMode,
                   onCancel: { store.rolePickerCancelled() },
                   onPick: { store.rolePickerPicked(role: $0) },
                   diskAccessOnly: store.chatListMode == .directory
               )
           }
            .sheet(isPresented: $store.showSidebarRolePicker) {
                RolePickerView(
                    mode: .newChat,
                    onCancel: { store.sidebarRolePickerCancelled() },
                    onPick: { store.sidebarRolePickerPicked(role: $0) }
                )
            }
            .sheet(isPresented: $store.showSidebarDirectoryPicker) {
                WorkdirPickerView(
                    onCancel: { store.sidebarDirectoryPickerCancelled() },
                    onPick: { store.sidebarDirectoryPickerPicked($0) }
                )
            }
           .onChange(of: store.chatInfoSidebarVisible) { _, _ in
               store.saveSidebarState()
               MainWindowController.shared.applyMinSize()
           }
    }
}
