// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// The chat area below the header: the message list, its overlays, a separator
/// and the input bar, laid out by hand in a single pass.
///
/// Having one view own both the list and the input is what makes growing the
/// input feel right. Each animation frame sets the bar's new height and the
/// list's remaining height together, so the conversation slides up in lockstep
/// with the bar instead of being resized a frame later by a separate layout
/// system (influenced by the input in Telegram's macOS client). The height
/// is a retargetable tween, so typing mid-animation redirects it smoothly.
/// The strip of queued messages above the bar grows and shrinks the same way.
final class ChatPaneView: NSView {
    static let barInsets = NSSize(width: 12, height: 10)
    /// Space between the queue strip and the bar.
    static let queueGap: CGFloat = 6
    static let animationDuration: CFTimeInterval = 0.2

    /// The tallest the bar may grow: a share of the pane, but never less than
    /// five lines.
    static func maxBarHeight(paneHeight: CGFloat) -> CGFloat {
        max(ChatInputBarView.height(forLines: 5), (paneHeight * 0.4).rounded(.down))
    }

    let listView: ChatListView
    let inputBar: ChatInputBarView
    let queueView: QueuedMessagesView

    private let separator = NSBox()
    private var loadingCover: LoadingCoverView?
    private var treeHost: PaneHostingView?
    private var searchHost: PaneHostingView?

    private var tween = ValueTween(value: ChatInputBarView.minHeight)
    /// Height of the queue strip plus its gap; zero while nothing is queued.
    private var queueTween = ValueTween(value: 0)
    private var displayLink: CADisplayLink?

