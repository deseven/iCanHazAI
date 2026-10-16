import AppKit

/// "This tool call needs your approval." with Allow once / Allow for this chat / Deny.
final class ApprovalView: FlippedView {
    var onEvent: ((RowEvent) -> Void)?

    private var callID = ""
    private let label = NSTextField(labelWithString: "This tool call needs your approval.")
    private let allowOnce = NSButton(title: "Allow once", target: nil, action: nil)
    private let allowForChat = NSButton(title: "Allow for this chat", target: nil, action: nil)
    private let deny = NSButton(title: "Deny", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.textColor = .secondaryLabelColor
        for (button, action) in [
            (allowOnce, #selector(allowOnceTapped)), (allowForChat, #selector(allowForChatTapped)),
            (deny, #selector(denyTapped)),
        ] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
            addSubview(button)
        }
        deny.hasDestructiveAction = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(callID: String, layout: RowLayout) {
        self.callID = callID
        let theme = layout.theme
        let s = theme.scale
        label.font = .systemFont(ofSize: theme.scaled(12))
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 0, y: 0)
        var x: CGFloat = 0
        let y = 22 * s
        for button in [allowOnce, allowForChat, deny] {
            button.font = .systemFont(ofSize: theme.scaled(11))
            button.sizeToFit()
            button.frame = NSRect(x: x, y: y, width: button.frame.width, height: max(button.frame.height, 22 * s))
            x = button.frame.maxX + 8 * s
        }
    }

    @objc private func allowOnceTapped() { onEvent?(.action(.allowToolCall(callID: callID))) }
    @objc private func allowForChatTapped() { onEvent?(.action(.allowToolCallForChat(callID: callID))) }
    @objc private func denyTapped() { onEvent?(.action(.denyToolCall(callID: callID))) }
}

/// A thinking or tool block: a clickable header and, when open, its body.
final class CollapsibleView: PanelView {
    var onEvent: ((RowEvent) -> Void)?
    private(set) var key = ""
    private var headerHeight: CGFloat = 28
    private var togglable = true

