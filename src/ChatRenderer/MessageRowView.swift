import AppKit

/// One message: header (avatar, role, hover details and actions), its blocks,
/// and the bottom action bar. Views are reused across rows, so everything is
/// driven by `configure`; hover and bottom-bar visibility come from the list.
final class MessageRowView: FlippedView {
    struct Signature: Equatable {
        let row: UUID
        let version: Int
        let width: CGFloat
        let scale: CGFloat
        let open: [Bool]
        let context: Int
        let isFirst: Bool
    }

    var onEvent: ((RowEvent) -> Void)?
    private(set) var signature: Signature?
    private var role: ChatRowModel.Role = .user
    private var cornerRadius: CGFloat = 10

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let headerActions = ActionBarView()
    private let bottomActions = ActionBarView()
    private let pendingSpinner = SpinnerView()
    private var texts: [MarkdownTextView] = []
    private var panels: [PanelView] = []
    private var collapsibles: [CollapsibleView] = []
    private var attachments: [AttachmentsView] = []
    private var errors: [ErrorBlockView] = []
    /// The message body's text view (never a panel), which search matches live in.
    private var bodyText: MarkdownTextView?

    var search: SearchHighlight? {
        didSet { if search != oldValue { applySearch() } }
    }

    private func applySearch() {
        bodyText?.searchHighlight = search
    }

    /// The ranges of the message body that are still fading in.
    var bodyFadingRanges: [NSRange] { bodyText?.fadingRanges ?? [] }

    /// The match's bounds in this view's coordinates, once the body is laid out.
    func rect(ofSearchRange range: NSRange) -> NSRect? {
        guard let tv = bodyText, !tv.isHidden, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let r = NSIntersectionRange(range, NSRange(location: 0, length: lm.textStorage?.length ?? 0))
        guard r.length > 0 else { return nil }
        var rect = lm.boundingRect(
            forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y
        return convert(rect, from: tv)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.isHidden = true
        headerActions.isHidden = true
        bottomActions.isHidden = true
        for bar in [headerActions, bottomActions] { bar.onEvent = { [weak self] in self?.onEvent?($0) } }
        for v in [icon, title, detail, headerActions, bottomActions, pendingSpinner] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Driven by the list: per-row tracking areas miss exits when content
    /// scrolls under a stationary cursor, and reused views keep stale state.
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            detail.isHidden = !isHovered
            updateActionVisibility()
        }
    }

    /// The header has scrolled out of view while the row is still visible; the
    /// bottom bar then takes over, but only while the row is hovered.
    var showsBottomActions = false {
        didSet {
            guard showsBottomActions != oldValue else { return }
            updateActionVisibility()
        }
    }

    private func updateActionVisibility() {
        headerActions.isHidden = !isHovered
        bottomActions.isHidden = !(isHovered && showsBottomActions)
        for bar in [headerActions, bottomActions] { window?.invalidateCursorRects(for: bar) }
    }

    private var flashOverlay: NSView?

