// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            // Left: chat tabs sidebar
            ChatSidebar()
                .frame(width: 220)

            Divider()

            // Right: selected chat + status bar
            VStack(spacing: 0) {
                if store.selectedChatItem != nil {
                    ChatView()
                } else {
                    VStack {
                        Spacer()
                        Text("No chat selected")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                Divider()
                StatusBar()
                    .frame(height: 36)
            }
        }
    }
}
