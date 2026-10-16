import AppKit
import Testing

@testable import iCanHazAI

extension AllAppTests {

    @MainActor
    @Suite("Chat list view")
    struct ChatListViewTests {

        @MainActor
        private struct Harness {
            let window: NSWindow
            let list: ChatListView

            init(width: CGFloat = 900, height: CGFloat = 800) {
                window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                list = ChatListView(frame: NSRect(x: 0, y: 0, width: width, height: height))
                window.contentView = list
                list.layoutSubtreeIfNeeded()
            }
        }

        /// Suspends (instead of spinning the run loop, which can't drain the main
        /// queue from inside a main-queue block) until every row is measured at
        /// the current width.
        private static func waitForPass(_ list: ChatListView, timeout: Double = 30) async {
            var waited = 0.0
            while list.testExactCount < list.testRowCount, waited < timeout {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 0.05
            }
        }

        private func anchorMoved(_ list: ChatListView, _ anchor: (id: String, y: CGFloat)) -> CGFloat {
            abs((list.testScreenY(of: anchor.id) ?? .nan) - anchor.y)
        }

        @Test("opens pinned to the bottom with only the tail measured")
        func opensAtBottom() {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(1000)
            h.list.setMessages(rows)
            #expect(h.list.testIsPinned)
            #expect(abs(h.list.testDistanceFromBottom) < 1)
            #expect(h.list.testExactCount > 0)
            #expect(h.list.testExactCount < rows.count / 4)
            #expect(h.list.testVisibleIDs.contains(rows.last!.id))
            #expect(h.list.testViewsConsistent())
        }

        @Test("the background pass measures every row without moving the content on screen")
        func backgroundPassKeepsAnchor() async {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(1000)
            h.list.setMessages(rows)
            h.list.testScroll(toRow: rows.count / 2)
            let anchor = h.list.testAnchor()
            await Self.waitForPass(h.list)
            #expect(h.list.testExactCount == rows.count)
            #expect(anchorMoved(h.list, anchor) < 0.5)
            #expect(h.list.testViewsConsistent())
        }

        @Test("stays pinned to the bottom while a streaming message grows")
        func streaming() {
            let h = Harness()
            h.list.setMessages(ChatRendererFixtures.chat(200))
            h.list.jumpToBottom()
            var reply = ChatRendererFixtures.message("stream")
            h.list.append(reply)
            let text = Array(ChatRendererFixtures.streamingText)
            var pos = 0
            var pinned = true
            while pos < text.count {
                pos = min(text.count, pos + 40)
                reply.content = String(text[0..<pos])
                h.list.update(reply)
                pinned = pinned && abs(h.list.testDistanceFromBottom) < 1
            }
            #expect(pinned)
            #expect(h.list.testViewsConsistent())
        }

        @Test("the anchor stays put across a width change")
        func widthChange() async {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(1000)
            h.list.setMessages(rows)
            h.list.testScroll(toRow: rows.count / 3)
            let before = h.list.testAnchor()
            h.window.setContentSize(NSSize(width: 620, height: 800))
            h.list.layoutSubtreeIfNeeded()
            #expect(anchorMoved(h.list, before) < 0.5)
            #expect(h.list.testViewsConsistent())
            await Self.waitForPass(h.list)
            #expect(h.list.testExactCount == rows.count)
            #expect(anchorMoved(h.list, before) < 0.5)
        }

        @Test("inserting above the viewport keeps the anchor in place")
        func insertAbove() async {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(400)
            h.list.setMessages(rows)
            h.list.testScroll(toRow: 200)
            let anchor = h.list.testAnchor()
            let tall = ChatRendererFixtures.message("inserted", content: ChatRendererFixtures.streamingText)
            h.list.insert(tall, at: 10)
            #expect(h.list.testRowIDs[10] == "inserted")
            #expect(h.list.testRowCount == rows.count + 1)
            #expect(anchorMoved(h.list, anchor) < 0.5)
            await Self.waitForPass(h.list)
            #expect(anchorMoved(h.list, anchor) < 0.5)
            #expect(h.list.testViewsConsistent())
        }

        @Test("inserting below the viewport leaves the content where it is")
        func insertBelow() {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(400)
            h.list.setMessages(rows)
            h.list.testScroll(toRow: 100)
            let anchor = h.list.testAnchor()
            h.list.insert(ChatRendererFixtures.message("inserted", content: "new"), at: 300)
            #expect(h.list.testRowIDs[300] == "inserted")
            #expect(anchorMoved(h.list, anchor) < 0.5)
            #expect(h.list.testViewsConsistent())
        }

