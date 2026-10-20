import AppKit
import Testing

@testable import iCanHazAI

extension AllAppTests {

    @MainActor
    @Suite("Incremental layout of growing text")
    struct IncrementalLayoutTests {
        private let theme = Theme()
        private let width: CGFloat = 600

        private func render(_ markdown: String) -> RenderedText {
            MarkdownRenderer.render(markdown, theme: theme)
        }

        private func block(_ i: Int, table: Bool = false) -> String {
            let p = ChatRendererFixtures.paragraph
            let tableMarkdown = table ? "| Key | Value |\n| --- | ---: |\n| a | \(i) |\n| b | 2 |\n\n" : ""
            return """
                # Section \(i)

                Intro \(i) with **bold**, *italic*, `inline code`, ~~struck~~ and a [link](https://example.com/\(i)). \(p(i, 3))

                Setext heading \(i)
                ================

                > A quote with *emphasis* \(p(i + 1, 2))
                >
                > > nested quote \(i)

                1. one
                2. two
                3. three
                4. four
                5. five
                6. six
                7. seven
                8. eight
                9. nine
                10. ten
                11. eleven \(p(i, 1))

                - bullet a
                  - nested b \(p(i + 2, 1))
                    - nested c
                - bullet d

                \(tableMarkdown)```swift
                let x = \(i)
                print(x)
                ```

                \(p(i + 3, 5))

                ---

                - [ ] task one
                - [x] task two

                ```
                unlabeled \(i)
                ```

                Closing paragraph \(i). \(p(i + 4, 4))


                """
        }

        /// Every kind of block, no tables: reuse can go all the way to the end.
        private var document: String { (0..<3).map { block($0) }.joined() }

        /// The same with a table in the middle section: only what comes before it can be reused.
        private var tableDocument: String { (0..<3).map { block($0, table: $0 == 1) }.joined() }

        /// Cut into odd-sized chunks, so block boundaries fall at every possible place.
        private func prefixes(of text: String, step: Int) -> [String] {
            let chars = Array(text)
            return stride(from: step, to: chars.count + step, by: step).map { String(chars[0..<min($0, chars.count)]) }
        }

        // MARK: Pieces

        @Test("the shared prefix counts UTF-16 units up to the first difference")
        func sharedPrefix() {
            func shared(_ a: String, _ b: String) -> Int { StableText.sharedPrefix(a as NSString, b as NSString) }
            #expect(shared("", "abc") == 0)
            #expect(shared("abc", "abc") == 3)
            #expect(shared("abc", "abcdef") == 3)
            #expect(shared("abcx", "abcy") == 3)
            #expect(shared("a😀b", "a😀c") == 3)
            let long = String(repeating: "x", count: 5000)
            #expect(shared(long + "a", long + "b") == 5000)
            #expect(shared(long, long + "b") == 5000)
            #expect(shared("y" + long, "z" + long) == 0)
        }

        @Test("only blocks that are complete and unchanged in both texts are kept")
        func keptLength() {
            func blocks(_ marks: [(Int, Int)]) -> [TextBlock] { marks.map { TextBlock(start: $0.0, signature: $0.1) } }
            let old = blocks([(0, 1), (10, 2), (20, 3)])
            let new = blocks([(0, 1), (10, 2), (20, 3), (30, 4)])
            // The block holding the difference is replaced, so is the old last one, which may still have grown.
            #expect(StableText.keptLength(old: old, new: new, shared: 25) == 20)
            #expect(StableText.keptLength(old: old, new: new, shared: 15) == 10)
            #expect(StableText.keptLength(old: old, new: new, shared: 5) == 0)
            // A block whose attributes changed breaks the chain even though its characters didn't.
            let restyled = blocks([(0, 1), (10, 9), (20, 3), (30, 4)])
            #expect(StableText.keptLength(old: old, new: restyled, shared: 25) == 10)
            // Blocks starting somewhere else aren't the same blocks.
            let moved = blocks([(0, 1), (12, 2), (20, 3)])
            #expect(StableText.keptLength(old: old, new: moved, shared: 25) == 0)
            #expect(StableText.keptLength(old: [], new: new, shared: 25) == 0)
        }

