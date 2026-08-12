import Foundation
import Testing

@testable import iCanHazAI

/// Tests for the archived-chats picker: which chats are listed, their order,
/// name/filename fuzzy filtering, and the selection-survival rule that lets
/// an archived chat stay open in the chat view without being unarchived.
extension AllAppTests {

    @Suite("ArchivedChatsPicker")
    struct ArchivedChatsPickerTests {

        private func record(
            _ filename: String,
            name: String? = nil,
            archived: Bool = true,
            lastActivity: Date = .distantPast,
            temporary: Bool = false
        ) -> ChatRecord {
            ChatRecord(
                filename: filename, cachedName: name, cachedArchive: archived, cachedLastActivity: lastActivity,
                isTemporary: temporary)
        }

        // MARK: - Filtering

        @Test("Only archived, non-temporary chats are listed")
        func listsOnlyArchived() {
            let records = [
                record("archived.json"),
                record("visible.json", archived: false),
                record("temp-x.json", temporary: true),
            ]
            let items = ArchivedChatsPickerView.filter(records, query: "")
            #expect(items.map(\.filename) == ["archived.json"])
        }

        @Test("Chats are sorted by last activity, newest first")
        func sortedByActivity() {
            let records = [
                record("old.json", lastActivity: Date(timeIntervalSince1970: 1000)),
                record("new.json", lastActivity: Date(timeIntervalSince1970: 3000)),
                record("mid.json", lastActivity: Date(timeIntervalSince1970: 2000)),
            ]
            let items = ArchivedChatsPickerView.filter(records, query: "")
            #expect(items.map(\.filename) == ["new.json", "mid.json", "old.json"])
        }

        @Test("Search matches the display name, case-insensitively")
        func searchByName() {
            let records = [
                record("a.json", name: "Deploy scripts"),
                record("b.json", name: "Cookie recipes"),
            ]
            let items = ArchivedChatsPickerView.filter(records, query: "deploy")
            #expect(items.map(\.filename) == ["a.json"])
        }

        @Test("Search matches the filename and ranks the best match first")
        func searchByFilename() {
            let records = [
                record("2026-01-02 10-20-30.json", name: "Something"),
                record("2026-07-08 11-22-33.json", name: "Other"),
            ]
            // Fuzzy matching may loosely include the other filename, but the
            // exact-substring match must be ranked first.
            let items = ArchivedChatsPickerView.filter(records, query: "2026-07")
            #expect(items.first?.filename == "2026-07-08 11-22-33.json")
        }

        @Test("A query matching nothing yields an empty list")
        func searchNoMatch() {
            let records = [record("a.json", name: "Deploy scripts")]
            #expect(ArchivedChatsPickerView.filter(records, query: "xyzzyplugh").isEmpty)
        }

        // MARK: - Selection survival

        @Test("Selection survives for the previewed archived chat only")
        func selectionSurvival() {
            let archived = record("a.json")
            let otherArchived = record("b.json")
            let visible = record("v.json", archived: false)
            #expect(AppViewModel.isSelectedChatVisible(visible, archivedPreviewID: nil))
            #expect(!AppViewModel.isSelectedChatVisible(archived, archivedPreviewID: nil))
            #expect(!AppViewModel.isSelectedChatVisible(archived, archivedPreviewID: "b.json"))
            #expect(AppViewModel.isSelectedChatVisible(archived, archivedPreviewID: "a.json"))
            #expect(!AppViewModel.isSelectedChatVisible(otherArchived, archivedPreviewID: "a.json"))
        }
    }
}
