import Testing
import Foundation
@testable import iCanHazAI

/// Integration tests for [`ChatStore`](src/ChatStore.swift) backed by a real
/// temp directory and a real SwiftData cache (see [`TempEnv`](tests/AppTestHarness.swift)).
///
/// These exercise the store's full contract: save/load round-trips, cache
/// upsert/lookup, deletion, `startupSync` reconciliation (fresh, stale, missing,
/// undecodable), and the external-change hooks (`handleExternalChange` /
/// `handleExternalDeletion`) that the FSEvents router in
/// [`ChatEngine`](src/ChatEngine.swift) calls. The FSEvents delivery itself is
/// covered by [`ChatStoreFSEventsTests`](tests/ChatStoreTests.swift) below.
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

    @Test("saveChat writes pretty-printed, sorted-key JSON to disk")
    func saveChatEncoding() throws {
        env.store.saveChat(Fixtures.simpleChat(), filename: "a.json")
        let raw = try String(contentsOf: env.chatURL("a.json"), encoding: .utf8)
        // Pretty-printed → multi-line.
        #expect(raw.contains("\n"))
        // Sorted keys → "id" appears before "messages" in the output.
        let idRange = try #require(raw.range(of: "\"id\""))
        let msgRange = try #require(raw.range(of: "\"messages\""))
        #expect(raw.distance(from: raw.startIndex, to: idRange.lowerBound) <
                raw.distance(from: raw.startIndex, to: msgRange.lowerBound))
    }

    @Test("saveChat creates a cache entry with derived name and disk mod time")
    func saveUpdatesCache() throws {
        let chat = Fixtures.simpleChat() // first user msg "What is 2+2?"
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

    // MARK: - External change hooks

    @Test("handleExternalChange reloads an externally-written file and updates the cache")
    func handleExternalChangeReloads() throws {
        try env.writeChatDirect(Fixtures.chat(title: "External"), filename: "ext.json")
        #expect(env.store.getEntry(filename: "ext.json") == nil) // not yet in cache

        let chat = env.store.handleExternalChange(filename: "ext.json")
        #expect(chat?.title == "External")

        let entry = try #require(env.store.getEntry(filename: "ext.json"))
        #expect(entry.name == "External")
        #expect(entry.modificationTime == env.modificationDate("ext.json"))
    }

    @Test("handleExternalChange updates an existing cache entry in place")
    func handleExternalChangeUpserts() throws {
        env.store.saveChat(Fixtures.chat(title: "V1"), filename: "ext.json")
        try env.writeChatDirect(Fixtures.chat(title: "V2"), filename: "ext.json")

        let chat = env.store.handleExternalChange(filename: "ext.json")
        #expect(chat?.title == "V2")
        #expect(env.store.getAllEntries().count == 1)
        #expect(env.store.getEntry(filename: "ext.json")?.name == "V2")
    }

    @Test("handleExternalChange returns nil for a missing file")
    func handleExternalChangeMissing() {
        #expect(env.store.handleExternalChange(filename: "ghost.json") == nil)
        #expect(env.store.getEntry(filename: "ghost.json") == nil)
    }

    @Test("handleExternalChange returns nil for an undecodable file")
    func handleExternalChangeUndecodable() throws {
        try Data("{ broken".utf8).write(to: env.chatURL("bad.json"))
        #expect(env.store.handleExternalChange(filename: "bad.json") == nil)
        #expect(env.store.getEntry(filename: "bad.json") == nil)
    }

    @Test("handleExternalDeletion removes the cache entry but leaves the file")
    func handleExternalDeletion() throws {
        env.store.saveChat(Fixtures.simpleChat(), filename: "a.json")
        #expect(env.store.getEntry(filename: "a.json") != nil)

        env.store.handleExternalDeletion(filename: "a.json")

        #expect(env.store.getEntry(filename: "a.json") == nil)
        // handleExternalDeletion only reconciles the cache; the file itself is
        // the FSEvents router's concern (a removed-file event implies it's gone).
        #expect(env.diskFilenames() == ["a.json"])
    }

    @Test("handleExternalDeletion is safe for an unknown filename")
    func handleExternalDeletionUnknown() {
        env.store.handleExternalDeletion(filename: "ghost.json")
        #expect(env.store.getAllEntries() == [])
    }

    // MARK: - Delegates

    @Test("newChatFilename produces a timestamped .json filename")
    func newChatFilename() {
        let name = env.store.newChatFilename()
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}\.json$"#
        #expect(name.range(of: pattern, options: .regularExpression) != nil)
    }

    @Test("newChatFilename returns distinct values across a second boundary")
    func newChatFilenameDistinct() {
        // newChatFilename() is second-granular, so two calls in the same second
        // yield the same name; across a second boundary they differ.
        let a = env.store.newChatFilename()
        let sameSecond = env.store.newChatFilename()
        #expect(a == sameSecond)

        Thread.sleep(forTimeInterval: 1.1)
        let b = env.store.newChatFilename()
        #expect(a != b)
    }
}
} // extension AllAppTests

