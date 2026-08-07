import Testing
import AppKit
@testable import iCanHazAI

extension AllAppTests {

@Suite("Main split layout")
struct MainSplitLayoutTests {

    @Test("sidebar widths clamp to their supported ranges")
    func clampsSidebarWidths() {
        let narrow = MainSplitLayout.paneWidths(totalWidth: 1024, dividerThickness: 2, listWidth: 100, infoWidth: 100)
        #expect(narrow.list == SidebarSizing.chatListRange.lowerBound)
        #expect(narrow.info == SidebarSizing.chatInfoRange.lowerBound)

        let wide = MainSplitLayout.paneWidths(totalWidth: 1600, dividerThickness: 2, listWidth: 800, infoWidth: 900)
        #expect(wide.list == SidebarSizing.chatListRange.upperBound)
        #expect(wide.info == SidebarSizing.chatInfoRange.upperBound)
    }

    @Test("detail receives the remaining width")
    func distributesRemainingWidth() {
        let widths = MainSplitLayout.paneWidths(totalWidth: 1024, dividerThickness: 2, listWidth: 220, infoWidth: 260)
        #expect(widths.list == 220)
        #expect(widths.detail == 540)
        #expect(widths.info == 260)
    }

    @Test("hidden info sidebar reserves no width")
    func hiddenInfoSidebar() {
        let widths = MainSplitLayout.paneWidths(totalWidth: 1024, dividerThickness: 2, listWidth: 220, infoWidth: nil)
        #expect(widths.list == 220)
        #expect(widths.detail == 802)
        #expect(widths.info == nil)
    }

    @MainActor
    @Test("main window minimum content size is 1024 by 600")
    func minimumWindowSize() {
        #expect(MainWindowController.minWindowSize == NSSize(width: 1024, height: 600))
    }
}
}
