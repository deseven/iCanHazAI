import AppKit
import ImageIO

enum ThumbnailSource: Sendable {
    case file(URL)
    case base64(String)
}

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

/// Decodes downsampled images off the main thread and keeps them in memory.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()
    private var waiting: [String: [@MainActor (NSImage?) -> Void]] = [:]

    init() {
        cache.countLimit = 300
    }

    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    /// Calls `completion` on the main actor, immediately when the image is cached.
    func load(
        key: String, source: ThumbnailSource, maxPixel: CGFloat, completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        if let image = cached(key) {
            completion(image)
            return
        }
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return
        }
        waiting[key] = [completion]
        Task { [weak self] in
            let box = await Task.detached(priority: .utility) {
                UncheckedBox(value: Self.makeThumbnail(source, maxPixel: maxPixel))
            }.value
            self?.finish(key, box.value)
        }
    }

    private func finish(_ key: String, _ image: NSImage?) {
        if let image { cache.setObject(image, forKey: key as NSString) }
        let callbacks = waiting.removeValue(forKey: key) ?? []
        for callback in callbacks { callback(image) }
    }

    nonisolated static func makeThumbnail(_ source: ThumbnailSource, maxPixel: CGFloat) -> NSImage? {
        let imageSource: CGImageSource?
        switch source {
        case .file(let url):
            imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        case .base64(let string):
            imageSource = Data(base64Encoded: string).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
        }
        guard let imageSource else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// A rounded, bordered image that loads lazily. `.fill` crops to the square
/// (attachment thumbnails); `.fit` shows the whole image (tool result images).
final class ImageThumbnailView: FlippedView {
    enum Fit { case fill, fit }

    var fit = Fit.fill
    var cornerRadius: CGFloat = 8
    var onClick: (() -> Void)?

    private var image: NSImage?
    private var key: String?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(key: String, source: ThumbnailSource, maxPixel: CGFloat) {
        guard key != self.key else { return }
        self.key = key
        image = nil
        needsDisplay = true
        ThumbnailLoader.shared.load(key: key, source: source, maxPixel: maxPixel) { [weak self] image in
            guard let self, self.key == key else { return }
            self.image = image
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        Theme.panelBackground.setFill()
        shape.fill()
        if let image, image.size.width > 0, image.size.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let iw = image.size.width
            let ih = image.size.height
            switch fit {
            case .fill:
                let scale = max(bounds.width / iw, bounds.height / ih)
                let src = NSRect(
                    x: (iw - bounds.width / scale) / 2, y: (ih - bounds.height / scale) / 2,
                    width: bounds.width / scale,
                    height: bounds.height / scale)
                image.draw(in: bounds, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            case .fit:
                let scale = min(bounds.width / iw, bounds.height / ih)
                let dest = NSRect(x: 0, y: 0, width: iw * scale, height: ih * scale)
                image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius
        ).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// Clickable chip of a text/document attachment: name plus a notice when
/// extraction was truncated or failed.
final class DocumentChipView: FlippedView {
    var onClick: (() -> Void)?

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let notice = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.contentTintColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingMiddle
        notice.lineBreakMode = .byTruncatingTail
        for v in [icon, name, notice] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Sizes itself to its content, up to `maxWidth`.
    func configure(_ info: ChatRowModel.AttachmentInfo, maxWidth: CGFloat, layout: RowLayout) {
        let theme = layout.theme
        let s = theme.scale
        let height = layout.chipHeight
        toolTip = info.originalName.map { "Open \($0)" } ?? "Open file"
        icon.image = .symbol("doc.text", size: theme.scaled(12))
        name.font = .systemFont(ofSize: theme.scaled(12), weight: .medium)
        name.stringValue = info.displayName
        notice.font = .systemFont(ofSize: theme.scaled(11))
        notice.stringValue = info.statusText ?? ""
        notice.textColor = info.status == .failed ? .systemRed : .secondaryLabelColor
        notice.isHidden = info.statusText == nil

        let pad = 9 * s
        let iconSize = 14 * s
        name.sizeToFit()
        notice.sizeToFit()
        var width = pad + iconSize + 6 * s + name.frame.width + pad
        if !notice.isHidden { width += 8 * s + notice.frame.width }
        width = min(width, maxWidth)
        frame.size = NSSize(width: width, height: height)

        icon.frame = NSRect(x: pad, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        let nameX = pad + iconSize + 6 * s
        let available = max(0, width - nameX - pad)
        let noticeGap = notice.isHidden ? 0 : 8 * s
        var nameWidth = name.frame.width
        var noticeWidth = notice.isHidden ? 0 : notice.frame.width
        if nameWidth + noticeGap + noticeWidth > available {
            if notice.isHidden {
                nameWidth = available
            } else {
                nameWidth = min(nameWidth, available * 0.6)
                noticeWidth = max(0, available - nameWidth - noticeGap)
            }
        }
        name.frame = NSRect(x: nameX, y: (height - name.frame.height) / 2, width: nameWidth, height: name.frame.height)
        notice.frame = NSRect(
            x: name.frame.maxX + noticeGap, y: (height - notice.frame.height) / 2, width: noticeWidth,
            height: notice.frame.height)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        Theme.panelBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A message's attachments: image thumbnails in a wrapping grid, then one chip
/// per document.
final class AttachmentsView: FlippedView {
    var onEvent: ((RowEvent) -> Void)?

    private var thumbnails: [ImageThumbnailView] = []
    private var chips: [DocumentChipView] = []

    func configure(
        _ block: AttachmentsBlock, messageID: String, directory: URL?, width: CGFloat, layout: RowLayout
    ) {
        let theme = layout.theme
        let side = layout.fittedThumbnailSide(width: width)
        let perRow = layout.thumbnailsPerRow(width: width)
        var y: CGFloat = 0
        for (i, info) in block.images.enumerated() {
            let v = take(&thumbnails, i) { ImageThumbnailView() }
            let row = i / perRow
            let col = i % perRow
            v.cornerRadius = theme.scaled(8)
            v.frame = NSRect(
                x: CGFloat(col) * (side + layout.thumbnailGap), y: CGFloat(row) * (side + layout.thumbnailGap),
                width: side, height: side)
            v.toolTip = info.displayName
            v.onClick = { [weak self] in
                self?.onEvent?(.previewAttachment(messageID: messageID, filename: info.filename))
            }
            if let directory {
                let url = directory.appendingPathComponent(info.filename)
                v.show(key: "\(url.path)@\(Int(side))", source: .file(url), maxPixel: ceil(side * 2))
            }
            y = v.frame.maxY
        }
        for v in thumbnails.dropFirst(block.images.count) { v.isHidden = true }

        if !block.images.isEmpty, !block.documents.isEmpty { y += layout.thumbnailGap }
        for (i, info) in block.documents.enumerated() {
            let v = take(&chips, i) { DocumentChipView() }
            v.configure(info, maxWidth: width, layout: layout)
            v.frame.origin = NSPoint(x: 0, y: y)
            v.onClick = { [weak self] in
                if QuickLookSupport.canPreview(filename: info.filename, kind: info.kind) {
                    self?.onEvent?(.previewAttachment(messageID: messageID, filename: info.filename))
                } else {
                    self?.onEvent?(.openAttachment(info))
                }
            }
            y = v.frame.maxY + layout.chipGap
        }
        for v in chips.dropFirst(block.documents.count) { v.isHidden = true }
        for v in thumbnails { window?.invalidateCursorRects(for: v) }
    }

    private func take<V: NSView>(_ pool: inout [V], _ index: Int, make: () -> V) -> V {
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
