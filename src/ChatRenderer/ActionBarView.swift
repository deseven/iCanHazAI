import AppKit

/// Copy / Regenerate / branch switcher / Edit / Delete. A row has two: the
/// header's (shown on hover) and the bottom one (shown when the header has
/// scrolled out of view).
final class ActionBarView: FlippedView {
    var onEvent: ((RowEvent) -> Void)?
    private(set) var contentWidth: CGFloat = 0

    private var messageID = ""
    private let copyButton = NSButton()
    private let regenerateButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let counter = NSTextField(labelWithString: "")
    private let editButton = NSButton()
    private let deleteButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUp(copyButton, symbol: "doc.on.doc", tip: "Copy", action: #selector(copyTapped))
        setUp(
            regenerateButton, symbol: "arrow.counterclockwise", tip: "Regenerate", action: #selector(regenerateTapped))
        setUp(previousButton, symbol: "chevron.left", tip: "Previous sibling", action: #selector(previousTapped))
        setUp(nextButton, symbol: "chevron.right", tip: "Next sibling", action: #selector(nextTapped))
        setUp(editButton, symbol: "square.and.pencil", tip: "Edit", action: #selector(editTapped))
        setUp(deleteButton, symbol: "trash", tip: "Delete", action: #selector(deleteTapped))
        deleteButton.contentTintColor = .systemRed.withAlphaComponent(0.85)
        counter.textColor = .secondaryLabelColor
        addSubview(counter)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        addSubview(button)
    }

    func configure(model: ChatRowModel, canRegenerate: Bool, streaming: Bool, theme: Theme) {
        messageID = model.id
        let s = theme.scale
        let buttonWidth = 24 * s
        let height = theme.scaled(20)
        let symbolSize = theme.scaled(13)
        for b in [copyButton, regenerateButton, previousButton, nextButton, editButton, deleteButton] {
            b.image = b.image?.withSymbolConfiguration(.init(pointSize: symbolSize, weight: .regular))
        }
        counter.font = .monospacedDigitSystemFont(ofSize: theme.scaled(11), weight: .regular)
        counter.stringValue = model.siblings.map { "\($0.index + 1)/\($0.count)" } ?? ""
        counter.sizeToFit()

        regenerateButton.isHidden = !canRegenerate
        let showsSwitcher = model.hasSiblings
        previousButton.isHidden = !showsSwitcher
        nextButton.isHidden = !showsSwitcher
        counter.isHidden = !showsSwitcher
        previousButton.isEnabled = !streaming
        nextButton.isEnabled = !streaming

        var x: CGFloat = 0
        func place(_ v: NSView, width: CGFloat) {
            v.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width
        }
        place(copyButton, width: buttonWidth)
        if canRegenerate { place(regenerateButton, width: buttonWidth) }
        if showsSwitcher {
            place(previousButton, width: buttonWidth * 0.8)
            let w = ceil(counter.frame.width) + 4 * s
            counter.frame = NSRect(
                x: x, y: (height - counter.frame.height) / 2, width: w, height: counter.frame.height)
            counter.alignment = .center
            x += w
            place(nextButton, width: buttonWidth * 0.8)
        }
        place(editButton, width: buttonWidth)
        place(deleteButton, width: buttonWidth)
        contentWidth = x
        frame.size = NSSize(width: x, height: height)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        for case let button as NSButton in subviews where !button.isHidden && button.isEnabled {
            addCursorRect(button.frame, cursor: .pointingHand)
        }
    }

    @objc private func copyTapped() { onEvent?(.action(.copy(messageID: messageID))) }
    @objc private func regenerateTapped() { onEvent?(.action(.regenerate(messageID: messageID))) }
    @objc private func previousTapped() { onEvent?(.action(.switchBranch(messageID: messageID, direction: -1))) }
    @objc private func nextTapped() { onEvent?(.action(.switchBranch(messageID: messageID, direction: 1))) }
    @objc private func editTapped() { onEvent?(.action(.edit(messageID: messageID))) }
    @objc private func deleteTapped() { onEvent?(.action(.delete(messageID: messageID))) }
}