// MARK: - FSEvents integration

/// Verifies that [`EnvironmentWatcher`](src/EnvironmentWatcher.swift) actually
/// delivers FSEvents for chat-file changes, and that routing those events
/// through the store's external-change hooks (as
/// [`ChatEngine.handleFSEvent`](src/ChatEngine.swift:279) does) keeps the cache
/// in sync. These are real filesystem events on a temp directory, so they use
/// generous timeouts via [`FSEventCollector`](tests/AppTestHarness.swift).
extension AllAppTests {

@Suite("ChatStore.FSEvents", .serialized, .timeLimit(.minutes(2)))
struct ChatStoreFSEventsTests {

    let env: TempEnv
    init() throws { env = try TempEnv() }

    @Test("watcher delivers an event when a chat file is created externally")
    func eventOnCreate() throws {
        let collector = FSEventCollector(rootPath: env.rootURL.path)
        defer { _ = collector } // keep watcher alive for the test duration

        try env.writeChatDirect(Fixtures.chat(title: "Created"), filename: "created.json")

        #expect(collector.waitForFile("created.json"), "expected an FSEvent for created.json")
    }

    @Test("watcher delivers an event when a chat file is modified externally")
    func eventOnModify() throws {
        try env.writeChatDirect(Fixtures.chat(title: "V1"), filename: "m.json")
        let collector = FSEventCollector(rootPath: env.rootURL.path)
        defer { _ = collector }

        try env.modifyChatDirect("m.json") { $0.title = "V2" }

        #expect(collector.waitForFile("m.json"))
    }

    @Test("watcher delivers an event when a chat file is deleted externally")
    func eventOnDelete() throws {
        try env.writeChatDirect(Fixtures.chat(title: "Doomed"), filename: "del.json")
        let collector = FSEventCollector(rootPath: env.rootURL.path)
        defer { _ = collector }

        env.deleteChatDirect("del.json")

        #expect(collector.waitForFile("del.json"))
    }

    @Test("routing a create event through the store populates the cache")
    func createEventUpdatesCache() throws {
        let collector = FSEventCollector(rootPath: env.rootURL.path)
        defer { _ = collector }
        try env.writeChatDirect(Fixtures.chat(title: "Synced"), filename: "sync.json")

        // Wait for the event, then do what the engine does on a chat-file event.
        #expect(collector.waitForFile("sync.json"))
        let chat = try #require(env.store.handleExternalChange(filename: "sync.json"))
        #expect(chat.title == "Synced")
        #expect(env.store.getEntry(filename: "sync.json")?.name == "Synced")
    }

    @Test("routing a delete event through the store clears the cache entry")
    func deleteEventClearsCache() throws {
        env.store.saveChat(Fixtures.chat(title: "Cached"), filename: "gone.json")
        #expect(env.store.getEntry(filename: "gone.json") != nil)

        let collector = FSEventCollector(rootPath: env.rootURL.path)
        defer { _ = collector }
        env.deleteChatDirect("gone.json")
        #expect(collector.waitForFile("gone.json"))

        // The engine routes a removed-file chat event to handleExternalDeletion.
        env.store.handleExternalDeletion(filename: "gone.json")
        #expect(env.store.getEntry(filename: "gone.json") == nil)
    }
}

} // extension AllAppTests
