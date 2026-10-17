import Foundation
import Testing

@testable import iCanHazAI

/// Runs `body` with stderr redirected to /dev/null, restoring it afterward.
/// Used to silence the framework-level `CoreData: error:` log SwiftData emits
/// when it fails to open a deliberately-corrupt store in the self-heal test.
private func suppressingStderr<T>(_ body: () throws -> T) rethrows -> T {
    let originalFD = dup(STDERR_FILENO)
    let devNull = open("/dev/null", O_WRONLY)
    dup2(devNull, STDERR_FILENO)
    defer {
        if originalFD != -1 {
            dup2(originalFD, STDERR_FILENO)
            close(originalFD)
        }
        if devNull != -1 { close(devNull) }
    }
    return try body()
}

/// Integration tests for [`ChatStore`](src/Chat/ChatStore.swift) backed by a real
/// temp directory and a real SwiftData cache (see [`TempEnv`](tests/AppTestHarness.swift)).
///
/// These exercise the store's full contract: save/load round-trips, cache
/// upsert/lookup, deletion, `startupSync` reconciliation (fresh, stale, missing,
/// undecodable).
///
/// Each test gets its own `TempEnv` (fresh temp root + fresh ChatStore + fresh
/// SQLite cache), so there's no cross-test state. The suite is nested under
/// `AllAppTests` so its `.serialized` trait runs these one at a time.
extension AllAppTests {

    @Suite("ChatStore")
    struct ChatStoreTests {

        let env: TempEnv
        init() throws { env = try TempEnv() }

        // MARK: - Empty state

        @Test("empty environment has no cache entries")
        func emptyCache() {
            #expect(env.store.getAllEntries() == [])
            #expect(env.store.getEntry(filename: "nope.json") == nil)
            #expect(env.store.loadChat(filename: "nope.json") == nil)
        }

        // MARK: - Save / load

        @Test("saveChat persists the file and loadChat reads it back")
        func saveThenLoad() throws {
            let chat = Fixtures.simpleChat(title: "Round Trip")
            env.store.saveChat(chat, filename: "a.json")

            #expect(env.diskFilenames() == ["a.json"])
            let loaded = env.store.loadChat(filename: "a.json")
            #expect(loaded == chat)
        }

        @Test("saveChat persists the per-chat auto_allow list")
        func saveThenLoadAutoAllow() throws {
            var chat = Fixtures.simpleChat()
            chat.autoAllow = ["read_file", "mcp__Tavily__search"]
            env.store.saveChat(chat, filename: "a.json")

            let raw = try String(contentsOf: env.chatURL("a.json"), encoding: .utf8)
            #expect(raw.contains("\"auto_allow\""))
            #expect(env.store.loadChat(filename: "a.json")?.autoAllow == ["read_file", "mcp__Tavily__search"])
        }

        @Test("saveChat writes pretty-printed, sorted-key JSON to disk")
        func saveChatEncoding() throws {
            env.store.saveChat(Fixtures.simpleChat(), filename: "a.json")
            let raw = try String(contentsOf: env.chatURL("a.json"), encoding: .utf8)
            // Pretty-printed → multi-line.
            #expect(raw.contains("\n"))
            // Sorted keys → "id" appears before "messages" in the output.
            let idRange = try #require(raw.range(of: "\"id\""))
            let msgRange = try #require(raw.range(of: "\"messages\""))
            #expect(
                raw.distance(from: raw.startIndex, to: idRange.lowerBound)
                    < raw.distance(from: raw.startIndex, to: msgRange.lowerBound))
        }

        @Test("saveChat creates a cache entry with derived name and disk mod time")
        func saveUpdatesCache() throws {
            let chat = Fixtures.simpleChat()  // first user msg "What is 2+2?"
            env.store.saveChat(chat, filename: "a.json")

            let entry = try #require(env.store.getEntry(filename: "a.json"))
            #expect(entry.filename == "a.json")
            #expect(entry.name == "What is 2+2?")
            #expect(entry.modificationTime == env.modificationDate("a.json"))
        }

