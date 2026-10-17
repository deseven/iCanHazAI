// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// The messages waiting to be sent, shown above the input bar: one truncated
/// line per message, and two buttons acting on the whole queue (send it now,
/// or throw it away).
///
/// Like the input bar it only reports the height it wants (`preferredHeight`);
/// `ChatPaneView` owns the frame and animates it.
final class QueuedMessagesView: NSView {
    static let rowHeight: CGFloat = 20
    static let verticalPadding: CGFloat = 4
    static let sidePadding: CGFloat = 10
    static let buttonSize: CGFloat = 22
    /// Rows beyond this collapse into a "+N more" line.
    static let maxRows = 3

    var onSendNow: (() -> Void)?
    var onDiscard: (() -> Void)?
    /// The preferred height may have changed.
    var onHeightInvalidated: ((Bool) -> Void)?

    private(set) var items: [String] = []
    private var labels: [NSTextField] = []
    private let sendButton = NSButton()
    private let discardButton = NSButton()

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true

        configure(
            sendButton, symbol: "arrowshape.up.circle.fill", tip: "Send queued messages now",
            action: #selector(sendTapped))
        configure(
            discardButton, symbol: "xmark.circle.fill", tip: "Discard queued messages",
            action: #selector(discardTapped))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            .applying(.init(hierarchicalColor: .controlAccentColor))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.toolTip = tip
        button.target = self
        button.action = action
        addSubview(button)
    }

    // MARK: Content

    /// One-line previews of the queued messages, in send order.
    func setItems(_ new: [String]) {
        guard new != items else { return }
        items = new
        labels.forEach { $0.removeFromSuperview() }
        labels = rowTexts.map { text in
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
            return label
        }
        isHidden = new.isEmpty
        needsLayout = true
        onHeightInvalidated?(true)
    }

    private var rowTexts: [String] {
        guard items.count > Self.maxRows else { return items }
        let shown = Self.maxRows - 1
        return Array(items.prefix(shown)) + ["+\(items.count - shown) more"]
    }

    var preferredHeight: CGFloat {
        items.isEmpty ? 0 : CGFloat(labels.count) * Self.rowHeight + Self.verticalPadding * 2
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let buttons = Self.buttonSize * 2 + 4
        let textWidth = max(0, bounds.width - Self.sidePadding * 2 - buttons - 6)
        for (i, label) in labels.enumerated() {
            let height = ceil(label.intrinsicContentSize.height)
            label.frame = NSRect(
                x: Self.sidePadding,
                y: Self.verticalPadding + CGFloat(i) * Self.rowHeight + (Self.rowHeight - height) / 2,
                width: textWidth, height: height)
        }
        // Centered in the full strip height, so the buttons stay put while it animates.
        let target = preferredHeight
        let y = (target - Self.buttonSize) / 2
        discardButton.frame = NSRect(
            x: bounds.width - Self.sidePadding - Self.buttonSize, y: y, width: Self.buttonSize,
            height: Self.buttonSize)
        sendButton.frame = NSRect(
            x: discardButton.frame.minX - 4 - Self.buttonSize, y: y, width: Self.buttonSize,
            height: Self.buttonSize)
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = ChatInputBarView.cornerRadius
        layer.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
            layer.borderColor = NSColor.separatorColor.cgColor
        }
    }

    @objc private func sendTapped() { onSendNow?() }
    @objc private func discardTapped() { onDiscard?() }
}
