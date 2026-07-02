// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var store: AppViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ChatSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            HStack(spacing: 0) {
                if store.selectedChatItem != nil {
                    ChatView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack {
                        Spacer()
                        Text("No chat selected")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if store.chatInfoSidebarVisible && store.selectedChatItem != nil {
                    Divider()
                    ChatInfoSidebar()
                        .frame(width: 260)
                }
            }
            .navigationTitle(store.selectedChatItem?.displayTitle ?? "")
        }
        .overlay {
            MCPConfigurationOverlay()
        }
        .onAppear {
            columnVisibility = store.chatListSidebarVisible ? .all : .detailOnly
        }
        .onChange(of: store.chatListSidebarVisible) { _, visible in
            columnVisibility = visible ? .all : .detailOnly
        }
        .onChange(of: columnVisibility) { _, newValue in
            let visible = newValue != .detailOnly
            if store.chatListSidebarVisible != visible {
                store.chatListSidebarVisible = visible
                store.saveSidebarState()
            }
        }
        .onChange(of: store.chatInfoSidebarVisible) { _, _ in
            store.saveSidebarState()
        }
    }
}