        @Test("saveChat on an untitled, empty chat caches a nil name")
        func saveEmptyChatCachesNilName() throws {
            env.store.saveChat(Fixtures.chat(messages: []), filename: "empty.json")
            let entry = try #require(env.store.getEntry(filename: "empty.json"))
            #expect(entry.name == nil)
        }

        @Test("saveChat caches the chat's role")
        func saveCachesRole() throws {
            env.store.saveChat(Fixtures.chat(role: "Assistant"), filename: "a.json")
            let entry = try #require(env.store.getEntry(filename: "a.json"))
            #expect(entry.role == "Assistant")
        }

        @Test("saveChat caches a nil role when the chat has none")
        func saveCachesNilRole() throws {
            env.store.saveChat(Fixtures.chat(role: nil), filename: "a.json")
            let entry = try #require(env.store.getEntry(filename: "a.json"))
            #expect(entry.role == nil)
        }

        @Test("re-saving with a new role updates the cached role")
        func saveUpsertsRole() throws {
            env.store.saveChat(Fixtures.chat(role: "Assistant"), filename: "a.json")
            try env.setModificationDate("a.json", Date(timeIntervalSince1970: 1_000))
            env.store.saveChat(Fixtures.chat(role: "Developer"), filename: "a.json")
            let entry = try #require(env.store.getEntry(filename: "a.json"))
            #expect(entry.role == "Developer")
        }

        @Test("startupSync caches the role for chats loaded from disk")
        func startupSyncCachesRole() throws {
            try env.writeChatDirect(Fixtures.chat(role: "Developer"), filename: "a.json")
            _ = env.store.startupSync()
            #expect(env.store.getEntry(filename: "a.json")?.role == "Developer")
        }

        // MARK: - Archive caching

        @Test("saveChat caches the archive flag")
        func saveCachesArchive() throws {
            env.store.saveChat(Fixtures.chat(archive: true), filename: "a.json")
            let entry = try #require(env.store.getEntry(filename: "a.json"))
            #expect(entry.archive == true)
        }

        @Test("saveChat caches a false archive flag")
        func saveCachesFalseArchive() throws {
            env.store.saveChat(Fixtures.chat(archive: false), filename: "a.json")
            let entry = try #require(env.store.getEntry(filename: "a.json"))
            #expect(entry.archive == false)
        }

        @Test("saveChat defaults archive to false when nil")
        func saveCachesNilArchive() throws {
            env.store.saveChat(Fixtures.chat(archive: nil), filename: "a.json")
            let entry = try #require(env.store.getEntry(filename: "a.json"))
            #expect(entry.archive == false)
        }

        @Test("re-saving with a new archive flag updates the cache")
        func saveUpsertsArchive() throws {
            env.store.saveChat(Fixtures.chat(archive: false), filename: "a.json")
            try env.setModificationDate("a.json", Date(timeIntervalSince1970: 1_000))
            env.store.saveChat(Fixtures.chat(archive: true), filename: "a.json")
            let entry = try #require(env.store.getEntry(filename: "a.json"))
            #expect(entry.archive == true)
        }

        @Test("startupSync caches the archive flag for chats loaded from disk")
        func startupSyncCachesArchive() throws {
            try env.writeChatDirect(Fixtures.chat(archive: true), filename: "a.json")
            _ = env.store.startupSync()
            #expect(env.store.getEntry(filename: "a.json")?.archive == true)
        }

        @Test("startupSync picks up an externally-removed archive flag")
        func startupSyncRemovesArchive() throws {
            // First sync: chat is archived.
            try env.writeChatDirect(Fixtures.chat(archive: true), filename: "a.json")
            _ = env.store.startupSync()
            #expect(env.store.getEntry(filename: "a.json")?.archive == true)
            // Externally rewrite without the archive flag and force a later mod time.
            try env.writeChatDirect(Fixtures.chat(archive: nil), filename: "a.json")
            try env.setModificationDate("a.json", Date(timeIntervalSince1970: 9_000))
            _ = env.store.startupSync()
            #expect(env.store.getEntry(filename: "a.json")?.archive == false)
        }

        // MARK: - lastActivity caching

