import AppKit
import Testing

@testable import iCanHazAI

extension AllAppTests {

    @Suite("Markdown renderer")
    struct MarkdownRendererTests {

        private let theme = Theme()

        @Test("plain text drops the markup and joins blocks on one line")
        func plainText() {
            #expect(MarkdownRenderer.plainText("> hello **how** are you?") == "hello how are you?")
            #expect(MarkdownRenderer.plainText("# Title\n\nsome ~~old~~ `code`\nnext") == "Title some old code next")
            #expect(MarkdownRenderer.plainText("```swift\nlet x = 1\n```") == "let x = 1")
            #expect(MarkdownRenderer.plainText("| a | b |\n|---|---|\n| 1 | 2 |") == "a b 1 2")
            #expect(MarkdownRenderer.plainText("![alt text](https://x.example/i.png)") == "alt text")
        }

        private func render(_ markdown: String, theme: Theme? = nil) -> RenderedText {
            MarkdownRenderer.render(markdown, theme: theme ?? self.theme)
        }

        private func attribute<T>(
            _ key: NSAttributedString.Key, at index: Int, in text: RenderedText, as: T.Type = T.self
        ) -> T? {
            text.string.attribute(key, at: index, effectiveRange: nil) as? T
        }

        private func paragraphStyle(at index: Int, in text: RenderedText) -> NSParagraphStyle? {
            attribute(.paragraphStyle, at: index, in: text)
        }

        // MARK: Plain text

        @Test("empty input renders nothing and has no height")
        func empty() {
            let text = render("")
            #expect(text.string.length == 0)
            #expect(text.height(forWidth: 300) == 0)
            #expect(text.topInset == 0)
            #expect(text.bottomInset == 0)
        }

        @Test("the trailing newline of the last paragraph is stripped")
        func trailingNewline() {
            #expect(render("hello\n\n").string.string == "hello")
            #expect(render("one\n\ntwo").string.string == "one\ntwo")
        }

        @Test("CRLF line endings are normalized")
        func crlf() {
            let text = render("a\r\nb\r\n\r\nc")
            #expect(!text.string.string.contains("\r"))
            #expect(text.string.string == "a b\nc")
        }

        @Test("a hard break becomes a line separator inside the paragraph")
        func hardBreak() {
            #expect(render("a\\\nb").string.string == "a\u{2028}b")
        }

        @Test("every font size follows the theme scale")
        func scaledFonts() {
            let body = attribute(.font, at: 0, in: render("body"), as: NSFont.self)
            let scaled = attribute(.font, at: 0, in: render("body", theme: Theme(scale: 2)), as: NSFont.self)
            #expect(body?.pointSize == 13)
            #expect(scaled?.pointSize == 26)
        }

        @Test("headings use the heading sizes, deeper levels fall back to the body size")
        func headings() {
            let text = render("# One\n\n## Two\n\n### Three\n\n#### Four\n\nbody")
            let ns = text.string.string as NSString
            func size(of word: String) -> CGFloat? {
                attribute(.font, at: ns.range(of: word).location, in: text, as: NSFont.self)?.pointSize
            }
            #expect(size(of: "One") == theme.headingSize(1))
            #expect(size(of: "Two") == theme.headingSize(2))
            #expect(size(of: "Three") == theme.headingSize(3))
            #expect(size(of: "Four") == theme.fontSize)
            #expect(size(of: "body") == theme.fontSize)
            #expect(size(of: "One")! > size(of: "Two")!)
        }

        // MARK: Lists

        @Test("bullet lists get a tab-separated marker with tab stops at the content indent")
        func bullets() throws {
            let text = render("- one\n- two")
            #expect(text.string.string == "\t•\tone\n\t•\ttwo")
            let style = try #require(paragraphStyle(at: 3, in: text))
            #expect(style.firstLineHeadIndent == 0)
            #expect(style.headIndent == theme.bulletWidth)
            #expect(style.tabStops.count == 2)
            #expect(style.tabStops[0].location == theme.bulletWidth - theme.markerGap)
            #expect(style.tabStops[0].alignment == .right)
            #expect(style.tabStops[1].location == theme.bulletWidth)
            #expect(style.tabStops[1].alignment == .left)
        }

