import Foundation
import Testing

@testable import iCanHazAI

extension AllAppTests {
    @Suite("Dock badge")
    struct DockBadgeTests {

        @Test("only unread, non-archived chats count")
        func unreadChats() {
            let records = [
                ChatRecord(filename: "a.json", hasUnreadActivity: true),
                ChatRecord(filename: "b.json", hasUnreadActivity: false),
                ChatRecord(filename: "c.json", cachedArchive: true, hasUnreadActivity: true),
            ]
            #expect(DockBadge.unreadChatIDs(in: records) == ["a.json"])
        }

        @Test("a chat that is both unread and awaiting approval counts once")
        func chatCountsOnce() {
            #expect(DockBadge.count(unread: ["a", "b"], awaitingApproval: ["b", "c"]) == 3)
            #expect(DockBadge.count(unread: [], awaitingApproval: []) == 0)
        }

        @Test("no label at zero")
        func label() {
            #expect(DockBadge.label(for: 0) == nil)
            #expect(DockBadge.label(for: 3) == "3")
        }
    }
}