        @Test("saveChat caches the last message timestamp as lastActivity")
        func saveCachesLastActivity() throws {
            let ts = Date(timeIntervalSince1970: 1_700_000_010)
            let chat = Fixtures.chat(messages: [
                Fixtures.message(role: .user, content: "hi", timestamp: Date(timeIntervalSince1970: 1_700_000_000)),
                Fixtures.message(role: .assistant, content: "yo", timestamp: ts),
            ])
            env.store.saveChat(chat, filename: "a.json")
            let entry = try #require(env.store.getEntry(filename: "a.json"))
            #expect(entry.lastActivity == ts)
        }

        @Test("saveChat falls back to modification time for an empty chat")
        func saveCachesLastActivityFallback() throws {
            let chat = Fixtures.chat(messages: [])
            env.store.saveChat(chat, filename: "a.json")
            let entry = try #require(env.store.getEntry(filename: "a.json"))
            #expect(entry.lastActivity == entry.modificationTime)
        }

        @Test("startupSync caches lastActivity from the chat's last message")
        func startupSyncCachesLastActivity() throws {
            let ts = Date(timeIntervalSince1970: 1_700_000_050)
            try env.writeChatDirect(
                Fixtures.chat(messages: [
                    Fixtures.message(role: .user, content: "hi", timestamp: Date(timeIntervalSince1970: 1_700_000_000)),
                    Fixtures.message(role: .assistant, content: "yo", timestamp: ts),
                ]), filename: "a.json")
            _ = env.store.startupSync()
            #expect(env.store.getEntry(filename: "a.json")?.lastActivity == ts)
        }

        @Test("getAllEntries is sorted by lastActivity descending")
        func getAllEntriesOrderedByLastActivity() throws {
            let early = Date(timeIntervalSince1970: 1_000)
            let late = Date(timeIntervalSince1970: 5_000)
            try env.writeChatDirect(
                Fixtures.chat(messages: [Fixtures.message(timestamp: early)]), filename: "early.json")
            try env.writeChatDirect(Fixtures.chat(messages: [Fixtures.message(timestamp: late)]), filename: "late.json")
            _ = env.store.startupSync()
            let entries = env.store.getAllEntries()
            #expect(entries.count == 2)
            #expect(entries[0].filename == "late.json")
            #expect(entries[1].filename == "early.json")
        }

        @Test("re-saving a filename upserts the cache instead of duplicating")
        func saveUpserts() throws {
            env.store.saveChat(Fixtures.chat(title: "First"), filename: "a.json")
            // Force a different mod time so the second save is distinguishable.
            try env.setModificationDate("a.json", Date(timeIntervalSince1970: 1_000))
            env.store.saveChat(Fixtures.chat(title: "Second"), filename: "a.json")

            #expect(env.store.getAllEntries().count == 1)
            let entry = try #require(env.store.getEntry(filename: "a.json"))
            #expect(entry.name == "Second")
            #expect(entry.modificationTime == env.modificationDate("a.json"))
        }

        @Test("getAllEntries lists all chats sorted by mod time descending")
        func getAllEntriesOrdering() throws {
            // Write two chats directly with deterministic, distinct mod times, then
            // reconcile so the cache picks up those disk mod times.
            try env.writeChatDirect(Fixtures.chat(title: "old"), filename: "old.json")
            try env.writeChatDirect(Fixtures.chat(title: "new"), filename: "new.json")
            try env.setModificationDate("old.json", Date(timeIntervalSince1970: 1_000))
            try env.setModificationDate("new.json", Date(timeIntervalSince1970: 5_000))
            _ = env.store.startupSync()

            let entries = env.store.getAllEntries()
            #expect(entries.count == 2)
            #expect(entries[0].filename == "new.json")
            #expect(entries[1].filename == "old.json")
        }

        // MARK: - Delete

        @Test("deleteChat removes the file and the cache entry")
        func deleteChat() throws {
            env.store.saveChat(Fixtures.simpleChat(), filename: "a.json")
            #expect(env.store.getEntry(filename: "a.json") != nil)

            env.store.deleteChat(filename: "a.json")

            #expect(env.diskFilenames() == [])
            #expect(env.store.getEntry(filename: "a.json") == nil)
            #expect(env.store.getAllEntries() == [])
        }

        @Test("deleteChat is safe for a never-saved filename")
        func deleteMissingSafe() {
            env.store.deleteChat(filename: "ghost.json")
            #expect(env.store.getAllEntries() == [])
        }

