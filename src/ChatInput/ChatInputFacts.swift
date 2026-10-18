// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The slice of app state the message input depends on. Captured when the
/// store publishes, so per-keystroke work only combines it with the typed
/// content instead of re-querying the store (some of these are not free).
struct ChatInputFacts: Equatable {
    var supportsAttachments = false
    var hasValidRole = false
    var hasModel = false
    var workdirRequired = false
    var lastMessageIsFromUser = false
    var isStreaming = false
    var stopAfterIterationPending = false
    var queuedCount = 0

    /// Whether the message input is disabled (the chat's role is missing).
    var inputDisabled: Bool { !hasValidRole }

    /// Whether the send/stop button is enabled.
    func actionEnabled(hasText: Bool, hasAttachments: Bool) -> Bool {
        if isStreaming { return true }
        if !hasValidRole || !hasModel { return false }
        // Directory-relevant tools (Filesystem/Code) require a working
        // directory before requests can be sent.
        if workdirRequired { return false }
        if hasAttachments || hasText || queuedCount > 0 { return true }
        // Empty input is allowed when the last message is from the user —
        // pressing send triggers the assistant reply on that message.
        return lastMessageIsFromUser
    }
}