    /// Briefly tints the whole row so it's easy to spot after a jump.
    func flash() {
        cancelFlash()
        let overlay = FlashOverlayView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = cornerRadius
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            overlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        }
        addSubview(overlay)
        flashOverlay = overlay
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.6
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            overlay.animator().alphaValue = 0
        } completionHandler: { [weak self, weak overlay] in
            MainActor.assumeIsolated {
                guard let overlay else { return }
                overlay.removeFromSuperview()
                if self?.flashOverlay === overlay { self?.flashOverlay = nil }
            }
        }
    }

    func cancelFlash() {
        flashOverlay?.removeFromSuperview()
        flashOverlay = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard role == .user else { return }
        Theme.userRowBackground.setFill()
        let inset = cornerRadius * 0.4
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: inset), xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    func configure(
        _ row: RowState, context: ChatRowContext, isFirst: Bool, textWidth: CGFloat, open: [Bool], layout: RowLayout,
        contextVersion: Int
    ) {
        let signature = Signature(
            row: row.uid, version: row.version, width: textWidth, scale: layout.theme.scale, open: open,
            context: contextVersion, isFirst: isFirst)
        guard signature != self.signature, let rendered = row.rendered else { return }
        // Only a view that already showed this very row can be continuing its text.
        let fadeIn = context.easesStreaming && self.signature?.row == row.uid && StreamingMotion.fades
        self.signature = signature
        let theme = layout.theme
        let m = row.model
        role = m.role
        cornerRadius = theme.scaled(10)
        needsDisplay = true

        configureHeader(m, context: context, isFirst: isFirst, textWidth: textWidth, layout: layout)

        let x = layout.rowInset
        let (frames, _) = layout.blockFrames(rendered, heights: row.heights, open: open)
        var counts = PoolCounts()
        var showsPending = false
        bodyText = nil
        for (i, block) in rendered.blocks.enumerated() {
            let f = frames[i]
            switch block {
            case .pending:
                showsPending = true
                let side = 16 * theme.scale
                pendingSpinner.frame = NSRect(x: x, y: f.y + (f.height - side) / 2, width: side, height: side)
            case .collapsible(let c):
                let v = take(&collapsibles, &counts.collapsibles) {
                    let v = CollapsibleView()
                    v.onEvent = { [weak self] in self?.onEvent?($0) }
                    return v
                }
                v.frame = NSRect(x: x, y: f.y, width: textWidth, height: f.height)
                let isOpen = i < open.count && open[i]
                let geometry = layout.collapsible(
                    c, open: isOpen, bodyHeight: i < row.heights.count ? row.heights[i] : nil)
                v.configure(c, open: isOpen, geometry: geometry, layout: layout, fadeIn: fadeIn)
            case .attachments(let a):
                let v = take(&attachments, &counts.attachments) {
                    let v = AttachmentsView()
                    v.onEvent = { [weak self] in self?.onEvent?($0) }
                    return v
                }
                v.frame = NSRect(x: x, y: f.y, width: textWidth, height: f.height)
                v.configure(
                    a, messageID: m.id, directory: context.attachmentsDirectory, width: textWidth, layout: layout)
            case .text(let text, let panel):
                let tv = take(&texts, &counts.texts) { MarkdownTextView() }
                tv.theme = theme
                tv.searchHighlight = nil
                if !panel { bodyText = tv }
                if panel {
                    let p = take(&panels, &counts.panels) { PanelView() }
                    p.cornerRadius = theme.scaled(7)
                    p.needsDisplay = true
                    p.frame = NSRect(x: x, y: f.y, width: textWidth, height: f.height)
                    if tv.superview !== p { p.addSubview(tv) }
                    tv.frame = NSRect(
                        x: layout.panelPad, y: layout.panelPad, width: textWidth - layout.panelPad * 2,
                        height: f.height - layout.panelPad * 2)
                } else {
                    if tv.superview !== self { addSubview(tv) }
                    tv.frame = NSRect(x: x, y: f.y, width: textWidth, height: f.height)
                }
                tv.setRenderedIfNeeded(text, width: tv.frame.width, fadeIn: fadeIn)
            case .error(let text):
                let v = take(&errors, &counts.errors) {
                    let v = ErrorBlockView()
                    v.onEvent = { [weak self] in self?.onEvent?($0) }
                    return v
                }
                v.frame = NSRect(x: x, y: f.y, width: textWidth, height: f.height)
                v.configure(text, layout: layout)
            }
        }
        applySearch()
        pendingSpinner.setActive(showsPending)
        for v in texts[counts.texts...] { v.isHidden = true }
        for v in panels[counts.panels...] { v.isHidden = true }
        for v in collapsibles[counts.collapsibles...] { v.isHidden = true }
        for v in attachments[counts.attachments...] { v.isHidden = true }
        for v in errors[counts.errors...] { v.isHidden = true }
    }

    private func configureHeader(
        _ m: ChatRowModel, context: ChatRowContext, isFirst: Bool, textWidth: CGFloat, layout: RowLayout
    ) {
        let theme = layout.theme
        let s = theme.scale
        let accent = m.role == .assistant ? context.roleAccent : nil
        let (symbolName, label): (String, String) =
            switch m.role {
            case .user: ("person.crop.circle", "You")
            case .assistant: (context.roleIcon ?? Role.defaultIcon, context.assistantLabel)
            case .tool: ("terminal", "Tool")
            case .system: ("gearshape", "System")
            }
        icon.image = .symbol(symbolName, size: theme.scaled(14)) ?? .symbol(Role.defaultIcon, size: theme.scaled(14))
        icon.contentTintColor = accent ?? (m.role == .user ? .labelColor : .secondaryLabelColor)
        title.font = .systemFont(ofSize: theme.scaled(13), weight: .semibold)
        title.stringValue = label
        title.textColor = accent ?? .labelColor
        detail.font = .systemFont(ofSize: theme.scaled(11))
        detail.stringValue = Self.detailText(m)

        let x = layout.rowInset
        let hy = layout.top
        icon.frame = NSRect(x: x, y: hy + s, width: 18 * s, height: 18 * s)
        title.sizeToFit()
        title.frame.origin = NSPoint(x: x + 24 * s, y: hy + (layout.header - title.frame.height) / 2)

        let canRegenerate = m.canRegenerate(
            isFirst: isFirst, features: context.features, streaming: context.isStreaming)
        for bar in [headerActions, bottomActions] {
            bar.configure(model: m, canRegenerate: canRegenerate, streaming: context.isStreaming, theme: theme)
        }
        let barX = x + textWidth - headerActions.contentWidth
        headerActions.frame.origin = NSPoint(x: barX, y: hy)
        bottomActions.frame.origin = NSPoint(x: barX, y: bounds.height - layout.bottom - layout.actionBar)

        detail.sizeToFit()
        let detailX = title.frame.maxX + 10 * s
        detail.frame = NSRect(
            x: detailX, y: hy + (layout.header - detail.frame.height) / 2 + s,
            width: max(0, min(detail.frame.width, barX - detailX - 8 * s)), height: detail.frame.height)
    }

    static func detailText(_ m: ChatRowModel) -> String {
        var parts = [timeFormatter.string(from: m.timestamp)]
        if m.role == .assistant, let model = m.model, !model.isEmpty {
            parts.append("via \(model)")
        }
        return parts.joined(separator: " · ")
    }

    private final class FlashOverlayView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private struct PoolCounts {
        var texts = 0
        var panels = 0
        var collapsibles = 0
        var attachments = 0
        var errors = 0
    }

    private func take<V: NSView>(_ pool: inout [V], _ index: inout Int, make: () -> V) -> V {
        defer { index += 1 }
        if index < pool.count {
            pool[index].isHidden = false
            return pool[index]
        }
        let v = make()
        addSubview(v)
        pool.append(v)
        return v
    }
}
