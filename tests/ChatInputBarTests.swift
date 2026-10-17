import AppKit
import Testing

@testable import iCanHazAI

/// Tests for the AppKit message input: the bar's height rules and layout
/// ([`ChatInputBarView`](src/ChatInput/ChatInputBarView.swift)) and the pane
/// that sizes it together with the message list
/// ([`ChatPaneView`](src/ChatInput/ChatPaneView.swift)).
extension AllAppTests {

    @Suite("Chat input bar")
    @MainActor
    struct ChatInputBarTests {

        private var minHeight: CGFloat { ChatInputBarView.minHeight }
        private var lineFragment: CGFloat { ChatInputTextView.lineHeight - ChatInputTextView.insets.height * 2 }

        private func makeBar(width: CGFloat = 400) -> ChatInputBarView {
            let bar = ChatInputBarView()
            bar.frame = NSRect(x: 0, y: 0, width: width, height: minHeight)
            bar.layoutSubtreeIfNeeded()
            return bar
        }

        private func chip(_ name: String = "a.txt") -> AttachmentChipItem {
            AttachmentChipItem(id: UUID(), kind: .text, name: name)
        }

        private func button(in bar: ChatInputBarView, tooltip: String) -> NSButton? {
            bar.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == tooltip }
        }

        @Test("an empty bar is exactly its minimum height")
        func emptyBarIsMinimum() {
            #expect(makeBar().preferredHeight(maxHeight: 500) == minHeight)
        }

        @Test("the minimum height fits one text line plus padding")
        func minimumHeightComposition() {
            #expect(minHeight == ChatInputTextView.lineHeight + ChatInputBarView.verticalPadding * 2)
            #expect(ChatInputBarView.height(forLines: 1) == minHeight)
            #expect(ChatInputBarView.height(forLines: 5) == minHeight + 4 * lineFragment)
        }

        @Test("the preferred height grows with the text")
        func growsWithText() {
            let bar = makeBar()
            bar.setText("a\nb\nc", animated: false)
            let height = bar.preferredHeight(maxHeight: 500)
            #expect(abs(height - (minHeight + 2 * lineFragment)) <= 1)
        }

        @Test("the preferred height is capped at the maximum")
        func cappedAtMaximum() {
            let bar = makeBar()
            bar.setText(String(repeating: "line\n", count: 100), animated: false)
            #expect(bar.preferredHeight(maxHeight: 150) == 150)
        }

        @Test("a maximum below the minimum never shrinks the bar under one line")
        func maximumFloor() {
            let bar = makeBar()
            #expect(bar.preferredHeight(maxHeight: 1) == minHeight)
        }

