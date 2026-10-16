import AppKit

/// TextKit 1 is used on purpose: every message is a small, independent text
/// view, so TextKit 2's viewport laziness buys nothing, while TK1 measurement
/// is fast, deterministic and safe on background threads (one stack per call).
enum TextMeasurer {
    private final class Stack {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        init() {
            container.lineFragmentPadding = 0
            lm.addTextContainer(container)
            storage.addLayoutManager(lm)
        }
    }

    /// One reusable stack per thread: building a fresh TextKit stack per
    /// measurement costs more than the layout itself for short messages.
    private static var stack: Stack {
        let key = "ChatRenderer.TextMeasurer"
        if let s = Thread.current.threadDictionary[key] as? Stack { return s }
        let s = Stack()
        Thread.current.threadDictionary[key] = s
        return s
    }

    static func height(of string: NSAttributedString, width: CGFloat) -> CGFloat {
        autoreleasepool {
            let s = stack
            s.container.size = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
            s.storage.setAttributedString(string)
            s.lm.ensureLayout(for: s.container)
            let h = ceil(s.lm.usedRect(for: s.container).height)
            s.storage.setAttributedString(NSAttributedString())
            return h
        }
    }
}

final class MarkdownLayoutManager: NSLayoutManager {
    var theme = Theme()

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first, storage.length > 0 {
            let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            drawCodeBlocks(storage, container, chars, origin)
            drawInlineCode(storage, container, chars, origin)
            drawQuotes(storage, chars, origin)
            drawRules(storage, container, chars, origin)
        }
        // Selection highlight is drawn by super, so it must come after our fills.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Vertical extent of a character range's lines, excluding paragraph
    /// spacing and the trailing line spacing TK1 folds into used rects.
    private func verticalExtent(of range: NSRange, in storage: NSTextStorage) -> (top: CGFloat, bottom: CGFloat)? {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return nil }
        let firstGlyph = glyphIndexForCharacter(at: range.location)
        let lastGlyph = glyphIndexForCharacter(at: NSMaxRange(range) - 1)
        let first = lineFragmentUsedRect(forGlyphAt: firstGlyph, effectiveRange: nil)
        var lineRange = NSRange()
        let last = lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: &lineRange)
        var bottom = last.maxY
        if NSMaxRange(lineRange) < numberOfGlyphs,
            let p = storage.attribute(.paragraphStyle, at: NSMaxRange(range) - 1, effectiveRange: nil)
                as? NSParagraphStyle
        {
            bottom -= p.lineSpacing
        }
        return (first.minY, bottom)
    }

    private func drawCodeBlocks(
        _ storage: NSTextStorage, _ container: NSTextContainer, _ chars: NSRange, _ origin: NSPoint
    ) {
        storage.enumerateAttribute(MDAttr.codeBlock, in: chars) { value, _, _ in
            guard let m = value as? CodeBlockMarker, let ext = verticalExtent(of: m.range, in: storage) else { return }
            let label = m.language != nil ? theme.codeLabelHeight : 0
            let rect = NSRect(
                x: origin.x + m.indent, y: origin.y + ext.top - theme.codePadV - label,
                width: container.size.width - m.indent,
                height: ext.bottom - ext.top + theme.codePadV * 2 + label)
            let path = NSBezierPath(roundedRect: rect, xRadius: theme.codeCornerRadius, yRadius: theme.codeCornerRadius)
            Theme.codeBackground.setFill()
            path.fill()
            Theme.codeBorder.setStroke()
            path.lineWidth = 1
            NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: theme.codeCornerRadius,
                yRadius: theme.codeCornerRadius
            ).stroke()
            if let lang = m.language {
                (lang as NSString).draw(
                    at: NSPoint(x: rect.minX + theme.codePadH, y: rect.minY + theme.scaled(6)),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: theme.codeLabelFontSize, weight: .medium),
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ])
            }
        }
    }

    private func drawInlineCode(
        _ storage: NSTextStorage, _ container: NSTextContainer, _ chars: NSRange, _ origin: NSPoint
    ) {
        Theme.inlineCodeBackground.setFill()
        storage.enumerateAttribute(MDAttr.inlineCode, in: chars) { value, range, _ in
            guard value != nil else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
                let sub = NSIntersectionRange(glyphs, lineGlyphs)
                guard sub.length > 0 else { return }
                var r = self.boundingRect(forGlyphRange: sub, in: container)
                // The trailing gap is kerning on the last code glyph; keep it outside the pill.
                if NSMaxRange(sub) == NSMaxRange(glyphs) {
                    r.size.width -=
                        (storage.attribute(.kern, at: NSMaxRange(range) - 1, effectiveRange: nil) as? CGFloat) ?? 0
                }
                if let font {
                    let baseline = lineRect.minY + self.location(forGlyphAt: sub.location).y
                    r.origin.y = baseline - font.ascender - self.theme.scaled(1.5)
                    r.size.height = font.ascender - font.descender + self.theme.scaled(3)
                }
                r = r.insetBy(dx: -self.theme.scaled(2.5), dy: 0).offsetBy(dx: origin.x, dy: origin.y)
                let radius = self.theme.scaled(3.5)
                NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            }
        }
    }

    private func drawQuotes(_ storage: NSTextStorage, _ chars: NSRange, _ origin: NSPoint) {
        var seen = Set<ObjectIdentifier>()
        NSColor.quaternaryLabelColor.setFill()
        storage.enumerateAttribute(MDAttr.quote, in: chars) { value, _, _ in
            guard let markers = value as? [QuoteMarker] else { return }
            for m in markers where seen.insert(ObjectIdentifier(m)).inserted {
                guard let ext = verticalExtent(of: m.range, in: storage) else { continue }
                NSBezierPath(
                    roundedRect: NSRect(
                        x: origin.x + m.x + 1, y: origin.y + ext.top, width: theme.quoteBarWidth,
                        height: ext.bottom - ext.top),
                    xRadius: theme.quoteBarWidth / 2, yRadius: theme.quoteBarWidth / 2
                ).fill()
            }
        }
    }

    private func drawRules(_ storage: NSTextStorage, _ container: NSTextContainer, _ chars: NSRange, _ origin: NSPoint)
    {
        NSColor.separatorColor.setFill()
        storage.enumerateAttribute(MDAttr.rule, in: chars) { value, range, _ in
            guard let m = value as? RuleMarker else { return }
            let used = lineFragmentUsedRect(forGlyphAt: glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            NSRect(
                x: origin.x + m.indent, y: origin.y + floor(used.midY), width: container.size.width - m.indent,
                height: 1
            ).fill()
        }
    }
}

