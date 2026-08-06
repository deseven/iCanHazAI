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
}
}
