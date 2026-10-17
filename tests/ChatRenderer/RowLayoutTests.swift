import AppKit
import Testing

@testable import iCanHazAI

extension AllAppTests {

    @Suite("Row layout")
    struct RowLayoutTests {

        private let theme = Theme()
        private var layout: RowLayout { RowLayout(theme: theme) }
        private let width: CGFloat = 600

        private var chrome: CGFloat { layout.chrome }

        private func render(_ m: ChatRowModel, streaming: Bool = false) -> RenderedMessage {
            RenderedMessage.render(m, theme: theme, streaming: streaming)
        }

        private func measure(_ r: RenderedMessage, open: [Bool]? = nil) -> [CGFloat?] {
            layout.measure(r, width: width, existing: [], open: open ?? Array(repeating: false, count: r.blocks.count))
        }

        private func closed(_ r: RenderedMessage) -> [Bool] { Array(repeating: false, count: r.blocks.count) }

        private func toolMessage(
            pending: Bool = false, result: ChatRowModel.ToolResult? = nil, diff: String? = nil
        ) -> ChatRowModel {
            var m = ChatRendererFixtures.message("m")
            m.toolCalls = [
                .init(
                    id: "c1", name: "shell", arguments: #"{"command":"ls"}"#, summary: "ls", pendingApproval: pending,
                    diff: diff)
            ]
            if let result { m.toolResults = [result] }
            return m
        }

        private func collapsible(_ r: RenderedMessage, at i: Int = 0) -> CollapsibleBlock {
            guard case .collapsible(let c) = r.blocks[i] else { fatalError("expected a collapsible block") }
            return c
        }

        @Test("a message without blocks is just the chrome, including the reserved action bar")
        func empty() {
            let r = render(ChatRendererFixtures.message("m"))
            #expect(r.blocks.isEmpty)
            #expect(layout.height(r, heights: [], open: []) == ceil(chrome))
            #expect(chrome >= layout.top + layout.header + layout.headerGap + layout.actionBar)
        }

        @Test("a text block adds its measured height")
        func textBlock() throws {
            let m = ChatRendererFixtures.message("m", content: "hello")
            let r = render(m)
            let heights = measure(r)
            let body = try #require(heights[0])
            #expect(body > 0)
            #expect(layout.height(r, heights: heights, open: closed(r)) == ceil(chrome + body))
        }

        @Test("a streaming assistant message with nothing yet shows only the spinner block")
        func pendingBlock() {
            let m = ChatRendererFixtures.message("m")
            #expect(render(m).blocks.isEmpty)
            let r = render(m, streaming: true)
            #expect(r.blocks.count == 1)
            guard case .pending = r.blocks[0] else {
                Issue.record("expected the pending block")
                return
            }
            #expect(layout.height(r, heights: measure(r), open: [false]) == ceil(chrome + layout.pendingHeight))
        }

        @Test("a standalone tool result is a measured panel")
        func panelBlock() throws {
            var m = ChatRendererFixtures.message("m", role: .tool)
            m.toolResults = [.init(callID: "c", content: String(repeating: "word ", count: 200), isError: false)]
            let r = render(m)
            guard case .text(let text, let panel) = r.blocks[0] else {
                Issue.record("expected a text block")
                return
            }
            #expect(panel)
            let heights = measure(r)
            #expect(heights[0] == text.height(forWidth: width - layout.panelPad * 2))
            #expect(
                layout.height(r, heights: heights, open: [false]) == ceil(chrome + heights[0]! + layout.panelPad * 2))
        }

