// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var store: AppViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Left sidebar: chat selector.
            ChatSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            // Detail: chat + optional right info panel side by side.
            // Using a stable HStack avoids layout thrashing and scroll
            // artifacts that happen when swapping between 2-col/3-col layouts.
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
        // MCP configuration overlay: a half-transparent layer shown over the
        // whole window while MCP servers are being (re)configured. Blocks
        // interaction with the underlying UI during configuration.
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
