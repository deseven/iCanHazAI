// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// An unsent chat input draft: the composed text plus any pending image
/// attachments. Runtime-only — never persisted to disk.
struct ChatInputDraft: Equatable {
    var text: String = ""
    var images: [PendingImageAttachment] = []

    var isEmpty: Bool { text.isEmpty && images.isEmpty }
}

/// Runtime-only store for per-chat input drafts, keyed by chat filename.
/// Lets the user switch chats mid-composition without losing their unsent
/// input. Empty drafts are pruned so the store doesn't accumulate dead entries.
struct InputDraftStore {
    private var drafts: [String: ChatInputDraft] = [:]

    func draft(for filename: String) -> ChatInputDraft? { drafts[filename] }

    mutating func set(_ draft: ChatInputDraft, for filename: String) {
        if draft.isEmpty {
            drafts.removeValue(forKey: filename)
        } else {
            drafts[filename] = draft
        }
    }

    mutating func remove(for filename: String) {
        drafts.removeValue(forKey: filename)
    }

    /// Drops drafts belonging to temporary chats that no longer exist.
    /// Temporary chats are destroyed without a user-facing deletion step, so
    /// their drafts would otherwise linger forever (their UUID filenames are
    /// never reused).
    mutating func removeStaleTemporaryDrafts(validFilenames: Set<String>) {
        drafts = drafts.filter { key, _ in
            !EnvironmentManager.isTemporaryChatFilename(key) || validFilenames.contains(key)
        }
    }
}
