// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// What the primary button on the right does right now.
enum ChatInputAction: Equatable {
    case send(enabled: Bool)
    /// Streaming; `afterIteration` is shown while Option is held.
    case stop(afterIteration: Bool)
    /// A "stop after streaming" request is pending: nothing to press.
    case finishing
    /// Streaming with something typed: the message waits for the answer to end.
    case queue
    /// Same, with Option held: stop and send now.
    case sendImmediately
}

/// Everything the bar shows that comes from outside it.
struct ChatInputBarState: Equatable {
    var showsAttachButton = false
    var attachEnabled = true
    var inputEnabled = true
    var action: ChatInputAction = .send(enabled: false)
}

/// The message input: a rounded bar holding an attach button, an attachment
/// chip strip, a growing plain-text editor and the send/stop button.
///
/// The bar knows how tall it wants to be (`preferredHeight`) but does not size
/// itself: `ChatPaneView` owns the frame, animates it, and resizes the message
/// list alongside, so everything stays in one layout pass. The bar only
/// reports that its preferred height may have changed.
final class ChatInputBarView: NSView, NSTextViewDelegate {
    static let verticalPadding: CGFloat = 6
    static let sidePadding: CGFloat = 4
    static let buttonSize: CGFloat = 28
    static let chipsSpacing: CGFloat = 4
    static let cornerRadius: CGFloat = 10
    static let minHeight: CGFloat = ChatInputTextView.lineHeight + verticalPadding * 2

    /// Height of the bar showing `lines` lines of text and nothing else.
    static func height(forLines lines: Int) -> CGFloat {
        let line = ChatInputTextView.lineHeight - ChatInputTextView.insets.height * 2
        return minHeight + CGFloat(max(lines - 1, 0)) * line
    }

    /// The text changed, by typing or programmatically.
    var onTextChange: (() -> Void)?
    /// The preferred height may have changed; the flag says whether the
    /// change should animate.
    var onHeightInvalidated: ((Bool) -> Void)?
    var onAttach: (() -> Void)?
    var onAction: (() -> Void)?
    var onRemoveAttachment: ((UUID) -> Void)?

    var state = ChatInputBarState() {
        didSet { if state != oldValue { apply(state, replacing: oldValue) } }
    }

    let textView = ChatInputTextView()
    private let scrollView = NSScrollView()
    private let chips = AttachmentChipsView()
    private let attachButton = NSButton()
    private let actionButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let placeholder = PlaceholderLabel(labelWithString: "Message")
    private var chipItems: [AttachmentChipItem] = []
    /// Whether the text fit the last preferred height, i.e. needs no scrolling.
    private var contentFits = true

