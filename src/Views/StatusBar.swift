// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct StatusBar: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            // Connection picker
            Picker("Connection", selection: Binding(
                get: { store.selectedChatItem?.chat.connection ?? "" },
                set: { store.setConnection($0) }
            )) {
                Text("No connection").tag("")
                ForEach(store.connections) { connection in
                    Text(connection.displayName).tag(connection.id)
                }
            }
            .labelsHidden()
            .frame(width: 240)

            Divider()
                .frame(height: 20)

            // Role picker
            Picker("Role", selection: Binding(
                get: { store.selectedChatItem?.chat.role ?? "" },
                set: { store.setRole($0) }
            )) {
                Text("No role").tag("")
                ForEach(store.roles) { role in
                    HStack {
                        Text(role.name)
                        if role.isDefault {
                            Image(systemName: "checkmark.seal")
                        }
                    }
                    .tag(role.name)
                }
            }
            .labelsHidden()
            .frame(width: 200)

            Spacer()

            // Status indicator
            if store.isStreaming {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
    }
}
