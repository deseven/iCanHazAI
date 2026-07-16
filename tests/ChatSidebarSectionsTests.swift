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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()
}

} // extension AllAppTests