        @Test("nested bullets cycle through the marker glyphs and indent further")
        func nestedBullets() throws {
            let text = render("- a\n  - b\n    - c")
            #expect(text.string.string == "\t•\ta\n\t◦\tb\n\t▪\tc")
            let outer = try #require(paragraphStyle(at: 3, in: text))
            let inner = try #require(paragraphStyle(at: text.string.string.count - 1, in: text))
            #expect(inner.headIndent > outer.headIndent)
            #expect(inner.firstLineHeadIndent > outer.firstLineHeadIndent)
        }

        @Test("ordered lists number from the start value and widen the marker column for long numbers")
        func ordered() throws {
            let short = render("1. a\n2. b")
            #expect(short.string.string == "\t1.\ta\n\t2.\tb")

            let long = render("8) a\n9) b\n10) c")
            #expect(long.string.string == "\t8.\ta\n\t9.\tb\n\t10.\tc")
            let shortStyle = try #require(paragraphStyle(at: 3, in: short))
            let longStyle = try #require(paragraphStyle(at: 3, in: long))
            #expect(longStyle.headIndent > shortStyle.headIndent)
            #expect(longStyle.tabStops[0].location == longStyle.headIndent - theme.markerGap)
        }

        @Test("task list items show a checkbox glyph")
        func taskList() {
            #expect(render("- [x] done\n- [ ] todo").string.string == "\t☑\tdone\n\t☐\ttodo")
        }

        // MARK: Quotes

        @Test("blockquotes carry one marker per nesting level, each with its character range")
        func quotes() throws {
            let text = render("plain\n\n> outer\n>\n> > inner")
            let ns = text.string.string as NSString
            let outerAt = ns.range(of: "outer").location
            let innerAt = ns.range(of: "inner").location

            #expect(attribute(MDAttr.quote, at: 0, in: text, as: [QuoteMarker].self) == nil)
            let outerMarkers = try #require(attribute(MDAttr.quote, at: outerAt, in: text, as: [QuoteMarker].self))
            let innerMarkers = try #require(attribute(MDAttr.quote, at: innerAt, in: text, as: [QuoteMarker].self))
            #expect(outerMarkers.count == 1)
            #expect(innerMarkers.count == 2)
            #expect(innerMarkers[0] === outerMarkers[0])

            let outer = outerMarkers[0]
            let inner = innerMarkers[1]
            #expect(NSLocationInRange(outerAt, outer.range))
            #expect(NSLocationInRange(innerAt, outer.range))
            #expect(NSLocationInRange(innerAt, inner.range))
            #expect(!NSLocationInRange(outerAt, inner.range))
            #expect(inner.x == outer.x + theme.quoteIndent)
        }

        // MARK: Code

        @Test("a fenced code block is one paragraph with U+2028 separators and a marker covering it")
        func fencedCode() throws {
            let text = render("```swift\nlet a = 1\nlet b = 2\n```")
            #expect(text.string.string == "let a = 1\u{2028}let b = 2")
            let marker = try #require(attribute(MDAttr.codeBlock, at: 0, in: text, as: CodeBlockMarker.self))
            #expect(marker.language == "swift")
            #expect(marker.range == NSRange(location: 0, length: text.string.length))
            #expect(attribute(.font, at: 0, in: text, as: NSFont.self)?.isFixedPitch == true)
            #expect(!text.string.string.contains("\n"))
        }

        @Test("an indented code block has no language marker")
        func indentedCode() throws {
            let text = render("    one\n    two")
            #expect(text.string.string == "one\u{2028}two")
            let marker = try #require(attribute(MDAttr.codeBlock, at: 0, in: text, as: CodeBlockMarker.self))
            #expect(marker.language == nil)
        }

        @Test("an empty code block still occupies a line")
        func emptyCode() {
            let text = render("```\n```")
            #expect(text.string.length == 1)
            #expect(attribute(MDAttr.codeBlock, at: 0, in: text, as: CodeBlockMarker.self) != nil)
        }

        @Test("a leading or trailing code block reserves the room TextKit can't give its box")
        func codeInsets() {
            let plain = render("text")
            #expect(plain.topInset == 0)
            #expect(plain.bottomInset == 0)

            let unlabelled = render("```\ncode\n```")
            #expect(unlabelled.topInset == theme.codePadV + theme.codeLabelHeight)
            #expect(unlabelled.bottomInset == theme.codePadV)

            let labelled = render("```py\ncode\n```")
            #expect(labelled.topInset == theme.codePadV + theme.codeLabelHeight)

            let trailing = render("text\n\n```\ncode\n```")
            #expect(trailing.topInset == 0)
            #expect(trailing.bottomInset == theme.codePadV)

            let leading = render("```\ncode\n```\n\ntext")
            #expect(leading.topInset == theme.codePadV + theme.codeLabelHeight)
            #expect(leading.bottomInset == 0)
        }