        @Test("an error block measures its text beside the icon and reserves the Retry button")
        func errorBlock() throws {
            let m = ChatRendererFixtures.message("m", error: String(repeating: "word ", count: 200))
            let r = render(m)
            guard case .error(let text) = r.blocks[0] else {
                Issue.record("expected an error block")
                return
            }
            let heights = measure(r)
            #expect(heights[0] == text.height(forWidth: layout.errorTextWidth(width)))
            #expect(
                layout.height(r, heights: heights, open: [false])
                    == ceil(chrome + layout.errorHeight(text: heights[0]!)))
        }

        @Test("blocks are separated by the block gap")
        func gaps() throws {
            let m = ChatRendererFixtures.message("m", content: "one", error: "two")
            let r = render(m)
            #expect(r.blocks.count == 2)
            let heights = measure(r)
            let expected = chrome + heights[0]! + layout.blockGap + layout.errorHeight(text: heights[1]!)
            #expect(layout.height(r, heights: heights, open: closed(r)) == ceil(expected))
        }

        @Test("collapsed bodies are never measured and take only the header")
        func collapsed() throws {
            let m = ChatRendererFixtures.message("m", thinking: "deep thoughts")
            let r = render(m)
            let heights = measure(r)
            #expect(heights == [nil])
            #expect(layout.height(r, heights: heights, open: [false]) == ceil(chrome + layout.collapsibleHeader))
        }

        @Test("an expanded collapsible adds its body and bottom padding")
        func expandedBlock() throws {
            let m = ChatRendererFixtures.message("m", thinking: "deep thoughts")
            let r = render(m)
            let heights = measure(r, open: [true])
            let body = try #require(heights[0])
            #expect(body > 0)
            #expect(
                layout.height(r, heights: heights, open: [true])
                    == ceil(chrome + layout.collapsibleHeader + body + layout.panelPad))
        }

        @Test("existing measurements are kept, missing ones are filled in")
        func incremental() throws {
            let m = ChatRendererFixtures.message("m", content: "hello", thinking: "thoughts")
            let r = render(m)
            let first = measure(r)
            #expect(first[0] == nil)
            #expect(first[1] != nil)

            let second = layout.measure(r, width: width, existing: first, open: [true, false])
            #expect(second[1] == first[1])
            #expect(second[0] != nil)
        }

        @Test("a tool result folds into its call's block; there is no separate result block")
        func toolBlocks() {
            var m = toolMessage(result: .init(callID: "c1", content: "out", isError: true))
            m.content = "running"
            let r = render(m)
            let keys = r.blocks.compactMap { block -> String? in
                if case .collapsible(let c) = block { return c.key }
                return nil
            }
            #expect(keys == ["m/call/c1"])
            #expect(r.blocks.count == 2)
        }

        @Test("a collapsed tool block with a status takes a second header line")
        func statusLine() {
            let done = ToolSummary.Status(kind: .done, label: "done", description: "ok")
            let withStatus = render(
                toolMessage(result: .init(callID: "c1", content: "out", isError: false, summary: done)))
            let c = collapsible(withStatus)
            #expect(layout.collapsible(c, open: false, bodyHeight: nil).total == layout.collapsibleHeaderWithStatus)
            #expect(layout.collapsible(c, open: true, bodyHeight: 50).header == layout.collapsibleHeader)

            let noStatus = collapsible(render(toolMessage()))
            #expect(noStatus.status == nil)
            #expect(layout.collapsible(noStatus, open: false, bodyHeight: nil).total == layout.collapsibleHeader)
        }

        @Test("a pending approval forces the block open and reserves room for the buttons")
        func approval() throws {
            let r = render(toolMessage(pending: true))
            let c = collapsible(r)
            #expect(c.forcedOpen)
            #expect(c.approvalCallID == "c1")
            #expect(c.status?.kind == .pending)
            #expect(OpenPolicy().isOpen(c))

            let heights = measure(r, open: [true])
            let body = try #require(heights[0])
            let g = layout.collapsible(c, open: true, bodyHeight: body)
            #expect(g.approvalY == layout.collapsibleHeader + body + layout.segmentGap)
            #expect(g.collapseLinkY == nil)
            #expect(g.total == g.approvalY! + layout.approvalHeight + layout.panelPad)
            #expect(layout.height(r, heights: heights, open: [true]) == ceil(chrome + g.total))
        }

        @Test("only tall open bodies get a collapse link")
        func collapseLink() {
            let r = render(toolMessage(result: .init(callID: "c1", content: "x", isError: false)))
            let c = collapsible(r)
            let short = layout.collapsible(c, open: true, bodyHeight: layout.collapseThreshold - 1)
            #expect(short.collapseLinkY == nil)
            let tall = layout.collapsible(c, open: true, bodyHeight: layout.collapseThreshold)
            #expect(tall.collapseLinkY == layout.collapsibleHeader + layout.collapseThreshold)
            #expect(tall.total == short.total + 1 + layout.collapseLinkHeight)
        }

        @Test("tool bodies stack their text segments and the image of an image result")
        func imageResult() throws {
            let image = ToolResultImage(data: "AAAA", mimeType: "image/png", fallback: "a cat")
            let r = render(toolMessage(result: .init(callID: "c1", content: "a cat", isError: false, image: image)))
            let c = collapsible(r)
            let body = layout.bodyLayout(c.body, width: width)
            #expect(body.frames.count == 3)
            #expect(body.frames[1].height == layout.resultImageHeight)
            #expect(body.frames[1].y == body.frames[0].maxY + layout.segmentGap)
            #expect(body.total == body.frames[2].maxY)
        }

        @Test("image attachments wrap into rows, documents get a row each")
        func attachments() {
            func info(_ kind: AttachmentKind) -> ChatRowModel.AttachmentInfo {
                .init(kind: kind, filename: "f", originalName: "f")
            }
            let side = layout.thumbnailSide
            let gap = layout.thumbnailGap
            let a = AttachmentsBlock(images: [info(.image), info(.image), info(.image)], documents: [])
            // Two thumbnails fit into 600pt, the third wraps.
            #expect(layout.thumbnailsPerRow(width: width) == 2)
            #expect(layout.attachmentsHeight(a, width: width) == side * 2 + gap)
            #expect(layout.attachmentsHeight(a, width: 1000) == side)

            let docs = AttachmentsBlock(images: [info(.image)], documents: [info(.text), info(.document)])
            #expect(
                layout.attachmentsHeight(docs, width: width)
                    == side + gap + layout.chipHeight * 2 + layout.chipGap)

            var m = ChatRendererFixtures.message("m", role: .user)
            m.attachments = [info(.image), info(.text)]
            let r = render(m)
            #expect(r.blocks.count == 1)
            let heights = measure(r)
            #expect(heights[0] == side + gap + layout.chipHeight)
        }

        @Test("narrow columns shrink thumbnails instead of overflowing")
        func narrowThumbnails() {
            #expect(layout.fittedThumbnailSide(width: 100) == 100)
            #expect(layout.thumbnailsPerRow(width: 100) == 1)
        }

        @Test("every metric follows the interface scale")
        func scaling() {
            let big = RowLayout(theme: Theme(scale: 2))
            #expect(big.header == layout.header * 2)
            #expect(big.maxColumn == layout.maxColumn * 2)
            #expect(big.collapsibleHeader == layout.collapsibleHeader * 2)
            #expect(big.actionBar == layout.actionBar * 2)
            #expect(big.approvalHeight == layout.approvalHeight * 2)

            let m = ChatRendererFixtures.message("m", content: "hello")
            let small = RenderedMessage.render(m, theme: theme)
            let large = RenderedMessage.render(m, theme: Theme(scale: 2))
            let smallHeight = layout.height(small, heights: measure(small), open: [false])
            let largeHeight = big.height(
                large, heights: big.measure(large, width: width, existing: [], open: [false]), open: [false])
            #expect(largeHeight > smallHeight * 1.8)
        }

        @Test("the column is capped at the maximum width and never negative")
        func column() {
            #expect(layout.column(forListWidth: 5000) == layout.maxColumn)
            #expect(layout.column(forListWidth: 500) == 500 - layout.hPad * 2)
            #expect(layout.column(forListWidth: 10) == 0)
            #expect(layout.textWidth(column: 500) == 500 - layout.rowInset * 2)
        }

        @Test("estimates grow with the content")
        func estimates() {
            let short = ChatRendererFixtures.message("a", content: "hi")
            let long = ChatRendererFixtures.message("b", content: String(repeating: "word ", count: 500))
            #expect(layout.estimate(long, width: 600) > layout.estimate(short, width: 600))
            #expect(layout.estimate(short, width: 600) >= chrome)
            var withImage = short
            withImage.attachments = [.init(kind: .image, filename: "f", originalName: nil)]
            #expect(layout.estimate(withImage, width: 600) > layout.estimate(short, width: 600) + layout.thumbnailSide)
        }

        @Test("open policy: tools default from the preference, thinking is closed, toggles flip them")
        func openPolicy() {
            let m = ChatRendererFixtures.message("m", content: "x", thinking: "t")
            let r = render(m)
            let c = collapsible(r, at: 0)
            #expect(c.key == "m/thinking")
            var policy = OpenPolicy()
            #expect(!policy.isOpen(c))
            policy.toggled = ["m/thinking"]
            #expect(policy.isOpen(c))
            policy.toggled = []
            policy.toolsByDefault = true
            #expect(!policy.isOpen(c))
            #expect(policy.mask(for: r) == [false, false])
        }

        @Test("thinking header shows the recorded duration once it's no longer streaming")
        func thinkingTitle() {
            var m = ChatRendererFixtures.message("m", content: "x", thinking: "t")
            #expect(collapsible(render(m)).title == "Thinking")
            m.thinkingDuration = 12.4
            #expect(collapsible(render(m)).title == "Thought for 12 seconds")
            m.content = ""
            #expect(collapsible(render(m, streaming: true)).title == "Thinking")
            #expect(RenderedMessage.thinkingTitle(0.2) == "Thought for 1 second")
            #expect(RenderedMessage.thinkingTitle(0) == "Thinking")
            #expect(RenderedMessage.thinkingTitle(60) == "Thought for 1m")
            #expect(RenderedMessage.thinkingTitle(125) == "Thought for 2m 5s")
        }

        @Test("thinking that streams alone is locked open; any other output releases it")
        func thinkingLock() {
            var m = ChatRendererFixtures.message("m", thinking: "t")
            #expect(!collapsible(render(m), at: 0).forcedOpen)
            let streaming = collapsible(render(m, streaming: true), at: 0)
            #expect(streaming.forcedOpen)
            #expect(streaming.showsSpinner)
            #expect(OpenPolicy().isOpen(streaming))

            m.content = "x"
            #expect(!collapsible(render(m, streaming: true), at: 0).forcedOpen)
            m.content = ""
            m.toolCalls = [.init(id: "c", name: "t", arguments: "{}")]
            #expect(!collapsible(render(m, streaming: true), at: 0).forcedOpen)
        }
    }
}