/// Read-only, selectable text view for one rendered block.
final class MarkdownTextView: NSTextView {
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { needsDisplay = true } }
    }

    var theme = Theme() {
        didSet {
            guard theme != oldValue else { return }
            (layoutManager as? MarkdownLayoutManager)?.theme = theme
            needsDisplay = true
        }
    }

    convenience init() {
        let storage = NSTextStorage()
        let lm = MarkdownLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        lm.addTextContainer(container)
        self.init(frame: NSRect(x: 0, y: 0, width: 100, height: 20), textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = true
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        autoresizingMask = []
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        usesFindBar = false
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: 0, y: topInset) }

    private weak var renderedSource: NSAttributedString?

    /// `width` must be the width the text was measured at (tables depend on it).
    func setRenderedIfNeeded(_ text: RenderedText, width: CGFloat) {
        let string = text.string(forWidth: width)
        guard renderedSource !== string else { return }
        renderedSource = string
        topInset = text.topInset
        textStorage?.setAttributedString(string)
    }

    /// Only web and mail links leave the app; anything else (relative or
    /// custom-scheme URLs a model may produce) is ignored.
    nonisolated static func canOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url, Self.canOpen(url) else { return }
        NSWorkspace.shared.open(url)
    }

    override func resignFirstResponder() -> Bool {
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        return super.resignFirstResponder()
    }

    // Code blocks and hard breaks use U+2028 internally; copy real newlines.
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else {
            return super.writeSelection(to: pboard, type: type)
        }
        let text = selectedRanges.map { storage.attributedSubstring(from: $0.rangeValue).string }.joined(
            separator: "\n")
        return pboard.setString(text.replacingOccurrences(of: "\u{2028}", with: "\n"), forType: .string)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
