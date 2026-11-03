import Foundation

/// The dock-icon badge: how many chats need the user's attention. A chat
/// counts once however much it has pending — an unread answer, one or several
/// tool calls awaiting approval, or both.
enum DockBadge {
    /// Chats with an unread answer. Archived chats are hidden from the UI, so
    /// they don't nag.
    static func unreadChatIDs(in records: [ChatRecord]) -> Set<String> {
        Set(records.lazy.filter { $0.hasUnreadActivity && !$0.isArchived }.map(\.filename))
    }

    static func count(unread: Set<String>, awaitingApproval: Set<String>) -> Int {
        unread.union(awaitingApproval).count
    }

    /// The tile label for `count`; nil removes the badge.
    static func label(for count: Int) -> String? {
        count > 0 ? String(count) : nil
    }
}