        @Test("rendering the same markdown twice gives the same block signatures")
        func signaturesAreDeterministic() {
            let a = render(document).blocks
            let b = render(document).blocks
            #expect(a.count > 10)
            #expect(a == b)
            #expect(a.map(\.start) == a.map(\.start).sorted())
        }

        @Test("blocks that differ only in how they look get different signatures")
        func signaturesSeeAttributes() {
            #expect(render("*a*\n\nx").blocks[0].signature != render("a\n\nx").blocks[0].signature)
            #expect(render("# a\n\nx").blocks[0].signature != render("a\n\nx").blocks[0].signature)
            #expect(
                render("[a](https://x.test/1)\n\nx").blocks[0].signature
                    != render("[a](https://x.test/2)\n\nx").blocks[0].signature)
            #expect(render("- a\n\nx").blocks[0].signature != render("1. a\n\nx").blocks[0].signature)

            let big = MarkdownRenderer.render("a\n\nx", theme: Theme(scale: 1.5))
            #expect(big.blocks[0].signature != render("a\n\nx").blocks[0].signature)
        }

        @Test("a table ends the part of a text that can be reused")
        func tableEndsBlocks() {
            let text = render("intro\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nafter the table\n\nand more")
            let table = text.tables.first?.cells.first?.range.location ?? .max
            #expect(text.blocks.count == 2)
            #expect(text.blocks.allSatisfy { $0.start <= table })
        }

        // MARK: Measuring

        private func fullHeight(of text: RenderedText, width: CGFloat) -> CGFloat {
            text.topInset + TextMeasurer.height(of: text.string(forWidth: width), width: width) + text.bottomInset
        }

        @Test("the height of a message growing chunk by chunk always matches a full layout")
        func measureMatchesFullLayout() {
            var reused = 0
            var long = 0
            for markdown in prefixes(of: document, step: 53) {
                let text = render(markdown)
                let height = text.height(forWidth: width)
                #expect(height == fullHeight(of: text, width: width), "at \(markdown.count) characters")
                if text.string.length >= TextMeasurer.growingThreshold {
                    long += 1
                    if TextMeasurer.lastKeptLength > 0 { reused += 1 }
                }
            }
            #expect(long > 20)
            #expect(reused > long * 6 / 10)
        }

        @Test("messages with a table in them measure like a full layout at every step")
        func measureWithTable() {
            var reused = 0
            for markdown in prefixes(of: tableDocument, step: 61) {
                let text = render(markdown)
                #expect(text.height(forWidth: width) == fullHeight(of: text, width: width), "at \(markdown.count)")
                if TextMeasurer.lastKeptLength > 0 { reused += 1 }
            }
            #expect(reused > 0)
        }

        @Test("a width change, another message or a restyled block never reuses stale layout")
        func measureDoesNotReuseStaleLayout() {
            let filler = (0..<12).map { ChatRendererFixtures.paragraph($0, sentences: 5) }.joined(separator: "\n\n")
            let a = render("*a*\n\n" + filler)
            let b = render("a\n\n" + filler)
            #expect(a.string.length >= TextMeasurer.growingThreshold)
            #expect(a.height(forWidth: width) == fullHeight(of: a, width: width))
            #expect(b.height(forWidth: width) == fullHeight(of: b, width: width))
            // Same characters and block starts, but the first block is italic in one of them.
            #expect(TextMeasurer.lastKeptLength == 0)

            let grown = render("a\n\n" + filler + "\n\nmore text that continues the message")
            #expect(grown.height(forWidth: width) == fullHeight(of: grown, width: width))
            #expect(TextMeasurer.lastKeptLength > 0)

            for w in [width - 150, width, width - 90] {
                #expect(grown.height(forWidth: w) == fullHeight(of: grown, width: w))
            }
            let other = render(document)
            #expect(other.height(forWidth: width) == fullHeight(of: other, width: width))
        }