    init(listView: ChatListView, inputBar: ChatInputBarView, queueView: QueuedMessagesView = QueuedMessagesView()) {
        self.listView = listView
        self.inputBar = inputBar
        self.queueView = queueView
        super.init(frame: .zero)
        separator.boxType = .separator
        addSubview(listView)
        addSubview(separator)
        addSubview(inputBar)
        addSubview(queueView)
        inputBar.onHeightInvalidated = { [weak self] animated in self?.syncInputHeight(animated: animated) }
        queueView.onHeightInvalidated = { [weak self] animated in self?.syncQueueHeight(animated: animated) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Overlays

    /// Opaque cover over the list while a chat is still loading.
    func setLoading(_ loading: Bool) {
        if loading, loadingCover == nil {
            let cover = LoadingCoverView()
            addSubview(cover, positioned: .above, relativeTo: listView)
            loadingCover = cover
            needsLayout = true
        } else if !loading, let cover = loadingCover {
            cover.removeFromSuperview()
            loadingCover = nil
        }
    }

    /// Shows `view` over the list (and any loading cover), or removes it for nil.
    func setTreeOverview(_ view: AnyView?) {
        guard let view else {
            treeHost?.removeFromSuperview()
            treeHost = nil
            return
        }
        if let treeHost {
            treeHost.rootView = view
            return
        }
        let host = PaneHostingView(rootView: view)
        addSubview(host, positioned: .above, relativeTo: loadingCover ?? listView)
        treeHost = host
        needsLayout = true
    }

    /// Shows `view` floating at the list's top-right corner, or removes it for nil.
    func setSearchBar(_ view: AnyView?) {
        guard let view else {
            searchHost?.removeFromSuperview()
            searchHost = nil
            return
        }
        guard searchHost == nil else { return }
        // Transparent margin so the bar's shadow isn't clipped by the host.
        let host = PaneHostingView(rootView: AnyView(view.padding(Self.searchMargin)), sizesToContent: true)
        host.onContentSizeChange = { [weak self] in self?.needsLayout = true }
        addSubview(host, positioned: .above, relativeTo: treeHost ?? loadingCover ?? listView)
        searchHost = host
        needsLayout = true
    }

    private static let searchMargin: CGFloat = 10

    // MARK: Layout

    override func layout() {
        super.layout()
        let barWidth = max(0, bounds.width - Self.barInsets.width * 2)
        // Measure at the new width: wrapping, and so the height, depends on it.
        if inputBar.frame.width != barWidth {
            inputBar.setFrameSize(NSSize(width: barWidth, height: inputBar.frame.height))
            inputBar.layoutSubtreeIfNeeded()
        }
        syncInputHeight(animated: false, layingOut: true)
        syncQueueHeight(animated: false, layingOut: true)
        applyFrames()
    }

    /// Recomputes the bar's target height and starts (or redirects) the
    /// animation toward it, or snaps when `animated` is false.
    private func syncInputHeight(animated: Bool, layingOut: Bool = false) {
        guard bounds.width > 0 else { return }
        let target = inputBar.preferredHeight(maxHeight: Self.maxBarHeight(paneHeight: bounds.height))
        guard target != tween.target else { return }
        if animated, canAnimate {
            tween.retarget(to: target, now: CACurrentMediaTime(), duration: Self.animationDuration)
            startDisplayLink()
        } else {
            tween.jump(to: target)
            if queueTween.isFinished { stopDisplayLink() }
        }
        if !layingOut {
            applyFrames()
            // Resize the text viewport now, before AppKit's own post-edit
            // scroll-to-caret can run against the stale, smaller one.
            inputBar.layoutSubtreeIfNeeded()
        }
    }

    /// Same as `syncInputHeight`, for the queue strip.
    private func syncQueueHeight(animated: Bool, layingOut: Bool = false) {
        let strip = queueView.preferredHeight
        let target = strip > 0 ? strip + Self.queueGap : 0
        guard target != queueTween.target else { return }
        if animated, canAnimate {
            queueTween.retarget(to: target, now: CACurrentMediaTime(), duration: Self.animationDuration)
            startDisplayLink()
        } else {
            queueTween.jump(to: target)
            if tween.isFinished { stopDisplayLink() }
        }
        if !layingOut { applyFrames() }
    }

    private var canAnimate: Bool {
        window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Sets every frame from the current bar height. Called once per
    /// animation frame, so keep it light: nothing here re-measures text.
    private func applyFrames() {
        let scale = window?.backingScaleFactor ?? 2
        let barHeight = (tween.value * scale).rounded() / scale
        let queueBlock = (queueTween.value * scale).rounded() / scale
        let regionHeight = barHeight + queueBlock + Self.barInsets.height * 2
        let width = bounds.width
        let listHeight = max(0, bounds.height - regionHeight - 1)

        inputBar.settledHeight = tween.target
        inputBar.frame = NSRect(
            x: Self.barInsets.width, y: Self.barInsets.height,
            width: max(0, width - Self.barInsets.width * 2), height: barHeight)
        queueView.frame = NSRect(
            x: Self.barInsets.width, y: Self.barInsets.height + barHeight + Self.queueGap,
            width: max(0, width - Self.barInsets.width * 2), height: max(0, queueBlock - Self.queueGap))
        separator.frame = NSRect(x: 0, y: regionHeight, width: width, height: 1)
        let listFrame = NSRect(x: 0, y: regionHeight + 1, width: width, height: listHeight)
        listView.frame = listFrame
        loadingCover?.frame = listFrame
        treeHost?.frame = listFrame
        if let searchHost {
            let size = searchHost.fittingSize
            searchHost.frame = NSRect(
                x: listFrame.maxX - size.width - (18 - Self.searchMargin),
                y: listFrame.maxY - size.height - (10 - Self.searchMargin),
                width: size.width, height: size.height)
        }
    }

    // MARK: Animation

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        tween.advance(now: now)
        queueTween.advance(now: now)
        applyFrames()
        if tween.isFinished, queueTween.isFinished { stopDisplayLink() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopDisplayLink()
            tween.jump(to: tween.target)
            queueTween.jump(to: queueTween.target)
        }
    }

    // MARK: Test hooks

    var currentBarHeight: CGFloat { tween.value }
    var targetBarHeight: CGFloat { tween.target }
    var isAnimatingHeight: Bool { displayLink != nil }
}

/// A SwiftUI host placed by hand. Frames are set by the pane, so it must not
/// push size constraints into the window; hosts that size to their content
/// report when that size changes so the pane can reposition them.
private final class PaneHostingView: NSHostingView<AnyView> {
    var onContentSizeChange: (() -> Void)?

    convenience init(rootView: AnyView, sizesToContent: Bool = false) {
        self.init(rootView: rootView)
        sizingOptions = sizesToContent ? [.intrinsicContentSize] : []
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) { fatalError() }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentSizeChange?()
    }
}

/// Opaque placeholder shown over the list while its chat loads.
private final class LoadingCoverView: NSView {
    private let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        spinner.sizeToFit()
        spinner.frame.origin = NSPoint(
            x: bounds.midX - spinner.frame.width / 2, y: bounds.midY - spinner.frame.height / 2)
    }

    // Swallow clicks so the list underneath isn't interactive while covered.
    override func mouseDown(with event: NSEvent) {}
}
