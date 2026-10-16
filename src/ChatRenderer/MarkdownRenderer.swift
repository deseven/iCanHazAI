import AppKit
import cmark_gfm
import cmark_gfm_extensions

/// A rendered text plus the vertical insets TextKit can't express itself: it
/// ignores `paragraphSpacingBefore` on the first paragraph and `paragraphSpacing`
/// on the last one, but code block boxes need that room.
struct RenderedText: @unchecked Sendable {
    let string: NSAttributedString
    let topInset: CGFloat
    let bottomInset: CGFloat
    let tables: [TableSpec]
    private let variants = VariantCache()
    private let heights = HeightCache()

    init(string: NSAttributedString, topInset: CGFloat, bottomInset: CGFloat, tables: [TableSpec] = []) {
        self.string = string
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.tables = tables
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard string.length > 0 else { return 0 }
        return heights.value(for: width) {
            topInset + TextMeasurer.height(of: string(forWidth: width), width: width) + bottomInset
        }
    }

    /// TextKit can't size table columns by content, so messages with tables
    /// get a per-width copy whose column widths are computed here.
    func string(forWidth width: CGFloat) -> NSAttributedString {
        guard !tables.isEmpty else { return string }
        return variants.value(for: width) {
            let copy = NSMutableAttributedString(attributedString: string)
            for t in tables { t.apply(to: copy, width: width) }
            return copy
        }
    }
}

/// Remembers the last measured heights, so a view laying out a body that the
/// list already measured doesn't lay the text out a second time.
final class HeightCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(CGFloat, CGFloat)] = []

    func value(for width: CGFloat, make: () -> CGFloat) -> CGFloat {
        lock.lock()
        if let hit = entries.first(where: { $0.0 == width }) {
            lock.unlock()
            return hit.1
        }
        lock.unlock()
        let v = make()
        lock.lock()
        entries.append((width, v))
        if entries.count > 2 { entries.removeFirst() }
        lock.unlock()
        return v
    }
}

final class VariantCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(CGFloat, NSAttributedString)] = []

    func value(for width: CGFloat, make: () -> NSAttributedString) -> NSAttributedString {
        lock.lock()
        if let hit = entries.first(where: { $0.0 == width }) {
            lock.unlock()
            return hit.1
        }
        lock.unlock()
        let v = make()
        lock.lock()
        // Two widths cover "main text" and "panel text"; live resize churns the rest.
        entries.append((width, v))
        if entries.count > 2 { entries.removeFirst() }
        lock.unlock()
        return v
    }
}

/// Everything needed to lay a table out at any width. Widths exclude cell padding.
/// Only mutated while the owning `MarkdownBuilder` is running.
final class TableSpec: @unchecked Sendable {
    struct Cell {
        let range: NSRange
        let row: Int
        let column: Int
        let header: Bool
        let style: NSParagraphStyle
    }

    let columns: Int
    let indent: CGFloat
    let marginTop: CGFloat
    let theme: Theme
    var cells: [Cell] = []
    var minWidths: [CGFloat]
    var maxWidths: [CGFloat]

    init(columns: Int, indent: CGFloat, marginTop: CGFloat, theme: Theme) {
        self.columns = columns
        self.indent = indent
        self.marginTop = marginTop
        self.theme = theme
        minWidths = Array(repeating: 0, count: columns)
        maxWidths = Array(repeating: 0, count: columns)
    }

    /// min = widest word, max = widest unwrapped cell, both per column.
    func measureContent(in s: NSAttributedString) {
        let ns = s.string as NSString
        for cell in cells {
            var r = NSIntersectionRange(cell.range, NSRange(location: 0, length: s.length))
            while r.length > 0, ns.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
            guard r.length > 0 else { continue }
            let natural = lineWidth(s.attributedSubstring(from: r))
            // Whitespace-separated chunks, not linguistic words: `--flag` must stay whole.
            var widest: CGFloat = 0
            var chunkStart = r.location
            for i in r.location...NSMaxRange(r) {
                let isBreak = i == NSMaxRange(r) || ns.character(at: i) == 32 || ns.character(at: i) == 0x2028
                guard isBreak else { continue }
                if i > chunkStart {
                    let chunk = NSRange(location: chunkStart, length: i - chunkStart)
                    widest = max(widest, lineWidth(s.attributedSubstring(from: chunk)))
                }
                chunkStart = i + 1
            }
            maxWidths[cell.column] = max(maxWidths[cell.column], natural)
            minWidths[cell.column] = max(minWidths[cell.column], min(widest, natural))
        }
    }

