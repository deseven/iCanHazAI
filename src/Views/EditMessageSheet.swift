// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A multiline plain-text editing modal for editing a message's content.
/// Presented by `ChatView` when a message row requests an edit action.
/// When `followOnWarning` is non-nil (editing a user message that has messages
/// after it), a warning line explains that saving will regenerate the response
/// and delete the following messages.
struct EditMessageSheet: View {
    let initialText: String
    /// Optional warning shown when saving the edit will delete follow-on
    /// messages (user-message edit & resend). Nil for in-place assistant edits.
    let followOnWarning: String?
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit message")
                .font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120, maxHeight: 240)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .focused($isFocused)

            if let followOnWarning {
                Text(followOnWarning)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onConfirm(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            text = initialText
            isFocused = true
        }
    }
}
