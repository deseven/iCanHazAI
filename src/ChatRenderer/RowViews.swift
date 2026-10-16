import AppKit

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

class PanelView: FlippedView {
    var tint: NSColor? {
        didSet { if tint != oldValue { needsDisplay = true } }
    }
    var cornerRadius: CGFloat = 7

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        Theme.panelBackground.setFill()
        path.fill()
        if let tint {
            tint.withAlphaComponent(0.35).setStroke()
            let border = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
            border.stroke()
        }
    }
}

/// Small colored pill with a status word in it.
final class BadgeView: FlippedView {
    private var text = ""
    private var color = NSColor.secondaryLabelColor
    private var font = NSFont.systemFont(ofSize: 10, weight: .medium)
    private let padding: CGFloat = 6

    func configure(text: String, color: NSColor, theme: Theme) {
        self.text = text
        self.color = color
        font = .systemFont(ofSize: theme.scaled(10.5), weight: .medium)
        needsDisplay = true
    }

    var preferredSize: NSSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width) + padding * 2, height: ceil(size.height) + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = (text as NSString).size(withAttributes: [.font: font])
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: [.font: font, .foregroundColor: color])
    }
}

final class SpinnerView: NSProgressIndicator {
    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        style = .spinning
        controlSize = .small
        isIndeterminate = true
        isDisplayedWhenStopped = false
        isHidden = true
    }

    func setActive(_ active: Bool) {
        if active {
            isHidden = false
            startAnimation(nil)
        } else {
            stopAnimation(nil)
            isHidden = true
        }
    }
}

/// Borderless text button, used for "collapse".
final class LinkButton: NSButton {
    convenience init(title: String) {
        self.init(frame: .zero)
        isBordered = false
        self.title = title
        setButtonType(.momentaryChange)
    }

    func configure(font: NSFont) {
        attributedTitle = NSAttributedString(
            string: title, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        sizeToFit()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

extension NSImage {
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}