        @Test("inserting while pinned keeps the list at the bottom")
        func insertPinned() {
            let h = Harness()
            h.list.setMessages(ChatRendererFixtures.chat(100))
            h.list.insert(ChatRendererFixtures.message("inserted", content: ChatRendererFixtures.streamingText), at: 50)
            #expect(h.list.testIsPinned)
            #expect(abs(h.list.testDistanceFromBottom) < 1)
        }

        @Test("deleting above the viewport keeps the anchor in place")
        func deleteAbove() async {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(400)
            h.list.setMessages(rows)
            h.list.testScroll(toRow: 200)
            let anchor = h.list.testAnchor()
            h.list.delete(id: rows[20].id)
            #expect(h.list.testRowCount == rows.count - 1)
            #expect(!h.list.testRowIDs.contains(rows[20].id))
            #expect(anchorMoved(h.list, anchor) < 0.5)
            await Self.waitForPass(h.list)
            #expect(anchorMoved(h.list, anchor) < 0.5)
            #expect(h.list.testViewsConsistent())
        }

        @Test("deleting the row at the top of the viewport keeps the list consistent")
        func deleteAnchor() {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(400)
            h.list.setMessages(rows)
            h.list.testScroll(toRow: 200)
            let anchor = h.list.testAnchor()
            h.list.delete(id: anchor.id)
            #expect(!h.list.testRowIDs.contains(anchor.id))
            #expect(h.list.testScreenY(of: anchor.id) == nil)
            #expect(h.list.testViewsConsistent())
            #expect(!h.list.testVisibleIDs.contains(anchor.id))
        }

        @Test("deleting unknown rows and every row is harmless")
        func deleteAll() {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(5)
            h.list.setMessages(rows)
            h.list.delete(id: "nope")
            #expect(h.list.testRowCount == 5)
            for r in rows { h.list.delete(id: r.id) }
            #expect(h.list.testRowCount == 0)
            #expect(h.list.testVisibleIDs.isEmpty)
            h.list.append(ChatRendererFixtures.message("again", content: "hi"))
            #expect(h.list.testRowIDs == ["again"])
        }

        @Test("expanding a block makes the row taller and collapsing restores it")
        func toggling() {
            let h = Harness()
            let rows = [
                ChatRendererFixtures.message("a", content: "hi", thinking: ChatRendererFixtures.streamingText)
            ]
            h.list.setMessages(rows)
            let collapsed = h.list.testDocumentHeight
            h.list.testToggle("a/thinking")
            let open = h.list.testDocumentHeight
            #expect(open > collapsed)
            h.list.testToggle("a/thinking")
            #expect(h.list.testDocumentHeight == collapsed)
        }

        @Test("changing the expand preferences flips every block the user didn't touch")
        func preferenceDefaults() {
            let h = Harness()
            let thinking = ChatRendererFixtures.streamingText
            h.list.setMessages([
                ChatRendererFixtures.message("a", thinking: thinking),
                ChatRendererFixtures.message("b", thinking: thinking),
            ])
            let collapsed = h.list.testDocumentHeight
            h.list.testToggle("a/thinking")
            let aOpen = h.list.testDocumentHeight
            #expect(aOpen > collapsed)

            var context = h.list.context
            context.expandThinking = true
            h.list.context = context
            // b opens, a (flipped by the user) closes.
            #expect(h.list.testIsOpen("a/thinking") == false)
            #expect(h.list.testIsOpen("b/thinking") == true)
            #expect(abs(h.list.testDocumentHeight - aOpen) < 1)

            context.expandThinking = false
            h.list.context = context
            #expect(h.list.testIsOpen("a/thinking") == true)
            #expect(h.list.testIsOpen("b/thinking") == false)
            #expect(abs(h.list.testDocumentHeight - aOpen) < 1)
        }

