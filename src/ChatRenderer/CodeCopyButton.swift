import AppKit

/// Copies one code block's source to the pasteboard.
final class CodeCopyButton: NSButton {
    var code = ""
    var symbolSize: CGFloat = 12 {
        didSet { if symbolSize != oldValue { showIcon() } }
    }

    private var isHovered = false {
        didSet { updateTint() }
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        toolTip = "Copy code"
        target = self
        action = #selector(copyCode)
        showIcon()
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    private func showIcon() {
        image = .symbol("doc.on.doc", size: symbolSize, weight: .medium)
        updateTint()
    }

    private func updateTint() {
        contentTintColor = isHovered ? .secondaryLabelColor : .tertiaryLabelColor
    }

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    // The hosting text view sets an I-beam through its own tracking; a cursor rect alone loses to it.
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
