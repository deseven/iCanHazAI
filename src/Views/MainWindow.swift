// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The main window content: chat list | chat | (optional) chat info.
///
/// The three-pane layout lives in
/// [`MainSplitView`](src/Views/MainSplitView.swift) (AppKit `NSSplitView`) —
/// see its doc comment for why this isn't a `NavigationSplitView` (collapsible
/// sidebar) or a pure-SwiftUI HStack (jittery drag, 1pt grab zone).
///
/// All dialogs are sheets of this window — see [`MainSheet`](src/Views/MainSheet.swift).
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
            // The only sheet host: every dialog (pickers, wizards,
            // Preferences) is a case of `MainSheet`, so at most one is up and
            // presenting another replaces it.
            .sheet(item: store.sheetBinding) { sheet in
                MainSheetContent(sheet: sheet)
            }
            .onChange(of: store.chatInfoSidebarVisible) { _, _ in
                store.saveSidebarState()
                MainWindowController.shared.applyMinSize()
            }
    }
}
