import Testing
import AppKit
@testable import iCanHazAI

/// Regression tests for [`ChatInputTextView`](src/Views/ChatView.swift)
/// container sizing: the text container width must follow the view's frame on
/// every resize, including programmatic ones (e.g. the window frame being
/// restored to a larger size at launch). NSTextView hit-tests within its text
/// container, so a stale narrower container left the right part of the empty
/// input unclickable until the first text change resynced it.
extension AllAppTests {

@Suite("Chat input text view sizing")
@MainActor
struct ChatInputTextViewTests {

    /// Mirrors the production setup in `ChatInputEditor.makeNSView`.
    private func makeView() -> ChatInputTextView {
        let tv = ChatInputTextView()
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.heightTracksTextView = false
        return tv
    }

    @Test("container width tracks frame width on programmatic resize")
    func containerTracksFrameWidth() {
        let tv = makeView()
        tv.setFrameSize(NSSize(width: 300, height: 25))
        #expect(tv.textContainer?.size.width == 292)
        // Simulates the window being restored to a larger frame after launch.
        tv.setFrameSize(NSSize(width: 900, height: 25))
        #expect(tv.textContainer?.size.width == 892)
    }

    @Test("container width never goes negative")
    func containerWidthClamped() {
        let tv = makeView()
        tv.setFrameSize(NSSize(width: 4, height: 25))
        #expect(tv.textContainer?.size.width == 0)
    }

    @Test("container height stays unbounded for manual height management")
    func containerHeightUnbounded() {
        let tv = makeView()
        tv.setFrameSize(NSSize(width: 300, height: 25))
        #expect(tv.textContainer?.size.height == CGFloat.greatestFiniteMagnitude)
    }

    @Test("reported height grows with line count")
    func reportedHeightGrowsWithLines() {
        let tv = makeView()
        tv.setFrameSize(NSSize(width: 300, height: 25))
        var oneLine: CGFloat = 0
        tv.contentHeightChanged = { oneLine = $0 }
        tv.string = "a"
        tv.reportContentHeight()
        var fourLines: CGFloat = 0
        tv.contentHeightChanged = { fourLines = $0 }
        tv.string = "a\nb\nc\nd"
        tv.reportContentHeight()
        #expect(oneLine > 0)
        // The growth must be exactly three line fragments (the insets are
        // counted once in both measurements). ±1 tolerance for the ceil
        // rounding of the fractional line height.
        let font = tv.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = tv.layoutManager?.defaultLineHeight(for: font) ?? 0
        #expect(lineHeight > 0)
        #expect(abs((fourLines - oneLine) - 3 * lineHeight) <= 1)
    }

    /// The self-heal path in `ChatInputEditor.updateNSView` relies on
    /// `reportContentHeight` returning the full content height even when no
    /// text change happened — e.g. after the SwiftUI-side editor height was
    /// reset to one line while multi-line text stayed.
    @Test("re-reporting without a text change still measures full content")
    func reReportWithoutTextChange() {
        let tv = makeView()
        tv.setFrameSize(NSSize(width: 300, height: 25))
        tv.string = "a\nb\nc\nd"
        var reported: [CGFloat] = []
        tv.contentHeightChanged = { reported.append($0) }
        tv.reportContentHeight()
        // Simulate the collapsed-editor state: the view shows one line while
        // the text holds four. A re-report must produce the same full height.
        tv.setFrameSize(NSSize(width: 300, height: reported[0] / 4))
        tv.reportContentHeight()
        #expect(reported.count == 2)
        #expect(reported[0] == reported[1])
        #expect(tv.frame.height == reported[1])
    }

    @Test("width change schedules a content height re-report")
    func widthChangeSchedulesReReport() async {
        let tv = makeView()
        tv.setFrameSize(NSSize(width: 900, height: 25))
        tv.string = String(repeating: "w", count: 200)
        // Flush the async re-report scheduled by the width sync above.
        try? await Task.sleep(for: .milliseconds(100))
        await confirmation("height re-reported after width change") { confirm in
            tv.contentHeightChanged = { _ in confirm() }
            tv.setFrameSize(NSSize(width: 100, height: 25))
            // The re-report is dispatched asynchronously from setFrameSize.
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
}