    private func lineWidth(_ s: NSAttributedString) -> CGFloat {
        // Slack covers inline code pill insets and rounding.
        ceil(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(s), nil, nil, nil)) + theme.scaled(6)
    }

    /// The CSS auto-table approach: natural widths if they fit, otherwise
    /// start from the minimums and hand out the remaining space in proportion
    /// to how much each column wants to grow.
    func columnWidths(available: CGFloat) -> [CGFloat] {
        let overhead = (theme.tableCellPadH * 2 + 1) * CGFloat(columns) + 1
        let space = available - indent - overhead
        let maxTotal = maxWidths.reduce(0, +)
        if maxTotal <= space { return maxWidths }
        let minTotal = minWidths.reduce(0, +)
        if minTotal >= space { return minWidths }
        let extra = space - minTotal
        let growth = maxTotal - minTotal
        return (0..<columns).map { c in
            floor(minWidths[c] + (maxWidths[c] - minWidths[c]) * extra / growth)
        }
    }

    func apply(to s: NSMutableAttributedString, width: CGFloat) {
        let widths = columnWidths(available: width)
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
        table.setWidth(marginTop, type: .absoluteValueType, for: .margin, edge: .minY)
        for cell in cells {
            let block = NSTextTableBlock(
                table: table, startingRow: cell.row, rowSpan: 1, startingColumn: cell.column, columnSpan: 1)
            block.setValue(widths[cell.column], type: .absoluteValueType, for: .width)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setBorderColor(Theme.tableBorder)
            block.setWidth(theme.tableCellPadV, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(theme.tableCellPadV, type: .absoluteValueType, for: .padding, edge: .maxY)
            block.setWidth(theme.tableCellPadH, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(theme.tableCellPadH, type: .absoluteValueType, for: .padding, edge: .maxX)
            if cell.header { block.backgroundColor = Theme.tableHeaderBackground }
            let p = cell.style.mutableCopy() as! NSMutableParagraphStyle
            p.textBlocks = [block]
            let r = NSIntersectionRange(cell.range, NSRange(location: 0, length: s.length))
            if r.length > 0 { s.addAttribute(.paragraphStyle, value: p, range: r) }
        }
    }
}

enum MarkdownRenderer {
    static func render(_ markdown: String, theme: Theme, color: NSColor = .labelColor) -> RenderedText {
        autoreleasepool {
            let builder = MarkdownBuilder(color: color, theme: theme)
            builder.build(markdown)
            return builder.finish()
        }
    }

    /// Applies the plain-text length cap and drops trailing newlines.
    static func clipped(_ text: String, theme: Theme) -> String {
        var text = text
        if text.utf16.count > theme.maxPlainLength {
            let cut = text.utf16.count - theme.maxPlainLength
            text = String(text.prefix(theme.maxPlainLength)) + "\n… (\(cut) more characters)"
        }
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// The text a markdown source reads as, without any markup (`> hi **you**` → `hi you`),
    /// on one line. Only a leading part of the source is parsed: callers want a snippet.
    static func plainText(_ markdown: String, parsing limit: Int = 1000) -> String {
        _ = registerExtensions
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return markdown }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
        var source = String(markdown.prefix(limit))
        source.withUTF8 { buf in
            buf.withMemoryRebound(to: CChar.self) { cmark_parser_feed(parser, $0.baseAddress, $0.count) }
        }
        guard let doc = cmark_parser_finish(parser) else { return markdown }
        defer { cmark_node_free(doc) }
        var out = ""
        collectPlainText(doc, into: &out)
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func collectPlainText(_ node: CMNode, into out: inout String) {
        let type = cmark_node_get_type(node)
        switch type {
        case CMARK_NODE_TEXT, CMARK_NODE_CODE, CMARK_NODE_HTML_INLINE, CMARK_NODE_CODE_BLOCK, CMARK_NODE_HTML_BLOCK:
            if let literal = cmark_node_get_literal(node) { out += String(cString: literal) }
        case CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK:
            out += " "
        default:
            var child = cmark_node_first_child(node)
            while let n = child {
                collectPlainText(n, into: &out)
                child = cmark_node_next(n)
            }
        }
        let inline: [cmark_node_type] = [
            CMARK_NODE_TEXT, CMARK_NODE_CODE, CMARK_NODE_HTML_INLINE, CMARK_NODE_EMPH, CMARK_NODE_STRONG,
            CMARK_NODE_LINK, CMARK_NODE_IMAGE, CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK,
        ]
        let name = cmark_node_get_type_string(node).map { String(cString: $0) }
        if !inline.contains(type), name != "strikethrough" { out += " " }
    }

    static func plain(_ text: String, theme: Theme, mono: Bool = true, color: NSColor = .labelColor) -> RenderedText {
        let text = clipped(text, theme: theme)
        let p = NSMutableParagraphStyle()
        p.lineSpacing = mono ? theme.monoLineSpacing : theme.lineSpacing
        p.lineBreakMode = mono ? .byCharWrapping : .byWordWrapping
        let font =
            mono
            ? FontCache.shared.font(size: theme.codeFontSize, mono: true)
            : FontCache.shared.font(size: theme.fontSize)
        let s = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        return RenderedText(string: s, topInset: 0, bottomInset: 0)
    }
}

private typealias CMNode = UnsafeMutablePointer<cmark_node>

private let registerExtensions: Void = cmark_gfm_core_extensions_ensure_registered()

/// Per-render front for `FontCache`, so concurrent renders don't fight over its lock.
private final class LocalFonts {
    private var cache: [FontCache.Key: NSFont] = [:]
    private let theme: Theme
    init(theme: Theme) { self.theme = theme }
    lazy var digits = NSFont.monospacedDigitSystemFont(ofSize: theme.fontSize, weight: .regular)
    lazy var digitAdvance: CGFloat = digits.advancement(forGlyph: digits.glyph(withName: "zero")).width

    func font(size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false, heading: Bool = false)
        -> NSFont
    {
        let key = FontCache.Key(size: size, bold: bold, italic: italic, mono: mono, heading: heading)
        if let f = cache[key] { return f }
        let f = FontCache.shared.font(size: size, bold: bold, italic: italic, mono: mono, heading: heading)
        cache[key] = f
        return f
    }
}

/// Builds plain text plus attribute runs, and only creates the attributed
/// string at the end. Every `NSAttributedString` attribute mutation uniques
/// its dictionary through a global lock-protected table, so building
/// incrementally was both slow and impossible to parallelize.
private final class MarkdownBuilder {
    struct BlockContext {
        var indent: CGFloat = 0
        var quotes: [QuoteMarker] = []
        var tight = false
        var listDepth = 0
        var color: NSColor
    }

    struct InlineState {
        var size: CGFloat
        var color: NSColor
        var bold = false
        var italic = false
        var strike = false
        var heading = false
        var mono = false
        var inlineCode = false
        var link: URL?
    }

    struct StyleKey: Hashable {
        let size: CGFloat
        let color: ObjectIdentifier
        let bold, italic, strike, heading, mono, inlineCode: Bool
        let link: URL?
    }

    struct PendingMarker {
        let text: String
        let column: CGFloat
        let contentIndent: CGFloat
        let color: NSColor
        let font: NSFont
    }

    struct Run {
        var end: Int
        let style: Int
    }

    struct Paragraph {
        let start: Int
        let end: Int
        var style: NSParagraphStyle
        let quotes: [QuoteMarker]
        let code: CodeBlockMarker?
        let extraAfter: CGFloat
        var isTableCell = false
    }

    let theme: Theme
    let fonts: LocalFonts
    let baseColor: NSColor

    var text = ""
    var length = 0
    var runs: [Run] = []
    var styles: [[NSAttributedString.Key: Any]] = []
    var styleIndex: [StyleKey: Int] = [:]
    var paragraphs: [Paragraph] = []
    var runBreak = true
    var lastStyle = 0

    var pendingMarker: PendingMarker?
    var topInset: CGFloat = 0
    /// Spacing owed after a table. Paragraph spacing on a cell would grow the
    /// cell itself, so it's moved onto whatever comes next.
    var pendingBefore: CGFloat = 0
    var tables: [TableSpec] = []

    init(color: NSColor, theme: Theme) {
        baseColor = color
        self.theme = theme
        fonts = LocalFonts(theme: theme)
    }

    func build(_ markdown: String) {
        _ = registerExtensions
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
        // TextKit treats a lone CR as a paragraph break; keep line endings uniform.
        var markdown = markdown.contains("\r") ? markdown.replacingOccurrences(of: "\r\n", with: "\n") : markdown
        markdown.withUTF8 { buf in
            buf.withMemoryRebound(to: CChar.self) { cmark_parser_feed(parser, $0.baseAddress, $0.count) }
        }
        guard let doc = cmark_parser_finish(parser) else { return }
        defer { cmark_node_free(doc) }
        renderChildren(of: doc, BlockContext(color: baseColor))
    }

    func finish() -> RenderedText {
        if text.hasSuffix("\n"), let lastPara = paragraphs.last, var lastRun = runs.last {
            text.removeLast()
            length -= 1
            lastRun.end -= 1
            runs[runs.count - 1] = lastRun
            if lastRun.end <= (runs.count > 1 ? runs[runs.count - 2].end : 0) { runs.removeLast() }
            paragraphs[paragraphs.count - 1] = Paragraph(
                start: lastPara.start, end: lastPara.end - 1, style: lastPara.style, quotes: lastPara.quotes,
                code: lastPara.code, extraAfter: lastPara.extraAfter, isTableCell: lastPara.isTableCell)
        }
        let out = NSMutableAttributedString(string: text)
        out.beginEditing()
        var start = 0
        var pi = 0
        for run in runs {
            while pi < paragraphs.count - 1, paragraphs[pi].end <= start { pi += 1 }
            var attrs = styles[run.style]
            if pi < paragraphs.count {
                let p = paragraphs[pi]
                attrs[.paragraphStyle] = p.style
                if !p.quotes.isEmpty { attrs[MDAttr.quote] = p.quotes }
                if let code = p.code { attrs[MDAttr.codeBlock] = code }
            }
            out.setAttributes(attrs, range: NSRange(location: start, length: run.end - start))
            start = run.end
        }
        addInlineCodeGaps(out)
        out.endEditing()
        for t in tables { t.measureContent(in: out) }
        return RenderedText(
            string: out, topInset: topInset, bottomInset: paragraphs.last?.extraAfter ?? 0, tables: tables)
    }

    /// Kerning (not real spaces, so copied text stays intact) around inline
    /// code, so the pill doesn't crowd its neighbours. `.kern` adds space
    /// after a glyph: the leading gap goes on the preceding character, the
    /// trailing gap on the span's last character.
    func addInlineCodeGaps(_ s: NSMutableAttributedString) {
        let ns = s.string as NSString
        // Full gap next to whitespace; punctuation only needs room for the pill's inset.
        func gap(_ neighbour: unichar) -> CGFloat { neighbour == 32 ? theme.inlineCodeGap : theme.inlineCodeGap / 2 }
        func isLineBreak(_ c: unichar) -> Bool { c == 10 || c == 0x2028 || c == 9 }
        var spans: [NSRange] = []
        s.enumerateAttribute(MDAttr.inlineCode, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if v != nil { spans.append(r) }
        }
        for r in spans {
            if r.location > 0 {
                let c = ns.character(at: r.location - 1)
                if !isLineBreak(c) {
                    s.addAttribute(.kern, value: gap(c), range: NSRange(location: r.location - 1, length: 1))
                }
            }
            let end = NSMaxRange(r)
            if end < s.length, !isLineBreak(ns.character(at: end)) {
                s.addAttribute(.kern, value: gap(ns.character(at: end)), range: NSRange(location: end - 1, length: 1))
            }
        }
    }

    // MARK: Text & styles

    func style(_ st: InlineState) -> Int {
        let key = StyleKey(
            size: st.size, color: ObjectIdentifier(st.color), bold: st.bold, italic: st.italic, strike: st.strike,
            heading: st.heading, mono: st.mono, inlineCode: st.inlineCode, link: st.link)
        if let i = styleIndex[key] { return i }
        var a: [NSAttributedString.Key: Any] = [
            .font: fonts.font(size: st.size, bold: st.bold, italic: st.italic, mono: st.mono, heading: st.heading),
            .foregroundColor: st.color,
        ]
        if let link = st.link { a[.link] = link }
        if st.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if st.inlineCode { a[MDAttr.inlineCode] = InlineCodeMarker.shared }
        styles.append(a)
        styleIndex[key] = styles.count - 1
        return styles.count - 1
    }

    /// The paragraph terminator keeps the last font (it affects line height)
    /// but must not carry decorations like inline code boxes or links.
    var newlineStyles: [Int: Int] = [:]
    func newlineStyle(after style: Int) -> Int {
        let a = styles[style]
        guard a[MDAttr.inlineCode] != nil || a[.link] != nil || a[.strikethroughStyle] != nil || a[MDAttr.rule] != nil
        else { return style }
        if let s = newlineStyles[style] { return s }
        var plain: [NSAttributedString.Key: Any] = [:]
        plain[.font] = a[.font]
        plain[.foregroundColor] = a[.foregroundColor]
        let s = uniqueStyle(plain)
        newlineStyles[style] = s
        return s
    }

    /// For one-off attributes (e.g. rule markers) that must never be merged.
    func uniqueStyle(_ attrs: [NSAttributedString.Key: Any]) -> Int {
        styles.append(attrs)
        return styles.count - 1
    }

    func append(_ s: String, _ style: Int) {
        guard !s.isEmpty else { return }
        text += s
        length += s.utf16.count
        if !runBreak, let last = runs.last, last.style == style {
            runs[runs.count - 1].end = length
        } else {
            runs.append(Run(end: length, style: style))
        }
        runBreak = false
        lastStyle = style
    }

    // MARK: Blocks

    func renderChildren(of parent: CMNode, _ ctx: BlockContext) {
        var child = cmark_node_first_child(parent)
        var first = true
        while let node = child {
            if !first { setSpacingAfterLast(ctx.tight ? theme.tightSpacing : theme.blockSpacing) }
            renderBlock(node, ctx)
            first = false
            child = cmark_node_next(node)
        }
    }

    func renderBlock(_ node: CMNode, _ ctx: BlockContext) {
        switch cmark_node_get_type(node) {
        case CMARK_NODE_PARAGRAPH:
            let start = length
            let style = paragraphStyle(ctx)
            consumeMarker(style)
            renderInlines(node, InlineState(size: theme.fontSize, color: ctx.color))
            endParagraph(start: start, style: style, ctx)

        case CMARK_NODE_HEADING:
            let level = Int(cmark_node_get_heading_level(node))
            let start = length
            let style = paragraphStyle(ctx, before: start > 0 ? theme.headingTopExtra : 0)
            consumeMarker(style)
            var st = InlineState(size: theme.headingSize(level), color: level >= 6 ? .secondaryLabelColor : ctx.color)
            st.heading = true
            renderInlines(node, st)
            endParagraph(start: start, style: style, ctx)

        case CMARK_NODE_BLOCK_QUOTE:
            flushMarker(ctx)
            let marker = QuoteMarker(x: ctx.indent)
            var c = ctx
            c.indent += theme.quoteIndent
            c.quotes.append(marker)
            c.tight = false
            c.color = .secondaryLabelColor
            let start = length
            renderChildren(of: node, c)
            marker.range = NSRange(location: start, length: length - start)

        case CMARK_NODE_LIST:
            renderList(node, ctx)

        case CMARK_NODE_CODE_BLOCK:
            var code = literal(node)
            if code.hasSuffix("\n") { code.removeLast() }
            let info = cmark_node_get_fence_info(node).map { String(cString: $0) } ?? ""
            let lang = info.split(separator: " ").first.map(String.init)
            let st = monoState(ctx)
            emitCodeBlock(language: lang?.isEmpty == false ? lang : nil, ctx) { self.append(code, self.style(st)) }

        case CMARK_NODE_HTML_BLOCK:
            var html = literal(node)
            while html.hasSuffix("\n") { html.removeLast() }
            let st = monoState(ctx)
            emitCodeBlock(language: "html", ctx) { self.append(html, self.style(st)) }

        case CMARK_NODE_THEMATIC_BREAK:
            flushMarker(ctx)
            let start = length
            let style = paragraphStyle(ctx, lineSpacing: 0)
            append(
                " ",
                uniqueStyle([.font: fonts.font(size: theme.fontSize), MDAttr.rule: RuleMarker(indent: ctx.indent)]))
            endParagraph(start: start, style: style, ctx)

        default:
            if typeString(node) == "table" {
                renderTable(node, ctx)
            } else {
                renderChildren(of: node, ctx)
            }
        }
    }

    func monoState(_ ctx: BlockContext) -> InlineState {
        var st = InlineState(size: theme.codeFontSize, color: ctx.color)
        st.mono = true
        return st
    }

    func renderList(_ node: CMNode, _ ctx: BlockContext) {
        flushMarker(ctx)
        let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
        let tight = cmark_node_get_list_tight(node) != 0
        let startNumber = Int(cmark_node_get_list_start(node))
        var count = 0
        var it = cmark_node_first_child(node)
        while let n = it {
            count += 1
            it = cmark_node_next(n)
        }

        let markerFont = ordered ? fonts.digits : fonts.font(size: theme.fontSize)
        var markerWidth = theme.bulletWidth
        if ordered {
            // Digits are tabular, so width is digit count × advance, no text layout needed.
            let digits = String(startNumber + max(count - 1, 0)).count
            markerWidth = max(
                markerWidth, ceil(fonts.digitAdvance * CGFloat(digits + 1)) + theme.markerGap + theme.scaled(2))
        }

        let bullets = ["•", "◦", "▪"]
        var item = cmark_node_first_child(node)
        var index = 0
        while let n = item {
            if index > 0 { setSpacingAfterLast(tight ? theme.tightSpacing : theme.blockSpacing) }
            var label: String
            var color = ctx.color
            if typeString(n) == "tasklist" {
                label = cmark_gfm_extensions_get_tasklist_item_checked(n) ? "☑" : "☐"
            } else if ordered {
                label = "\(startNumber + index)."
            } else {
                label = bullets[ctx.listDepth % bullets.count]
                color = .secondaryLabelColor
            }
            var c = ctx
            c.indent = ctx.indent + markerWidth
            c.tight = tight
            c.listDepth += 1
            pendingMarker = PendingMarker(
                text: label, column: ctx.indent, contentIndent: c.indent, color: color, font: markerFont)
            renderChildren(of: n, c)
            flushMarker(c)
            item = cmark_node_next(n)
            index += 1
        }
    }

    /// GFM tables use TextKit 1's native `NSTextTable`: every cell is a
    /// paragraph whose style carries an `NSTextTableBlock`, so tables live in
    /// the same text view and get selection/measurement for free. Columns are
    /// sized automatically and wrap when the table doesn't fit.
    func renderTable(_ node: CMNode, _ ctx: BlockContext) {
        flushMarker(ctx)
        let ncols = Int(cmark_gfm_extensions_get_table_columns(node))
        guard ncols > 0 else { return }
        var aligns = [UInt8](repeating: 0, count: ncols)
        if let a = cmark_gfm_extensions_get_table_alignments(node) {
            for i in 0..<ncols { aligns[i] = a[i] }
        }
        let spec = TableSpec(columns: ncols, indent: ctx.indent, marginTop: pendingBefore, theme: theme)
        pendingBefore = 0
        tables.append(spec)

        var rowIndex = 0
        var row = cmark_node_first_child(node)
        while let r = row {
            let header = cmark_gfm_extensions_get_table_row_is_header(r) != 0
            var cell = cmark_node_first_child(r)
            for col in 0..<ncols {
                let p = NSMutableParagraphStyle()
                p.lineSpacing = theme.tableLineSpacing
                switch aligns[col] {
                case UInt8(ascii: "r"): p.alignment = .right
                case UInt8(ascii: "c"): p.alignment = .center
                default: p.alignment = .natural
                }

                var st = InlineState(size: theme.fontSize, color: ctx.color)
                st.bold = header
                let start = length
                if let c = cell {
                    renderInlines(c, st)
                    cell = cmark_node_next(c)
                }
                if length == start { lastStyle = style(st) }
                endParagraph(start: start, style: p, ctx, tableCell: true)
                spec.cells.append(
                    .init(
                        range: NSRange(location: start, length: length - start), row: rowIndex, column: col,
                        header: header, style: p))
            }
            rowIndex += 1
            row = cmark_node_next(r)
        }
    }

    /// The whole block is a single paragraph with U+2028 line separators, so
    /// its padding maps onto paragraph spacing and drawing needs one range.
    /// `content` must use U+2028 instead of newlines.
    func emitCodeBlock(language: String?, _ ctx: BlockContext, content: () -> Void) {
        flushMarker(ctx)
        let marker = CodeBlockMarker(indent: ctx.indent, language: language)
        let label = language != nil ? theme.codeLabelHeight : 0
        var inner = ctx
        inner.indent += theme.codePadH
        let pstyle = paragraphStyle(inner, before: theme.codePadV + label, lineSpacing: theme.codeLineSpacing)
        pstyle.tailIndent = -theme.codePadH
        pstyle.paragraphSpacing = theme.codePadV
        pstyle.lineBreakMode = .byCharWrapping

        let start = length
        let textStart = text.endIndex
        content()
        if length == start {
            append(" ", style(monoState(ctx)))
        } else {
            text.replaceSubrange(
                textStart..<text.endIndex,
                with: text[textStart...].replacingOccurrences(of: "\n", with: "\u{2028}"))
        }
        marker.range = NSRange(location: start, length: length - start)
        endParagraph(start: start, style: pstyle, ctx, code: marker, extraAfter: theme.codePadV)
    }

    // MARK: Paragraph plumbing

    func paragraphStyle(_ ctx: BlockContext, before: CGFloat = 0, lineSpacing: CGFloat? = nil)
        -> NSMutableParagraphStyle
    {
        let p = NSMutableParagraphStyle()
        p.headIndent = ctx.indent
        p.firstLineHeadIndent = ctx.indent
        p.lineSpacing = lineSpacing ?? theme.lineSpacing
        p.paragraphSpacingBefore = before + pendingBefore
        pendingBefore = 0
        p.defaultTabInterval = theme.tabInterval
        p.tabStops = []
        return p
    }

    func consumeMarker(_ pstyle: NSMutableParagraphStyle) {
        guard let m = pendingMarker else { return }
        pendingMarker = nil
        pstyle.firstLineHeadIndent = m.column
        pstyle.tabStops = [
            NSTextTab(textAlignment: .right, location: m.contentIndent - theme.markerGap),
            NSTextTab(textAlignment: .left, location: m.contentIndent),
        ]
        let key = StyleKey(
            size: -1, color: ObjectIdentifier(m.font), bold: false, italic: false, strike: false, heading: false,
            mono: false, inlineCode: false, link: nil)
        let idx: Int
        if let i = styleIndex[key], (styles[i][.foregroundColor] as? NSColor) === m.color {
            idx = i
        } else {
            idx = uniqueStyle([.font: m.font, .foregroundColor: m.color])
            styleIndex[key] = idx
        }
        append("\t\(m.text)\t", idx)
    }

    /// List items whose first child isn't a paragraph get their marker on a line of its own.
    func flushMarker(_ ctx: BlockContext) {
        guard pendingMarker != nil else { return }
        let start = length
        let pstyle = paragraphStyle(ctx)
        consumeMarker(pstyle)
        endParagraph(start: start, style: pstyle, ctx)
    }

    func endParagraph(
        start: Int, style: NSParagraphStyle, _ ctx: BlockContext, code: CodeBlockMarker? = nil, extraAfter: CGFloat = 0,
        tableCell: Bool = false
    ) {
        if styles.isEmpty { lastStyle = self.style(InlineState(size: theme.fontSize, color: ctx.color)) }
        append("\n", newlineStyle(after: lastStyle))
        paragraphs.append(
            Paragraph(
                start: start, end: length, style: style, quotes: ctx.quotes, code: code, extraAfter: extraAfter,
                isTableCell: tableCell))
        if start == 0 { topInset = style.paragraphSpacingBefore }
        runBreak = true
    }

    /// Spacing between siblings is decided when the next sibling starts, by
    /// the innermost container that holds both.
    func setSpacingAfterLast(_ spacing: CGFloat) {
        guard var last = paragraphs.last else { return }
        if last.isTableCell {
            pendingBefore = spacing
            return
        }
        let s = last.style.mutableCopy() as! NSMutableParagraphStyle
        s.paragraphSpacing = last.extraAfter + spacing
        last.style = s
        paragraphs[paragraphs.count - 1] = last
    }

    // MARK: Inlines

    func renderInlines(_ parent: CMNode, _ st: InlineState) {
        var child = cmark_node_first_child(parent)
        while let node = child {
            switch cmark_node_get_type(node) {
            case CMARK_NODE_TEXT, CMARK_NODE_HTML_INLINE:
                append(literal(node), style(st))
            case CMARK_NODE_SOFTBREAK:
                append(" ", style(st))
            case CMARK_NODE_LINEBREAK:
                append("\u{2028}", style(st))
            case CMARK_NODE_CODE:
                var s = st
                s.size = round(st.size * 0.92)
                s.bold = st.bold || st.heading
                s.heading = false
                s.italic = false
                s.mono = true
                s.inlineCode = true
                append(literal(node), style(s))
            case CMARK_NODE_EMPH:
                var s = st
                s.italic = true
                renderInlines(node, s)
            case CMARK_NODE_STRONG:
                var s = st
                s.bold = true
                renderInlines(node, s)
            case CMARK_NODE_LINK:
                var s = st
                s.link = url(node)
                renderInlines(node, s)
            case CMARK_NODE_IMAGE:
                var s = st
                s.link = url(node)
                let alt = plainText(node)
                let src = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
                append(alt.isEmpty ? src : alt, style(s))
            default:
                var s = st
                if typeString(node) == "strikethrough" { s.strike = true }
                renderInlines(node, s)
            }
            child = cmark_node_next(node)
        }
    }

    // MARK: Node helpers

    func literal(_ node: CMNode) -> String {
        cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
    }

    func url(_ node: CMNode) -> URL? {
        guard let raw = cmark_node_get_url(node) else { return nil }
        return URL(string: String(cString: raw))
    }

    func typeString(_ node: CMNode) -> String {
        cmark_node_get_type_string(node).map { String(cString: $0) } ?? ""
    }

    func plainText(_ node: CMNode) -> String {
        var s = ""
        var child = cmark_node_first_child(node)
        while let n = child {
            switch cmark_node_get_type(n) {
            case CMARK_NODE_TEXT, CMARK_NODE_CODE, CMARK_NODE_HTML_INLINE: s += literal(n)
            case CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK: s += " "
            default: s += plainText(n)
            }
            child = cmark_node_next(n)
        }
        return s
    }
}
