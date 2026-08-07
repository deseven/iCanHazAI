import Testing
import Foundation
@testable import iCanHazAI

/// Tests for [`ChatSidebar.dateSections(for:)`](src/Views/ChatSidebar.swift) —
/// the day-based grouping of chats into "Today", "Yesterday", and dated
/// sections. Pure logic (no UI), so it can be unit-tested directly.
extension AllAppTests {

@Suite("ChatSidebarSections")
struct ChatSidebarSectionsTests {

    /// Builds a `ChatSummary` with a given sort key (the only field
    /// `dateSections` inspects).
    private func summary(_ id: String, sortKey: Date) -> ChatSummary {
        ChatSummary(record: ChatRecord(
            filename: id,
            chat: nil,
            cachedLastActivity: sortKey
        ))
    }

    @Test("empty input yields no sections")
    func emptySections() {
        #expect(ChatSidebar.dateSections(for: []).isEmpty)
    }

    @Test("chats from today are grouped under 'Today'")
    func todaySection() {
        let now = Date()
        let sections = ChatSidebar.dateSections(for: [
            summary("a.json", sortKey: now)
        ])
        #expect(sections.count == 1)
        #expect(sections[0].title == "Today")
        #expect(sections[0].items.map(\.filename) == ["a.json"])
    }

    @Test("chats from yesterday are grouped under 'Yesterday'")
    func yesterdaySection() {
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        let sections = ChatSidebar.dateSections(for: [
            summary("a.json", sortKey: yesterday)
        ])
        #expect(sections.count == 1)
        #expect(sections[0].title == "Yesterday")
    }

    @Test("older chats use the 'Thu 16 Jul 2026' date format")
    func olderDateSection() {
        let cal = Calendar.current
        // 3 days ago — definitely not today or yesterday.
        let older = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date()))!
        let sections = ChatSidebar.dateSections(for: [
            summary("a.json", sortKey: older)
        ])
        #expect(sections.count == 1)
        // Title should match the "EEE d MMM yyyy" format, e.g. "Sun 13 Jul 2026".
        let expected = Self.dateFormatter.string(from: cal.startOfDay(for: older))
        #expect(sections[0].title == expected)
    }

    @Test("sections are ordered most-recent first")
    func sectionOrdering() {
        let cal = Calendar.current
        let now = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: now))!
        let sections = ChatSidebar.dateSections(for: [
            summary("old.json", sortKey: twoDaysAgo),
            summary("today.json", sortKey: now),
            summary("yesterday.json", sortKey: yesterday),
        ])
        #expect(sections.count == 3)
        #expect(sections[0].title == "Today")
        #expect(sections[1].title == "Yesterday")
        #expect(sections[2].title != "Today")
        #expect(sections[2].title != "Yesterday")
    }

    @Test("chats within the same day are in the same section, sorted descending")
    func sameDayGrouping() {
        let cal = Calendar.current
        let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        let afternoon = cal.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        let sections = ChatSidebar.dateSections(for: [
            summary("morning.json", sortKey: morning),
            summary("afternoon.json", sortKey: afternoon),
        ])
        #expect(sections.count == 1)
        #expect(sections[0].title == "Today")
        // Afternoon (later) should come first within the section.
        #expect(sections[0].items.map(\.filename) == ["afternoon.json", "morning.json"])
    }

    @Test("chats from different days on the same calendar date are grouped together")
    func sameCalendarDateDifferentTime() {
        let cal = Calendar.current
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let midnight = cal.date(bySettingHour: 0, minute: 0, second: 0, of: Date())!
        let sections = ChatSidebar.dateSections(for: [
            summary("noon.json", sortKey: noon),
            summary("midnight.json", sortKey: midnight),
        ])
        #expect(sections.count == 1)
        #expect(sections[0].items.count == 2)
    }

    @Test("sidebar entries flatten sections into headers and rows with stable ids")
    func sidebarEntriesFlattening() {
        let cal = Calendar.current
        let now = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
        let entries = ChatSidebar.sidebarEntries(for: [
            summary("today.json", sortKey: now),
            summary("yesterday.json", sortKey: yesterday),
        ])
        #expect(entries.map(\.id) == ["section:Today", "today.json", "section:Yesterday", "yesterday.json"])
    }

    @Test("sidebar entries mark every row except the last in a section with a divider")
    func sidebarEntriesDividers() {
        let cal = Calendar.current
        let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        let afternoon = cal.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        let entries = ChatSidebar.sidebarEntries(for: [
            summary("morning.json", sortKey: morning),
            summary("afternoon.json", sortKey: afternoon),
        ])
        let dividers = entries.compactMap { entry -> (String, Bool)? in
            guard case .row(let item, let showsDivider) = entry else { return nil }
            return (item.filename, showsDivider)
        }
        #expect(dividers.count == 2)
        #expect(dividers[0].0 == "afternoon.json" && dividers[0].1 == true)
        #expect(dividers[1].0 == "morning.json" && dividers[1].1 == false)
    }

    @Test("sidebar entries keep row ids stable when a chat moves to another day section")
    func sidebarEntriesStableIDsAcrossDayRollover() {
        // Simulates the stuck-selection scenario: a chat rendered under
        // "Today" keeps its identity when it later falls under "Yesterday",
        // so SwiftUI treats it as the same view (a reorder, not a recreate).
        let cal = Calendar.current
        let now = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
        let before = ChatSidebar.sidebarEntries(for: [
            summary("other-today.json", sortKey: now),
            summary("moved.json", sortKey: now),
        ])
        let after = ChatSidebar.sidebarEntries(for: [
            summary("other-today.json", sortKey: now),
            summary("moved.json", sortKey: yesterday),
        ])
        #expect(before.map(\.id).contains("moved.json"))
        #expect(after.map(\.id).contains("moved.json"))
        #expect(after.map(\.id).count == Set(after.map(\.id)).count)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()
}