        @Test("the attachment strip adds its row to the height")
        func chipsAddHeight() {
            let bar = makeBar()
            bar.setAttachments([chip()], animated: false)
            #expect(
                bar.preferredHeight(maxHeight: 500) == minHeight + AttachmentChipsView.height
                    + ChatInputBarView.chipsSpacing)
            bar.setAttachments([], animated: false)
            #expect(bar.preferredHeight(maxHeight: 500) == minHeight)
        }

        @Test("the action button stays on the bottom edge as the bar grows")
        func actionButtonAnchoredToBottom() throws {
            let bar = makeBar()
            let send = try #require(button(in: bar, tooltip: "Send"))
            let inset = (minHeight - ChatInputBarView.buttonSize) / 2
            #expect(send.frame.maxY == bar.bounds.height - inset)

            bar.setFrameSize(NSSize(width: 400, height: 200))
            bar.layoutSubtreeIfNeeded()
            #expect(send.frame.maxY == 200 - inset)
            #expect(send.frame.maxX == 400 - ChatInputBarView.sidePadding)
        }

        @Test("the attach button takes room from the text column")
        func attachButtonNarrowsText() {
            let bar = makeBar()
            let before = bar.textView.superview?.superview?.frame.width ?? 0
            bar.state.showsAttachButton = true
            bar.layoutSubtreeIfNeeded()
            let after = bar.textView.superview?.superview?.frame.width ?? 0
            #expect(after < before)
        }

        @Test("setting the text reports a height change with the requested animation")
        func setTextInvalidatesHeight() {
            let bar = makeBar()
            var flags: [Bool] = []
            bar.onHeightInvalidated = { flags.append($0) }
            bar.setText("hello", animated: true)
            bar.setText("", animated: false)
            #expect(flags == [true, false])
        }

        @Test("setting the same text again does nothing")
        func sameTextIsNoOp() {
            let bar = makeBar()
            bar.setText("hello", animated: false)
            var changes = 0
            bar.onTextChange = { changes += 1 }
            bar.setText("hello", animated: false)
            #expect(changes == 0)
        }

        @Test("typing reports the text and an animated height change")
        func typingReports() {
            let bar = makeBar()
            var texts = 0
            var flags: [Bool] = []
            bar.onTextChange = { texts += 1 }
            bar.onHeightInvalidated = { flags.append($0) }
            bar.textDidChange(Notification(name: NSText.didChangeNotification, object: bar.textView))
            #expect(texts == 1)
            #expect(flags == [true])
        }

        @Test("showing the attach button reports a height change")
        func attachButtonInvalidatesHeight() {
            let bar = makeBar()
            var invalidated = 0
            bar.onHeightInvalidated = { _ in invalidated += 1 }
            bar.state.showsAttachButton = true
            #expect(invalidated == 1)
            bar.state.attachEnabled = false
            #expect(invalidated == 1)
        }

        @Test("the placeholder shows while the field is empty and hides once there is text")
        func placeholderFollowsText() {
            let bar = makeBar()
            #expect(bar.isPlaceholderVisible)
            bar.setText("hi", animated: false)
            #expect(!bar.isPlaceholderVisible)
            bar.setText("", animated: false)
            #expect(bar.isPlaceholderVisible)
        }

        @Test("typing hides the placeholder")
        func placeholderHidesWhileTyping() {
            let bar = makeBar()
            bar.textView.insertText("a", replacementRange: NSRange(location: 0, length: 0))
            bar.textDidChange(Notification(name: NSText.didChangeNotification, object: bar.textView))
            #expect(!bar.isPlaceholderVisible)
        }

        @Test("a disabled input shows no placeholder")
        func placeholderHiddenWhenDisabled() {
            let bar = makeBar()
            bar.state.inputEnabled = false
            #expect(!bar.isPlaceholderVisible)
            bar.state.inputEnabled = true
            #expect(bar.isPlaceholderVisible)
        }

        @Test("the placeholder sits on the first line and lets clicks through")
        func placeholderPlacementAndHitTesting() throws {
            let bar = makeBar()
            let label = try #require(bar.subviews.compactMap { $0 as? NSTextField }.first)
            #expect(label.stringValue == "Message")
            let scroll = try #require(bar.subviews.first { $0 is NSScrollView })
            #expect(label.frame.minY == scroll.frame.minY + ChatInputTextView.insets.height)
            #expect(label.frame.minX == scroll.frame.minX + ChatInputTextView.insets.width)
            #expect(label.hitTest(NSPoint(x: label.frame.midX, y: label.frame.midY)) == nil)
            #expect(bar.subviews.firstIndex(of: label)! < bar.subviews.firstIndex(of: scroll)!)
        }

        @Test("a disabled input is read-only")
        func disabledInput() {
            let bar = makeBar()
            bar.state.inputEnabled = false
            #expect(!bar.textView.isEditable)
            bar.state.inputEnabled = true
            #expect(bar.textView.isEditable)
        }

        @Test("the action button reflects streaming, stopping and sending")
        func actionStates() throws {
            let bar = makeBar()
            bar.state.action = .send(enabled: false)
            #expect(try #require(button(in: bar, tooltip: "Send")).isEnabled == false)
            bar.state.action = .send(enabled: true)
            #expect(try #require(button(in: bar, tooltip: "Send")).isEnabled)
            bar.state.action = .stop(afterIteration: false)
            #expect(button(in: bar, tooltip: "Stop (hold ⌥ to stop after streaming)") != nil)
            bar.state.action = .stop(afterIteration: true)
            #expect(button(in: bar, tooltip: "Stop After Streaming") != nil)
            bar.state.action = .finishing
            #expect(try #require(button(in: bar, tooltip: "Finishing the current iteration…")).isHidden)
        }
    }

    @Suite("Chat pane layout")
    @MainActor
    struct ChatPaneViewTests {

        private var minHeight: CGFloat { ChatInputBarView.minHeight }
        private var inset: NSSize { ChatPaneView.barInsets }

        @MainActor
        private struct Harness {
            let pane: ChatPaneView
            let bar: ChatInputBarView
            let list: ChatListView

            init(width: CGFloat = 800, height: CGFloat = 600) {
                list = ChatListView(frame: .zero)
                bar = ChatInputBarView()
                pane = ChatPaneView(listView: list, inputBar: bar)
                pane.frame = NSRect(x: 0, y: 0, width: width, height: height)
                pane.layoutSubtreeIfNeeded()
            }

            var regionHeight: CGFloat { bar.frame.height + ChatPaneView.barInsets.height * 2 }
        }

        @Test("the bar sits at the bottom with margins and the list fills the rest")
        func initialLayout() {
            let h = Harness()
            #expect(
                h.bar.frame == NSRect(x: inset.width, y: inset.height, width: 800 - inset.width * 2, height: minHeight))
            #expect(h.list.frame.minY == h.regionHeight + 1)
            #expect(h.list.frame.maxY == 600)
            #expect(h.list.frame.width == 800)
        }

        @Test("growing the input shrinks the list by the same amount, keeping its top fixed")
        func growthShrinksList() {
            let h = Harness()
            let listBefore = h.list.frame
            h.bar.setText("a\nb\nc\nd", animated: false)
            let grown = h.bar.frame.height - minHeight
            #expect(grown > 0)
            #expect(h.pane.targetBarHeight == h.bar.frame.height)
            #expect(h.list.frame.maxY == listBefore.maxY)
            #expect(abs(h.list.frame.height - (listBefore.height - grown)) < 0.5)
            #expect(h.list.frame.minY == h.regionHeight + 1)
        }

        @Test("clearing the input gives the space back")
        func shrinkRestoresList() {
            let h = Harness()
            let listBefore = h.list.frame
            h.bar.setText("a\nb\nc\nd", animated: false)
            h.bar.setText("", animated: false)
            #expect(h.bar.frame.height == minHeight)
            #expect(h.list.frame == listBefore)
        }

        @Test("the bar stops growing at its share of the pane")
        func growthIsCapped() {
            let h = Harness(height: 600)
            h.bar.setText(String(repeating: "line\n", count: 200), animated: false)
            #expect(h.bar.frame.height == ChatPaneView.maxBarHeight(paneHeight: 600))
            #expect(h.list.frame.height > 0)
        }

        @Test("the maximum is 40% of the pane but never under five lines")
        func maxBarHeight() {
            #expect(ChatPaneView.maxBarHeight(paneHeight: 1000) == 400)
            #expect(ChatPaneView.maxBarHeight(paneHeight: 100) == ChatInputBarView.height(forLines: 5))
        }

        @Test("narrowing the pane re-wraps the text and grows the bar")
        func widthChangeRewraps() {
            let h = Harness(width: 900)
            h.bar.setText(String(repeating: "word ", count: 60), animated: false)
            let wide = h.bar.frame.height
            h.pane.setFrameSize(NSSize(width: 300, height: 600))
            h.pane.layoutSubtreeIfNeeded()
            #expect(h.bar.frame.height > wide)
            #expect(h.bar.frame.width == 300 - inset.width * 2)
        }

        @Test("attachments make room above the text")
        func chipsGrowBar() {
            let h = Harness()
            h.bar.setAttachments([AttachmentChipItem(id: UUID(), kind: .image, name: "x.png")], animated: false)
            #expect(h.bar.frame.height == minHeight + AttachmentChipsView.height + ChatInputBarView.chipsSpacing)
        }

        @Test("resizing the pane keeps the list and bar consistent")
        func paneResize() {
            let h = Harness()
            h.pane.setFrameSize(NSSize(width: 800, height: 400))
            h.pane.layoutSubtreeIfNeeded()
            #expect(h.list.frame.maxY == 400)
            #expect(h.list.frame.minY == h.regionHeight + 1)
        }

        // MARK: Animation (needs a window for the display link)

        private func windowed(_ h: Harness) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = h.pane
            h.pane.layoutSubtreeIfNeeded()
            return window
        }

        @Test("an animated change starts from the current height instead of jumping")
        func animatedChange() {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let h = Harness()
            let window = windowed(h)
            defer { window.contentView = nil }

            h.bar.setText("a\nb\nc", animated: true)
            #expect(h.pane.targetBarHeight > minHeight)
            #expect(h.pane.currentBarHeight == minHeight)
            #expect(h.pane.isAnimatingHeight)
            #expect(h.bar.frame.height == minHeight)
        }

        @Test("while the bar animates, the text viewport already has the final height and no scroller")
        func viewportSettledDuringGrowth() throws {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let h = Harness()
            let window = windowed(h)
            defer { window.contentView = nil }

            h.bar.setText("a\nb\nc", animated: true)
            #expect(h.bar.frame.height == minHeight)
            let scroll = try #require(h.bar.subviews.first { $0 is NSScrollView } as? NSScrollView)
            let expected = h.pane.targetBarHeight - ChatInputBarView.verticalPadding * 2
            #expect(scroll.frame.height == expected)
            #expect(!scroll.hasVerticalScroller)
            #expect(scroll.contentView.bounds.origin.y == 0)
            #expect(h.bar.layer?.masksToBounds == true)
        }

        @Test("a change that lands mid-animation only moves the target")
        func retargetMidAnimation() {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let h = Harness()
            let window = windowed(h)
            defer { window.contentView = nil }

            h.bar.setText("a\nb", animated: true)
            let firstTarget = h.pane.targetBarHeight
            h.bar.setText("a\nb\nc\nd", animated: true)
            #expect(h.pane.targetBarHeight > firstTarget)
            #expect(h.pane.currentBarHeight == minHeight)
            #expect(h.pane.isAnimatingHeight)
        }

        @Test("unanimated changes snap even in a window")
        func unanimatedSnaps() {
            let h = Harness()
            let window = windowed(h)
            defer { window.contentView = nil }

            h.bar.setText("a\nb\nc", animated: false)
            #expect(h.pane.currentBarHeight == h.pane.targetBarHeight)
            #expect(!h.pane.isAnimatingHeight)
        }

        @Test("a window resize snaps instead of animating")
        func resizeSnaps() {
            let h = Harness()
            let window = windowed(h)
            defer { window.contentView = nil }

            h.bar.setText(String(repeating: "word ", count: 60), animated: false)
            h.pane.setFrameSize(NSSize(width: 300, height: 600))
            h.pane.layoutSubtreeIfNeeded()
            #expect(h.pane.currentBarHeight == h.pane.targetBarHeight)
            #expect(!h.pane.isAnimatingHeight)
        }
    }
}
