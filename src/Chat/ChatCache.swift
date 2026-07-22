// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SwiftData

/// SwiftData-backed cache entry for a chat's metadata. Stores just enough
/// to populate the sidebar (filename, display name, role, modification time)
/// without loading the full chat JSON from disk.
@Model
final class ChatCacheEntry {
    /// The chat filename, e.g. "2026-07-12 14-30-00.json". Unique.
    @Attribute(.unique) var filename: String
    /// Derived display name: the chat's title if set, otherwise a preview of
    /// the first user message. Nil when the chat is truly empty (no title,
    /// no user messages) — the UI shows "New chat" in that case.
    var name: String?
    /// Cached role name (filename of the role TOML, without extension).
    /// Mirrors `Chat.role` so the sidebar can badge each chat with its role
    /// without reading the full chat JSON. Nil for chats created before this
    /// field existed or chats with no role set.
    var role: String?
    /// File modification time of the chat JSON on disk. Used to detect
    /// external changes: if the file's mod time differs from this, the
    /// cache is stale and the file must be re-read. NOT used for sorting —
    /// see `lastActivity`.
    var modificationTime: Date
    /// Cached archive flag. Mirrors `Chat.archive` so the sidebar can hide
    /// archived chats without reading the full chat JSON. Defaults to false
    /// for chats created before this field existed.
    var archive: Bool
    /// Cached last-activity time (the most recent message timestamp, or
    /// `distantPast` for empty chats). Used as the sidebar sort key for
    /// unloaded chats. Distinct from `modificationTime` because a file can
    /// be touched without adding messages (e.g. a rename), and sorting by
    /// mod time would then mis-order chats relative to their real activity.
    var lastActivity: Date

    init(filename: String, name: String?, role: String?, modificationTime: Date, archive: Bool = false, lastActivity: Date = .distantPast) {
        self.filename = filename
        self.name = name
        self.role = role
        self.modificationTime = modificationTime
        self.archive = archive
        self.lastActivity = lastActivity
    }
}

/// A sendable snapshot of a cache entry, returned by the cache helpers so
/// callers don't need to touch the SwiftData model objects directly.
struct ChatCacheInfo: Sendable, Equatable {
    let filename: String
    let name: String?
    let role: String?
    let modificationTime: Date
    let archive: Bool
    let lastActivity: Date
}