        // MARK: - startupSync

        @Test("startupSync on empty disk returns no entries")
        func startupSyncEmpty() {
            #expect(env.store.startupSync() == [])
        }

        @Test("startupSync loads every chat file into a fresh cache")
        func startupSyncLoadsAll() throws {
            try env.writeChatDirect(Fixtures.chat(title: "Alpha"), filename: "a.json")
            try env.writeChatDirect(Fixtures.chat(title: "Beta"), filename: "b.json")

            let entries = env.store.startupSync()
            #expect(Set(entries.map(\.filename)) == ["a.json", "b.json"])
            #expect(env.store.getEntry(filename: "a.json")?.name == "Alpha")
            #expect(env.store.getEntry(filename: "b.json")?.name == "Beta")
            // Mod times in the cache must match disk after sync.
            #expect(env.store.getEntry(filename: "a.json")?.modificationTime == env.modificationDate("a.json"))
        }

        @Test("startupSync skips cache entries whose mod time still matches disk")
        func startupSyncFreshSkip() throws {
            env.store.saveChat(Fixtures.chat(title: "Saved"), filename: "a.json")
            let cachedBefore = env.store.getEntry(filename: "a.json")

            // No disk change → startupSync should leave the entry intact (fresh).
            let entries = env.store.startupSync()
            #expect(entries.count == 1)
            #expect(env.store.getEntry(filename: "a.json") == cachedBefore)
        }

        @Test("startupSync reloads stale entries whose mod time differs from disk")
        func startupSyncReloadsStale() throws {
            env.store.saveChat(Fixtures.chat(title: "Original"), filename: "a.json")
            let originalModTime = try #require(env.modificationDate("a.json"))

            // Externally rewrite the file with new content and force a later mod
            // time so the cache is unambiguously stale.
            try env.writeChatDirect(Fixtures.chat(title: "Rewritten"), filename: "a.json")
            let newModTime = Date(timeIntervalSince1970: originalModTime.timeIntervalSince1970 + 60)
            try env.setModificationDate("a.json", newModTime)

            let entries = env.store.startupSync()
            #expect(entries.count == 1)

            let entry = try #require(env.store.getEntry(filename: "a.json"))
            #expect(entry.name == "Rewritten")
            #expect(entry.modificationTime == Date(timeIntervalSince1970: newModTime.timeIntervalSince1970.rounded()))
        }

        @Test("startupSync removes cache entries for files deleted from disk")
        func startupSyncRemovesDeleted() throws {
            env.store.saveChat(Fixtures.simpleChat(), filename: "a.json")
            // Simulate the file vanishing externally (cache entry left behind).
            env.deleteChatDirect("a.json")

            let entries = env.store.startupSync()
            #expect(entries == [])
            #expect(env.store.getEntry(filename: "a.json") == nil)
        }

        @Test("startupSync ignores non-JSON files in the chats directory")
        func startupSyncIgnoresNonJson() throws {
            try Data("not a chat".utf8).write(to: env.chatURL("notes.txt"))
            try env.writeChatDirect(Fixtures.chat(title: "Real"), filename: "real.json")

            let entries = env.store.startupSync()
            #expect(entries.map(\.filename) == ["real.json"])
        }

        @Test("startupSync skips undecodable JSON files without creating an entry")
        func startupSyncSkipsUndecodable() throws {
            try Data("{ this is not valid json".utf8).write(to: env.chatURL("broken.json"))

            let entries = env.store.startupSync()
            #expect(entries == [])
            #expect(env.store.getEntry(filename: "broken.json") == nil)
        }

        @Test("startupSync reports fresh/decoded/failed counts via lastStartupSyncStats")
        func startupSyncStats() throws {
            // a.json: already cached and fresh (skipped re-read).
            env.store.saveChat(Fixtures.chat(title: "Cached"), filename: "a.json")
            // b.json: on disk but uncached (decoded this pass).
            try env.writeChatDirect(Fixtures.chat(title: "New"), filename: "b.json")
            // broken.json: undecodable (failed this pass).
            try Data("{ broken".utf8).write(to: env.chatURL("broken.json"))

            _ = env.store.startupSync()
            let stats = try #require(env.store.lastStartupSyncStats())
            #expect(stats.totalFiles == 3)
            #expect(stats.freshCached == 1)
            #expect(stats.decoded == 1)
            #expect(stats.failed == 1)
        }