        @Test("HTML blocks are shown as source in a code box, inline HTML stays literal")
        func html() throws {
            let block = render("<div>hi</div>")
            #expect(block.string.string == "<div>hi</div>")
            let marker = try #require(attribute(MDAttr.codeBlock, at: 0, in: block, as: CodeBlockMarker.self))
            #expect(marker.language == "html")

            let inline = render("a <b>c</b> d")
            #expect(inline.string.string == "a <b>c</b> d")
            #expect(attribute(MDAttr.codeBlock, at: 0, in: inline, as: CodeBlockMarker.self) == nil)
        }

        @Test("inline code is marked, monospaced and keeps the copied text intact")
        func inlineCode() throws {
            let text = render("a `b` c")
            #expect(text.string.string == "a b c")
            #expect(attribute(MDAttr.inlineCode, at: 0, in: text, as: InlineCodeMarker.self) == nil)
            #expect(attribute(MDAttr.inlineCode, at: 2, in: text, as: InlineCodeMarker.self) != nil)
            #expect(attribute(.font, at: 2, in: text, as: NSFont.self)?.isFixedPitch == true)
        }

        @Test("inline code spacing is kerning: full gap next to spaces, half next to punctuation, none at line starts")
        func inlineCodeGaps() {
            let spaced = render("a `b` c")
            #expect(attribute(.kern, at: 1, in: spaced, as: CGFloat.self) == theme.inlineCodeGap)
            #expect(attribute(.kern, at: 2, in: spaced, as: CGFloat.self) == theme.inlineCodeGap)

            let punctuated = render("(`b`)")
            #expect(punctuated.string.string == "(b)")
            #expect(attribute(.kern, at: 0, in: punctuated, as: CGFloat.self) == theme.inlineCodeGap / 2)
            #expect(attribute(.kern, at: 1, in: punctuated, as: CGFloat.self) == theme.inlineCodeGap / 2)

            let leading = render("`b` c")
            #expect(attribute(.kern, at: 0, in: leading, as: CGFloat.self) == theme.inlineCodeGap)

            let atEnd = render("a `b`")
            #expect(attribute(.kern, at: 1, in: atEnd, as: CGFloat.self) == theme.inlineCodeGap)
            #expect(attribute(.kern, at: 2, in: atEnd, as: CGFloat.self) == nil)

            let afterBreak = render("a\\\n`b`")
            #expect(afterBreak.string.string == "a\u{2028}b")
            #expect(attribute(.kern, at: 1, in: afterBreak, as: CGFloat.self) == nil)
        }

        // MARK: Inline styles