    private let chevron = NSImageView()
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let statusText = NSTextField(labelWithString: "")
    private let spinner = SpinnerView()
    private let badge = BadgeView()
    private let approval = ApprovalView()
    private let collapseLink = LinkButton(title: "collapse")
    private var texts: [MarkdownTextView] = []
    private var images: [ImageThumbnailView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.contentTintColor = .tertiaryLabelColor
        symbol.contentTintColor = .secondaryLabelColor
        summary.textColor = .secondaryLabelColor
        statusText.textColor = .secondaryLabelColor
        for label in [title, summary, statusText] {
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
        }
        collapseLink.target = self
        collapseLink.action = #selector(collapseTapped)
        approval.onEvent = { [weak self] in self?.onEvent?($0) }
        for v in [chevron, symbol, title, summary, statusText, spinner, badge, approval, collapseLink] as [NSView] {
            addSubview(v)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func color(for kind: ToolSummary.Status.Kind) -> NSColor {
        switch kind {
        case .running: return .systemBlue
        case .pending: return .systemYellow
        case .done: return .systemGreen
        case .error: return .systemRed
        case .denied: return .systemOrange
        case .cancelled: return .secondaryLabelColor
        }
    }

    func configure(
        _ block: CollapsibleBlock, open: Bool, geometry: RowLayout.CollapsibleGeometry, layout: RowLayout
    ) {
        let theme = layout.theme
        let s = theme.scale
        let w = bounds.width
        key = block.key
        togglable = !block.forcedOpen
        headerHeight = geometry.header
        tint = block.hasApproval ? Self.color(for: .pending) : nil
        cornerRadius = theme.scaled(7)
        needsDisplay = true

        chevron.image = .symbol(open ? "chevron.down" : "chevron.right", size: theme.scaled(10), weight: .semibold)
        symbol.image = .symbol(block.symbol, size: theme.scaled(11))
        title.font = .systemFont(ofSize: theme.scaled(12), weight: .semibold)
        title.stringValue = block.title

        let firstLine = layout.collapsibleHeader
        chevron.frame = NSRect(x: 9 * s, y: (firstLine - 12 * s) / 2, width: 12 * s, height: 12 * s)
        symbol.frame = NSRect(x: 25 * s, y: (firstLine - 16 * s) / 2, width: 16 * s, height: 16 * s)
        title.sizeToFit()
        title.frame = NSRect(
            x: 46 * s, y: (firstLine - title.frame.height) / 2, width: min(title.frame.width, w * 0.45),
            height: title.frame.height)

        let status = block.kind == .tool ? block.status : nil
        let running = block.showsSpinner || status?.kind == .running
        let showsStatusLine = !open && status != nil
        spinner.setActive(running)
        if let status {
            badge.configure(text: status.label, color: Self.color(for: status.kind), theme: theme)
        }
        badge.isHidden = status == nil

        summary.font = .monospacedSystemFont(ofSize: theme.scaled(11), weight: .regular)
        summary.stringValue = open ? "" : block.summary
        summary.isHidden = open || block.summary.isEmpty
        statusText.font = .systemFont(ofSize: theme.scaled(11))
        statusText.stringValue = status?.description ?? ""
        statusText.textColor = status?.kind == .error ? .systemRed : .secondaryLabelColor
        statusText.isHidden = !showsStatusLine || status?.description.isEmpty != false

        let spinnerSize = 14 * s
        func placeBadge(from startX: CGFloat, centerY: CGFloat) -> CGFloat {
            var x = startX
            if running {
                spinner.frame = NSRect(x: x, y: centerY - spinnerSize / 2, width: spinnerSize, height: spinnerSize)
                x += spinnerSize + 6 * s
            }
            if status != nil {
                let size = badge.preferredSize
                badge.frame = NSRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)
                x += size.width + 8 * s
            }
            return x
        }

        let afterTitle = title.frame.maxX + 8 * s
        if showsStatusLine {
            let lineCenter = firstLine + (geometry.header - firstLine) / 2
            let x = placeBadge(from: 46 * s, centerY: lineCenter)
            statusText.sizeToFit()
            statusText.frame = NSRect(
                x: x, y: lineCenter - statusText.frame.height / 2, width: max(0, w - x - 10 * s),
                height: statusText.frame.height)
        } else {
            _ = placeBadge(from: afterTitle, centerY: firstLine / 2)
        }
        let summaryHeight = ceil(summary.intrinsicContentSize.height)
        summary.frame = NSRect(
            x: afterTitle, y: (firstLine - summaryHeight) / 2, width: max(0, w - afterTitle - 10 * s),
            height: summaryHeight)

        layoutBody(block, open: open, geometry: geometry, layout: layout)
        window?.invalidateCursorRects(for: self)
    }

    private func layoutBody(
        _ block: CollapsibleBlock, open: Bool, geometry: RowLayout.CollapsibleGeometry, layout: RowLayout
    ) {
        let theme = layout.theme
        let pad = layout.panelPad
        let bodyWidth = bounds.width - pad * 2
        var textIndex = 0
        var imageIndex = 0
        if open {
            let body = layout.bodyLayout(block.body, width: bodyWidth)
            for (segment, frame) in zip(block.body.segments, body.frames) {
                let rect = NSRect(x: pad, y: geometry.body.y + frame.y, width: bodyWidth, height: frame.height)
                switch segment {
                case .text(let text):
                    let tv = take(&texts, &textIndex) { MarkdownTextView() }
                    tv.theme = theme
                    tv.frame = rect
                    tv.setRenderedIfNeeded(text, width: bodyWidth)
                case .image(let imageKey, let image):
                    let iv = take(&images, &imageIndex) {
                        let v = ImageThumbnailView()
                        v.fit = .fit
                        return v
                    }
                    iv.cornerRadius = theme.scaled(6)
                    iv.frame = rect
                    iv.show(
                        key: "\(imageKey)#\(image.data.count)@\(Int(frame.height))", source: .base64(image.data),
                        maxPixel: ceil(max(frame.height, bodyWidth) * 2))
                }
            }
        }
        for v in texts[textIndex...] { v.isHidden = true }
        for v in images[imageIndex...] { v.isHidden = true }

        if open, let y = geometry.approvalY, let callID = block.approvalCallID {
            approval.isHidden = false
            approval.frame = NSRect(x: pad, y: y, width: bodyWidth, height: layout.approvalHeight)
            approval.configure(callID: callID, layout: layout)
        } else {
            approval.isHidden = true
        }

        if open, let y = geometry.collapseLinkY {
            collapseLink.isHidden = false
            collapseLink.configure(font: .systemFont(ofSize: theme.scaled(11)))
            collapseLink.frame = NSRect(
                x: bounds.width - pad - collapseLink.frame.width, y: y, width: collapseLink.frame.width,
                height: layout.collapseLinkHeight)
        } else {
            collapseLink.isHidden = true
        }
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

    @objc private func collapseTapped() { onEvent?(.collapse(key: key)) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y <= headerHeight {
            if togglable { onEvent?(.toggle(key: key)) }
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        if togglable {
            addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight), cursor: .pointingHand)
        }
    }
}

/// Error text with a warning icon and a Retry button.
final class ErrorBlockView: PanelView {
    var onEvent: ((RowEvent) -> Void)?

    private let icon = NSImageView()
    private let text = MarkdownTextView()
    private let retry = NSButton(title: "Retry", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        tint = .systemRed
        icon.contentTintColor = .systemRed
        retry.bezelStyle = .rounded
        retry.controlSize = .small
        retry.imagePosition = .imageLeading
        retry.target = self
        retry.action = #selector(retryTapped)
        for v in [icon, text, retry] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ rendered: RenderedText, layout: RowLayout) {
        let theme = layout.theme
        let s = theme.scale
        let pad = layout.panelPad
        cornerRadius = theme.scaled(7)
        icon.image = .symbol("exclamationmark.triangle", size: theme.scaled(13))
        icon.frame = NSRect(x: pad, y: pad + 2 * s, width: 16 * s, height: 16 * s)
        let textWidth = layout.errorTextWidth(bounds.width)
        let textHeight = rendered.height(forWidth: textWidth)
        text.theme = theme
        text.frame = NSRect(x: pad + layout.errorIconWidth, y: pad, width: textWidth, height: textHeight)
        text.setRenderedIfNeeded(rendered, width: textWidth)
        retry.font = .systemFont(ofSize: theme.scaled(11))
        retry.image = .symbol("arrow.counterclockwise", size: theme.scaled(10))
        retry.sizeToFit()
        retry.frame = NSRect(
            x: pad + layout.errorIconWidth, y: pad + textHeight + layout.retryGap, width: retry.frame.width,
            height: max(retry.frame.height, 22 * s))
        needsDisplay = true
    }

    @objc private func retryTapped() { onEvent?(.action(.retry)) }
}