        @Test("two texts growing side by side don't evict each other")
        func interleavedGrowth() {
            let a = prefixes(of: document, step: 211)
            let b = prefixes(of: tableDocument.replacingOccurrences(of: "Section", with: "Part"), step: 211)
            var reused = 0
            var long = 0
            for i in 0..<min(a.count, b.count) {
                for markdown in [a[i], b[i]] {
                    let text = render(markdown)
                    #expect(text.height(forWidth: width) == fullHeight(of: text, width: width))
                    if text.string.length >= TextMeasurer.growingThreshold {
                        long += 1
                        if TextMeasurer.lastKeptLength > 0 { reused += 1 }
                    }
                }
            }
            #expect(long > 10)
            #expect(reused > long * 6 / 10)
        }

        @Test("plain text (thinking, results) grows the same way")
        func plainTextMeasures() {
            let lines = (0..<400).map { "line \($0): \(ChatRendererFixtures.paragraph($0 % 7, sentences: 1))" }
            var reused = 0
            for markdown in prefixes(of: lines.joined(separator: "\n"), step: 211) {
                let text = MarkdownRenderer.plain(markdown, theme: theme, mono: false)
                #expect(text.height(forWidth: width) == fullHeight(of: text, width: width))
                if TextMeasurer.lastKeptLength > 0 { reused += 1 }
            }
            #expect(reused > 20)
        }

        // MARK: Showing

