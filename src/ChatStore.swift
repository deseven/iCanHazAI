// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SwiftData

/// The chat data abstraction layer. Owns the SwiftData metadata cache and
/// all chat file I/O. Callers (ChatEngine) never touch chat files directly —
/// they go through this store to read, write, or delete chat data.
///
/// The store maintains a SwiftData cache of chat metadata (filename, display
/// name, file modification time) so the sidebar can be populated without
/// reading any chat JSON files. Full chat data is loaded from disk on demand
/// and is not cached by the store — the engine holds loaded chats in its
/// `records` array and manages their lifecycle.
///
/// All SwiftData operations are serialized on a private dispatch queue to
/// ensure `ModelContext` is only accessed from one serialization domain.
/// File I/O delegates to `EnvironmentManager` (already `@unchecked Sendable`).
final class ChatStore: @unchecked Sendable {

    static let shared: ChatStore = {
        guard let store = ChatStore(env: EnvironmentManager.shared) else {
            fatalError("Failed to initialize ChatStore — SwiftData cache unavailable")
        }
        return store
    }()

    private let container: ModelContainer
    private let queue = DispatchQueue(label: "iCanHazAI.chatStore")
    private let env: EnvironmentManager

    /// Internal initializer taking an explicit `EnvironmentManager`, so tests
    /// can back the store with a temp directory instead of `~/iCanHazAI`.
    /// Each store gets its own SwiftData SQLite cache file under the env's
    /// `.cache` directory, so parallel test stores don't collide.
    init?(env: EnvironmentManager) {
        self.env = env
        let cacheDir = env.rootURL.appendingPathComponent(".cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let storeURL = cacheDir.appendingPathComponent("chat.cache")
        let config = ModelConfiguration(url: storeURL)
        do {
            container = try ModelContainer(for: ChatCacheEntry.self, configurations: config)
        } catch {
            debugLog("ChatStore", "failed to create ModelContainer: \(error)")
            return nil
        }
    }

    /// A per-queue `ModelContext`, created lazily on first access within the
    /// queue. SwiftData's `ModelContext` is not thread-safe, so we confine it
    /// to the serial queue.
    private var _context: ModelContext?
    private var context: ModelContext {
        if let ctx = _context { return ctx }
        let ctx = ModelContext(container)
        _context = ctx
        return ctx
    }

    // MARK: - Startup sync

    /// Synchronizes the cache with the chats directory. For each chat file on
    /// disk, compares its modification time against the cache entry:
    /// - If the cache is fresh (mod time matches) → skip (no file read needed).
    /// - If the cache is stale or missing → load the chat, extract metadata,
    ///   update the cache.
    ///
    /// Cache entries whose files no longer exist are removed. Returns the
    /// full set of cache entries after sync, so the engine can populate its
    /// records in one shot.
    @discardableResult
    func startupSync() -> [ChatCacheInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: env.chatsURL, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            queue.sync { clearAllCacheEntries() }
            return []
        }

        let chatFiles = files.filter { $0.pathExtension == "json" }
        var diskFilenames = Set<String>()

        for file in chatFiles {
            let filename = file.lastPathComponent
            diskFilenames.insert(filename)

            let diskModTime = file.modificationDate ?? Date()

            // Check if cache has a fresh entry.
            let isFresh = queue.sync {
                if let cached = fetchEntry(filename: filename) {
                    if cached.modificationTime == diskModTime {
                        return true
                    }
                    debugLog("ChatStore", "stale: \(filename) — cached=\(cached.modificationTime.timeIntervalSince1970) disk=\(diskModTime.timeIntervalSince1970)")
                    return false
                }
                debugLog("ChatStore", "no cache entry: \(filename)")
                return false
            }
            if isFresh { continue }

            // Cache is stale or missing — load the chat to extract metadata.
            debugLog("ChatStore", "startup sync — loading \(env.relativePath(file)) (stale or new cache entry)")
            if let chat = env.loadSingleChat(filename: filename) {
                queue.sync {
                    upsertCache(filename: filename, chat: chat, modificationTime: diskModTime)
                }
            }
        }

        // Remove cache entries for files that no longer exist on disk.
        let allEntries = queue.sync { fetchAllEntries() }
        debugLog("ChatStore", "startup sync — \(allEntries.count) entries in context, \(diskFilenames.count) files on disk")
        for entry in allEntries where !diskFilenames.contains(entry.filename) {
            debugLog("ChatStore", "startup sync — removing stale cache entry \(entry.filename)")
            queue.sync { removeCacheEntry(filename: entry.filename) }
        }

        let final = queue.sync { fetchAllEntries() }
        debugLog("ChatStore", "startup sync — done, \(final.count) entries")
        return final
    }

    // MARK: - Cache reads

    /// Returns all cache entries (for populating the sidebar on startup).
    func getAllEntries() -> [ChatCacheInfo] {
        queue.sync { fetchAllEntries() }
    }