        @Test("strikethrough, bold and italic map to attributes")
        func inlineStyles() {
            let text = render("~~gone~~ **bold** *slanted*")
            let ns = text.string.string as NSString
            let strike = ns.range(of: "gone").location
            let bold = ns.range(of: "bold").location
            let italic = ns.range(of: "slanted").location
            #expect(attribute(.strikethroughStyle, at: strike, in: text, as: Int.self) != nil)
            #expect(attribute(.strikethroughStyle, at: bold, in: text, as: Int.self) == nil)
            let boldFont = attribute(.font, at: bold, in: text, as: NSFont.self)
            let italicFont = attribute(.font, at: italic, in: text, as: NSFont.self)
            #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.italic) == false)
            #expect(boldFont != attribute(.font, at: strike, in: text, as: NSFont.self))
            #expect(italicFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        }

        @Test("links carry their URL; images turn into links showing the alt text or the URL")
        func links() {
            let link = render("[site](https://example.com/a)")
            #expect(link.string.string == "site")
            #expect(attribute(.link, at: 0, in: link, as: URL.self) == URL(string: "https://example.com/a"))

            let image = render("![a cat](https://example.com/cat.png)")
            #expect(image.string.string == "a cat")
            #expect(attribute(.link, at: 0, in: image, as: URL.self) == URL(string: "https://example.com/cat.png"))

            let bare = render("![](https://example.com/cat.png)")
            #expect(bare.string.string == "https://example.com/cat.png")
            #expect(attribute(.link, at: 0, in: bare, as: URL.self) != nil)
        }

        @Test("bare URLs become links")
        func autolinks() {
            let text = render("see https://example.com/x now")
            let ns = text.string.string as NSString
            let at = ns.range(of: "https").location
            #expect(attribute(.link, at: at, in: text, as: URL.self) == URL(string: "https://example.com/x"))
            #expect(attribute(.link, at: 0, in: text, as: URL.self) == nil)
            #expect(text.string.string == "see https://example.com/x now")
        }

        @Test("a horizontal rule is a marked placeholder paragraph")
        func rule() {
            let text = render("a\n\n---\n\nb")
            #expect(text.string.string == "a\n \nb")
            #expect(attribute(MDAttr.rule, at: 2, in: text, as: RuleMarker.self) != nil)
            #expect(attribute(MDAttr.rule, at: 0, in: text, as: RuleMarker.self) == nil)
        }

        // MARK: Tables

        private let tableMarkdown = """
            | Name | Description |
            | ---- | ----------: |
            | a | a much longer cell with many words in it |
            """

        @Test("table cells are paragraphs; the spec records their position, header flag and widths")
        func table() throws {
            let text = render(tableMarkdown)
            #expect(text.string.string == "Name\nDescription\na\na much longer cell with many words in it")
            let spec = try #require(text.tables.first)
            #expect(text.tables.count == 1)
            #expect(spec.columns == 2)
            #expect(spec.cells.count == 4)
            #expect(spec.cells.map(\.header) == [true, true, false, false])
            #expect(spec.cells.map(\.row) == [0, 0, 1, 1])
            #expect(spec.cells.map(\.column) == [0, 1, 0, 1])
            for c in 0..<2 {
                #expect(spec.minWidths[c] > 0)
                #expect(spec.minWidths[c] <= spec.maxWidths[c])
            }
            #expect(spec.maxWidths[1] > spec.maxWidths[0])
            #expect(spec.minWidths[1] < spec.maxWidths[1])
            #expect(spec.cells[1].style.alignment == .right)

            let bold = attribute(.font, at: 0, in: text, as: NSFont.self)
            let body = attribute(.font, at: spec.cells[2].range.location, in: text, as: NSFont.self)
            #expect(bold != body)
        }

        @Test("tables get native text blocks per layout width")
        func tableVariants() throws {
            let text = render(tableMarkdown)
            let wide = text.string(forWidth: 800)
            let narrow = text.string(forWidth: 200)
            #expect(wide !== narrow)
            #expect(text.string(forWidth: 800) === wide)
            #expect(wide.string == text.string.string)

            func block(in s: NSAttributedString, at index: Int) -> NSTextTableBlock? {
                (s.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?
                    .textBlocks.first as? NSTextTableBlock
            }
            let descriptionCell = try #require(text.tables.first?.cells[1])
            let wideBlock = try #require(block(in: wide, at: descriptionCell.range.location))
            let narrowBlock = try #require(block(in: narrow, at: descriptionCell.range.location))
            #expect(wideBlock.value(for: .width) > narrowBlock.value(for: .width))
            #expect(text.height(forWidth: 200) > text.height(forWidth: 800))
        }

        @Test("text without tables hands out the same string for every width")
        func noTableVariants() {
            let text = render("plain")
            #expect(text.string(forWidth: 100) === text.string)
            #expect(text.string(forWidth: 900) === text.string)
        }

        // MARK: Plain text rendering

        @Test("plain rendering keeps the text verbatim, drops trailing newlines and caps the length")
        func plain() {
            let text = MarkdownRenderer.plain("# not markdown\n\n", theme: theme)
            #expect(text.string.string == "# not markdown")
            #expect(attribute(.font, at: 0, in: text, as: NSFont.self)?.isFixedPitch == true)

            let proportional = MarkdownRenderer.plain("abc", theme: theme, mono: false)
            #expect(attribute(.font, at: 0, in: proportional, as: NSFont.self)?.isFixedPitch == false)

            let huge = String(repeating: "x", count: theme.maxPlainLength + 1000)
            let capped = MarkdownRenderer.plain(huge, theme: theme)
            #expect(capped.string.length < huge.utf16.count)
            #expect(capped.string.string.hasSuffix("… (1000 more characters)"))
        }

        // MARK: Copying

        @MainActor
        @Test("copying a selection turns line separators back into newlines")
        func copyRestoresNewlines() {
            let view = MarkdownTextView()
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
            view.setRenderedIfNeeded(render("```\none\ntwo\n```"), width: 400)
            view.setSelectedRange(NSRange(location: 0, length: view.textStorage?.length ?? 0))
            let board = NSPasteboard(name: NSPasteboard.Name("iCanHazAI.tests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.clearContents()
            #expect(view.writeSelection(to: board, type: .string))
            #expect(board.string(forType: .string) == "one\ntwo")
        }

        // MARK: Fade-in

        @MainActor
        @Test("only the text past what the view already showed fades in")
        func fadeTracksNewText() throws {
            let view = MarkdownTextView()
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
            view.setRenderedIfNeeded(render("Hello wor"), width: 400)
            #expect(view.fadingRanges.isEmpty)
            let first = try #require(view.textStorage?.length)

            view.setRenderedIfNeeded(render("Hello world"), width: 400, fadeIn: true)
            let second = try #require(view.textStorage?.length)
            #expect(view.fadingRanges == [NSRange(location: first, length: second - first)])

            view.setRenderedIfNeeded(render("Hello world again"), width: 400, fadeIn: true)
            let third = try #require(view.textStorage?.length)
            #expect(
                view.fadingRanges == [
                    NSRange(location: first, length: second - first),
                    NSRange(location: second, length: third - second),
                ])

            // A rewrite earlier in the text drops the fades that no longer apply.
            view.setRenderedIfNeeded(render("Hello there"), width: 400, fadeIn: true)
            let shared = "Hello ".utf16.count
            #expect(view.fadingRanges.first?.location == shared)
            #expect(view.fadingRanges.allSatisfy { NSMaxRange($0) <= (view.textStorage?.length ?? 0) })

            view.setRenderedIfNeeded(render("Something else"), width: 400)
            #expect(view.fadingRanges.isEmpty)
        }

        @Test("a fade is transparent when it starts and opaque when it ends")
        func fadeAlpha() {
            let fade = TextFade(range: NSRange(location: 0, length: 1), start: 10, duration: 0.5)
            #expect(fade.alpha(at: 9) == 0)
            #expect(fade.alpha(at: 10) == 0)
            #expect(abs(fade.alpha(at: 10.25) - 0.5) < 1e-9)
            #expect(fade.alpha(at: 10.5) == 1)
            #expect(fade.alpha(at: 12) == 1)
            #expect(fade.isRunning(at: 10.4))
            #expect(!fade.isRunning(at: 10.5))
        }

        @MainActor
        @Test("faded text is drawn translucent while the rest keeps its ink")
        func fadedTextDraws() throws {
            let text = render("Hello world")
            let view = MarkdownTextView()
            view.theme = theme
            view.frame = NSRect(x: 0, y: 0, width: 300, height: text.height(forWidth: 300))
            view.setRenderedIfNeeded(text, width: 300)
            let lm = try #require(view.layoutManager as? MarkdownLayoutManager)
            let container = try #require(view.textContainer)

            func ink(_ range: NSRange) throws -> CGFloat {
                let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let box = lm.boundingRect(forGlyphRange: glyphs, in: container).insetBy(dx: 1, dy: 1)
                let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / view.bounds.width
                var total: CGFloat = 0
                for y in Int(box.minY * scale)..<Int(box.maxY * scale) {
                    for x in Int(box.minX * scale)..<Int(box.maxX * scale) {
                        total += rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    }
                }
                return total
            }

            let world = NSRange(location: 6, length: 5)
            let hello = NSRange(location: 0, length: 5)
            let solidWorld = try ink(world)
            let solidHello = try ink(hello)
            #expect(solidWorld > 0)

            lm.fades = [TextFade(range: world, start: CACurrentMediaTime() + 100, duration: 1)]
            #expect(try ink(world) < solidWorld * 0.05)
            #expect(try ink(hello) == solidHello)

            lm.fades = [TextFade(range: world, start: CACurrentMediaTime() - 0.5, duration: 1)]
            let half = try ink(world)
            #expect(half > solidWorld * 0.2 && half < solidWorld * 0.8)
        }
    }
}
