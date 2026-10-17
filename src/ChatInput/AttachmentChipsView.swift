// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// What a chip shows for one pending attachment.
struct AttachmentChipItem: Equatable {
    let id: UUID
    let kind: DocumentKind
    let name: String
}

/// A single-row, horizontally scrollable strip of attachment chips.
final class AttachmentChipsView: NSView {
    static let height: CGFloat = 26

    var onRemove: ((UUID) -> Void)?

    private let scrollView = NSScrollView()
    private let content = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.borderType = .noBorder
        scrollView.documentView = content
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setItems(_ items: [AttachmentChipItem]) {
        content.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 2
        for item in items {
            let chip = AttachmentChipView(item: item) { [weak self] id in self?.onRemove?(id) }
            chip.frame.origin = NSPoint(x: x, y: 0)
            content.addSubview(chip)
            x += chip.frame.width + 6
        }
        content.frame = NSRect(x: 0, y: 0, width: max(x, bounds.width), height: Self.height)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        content.frame.size = NSSize(width: max(content.frame.width, bounds.width), height: Self.height)
    }
}

/// A compact chip showing an attachment's name with a remove button. The
/// icon reflects the attachment kind (image vs. text/document).
private final class AttachmentChipView: NSView {
    private static let maxLabelWidth: CGFloat = 220
    private static let horizontalPadding: CGFloat = 8
    private static let spacing: CGFloat = 4

    private let onRemove: (UUID) -> Void
    private let id: UUID

    init(item: AttachmentChipItem, onRemove: @escaping (UUID) -> Void) {
        self.id = item.id
        self.onRemove = onRemove
        super.init(frame: .zero)
        wantsLayer = true

        let icon = NSImageView(
            image: NSImage(
                systemSymbolName: item.kind == .image ? "photo" : "doc", accessibilityDescription: nil)
                ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        icon.contentTintColor = .labelColor

        let label = NSTextField(labelWithString: item.name)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let remove = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove attachment")
                ?? NSImage(),
            target: self, action: #selector(removeTapped))
        remove.isBordered = false
        remove.imagePosition = .imageOnly
        remove.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        remove.contentTintColor = .labelColor
        remove.toolTip = "Remove attachment"

        let iconSize: CGFloat = 12
        let removeSize: CGFloat = 14
        let labelWidth = min(ceil(label.intrinsicContentSize.width), Self.maxLabelWidth)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        var x = Self.horizontalPadding
        let height = AttachmentChipsView.height

        icon.frame = NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        x += iconSize + Self.spacing
        label.frame = NSRect(x: x, y: (height - labelHeight) / 2, width: labelWidth, height: labelHeight)
        x += labelWidth + Self.spacing
        remove.frame = NSRect(x: x, y: (height - removeSize) / 2, width: removeSize, height: removeSize)
        x += removeSize + Self.horizontalPadding

        frame.size = NSSize(width: x, height: height)
        [icon, label, remove].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeTapped() {
        onRemove(id)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 6
        layer.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