    /// Returns a single cache entry by filename.
    func getEntry(filename: String) -> ChatCacheInfo? {
        queue.sync {
            guard let entry = fetchEntry(filename: filename) else { return nil }
            return ChatCacheInfo(filename: entry.filename, name: entry.name, role: entry.role, modificationTime: entry.modificationTime)
        }
    }

    // MARK: - Chat data access

    /// Loads a chat from disk. This is the only way to get full chat data
    /// (messages, settings, etc.). The store does not cache chat data in
    /// memory — the engine is responsible for holding loaded chats and
    /// unloading them when inactive.
    func loadChat(filename: String) -> Chat? {
        env.loadSingleChat(filename: filename)
    }

    /// Writes a chat to disk and updates the cache. The file modification
    /// time is read back from disk after writing so the cache exactly
    /// matches what FSEvents will report.
    func saveChat(_ chat: Chat, filename: String) {
        env.saveChat(chat, filename: filename)
        let url = env.chatsURL.appendingPathComponent(filename)
        let modTime = url.modificationDate ?? Date()
        queue.sync {
            upsertCache(filename: filename, chat: chat, modificationTime: modTime)
        }
    }

    /// Deletes a chat file and removes its cache entry. Safe to call for
    /// chats that were never persisted to disk (no file, no cache entry).
    func deleteChat(filename: String) {
        env.deleteChat(filename: filename)
        queue.sync { removeCacheEntry(filename: filename) }
    }

    // MARK: - External change handling

    /// Called when an FSEvent indicates a chat file was externally modified
    /// or created. Reloads the chat from disk, updates the cache, and returns
    /// the new chat so the engine can update its in-memory record if needed.
    /// Returns nil if the file is missing or undecodable.
    @discardableResult
    func handleExternalChange(filename: String) -> Chat? {
        let url = env.chatsURL.appendingPathComponent(filename)
        let modTime = url.modificationDate ?? Date()
        guard let chat = env.loadSingleChat(filename: filename) else {
            return nil
        }
        queue.sync {
            upsertCache(filename: filename, chat: chat, modificationTime: modTime)
        }
        return chat
    }

    /// Called when an FSEvent indicates a chat file was externally deleted.
    /// Removes the cache entry.
    func handleExternalDeletion(filename: String) {
        debugLog("ChatStore", "handleExternalDeletion — \(filename)")
        queue.sync { removeCacheEntry(filename: filename) }
    }

    // MARK: - Delegates

    func newChatFilename() -> String {
        env.newChatFilename()
    }

    // MARK: - SwiftData helpers (must be called within `queue.sync`)

    private func fetchAllEntries() -> [ChatCacheInfo] {
        let descriptor = FetchDescriptor<ChatCacheEntry>(sortBy: [SortDescriptor(\.modificationTime, order: .reverse)])
        guard let entries = try? context.fetch(descriptor) else { return [] }
        return entries.map { ChatCacheInfo(filename: $0.filename, name: $0.name, role: $0.role, modificationTime: $0.modificationTime) }
    }

    private func fetchEntry(filename: String) -> ChatCacheEntry? {
        let descriptor = FetchDescriptor<ChatCacheEntry>(predicate: #Predicate { $0.filename == filename })
        return try? context.fetch(descriptor).first
    }

    private func upsertCache(filename: String, chat: Chat, modificationTime: Date) {
        if let existing = fetchEntry(filename: filename) {
            existing.name = chat.cacheName
            existing.role = chat.role
            existing.modificationTime = modificationTime
        } else {
            let entry = ChatCacheEntry(filename: filename, name: chat.cacheName, role: chat.role, modificationTime: modificationTime)
            context.insert(entry)
        }
        do {
            try context.save()
        } catch {
            debugLog("ChatStore", "⚠️ context.save FAILED for \(filename): \(error)")
        }
    }

    private func removeCacheEntry(filename: String) {
        if let entry = fetchEntry(filename: filename) {
            context.delete(entry)
            do {
                try context.save()
            } catch {
                debugLog("ChatStore", "⚠️ removeCacheEntry save FAILED for \(filename): \(error)")
            }
        }
    }

    private func clearAllCacheEntries() {
        if let entries = try? context.fetch(FetchDescriptor<ChatCacheEntry>()) {
            for entry in entries {
                context.delete(entry)
            }
            try? context.save()
        }
    }
}

// MARK: - Chat cache name derivation

extension Chat {
    /// Derives a display name for the cache: the user-defined title if set,
    /// otherwise a preview of the first user message. Nil for truly empty
    /// chats (no title, no user messages).
    var cacheName: String? {
        if let title = title, !title.isEmpty { return title }
        if let firstUser = messages.first(where: { $0.role == .user }) {
            let trimmed = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(40)) }
        }
        return nil
    }
}

// MARK: - URL modification date helper

private extension URL {
    /// Returns the file's content modification date, rounded to the nearest
    /// second to avoid precision mismatches between SwiftData's SQLite
    /// storage and `FileManager.attributesOfItem`. Nil if it can't be read.
    var modificationDate: Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        guard let date = attrs[.modificationDate] as? Date else { return nil }
        return Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
    }
}