    /// The height the bar is animating toward. The text column is laid out for
    /// this height right away, and the bar's bounds clip it while the frame
    /// catches up. The viewport therefore never shrinks below the content, so
    /// growing neither scrolls the text nor flashes a scroller; the text just
    /// moves with the top edge and new lines are revealed. Nil uses the frame.
    /// (Influenced by the growing text input in Telegram's macOS client.)
    var settledHeight: CGFloat? {
        didSet { if settledHeight != oldValue { needsLayout = true } }
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Clips the text column, which is laid out for the final height while
        // the bar is still growing toward it.
        layer?.masksToBounds = true

        textView.delegate = self
        textView.setAccessibilityLabel("Message")
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // Legacy scrollers would take width from the text and make wrapping
        // depend on whether the content overflows.
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        addSubview(scrollView)

        // Beneath the scroll view, which draws no background, so it shows
        // through the empty text view.
        placeholder.font = ChatInputTextView.font
        placeholder.textColor = .placeholderTextColor
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.wantsLayer = true
        addSubview(placeholder, positioned: .below, relativeTo: scrollView)

        chips.isHidden = true
        chips.onRemove = { [weak self] id in self?.onRemoveAttachment?(id) }
        addSubview(chips)

        attachButton.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach files")
        attachButton.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        attachButton.contentTintColor = .labelColor
        attachButton.toolTip = "Attach files"
        attachButton.setAccessibilityLabel("Attach files")
        attachButton.target = self
        attachButton.action = #selector(attachTapped)
        attachButton.isHidden = true

        actionButton.target = self
        actionButton.action = #selector(actionTapped)

        for button in [attachButton, actionButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.focusRingType = .none
            addSubview(button)
        }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        addSubview(spinner)

        apply(state, replacing: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Content

    var text: String { textView.string }
    var hasNonBlankText: Bool { textView.hasNonBlankText }

    /// Replaces the whole text, as for a restored draft or after sending.
    /// Undo history is dropped: it belongs to the text that went away.
    func setText(_ new: String, animated: Bool) {
        guard textView.string != new else { return }
        textView.string = new
        textView.undoManager?.removeAllActions(withTarget: textView)
        textView.setSelectedRange(NSRange(location: (new as NSString).length, length: 0))
        updatePlaceholder(animated: animated)
        onTextChange?()
        onHeightInvalidated?(animated)
    }

    func setAttachments(_ items: [AttachmentChipItem], animated: Bool) {
        guard items != chipItems else { return }
        chipItems = items
        chips.setItems(items)
        chips.isHidden = items.isEmpty
        needsLayout = true
        onHeightInvalidated?(animated)
    }

    var isTextFocused: Bool { window?.firstResponder === textView }

    // MARK: Placeholder

    private static let placeholderSlide: CGFloat = 12
    private(set) var isPlaceholderVisible = true

    /// Fades the hint in and out as the field empties and fills. It also
    /// slides a little, toward the text's side when leaving, so typing the
    /// first character feels like pushing it away.
    private func updatePlaceholder(animated: Bool) {
        // Marked (IME) text is part of the string, so composing hides the hint too.
        let show = state.inputEnabled && (textView.textStorage?.length ?? 0) == 0
        guard show != isPlaceholderVisible else { return }
        isPlaceholderVisible = show

        let offset = show ? 0 : Self.placeholderSlide
        guard let layer = placeholder.layer else {
            placeholder.alphaValue = show ? 1 : 0
            return
        }
        let animate = animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            let current =
                (layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat)
                ?? (show ? Self.placeholderSlide : 0)
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = current
            slide.toValue = offset
            slide.duration = 0.2
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(slide, forKey: "slide")
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                placeholder.animator().alphaValue = show ? 1 : 0
            }
        } else {
            layer.removeAnimation(forKey: "slide")
            placeholder.alphaValue = show ? 1 : 0
        }
        layer.transform = CATransform3DMakeTranslation(offset, 0, 0)
    }

    @discardableResult
    func focusText() -> Bool {
        window?.makeFirstResponder(textView) ?? false
    }

    // MARK: Height

    private var chipsBlockHeight: CGFloat {
        chips.isHidden ? 0 : AttachmentChipsView.height + Self.chipsSpacing
    }

    /// The height the content wants, clamped to `[minHeight, maxHeight]`.
    /// Measures at the bar's current width, so lay the bar out first when
    /// the width has just changed.
    func preferredHeight(maxHeight: CGFloat) -> CGFloat {
        let natural = Self.verticalPadding * 2 + chipsBlockHeight + textView.contentHeight
        let result = max(min(natural, maxHeight), Self.minHeight)
        contentFits = natural <= result
        return result
    }

    // MARK: Layout

    private var textLeading: CGFloat {
        state.showsAttachButton ? Self.sidePadding + Self.buttonSize : 6
    }
    private var textTrailing: CGFloat { bounds.width - Self.sidePadding - Self.buttonSize }