        @Test("tool blocks follow their own preference")
        func toolPreference() {
            let h = Harness()
            var m = ChatRendererFixtures.message("a", thinking: "t")
            m.toolCalls = [.init(id: "c", name: "shell", arguments: #"{"command":"ls"}"#, summary: "ls")]
            h.list.setMessages([m])
            #expect(h.list.testIsOpen("a/call/c") == false)
            h.list.context.expandToolUse = true
            #expect(h.list.testIsOpen("a/call/c") == true)
            #expect(h.list.testIsOpen("a/thinking") == false)
        }

        @Test("a block waiting for approval stays open until it's decided")
        func approvalForcesOpen() {
            let h = Harness()
            var m = ChatRendererFixtures.message("a")
            m.toolCalls = [
                .init(id: "c", name: "shell", arguments: #"{"command":"ls"}"#, summary: "ls", pendingApproval: true)
            ]
            h.list.setMessages([m])
            #expect(h.list.testIsOpen("a/call/c") == true)
            let open = h.list.testDocumentHeight

            h.list.testToggle("a/call/c")
            #expect(h.list.testIsOpen("a/call/c") == true)
            #expect(h.list.testToggledKeys.isEmpty)

            m.toolCalls[0].pendingApproval = false
            h.list.update(m)
            #expect(h.list.testIsOpen("a/call/c") == false)
            #expect(h.list.testDocumentHeight < open)
        }

        @Test("collapsing from the bottom brings the block's header back into view")
        func collapseScrollsToHeader() {
            let h = Harness(height: 600)
            var rows = ChatRendererFixtures.chat(30)
            rows[15] = ChatRendererFixtures.message("tall", thinking: ChatRendererFixtures.streamingText)
            h.list.setMessages(rows)
            h.list.testScroll(toRow: 15)
            h.list.testToggle("tall/thinking")
            #expect(h.list.testIsOpen("tall/thinking") == true)
            h.list.testScroll(by: 1500)
            let headerBefore = (h.list.testScreenY(of: "tall") ?? 0) + 38
            #expect(headerBefore < 0)

            h.list.testCollapse("tall/thinking")
            #expect(h.list.testIsOpen("tall/thinking") == false)
            let header = (h.list.testScreenY(of: "tall") ?? .nan) + 38
            #expect(header >= -0.5)
            #expect(header < 600)
            #expect(h.list.testViewsConsistent())
        }

        @Test("the bottom action bar appears once the header has scrolled away")
        func bottomActions() {
            let h = Harness(height: 600)
            var rows = ChatRendererFixtures.chat(10)
            rows[5] = ChatRendererFixtures.message("tall", content: ChatRendererFixtures.streamingText)
            h.list.setMessages(rows)
            h.list.testScroll(toRow: 5)
            #expect(h.list.testBottomActionsVisible(of: "tall") == false)
            h.list.testScroll(by: 500)
            #expect(h.list.testBottomActionsVisible(of: "tall") == true)
            h.list.testScroll(by: -500)
            #expect(h.list.testBottomActionsVisible(of: "tall") == false)
        }

        @Test("streaming adds the pending spinner to an empty assistant message and removes it again")
        func streamingChangesHeight() {
            let h = Harness()
            h.list.setMessages([ChatRendererFixtures.message("a")])
            let idle = h.list.testHeight(of: "a")!
            h.list.context.isStreaming = true
            let streaming = h.list.testHeight(of: "a")!
            #expect(streaming > idle)
            #expect(streaming - idle >= RowLayout(theme: Theme()).pendingHeight - 1)
            h.list.context.isStreaming = false
            #expect(h.list.testHeight(of: "a") == idle)
        }

        @Test("role, accent and features reconfigure views without touching heights")
        func visualContext() {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(20)
            h.list.setMessages(rows)
            let before = h.list.testDocumentHeight
            h.list.context.roleName = "Developer"
            h.list.context.roleAccent = .systemTeal
            h.list.context.features = ChatRowFeatures(responseRegen: true, chatTrees: true)
            #expect(h.list.testDocumentHeight == before)
            #expect(h.list.testViewsConsistent())
        }

        @Test("row actions reach the host")
        func actions() {
            let h = Harness()
            h.list.setMessages([ChatRendererFixtures.message("a", content: "hi")])
            var received: [ChatRowAction] = []
            h.list.onAction = { received.append($0) }
            h.list.testHandle(.action(.copy(messageID: "a")))
            h.list.testHandle(.action(.switchBranch(messageID: "a", direction: -1)))
            h.list.testHandle(.action(.retry))
            #expect(received == [.copy(messageID: "a"), .switchBranch(messageID: "a", direction: -1), .retry])
        }

        @Test("changing the interface scale re-measures everything and keeps the list consistent")
        func interfaceScale() async {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(300)
            h.list.setMessages(rows)
            await Self.waitForPass(h.list)
            let before = h.list.testDocumentHeight

            h.list.interfaceScale = 150
            #expect(h.list.testIsPinned)
            #expect(abs(h.list.testDistanceFromBottom) < 1)
            await Self.waitForPass(h.list)
            #expect(h.list.testExactCount == rows.count)
            #expect(h.list.testDocumentHeight > before * 1.3)
            #expect(h.list.testViewsConsistent())

            h.list.interfaceScale = 100
            await Self.waitForPass(h.list)
            #expect(h.list.testExactCount == rows.count)
            #expect(abs(h.list.testDocumentHeight - before) < 1)
        }

        @Test("changing the interface scale away from the bottom keeps the same row in view")
        func interfaceScaleAnchor() async {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(300)
            h.list.setMessages(rows)
            await Self.waitForPass(h.list)
            h.list.testScroll(toRow: 100)
            let anchor = h.list.testAnchor()
            h.list.interfaceScale = 130
            await Self.waitForPass(h.list)
            #expect(!h.list.testIsPinned)
            #expect(h.list.testViewsConsistent())
            let moved = h.list.testScreenY(of: anchor.id) ?? .nan
            #expect(abs(moved - anchor.y * 1.3) < 1)
        }

        @Test("scrolling to a message that was never measured puts it near the top of the viewport")
        func scrollToUnmeasuredMessage() async {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(1000)
            h.list.setMessages(rows)
            let target = rows[300].id
            h.list.scrollToMessage(id: target)
            #expect(!h.list.testIsPinned)
            #expect(h.list.testVisibleIDs.contains(target))
            #expect(h.list.testViewsConsistent())
            let y = h.list.testScreenY(of: target) ?? .nan
            #expect(y >= 0 && y < 40)

            // The background pass measures everything above without moving it.
            await Self.waitForPass(h.list)
            #expect(abs((h.list.testScreenY(of: target) ?? .nan) - y) < 0.5)
        }

        @Test("scrolling to an unknown message does nothing")
        func scrollToUnknownMessage() {
            let h = Harness()
            h.list.setMessages(ChatRendererFixtures.chat(50))
            h.list.scrollToMessage(id: "missing")
            #expect(h.list.testIsPinned)
        }

        @Test("pinned changes are reported once the list settles")
        func pinnedReports() async {
            let h = Harness()
            var reports: [Bool] = []
            h.list.onPinnedChange = { reports.append($0) }
            h.list.setMessages(ChatRendererFixtures.chat(200))
            h.list.testScroll(toRow: 50)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
            #expect(reports == [false])
            h.list.jumpToBottom()
            try? await Task.sleep(for: .milliseconds(50))
            #expect(reports == [false, true])
        }

        @Test("views are reconfigured for rows that replace deleted ones, even with the same structure")
        func replacedRowsReconfigureViews() {
            let h = Harness()
            let rows = (0..<6).map { ChatRendererFixtures.message("m-\($0)", content: "same shape \($0)") }
            h.list.setMessages(rows)
            for round in 0..<20 {
                for row in rows.suffix(3) { h.list.delete(id: row.id + "-\(round)") }
                h.list.delete(id: "m-5")
                h.list.append(ChatRendererFixtures.message("m-5", content: "again \(round)"))
                #expect(h.list.testViewsConsistent())
            }
        }

        @Test("a batch of edits that replaces the row at the viewport's top keeps the content in place")
        func replacedAnchorKeepsPosition() {
            let h = Harness()
            let rows = ChatRendererFixtures.chat(60)
            h.list.setMessages(rows)
            h.list.testScroll(toRow: 30)
            let anchor = h.list.testAnchor()
            var replacement = ChatRendererFixtures.message("swap", content: ChatRendererFixtures.paragraph(1))
            replacement.role = rows[30].role
            let index = h.list.testRowIDs.firstIndex(of: anchor.id)!
            h.list.performEdits {
                for id in h.list.testRowIDs[index...] { h.list.delete(id: id) }
                h.list.append(replacement)
                for r in rows[(index + 1)...] { h.list.append(r) }
            }
            #expect(!h.list.testIsPinned)
            #expect(abs((h.list.testScreenY(of: "swap") ?? .nan) - anchor.y) < 40)
            #expect(h.list.testViewsConsistent())
        }

        @Test("replacing the messages together with the context renders with the new context")
        func setMessagesWithContext() {
            let h = Harness()
            h.list.setMessages(ChatRendererFixtures.chat(20))
            var context = ChatRowContext()
            context.isStreaming = true
            context.roleName = "Coder"
            let rows = ChatRendererFixtures.chat(10)
            h.list.setMessages(rows, context: context)
            #expect(h.list.context == context)
            #expect(h.list.testRowIDs == rows.map(\.id))
            #expect(h.list.testIsPinned)
        }
    }
}
