// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A simple rename dialog with a text field and Cancel/OK buttons. The field
/// is pre-filled with the current chat name and its contents selected on appear
/// so the user can immediately overwrite or edit it.
struct RenameChatSheet: View {
    let initialText: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename chat")
                .font(.headline)
            TextField("Chat title", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onAppear {
                    text = initialText
                    // Focus the field and select all its text so the user can
                    // immediately type over it or edit part of it.
                    isFocused = true
                    DispatchQueue.main.async {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("OK") { onConfirm(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