        @Test("ChatStore self-heals when the on-disk cache is corrupt")
        func selfHealCorruptCache() throws {
            // Use a standalone root (no pre-opened store) so corrupting the cache
            // file is deterministic — an already-open connection could mask it.
            let fm = FileManager.default
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ichai-selfheal-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }

            let env = EnvironmentManager(rootURL: root)
            env.ensureDirectories()

            // A real chat file on disk that startupSync should recover.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let chat = Fixtures.chat(messages: [Fixtures.message(role: .user, content: "hi")], title: "Heal")
            try encoder.encode(chat).write(to: env.chatsURL.appendingPathComponent("a.json"), options: .atomic)

            // Pre-create a corrupt cache so ModelContainer can't open it.
            let cacheDir = root.appendingPathComponent(".cache", isDirectory: true)
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try Data("definitely not a sqlite database".utf8).write(to: cacheDir.appendingPathComponent("chat.cache"))

            // The store self-heals: drops the corrupt cache and reopens empty.
            // (stderr is suppressed only to hide the expected CoreData open-failure
            // log the framework prints for the corrupt store.)
            let store = try #require(suppressingStderr { ChatStore(env: env) })
            #expect(store.getAllEntries() == [])

            // startupSync repopulates from the chat file on disk.
            let entries = store.startupSync()
            #expect(entries.count == 1)
            #expect(entries.first?.name == "Heal")
        }

        // MARK: - Delegates

        @Test("newChatFilename produces a timestamped .json filename")
        func newChatFilename() {
            let name = env.store.newChatFilename()
            let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}\.json$"#
            #expect(name.range(of: pattern, options: .regularExpression) != nil)
        }

        @Test("newChatFilename adds a numeric suffix when the timestamp name already exists")
        func newChatFilenameDeduplicatesExistingFiles() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let base = env.env.newChatFilename(now: now)
            let stem = (base as NSString).deletingPathExtension
            env.store.saveChat(Fixtures.simpleChat(), filename: base)
            env.store.saveChat(Fixtures.simpleChat(), filename: "\(stem) (2).json")

            let next = env.env.newChatFilename(now: now)
            #expect(next == "\(stem) (3).json")
        }

        @Test("newChatFilename avoids reserved in-memory filenames")
        func newChatFilenameAvoidsReservedFilenames() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let base = env.env.newChatFilename(now: now)
            let stem = (base as NSString).deletingPathExtension

            let next = env.env.newChatFilename(
                now: now, reservedFilenames: [base, "\(stem) (2).json"])
            #expect(next == "\(stem) (3).json")
        }
    }
}  // extension AllAppTests

// MARK: - shouldPersist

extension AllAppTests {

    @Suite("Chat.shouldPersist")
    struct ChatShouldPersistTests {

        @Test("shouldPersist is false for a chat with no messages and no title")
        func shouldPersistEmptyUntitled() {
            let chat = Fixtures.chat(messages: [], title: nil)
            #expect(chat.shouldPersist == false)
        }

        @Test("shouldPersist is false for a chat with no messages and an empty title")
        func shouldPersistEmptyEmptyTitle() {
            let chat = Fixtures.chat(messages: [], title: "")
            #expect(chat.shouldPersist == false)
        }

        @Test("shouldPersist is true for a chat with no messages but a non-empty title")
        func shouldPersistTitledEmpty() {
            let chat = Fixtures.chat(messages: [], title: "Plans for later")
            #expect(chat.shouldPersist == true)
        }

        @Test("shouldPersist is true for a chat with messages and no title")
        func shouldPersistHasMessages() {
            let chat = Fixtures.simpleChat(title: nil)
            #expect(chat.shouldPersist == true)
        }

        @Test("shouldPersist is true for a chat with messages and a title")
        func shouldPersistHasMessagesAndTitle() {
            let chat = Fixtures.simpleChat(title: "Math")
            #expect(chat.shouldPersist == true)
        }
    }

}  // extension AllAppTests