    override func layout() {
        super.layout()
        let h = bounds.height
        let contentBottom = settledHeight ?? h
        let button = Self.buttonSize
        // Anchored to the bottom edge so they stay beside the last line as the
        // bar grows; centered on the first line when the bar is one line tall.
        let buttonY = h - (Self.minHeight - button) / 2 - button

        attachButton.frame = NSRect(x: Self.sidePadding, y: buttonY, width: button, height: button)
        actionButton.frame = NSRect(
            x: bounds.width - Self.sidePadding - button, y: buttonY, width: button, height: button)
        spinner.sizeToFit()
        spinner.frame = spinner.frame.size.centered(in: actionButton.frame)

        let width = max(0, textTrailing - textLeading)
        var top = Self.verticalPadding
        chips.frame = NSRect(x: textLeading, y: top, width: width, height: AttachmentChipsView.height)
        top += chipsBlockHeight
        let scrollFrame = NSRect(
            x: textLeading, y: top, width: width, height: max(0, contentBottom - top - Self.verticalPadding))
        scrollView.frame = scrollFrame
        // Only a bar capped at its maximum height scrolls. Enabling the
        // scroller just for that keeps it from flashing while the text view
        // briefly outgrows the viewport as a line is added.
        scrollView.hasVerticalScroller = !contentFits
        textView.minSize = NSSize(width: 0, height: scrollFrame.height)

        // Lines up with the first line of text: same origin as the text view's
        // container (the text view sits at the scroll view's top-left).
        let insets = ChatInputTextView.insets
        placeholder.frame = NSRect(
            x: scrollFrame.minX + insets.width, y: scrollFrame.minY + insets.height,
            width: max(0, scrollFrame.width - insets.width * 2), height: ceil(placeholder.intrinsicContentSize.height))

        // While the bar is still growing, NSTextView may have scrolled to keep
        // the caret visible in the smaller viewport; text that fits the final
        // height belongs at the top.
        if contentFits, scrollView.contentView.bounds.origin.y != 0 {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = Self.cornerRadius
        layer.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Clicks on the bar's padding focus the editor, like clicking the text.
    override func mouseDown(with event: NSEvent) {
        if state.inputEnabled { focusText() } else { super.mouseDown(with: event) }
    }

    // MARK: State

    private func apply(_ state: ChatInputBarState, replacing old: ChatInputBarState?) {
        attachButton.isHidden = !state.showsAttachButton
        attachButton.isEnabled = state.attachEnabled
        attachButton.alphaValue = state.attachEnabled ? 1 : 0.4

        textView.isEditable = state.inputEnabled
        textView.isSelectable = state.inputEnabled
        textView.alphaValue = state.inputEnabled ? 1 : 0.5
        updatePlaceholder(animated: false)

        switch state.action {
        case .send(let enabled):
            show(symbol: "arrow.up.circle.fill", color: enabled ? .controlAccentColor : .secondaryLabelColor)
            actionButton.isEnabled = enabled
            actionButton.toolTip = "Send"
        case .stop(let afterIteration):
            show(symbol: afterIteration ? "stopwatch" : "stop.circle.fill", color: .controlAccentColor)
            actionButton.isEnabled = true
            actionButton.toolTip = afterIteration ? "Stop After Streaming" : "Stop (hold ⌥ to stop after streaming)"
        case .finishing:
            actionButton.toolTip = "Finishing the current iteration…"
        case .queue:
            show(symbol: "arrow.up.right.circle.fill", color: .controlAccentColor)
            actionButton.isEnabled = true
            actionButton.toolTip = "Queue the message"
        case .sendImmediately:
            show(symbol: "arrowshape.up.circle.fill", color: .controlAccentColor)
            actionButton.isEnabled = true
            actionButton.toolTip = "Send immediately"
        }
        let finishing = state.action == .finishing
        actionButton.isHidden = finishing
        spinner.isHidden = !finishing
        if finishing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.toolTip = actionButton.toolTip
        actionButton.setAccessibilityLabel(actionButton.toolTip)
        spinner.setAccessibilityLabel(actionButton.toolTip)

        needsLayout = true
        // The text column's left edge depends on the attach button, so its
        // wrapping (and with it the bar's height) can change.
        if let old, old.showsAttachButton != state.showsAttachButton {
            layoutSubtreeIfNeeded()
            onHeightInvalidated?(true)
        }
    }

    private func show(symbol: String, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            .applying(.init(hierarchicalColor: color))
        actionButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    @objc private func attachTapped() { onAttach?() }
    @objc private func actionTapped() { onAction?() }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        updatePlaceholder(animated: true)
        onTextChange?()
        onHeightInvalidated?(true)
    }
}

/// A label that never takes clicks, so they reach the text view beneath it.
private final class PlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSSize {
    fileprivate func centered(in rect: NSRect) -> NSRect {
        NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}
