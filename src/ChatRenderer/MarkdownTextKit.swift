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

    /// Strings at least this long are measured on a stack that keeps its text between calls.
    static let growingThreshold = 2000

    /// A stack for one growing text, only used on the main thread, where a streaming message
    /// is measured again with every flush. It keeps the text it laid out last and, when the next
    /// one starts with the same blocks, replaces only the tail: TextKit then lays out just that,
    /// instead of the whole message, which is what made every flush slower the longer the reply got.
    private final class Growing {
        let stack = Stack()
        var blocks: [TextBlock] = []
        var width: CGFloat = -1
        var lastKept = 0

        /// How much of what this stack holds the string can build on.
        func reusable(for string: NSAttributedString, width: CGFloat, blocks: [TextBlock]) -> Int {
            guard width == self.width else { return 0 }
            let shared = StableText.sharedPrefix(stack.storage.string as NSString, string.string as NSString)
            return StableText.keptLength(old: self.blocks, new: blocks, shared: shared)
        }

        func height(of string: NSAttributedString, width: CGFloat, blocks: [TextBlock]) -> CGFloat {
            let storage = stack.storage
            let kept = reusable(for: string, width: width, blocks: blocks)
            let target = max(width, 1)
            if stack.container.size.width != target {
                stack.container.size = NSSize(width: target, height: .greatestFiniteMagnitude)
            }
            if kept > 0 {
                let tail = NSRange(location: kept, length: string.length - kept)
                storage.replaceCharacters(
                    in: NSRange(location: kept, length: storage.length - kept),
                    with: string.attributedSubstring(from: tail))
            } else {
                storage.setAttributedString(string)
            }
            self.blocks = blocks
            self.width = width
            lastKept = kept
            stack.lm.ensureLayout(for: stack.container)
            return ceil(stack.lm.usedRect(for: stack.container).height)
        }
    }

    /// A few, least recently used first: a row can measure more than one long text per flush
    /// (say an open thinking block and the reply), and those must not evict each other.
    nonisolated(unsafe) private static var growing: [Growing] = []
    private static let growingSlots = 3

    /// How many leading characters the last growing-text measurement kept from the one before.
    static var lastKeptLength: Int { growing.last?.lastKept ?? 0 }

    /// `blocks` (from the `RenderedText` the string belongs to) tells a long string's measurement
    /// which part of the previous one it can build on.
    static func height(of string: NSAttributedString, width: CGFloat, blocks: [TextBlock] = []) -> CGFloat {
        if !blocks.isEmpty, string.length >= growingThreshold, Thread.isMainThread {
            return autoreleasepool {
                var best: (index: Int, kept: Int)?
                for (i, g) in growing.enumerated() {
                    let kept = g.reusable(for: string, width: width, blocks: blocks)
                    if kept > (best?.kept ?? 0) { best = (i, kept) }
                }
                let g: Growing
                if let best {
                    g = growing.remove(at: best.index)
                } else if growing.count >= growingSlots {
                    g = growing.removeFirst()
                } else {
                    g = Growing()
                }
                growing.append(g)
                return g.height(of: string, width: width, blocks: blocks)
            }
        }
        return autoreleasepool {
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
    var search: SearchHighlight?
    /// Sorted and non-overlapping.
    var fades: [TextFade] = []

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !fades.isEmpty, let storage = textStorage, let context = NSGraphicsContext.current?.cgContext else {
            return super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        }
        let now = CACurrentMediaTime()
        let all = NSRange(location: 0, length: storage.length)
        var cursor = glyphsToShow.location
        for fade in fades {
            let chars = NSIntersectionRange(fade.range, all)
            guard chars.length > 0 else { continue }
            let glyphs = NSIntersectionRange(
                glyphRange(forCharacterRange: chars, actualCharacterRange: nil), glyphsToShow)
            guard glyphs.length > 0 else { continue }
            if glyphs.location > cursor {
                super.drawGlyphs(
                    forGlyphRange: NSRange(location: cursor, length: glyphs.location - cursor), at: origin)
            }
            context.saveGState()
            context.setAlpha(fade.alpha(at: now))
            super.drawGlyphs(forGlyphRange: glyphs, at: origin)
            context.restoreGState()
            cursor = NSMaxRange(glyphs)
        }
        if cursor < NSMaxRange(glyphsToShow) {
            super.drawGlyphs(
                forGlyphRange: NSRange(location: cursor, length: NSMaxRange(glyphsToShow) - cursor), at: origin)
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first, storage.length > 0 {
            let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            drawCodeBlocks(storage, container, chars, origin)
            drawInlineCode(storage, container, chars, origin)
            drawQuotes(storage, chars, origin)
            drawRules(storage, container, chars, origin)
            drawSearch(storage, container, chars, origin)
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

    /// The box of a code block (header row included) in text container coordinates.
    func codeBlockRect(_ m: CodeBlockMarker) -> NSRect? {
        guard let storage = textStorage, let container = textContainers.first,
            let ext = verticalExtent(of: m.range, in: storage)
        else { return nil }
        let label = theme.codeLabelHeight
        return NSRect(
            x: m.indent, y: ext.top - theme.codePadV - label, width: container.size.width - m.indent,
            height: ext.bottom - ext.top + theme.codePadV * 2 + label)
    }

    private func drawCodeBlocks(
        _ storage: NSTextStorage, _ container: NSTextContainer, _ chars: NSRange, _ origin: NSPoint
    ) {
        storage.enumerateAttribute(MDAttr.codeBlock, in: chars) { value, _, _ in
            guard let m = value as? CodeBlockMarker, var rect = codeBlockRect(m) else { return }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            let path = NSBezierPath(roundedRect: rect, xRadius: theme.codeCornerRadius, yRadius: theme.codeCornerRadius)
            Theme.codeBackground.setFill()
            path.fill()
            Theme.codeBorder.setStroke()
            path.lineWidth = 1
            NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: theme.codeCornerRadius,
                yRadius: theme.codeCornerRadius
            ).stroke()
            (m.label as NSString).draw(
                at: NSPoint(x: rect.minX + theme.codePadH, y: rect.minY + theme.scaled(6)),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: theme.codeLabelFontSize, weight: .medium),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
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

    /// Painted under the text, so glyph colors (syntax highlighting included) stay readable.
    private func drawSearch(
        _ storage: NSTextStorage, _ container: NSTextContainer, _ chars: NSRange, _ origin: NSPoint
    ) {
        guard let search, !search.ranges.isEmpty else { return }
        let all = NSRange(location: 0, length: storage.length)
        for (i, range) in search.ranges.enumerated() {
            let r = NSIntersectionRange(range, all)
            guard r.length > 0, NSIntersectionRange(r, chars).length > 0 else { continue }
            let isCurrent = search.current == i
            (isCurrent
                ? NSColor.systemOrange.withAlphaComponent(0.75)
                : NSColor.systemYellow.withAlphaComponent(0.4)).setFill()
            let glyphs = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
                let sub = NSIntersectionRange(glyphs, lineGlyphs)
                guard sub.length > 0 else { return }
                var rect = self.boundingRect(forGlyphRange: sub, in: container)
                if let font = storage.attribute(
                    .font, at: self.characterIndexForGlyph(at: sub.location), effectiveRange: nil) as? NSFont
                {
                    let baseline = lineRect.minY + self.location(forGlyphAt: sub.location).y
                    rect.origin.y = baseline - font.ascender
                    rect.size.height = font.ascender - font.descender
                }
                rect = rect.insetBy(dx: -self.theme.scaled(1), dy: -self.theme.scaled(1))
                    .offsetBy(dx: origin.x, dy: origin.y)
                let radius = self.theme.scaled(3)
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
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
            updateCopyButtons()
        }
    }

    var searchHighlight: SearchHighlight? {
        didSet {
            guard searchHighlight != oldValue else { return }
            (layoutManager as? MarkdownLayoutManager)?.search = searchHighlight
            needsDisplay = true
        }
    }

    private var codeBlocks: [CodeBlockMarker] = []
    private var copyButtons: [CodeCopyButton] = []
    private var detectionTask: Task<Void, Never>?

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
    private var renderedBlocks: [TextBlock] = []
    /// How many leading characters the last `setRenderedIfNeeded` left as they were.
    private(set) var lastKeptLength = 0

    /// `width` must be the width the text was measured at (tables depend on it).
    /// With `fadeIn`, the text beyond what the view already showed fades in; pass it
    /// only when the view is continuing the same message, not when it's reused for another.
    ///
    /// A text that continues the one shown (a streaming message) only replaces its tail, from the
    /// start of the first block that differs: the rest keeps its layout, and so do the code
    /// blocks in it, together with the language detection that has already colored them.
    func setRenderedIfNeeded(_ text: RenderedText, width: CGFloat, fadeIn: Bool = false) {
        let string = text.string(forWidth: width)
        guard renderedSource !== string, let storage = textStorage else { return }
        renderedSource = string
        topInset = text.topInset
        let shared = StableText.sharedPrefix(storage.string as NSString, string.string as NSString)
        let kept = StableText.keptLength(old: renderedBlocks, new: text.blocks, shared: shared)
        lastKeptLength = kept
        trackFades(shared: fadeIn ? shared : nil, length: string.length)
        if kept > 0 {
            let tail = NSRange(location: kept, length: string.length - kept)
            storage.replaceCharacters(
                in: NSRange(location: kept, length: storage.length - kept),
                with: string.attributedSubstring(from: tail))
            codeBlocks =
                codeBlocks.filter { NSMaxRange($0.range) <= kept }
                + text.codeBlocks.filter { $0.range.location >= kept }
        } else {
            storage.setAttributedString(string)
            codeBlocks = text.codeBlocks
        }
        renderedBlocks = text.blocks
        detectionTask?.cancel()
        detectionTask = nil
        updateCopyButtons()
        detectLanguages(for: string)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !codeBlocks.isEmpty { updateCopyButtons() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clearFades() }
    }

    // MARK: Fade-in

    private lazy var fadeTicker = FrameTicker { [weak self] _ in self?.advanceFades() ?? false }

    var fadingRanges: [NSRange] { (layoutManager as? MarkdownLayoutManager)?.fades.map(\.range) ?? [] }

    /// Everything after the `shared` characters the old and new text start with is new (nil: nothing
    /// fades). Fades already running keep their own clocks as long as their text is still there.
    private func trackFades(shared: Int?, length: Int) {
        guard let lm = layoutManager as? MarkdownLayoutManager else { return }
        guard let shared else { return clearFades() }
        let now = CACurrentMediaTime()
        var fades = lm.fades.compactMap { fade -> TextFade? in
            let kept = NSIntersectionRange(fade.range, NSRange(location: 0, length: shared))
            guard kept.length > 0, fade.isRunning(at: now) else { return nil }
            return TextFade(range: kept, start: fade.start, duration: fade.duration)
        }
        if length > shared {
            fades.append(
                TextFade(
                    range: NSRange(location: shared, length: length - shared), start: now,
                    duration: StreamingMotion.fadeDuration))
        }
        lm.fades = fades
        if fades.isEmpty { fadeTicker.stop() } else { fadeTicker.start(in: self) }
    }

    private func clearFades() {
        (layoutManager as? MarkdownLayoutManager)?.fades = []
        fadeTicker.stop()
    }

    /// Redraws the faded text and drops the fades that have finished (the redraw
    /// that follows paints them at full strength).
    private func advanceFades() -> Bool {
        guard let lm = layoutManager as? MarkdownLayoutManager, let container = textContainer,
            let first = lm.fades.first, let last = lm.fades.last
        else { return false }
        let span = NSIntersectionRange(
            NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location),
            NSRange(location: 0, length: textStorage?.length ?? 0))
        if span.length > 0 {
            let glyphs = lm.glyphRange(forCharacterRange: span, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            setNeedsDisplay(rect.insetBy(dx: -2, dy: -4))
        }
        let now = CACurrentMediaTime()
        lm.fades.removeAll { !$0.isRunning(at: now) }
        return !lm.fades.isEmpty
    }

    // MARK: Code blocks

    private func updateCopyButtons() {
        guard let lm = layoutManager as? MarkdownLayoutManager else { return }
        let side = theme.scaled(16)
        let header = theme.codePadV + theme.codeLabelHeight
        var used = 0
        for marker in codeBlocks {
            guard let rect = lm.codeBlockRect(marker) else { continue }
            let button: CodeCopyButton
            if used < copyButtons.count {
                button = copyButtons[used]
            } else {
                button = CodeCopyButton()
                addSubview(button)
                copyButtons.append(button)
            }
            used += 1

            button.code = marker.code
            button.symbolSize = theme.scaled(11)
            button.isHidden = false
            button.frame = NSRect(
                x: rect.maxX - side - theme.scaled(6), y: topInset + rect.minY + (header - side) / 2, width: side,
                height: side)
        }
        for button in copyButtons[used...] { button.isHidden = true }
    }

    /// Unlabeled code is colored after the first, plain render: cached verdicts apply at once,
    /// the rest are detected in the background. The short delay keeps a streaming message,
    /// which replaces its string every few milliseconds, from starting work that's thrown away.
    private func detectLanguages(for string: NSAttributedString) {
        var remaining: [CodeBlockMarker] = []
        for marker in codeBlocks where marker.needsDetection {
            if let hit = SyntaxHighlighter.shared.cached(marker.code, language: nil) {
                apply(hit, to: marker)
            } else {
                remaining.append(marker)
            }
        }
        guard !remaining.isEmpty else { return }
        detectionTask = Task(priority: .utility) { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            for marker in remaining {
                guard !Task.isCancelled, let result = await SyntaxHighlighter.shared.detect(marker.code) else {
                    return
                }
                guard let self, self.renderedSource === string else { return }
                self.apply(result, to: marker)
            }
        }
    }

    /// Colors only; the font is untouched, so layout and heights stay valid.
    private func apply(_ result: SyntaxHighlighter.Result, to marker: CodeBlockMarker) {
        marker.detectedLanguage = result.language?.displayName
        needsDisplay = true
        guard let storage = textStorage, !result.spans.isEmpty else { return }
        storage.beginEditing()
        for span in result.spans {
            let range = NSRange(location: marker.range.location + span.range.location, length: span.range.length)
            guard NSMaxRange(range) <= NSMaxRange(marker.range), NSMaxRange(range) <= storage.length else { continue }
            storage.addAttribute(.foregroundColor, value: SyntaxTheme.color(for: span.token), range: range)
        }
        storage.endEditing()
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

    // NSTextView re-applies the I-beam on every mouse move and cursor update, overriding the
    // button's own cursor, so a copy button under the pointer has to win here.
    private func isOverCopyButton(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return copyButtons.contains { !$0.isHidden && $0.frame.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        if isOverCopyButton(event) {
            NSCursor.pointingHand.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isOverCopyButton(event) {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }
}