@Suite("ChatSidebarFilter")
struct ChatSidebarFilterTests {

    /// Builds a `ChatSummary` with a display title (via the cached name) and
    /// a filename — the two fields `filterChats` matches against.
    private func summary(_ filename: String, title: String) -> ChatSummary {
        ChatSummary(record: ChatRecord(filename: filename, cachedName: title))
    }

    @Test("empty query returns the list unchanged")
    func emptyQuery() {
        let items = [summary("a.json", title: "Alpha"), summary("b.json", title: "Beta")]
        #expect(ChatSidebar.filterChats(items, query: "").map(\.filename) == ["a.json", "b.json"])
        #expect(ChatSidebar.filterChats(items, query: "   ").map(\.filename) == ["a.json", "b.json"])
    }

    @Test("fuzzy match on the display title")
    func fuzzyTitleMatch() {
        let items = [
            summary("a.json", title: "Deploy scripts"),
            summary("b.json", title: "Grocery list"),
        ]
        // "dpl" fuzzy-matches "Deploy scripts" but not "Grocery list".
        #expect(ChatSidebar.filterChats(items, query: "dpl").map(\.filename) == ["a.json"])
    }

    @Test("exact substring match on the filename, case-insensitive")
    func filenameMatch() {
        let items = [
            summary("2026-08-07-chat-one.json", title: "Unrelated title"),
            summary("other.json", title: "Also unrelated"),
        ]
        #expect(ChatSidebar.filterChats(items, query: "CHAT-ONE").map(\.filename) == ["2026-08-07-chat-one.json"])
    }

    @Test("filename match includes chats the fuzzy title pass missed")
    func filenameMatchAppendedAfterTitleMatches() {
        let items = [
            summary("match-in-filename.json", title: "Nothing alike"),
            summary("plain.json", title: "Match in title"),
        ]
        let result = ChatSidebar.filterChats(items, query: "match")
        // Title match ranks first; the filename-only match follows.
        #expect(result.map(\.filename) == ["plain.json", "match-in-filename.json"])
    }

    @Test("a chat matching both title and filename appears only once")
    func noDuplicates() {
        let items = [summary("deploy.json", title: "Deploy chat")]
        #expect(ChatSidebar.filterChats(items, query: "deploy").map(\.filename) == ["deploy.json"])
    }

    @Test("non-matching query yields an empty list")
    func noMatches() {
        let items = [summary("a.json", title: "Alpha")]
        #expect(ChatSidebar.filterChats(items, query: "zzzzzz").isEmpty)
    }
}

} // extension AllAppTests
