// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// The plain-text editor behind the chat input.
///
/// Built on an explicit TextKit 1 stack (a bare `NSTextView()` opts into
/// TextKit 2, whose height queries are less predictable) and sized by the
/// standard scroll-view rules: it tracks the clip view's width and grows
/// vertically with its content, never below `minSize.height`. The owning bar
/// reads `contentHeight` to decide how tall to be; the view itself never
/// decides its own on-screen height.
///
/// It also:
/// - sends on Return (not Shift+Return), unless an input method is composing;
/// - offers pastes to `attachmentPasteHandler` before inserting text.
final class ChatInputTextView: NSTextView {
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let insets = NSSize(width: 4, height: 4)

    /// Height of one line of text including the vertical insets.
    static let lineHeight: CGFloat = {
        let lm = NSLayoutManager()
        return ceil(lm.defaultLineHeight(for: font)) + insets.height * 2
    }()

    /// Return pressed without Shift: return true if the key was consumed.
    var returnHandler: (() -> Bool)?
    /// Paste requested: return true if attachment content was consumed.
    var attachmentPasteHandler: (() -> Bool)?

    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        font = Self.font
        textColor = .labelColor
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        textContainerInset = Self.insets
        isHorizontallyResizable = false
        isVerticallyResizable = true
        minSize = NSSize(width: 0, height: Self.lineHeight)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = [.width]
        self.textContainer?.lineFragmentPadding = 0
        self.textContainer?.widthTracksTextView = true
        self.textContainer?.heightTracksTextView = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The height of the laid-out text plus insets. Lays out only what the
    /// pending edit invalidated, so calling it per keystroke is cheap. Falls
    /// back to one line while the view has no width yet, where every
    /// character would wrap onto its own line.
    var contentHeight: CGFloat {
        guard let layoutManager, let textContainer, textContainer.size.width > 0 else { return Self.lineHeight }
        layoutManager.ensureLayout(for: textContainer)
        // The extra line fragment is the empty line after a trailing newline
        // (or the only line of an empty field); `usedRect` can omit it.
        let bottom = max(layoutManager.usedRect(for: textContainer).maxY, layoutManager.extraLineFragmentRect.maxY)
        return max(ceil(bottom) + Self.insets.height * 2, Self.lineHeight)
    }

    /// Whether the text holds anything besides whitespace. Scans the backing
    /// store directly so a large paste is not copied into a `String` per keystroke.
    var hasNonBlankText: Bool {
        guard let storage = textStorage else { return false }
        return storage.mutableString.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted).location
            != NSNotFound
    }

    /// File drags are handled by the chat pane's drop destination (as
    /// attachments), so the text view must not claim them and insert paths.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let fileTypes: Set<NSPasteboard.PasteboardType> = [
            .fileURL, .tiff, .png, .pdf, .rtfd,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ]
        return super.acceptableDragTypes.filter { !fileTypes.contains($0) }
    }

    override func paste(_ sender: Any?) {
        if attachmentPasteHandler?() == true { return }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !event.modifierFlags.contains(.shift), !hasMarkedText(), let handler = returnHandler, handler() {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Intercept Cmd+V here because the standard NSTextView key equivalent
        // handling skips `paste:` when the pasteboard has no text content
        // (e.g. a copied screenshot that only has image data). We check for
        // attachments first; if found, consume. Otherwise let super handle the
        // normal text paste.
        if event.type == .keyDown,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.keyCode == 9,
            attachmentPasteHandler?() == true
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