        /// What each run of text looks like, merged across run boundaries the text system is free to place.
        private func appearance(of view: MarkdownTextView) -> [String] {
            guard let storage = view.textStorage else { return [] }
            var out: [(String, Int)] = []
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
                var h = Hasher()
                if let f = attrs[.font] as? NSFont { TextFingerprint.combine(f, into: &h) }
                let code = attrs[MDAttr.codeBlock] as? CodeBlockMarker
                if code == nil, let c = attrs[.foregroundColor] as? NSColor { TextFingerprint.combine(c, into: &h) }
                if let p = attrs[.paragraphStyle] as? NSParagraphStyle { TextFingerprint.combine(p, into: &h) }
                h.combine(attrs[.link] as? URL)
                h.combine(attrs[.kern] as? CGFloat)
                h.combine(attrs[.strikethroughStyle] != nil)
                h.combine(attrs[MDAttr.inlineCode] != nil)
                if let rule = attrs[MDAttr.rule] as? RuleMarker { h.combine(rule.indent) }
                for q in (attrs[MDAttr.quote] as? [QuoteMarker]) ?? [] {
                    h.combine(q.x)
                    h.combine(q.range.location)
                    h.combine(q.range.length)
                }
                if let code {
                    h.combine(code.indent)
                    h.combine(code.language)
                    h.combine(code.code)
                    h.combine(code.range.location)
                    h.combine(code.range.length)
                }
                let signature = String(h.finalize())
                if let last = out.last, last.0 == signature {
                    out[out.count - 1].1 += range.length
                } else {
                    out.append((signature, range.length))
                }
            }
            return out.map { "\($0.0):\($0.1)" }
        }

        private func codeBlocks(in view: MarkdownTextView) -> [CodeBlockMarker] {
            guard let storage = view.textStorage else { return [] }
            var markers: [CodeBlockMarker] = []
            storage.enumerateAttribute(MDAttr.codeBlock, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                if let m = v as? CodeBlockMarker { markers.append(m) }
            }
            return markers
        }

        private func visibleCopyButtons(_ view: MarkdownTextView) -> Int {
            view.subviews.compactMap { $0 as? CodeCopyButton }.filter { !$0.isHidden }.count
        }

        private func layoutHeight(_ view: MarkdownTextView) -> CGFloat {
            guard let lm = view.layoutManager, let tc = view.textContainer else { return 0 }
            lm.ensureLayout(for: tc)
            return ceil(lm.usedRect(for: tc).height)
        }

        private func shown(_ text: RenderedText, in view: MarkdownTextView) {
            view.frame = NSRect(x: 0, y: 0, width: width, height: text.height(forWidth: width))
            view.setRenderedIfNeeded(text, width: width)
        }

        @Test("a view fed a growing message ends up exactly like one shown the whole text at once")
        func viewMatchesFreshView() throws {
            let streaming = MarkdownTextView()
            streaming.theme = theme
            var reused = 0
            var steps = 0
            for markdown in prefixes(of: document, step: 53) {
                let text = render(markdown)
                shown(text, in: streaming)
                let fresh = MarkdownTextView()
                fresh.theme = theme
                shown(text, in: fresh)
                steps += 1
                if streaming.lastKeptLength > 0 { reused += 1 }

                #expect(streaming.textStorage?.string == fresh.textStorage?.string, "at \(markdown.count) characters")
                #expect(appearance(of: streaming) == appearance(of: fresh), "at \(markdown.count) characters")
                #expect(layoutHeight(streaming) == layoutHeight(fresh), "at \(markdown.count) characters")
                #expect(visibleCopyButtons(streaming) == visibleCopyButtons(fresh), "at \(markdown.count) characters")
                #expect(streaming.topInset == fresh.topInset)

                // Every code block in the text is the marker of a block that is really there.
                let markers = codeBlocks(in: streaming)
                #expect(markers.count == text.codeBlocks.count)
                for (marker, expected) in zip(markers, text.codeBlocks) {
                    #expect(marker.range == expected.range)
                    #expect(marker.code == expected.code)
                }
            }
            #expect(reused > steps * 6 / 10)
        }

        @Test("a view showing a message with a table matches a fresh one at every step")
        func viewWithTable() {
            let streaming = MarkdownTextView()
            streaming.theme = theme
            for markdown in prefixes(of: tableDocument, step: 97) {
                let text = render(markdown)
                shown(text, in: streaming)
                let fresh = MarkdownTextView()
                fresh.theme = theme
                shown(text, in: fresh)
                #expect(streaming.textStorage?.string == fresh.textStorage?.string, "at \(markdown.count)")
                #expect(appearance(of: streaming) == appearance(of: fresh), "at \(markdown.count)")
                #expect(layoutHeight(streaming) == layoutHeight(fresh), "at \(markdown.count)")
            }
        }

        @Test("a view reused for another message shows it completely")
        func viewReusedForAnotherMessage() {
            let view = MarkdownTextView()
            view.theme = theme
            shown(render(document), in: view)
            let other = render("# Other\n\nSomething else entirely.\n\n```python\nprint(1)\n```\n\ntail")
            shown(other, in: view)
            #expect(view.lastKeptLength == 0)
            let fresh = MarkdownTextView()
            fresh.theme = theme
            shown(other, in: fresh)
            #expect(view.textStorage?.string == fresh.textStorage?.string)
            #expect(appearance(of: view) == appearance(of: fresh))
            #expect(layoutHeight(view) == layoutHeight(fresh))
            #expect(visibleCopyButtons(view) == 1)
        }

        @Test("plain text in a view grows like a fresh one")
        func plainTextView() {
            let lines = (0..<300).map { "line \($0): \(ChatRendererFixtures.paragraph($0 % 5, sentences: 1))" }
            let streaming = MarkdownTextView()
            streaming.theme = theme
            var reused = 0
            for markdown in prefixes(of: lines.joined(separator: "\n"), step: 173) {
                let text = MarkdownRenderer.plain(markdown, theme: theme, mono: false)
                shown(text, in: streaming)
                if streaming.lastKeptLength > 0 { reused += 1 }
                let fresh = MarkdownTextView()
                fresh.theme = theme
                shown(text, in: fresh)
                #expect(streaming.textStorage?.string == fresh.textStorage?.string)
                #expect(appearance(of: streaming) == appearance(of: fresh))
                #expect(layoutHeight(streaming) == layoutHeight(fresh))
            }
            #expect(reused > 10)
        }

        @Test("highlighted code blocks keep their colors while the message grows")
        func detectedColorsSurvive() {
            let view = MarkdownTextView()
            view.theme = theme
            let head = "intro\n\n```swift\nlet value = 1\nprint(value)\n```\n\nbetween\n\n"
            shown(render(head + "tail"), in: view)
            guard let storage = view.textStorage else { return }
            let before = storage.attributes(
                at: (storage.string as NSString).range(of: "value").location, effectiveRange: nil)
            shown(render(head + "tail grows and grows"), in: view)
            #expect(view.lastKeptLength > 0)
            let after = storage.attributes(
                at: (storage.string as NSString).range(of: "value").location, effectiveRange: nil)
            #expect((before[.foregroundColor] as AnyObject?) === (after[.foregroundColor] as AnyObject?))
        }
    }
}
