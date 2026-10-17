import AppKit
import QuickLookUI

/// A virtualized message list: NSScrollView + a flipped document view whose
/// height is the sum of per-row heights. Only rows near the viewport get views.
///
/// Heights start as estimates and become exact as rows are rendered and
/// measured — synchronously for rows entering the viewport, and in a
/// concurrent background pass for everything else. Whenever heights change,
/// the scroll position is corrected so the content under the viewport stays
/// put (or stays pinned to the bottom).
@MainActor
final class ChatListView: NSView {
    /// Interface scale as a percentage (100 = unscaled). Changing it drops every
    /// rendered string and measured height.
    var interfaceScale: Double = 100 {
        didSet {
            let new = Theme(scale: CGFloat(interfaceScale / 100))
            if new != theme { applyTheme(new) }
        }
    }

    /// Chat-wide inputs: role, features, streaming, preferences, attachment location.
    var context = ChatRowContext() {
        didSet { contextChanged(from: oldValue) }
    }

    /// Called when the user asks for something only the host can do.
    var onAction: ((ChatRowAction) -> Void)?

    /// Called (coalesced, on a later main-actor turn) when the list becomes
    /// pinned to the bottom or stops being so.
    var onPinnedChange: ((Bool) -> Void)?

    /// Called whenever the number of matches or the current one changes.
    var onSearchChange: ((ChatSearchStatus) -> Void)?

    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private let jumpButton = NSButton()

    private var theme = Theme()
    private var rowLayout: RowLayout { RowLayout(theme: theme) }

    private var rows: [RowState] = []
    private var indexByID: [String: Int] = [:]
    /// `offsets[i]` is the top of row `i`; the last element is the bottom of the last row.
    private var offsets: [CGFloat] = [RowLayout(theme: Theme()).listPadTop]
    private var visibleViews: [String: MessageRowView] = [:]
    private var pool: [MessageRowView] = []
    /// Collapsible blocks the user flipped away from their default state.
    private var toggled: Set<String> = []
    private var contextVersion = 0

    private var openPolicy: OpenPolicy {
        OpenPolicy(toolsByDefault: context.expandToolUse, toggled: toggled)
    }

    /// Rows holding a rendered string, oldest first. Everything else keeps only
    /// heights; re-rendering a row is far cheaper than retaining all of them.
    private var renderedLRU: [RowState] = []
    private let renderedLimit = 300

    private var columnWidth: CGFloat = 0
    private var textWidth: CGFloat = 0
    private var columnX: CGFloat = 0
    private var pinnedToBottom = true {
        didSet { if pinnedToBottom != oldValue { schedulePinnedReport() } }
    }
    private var reportedPinned = true
    private var pinnedReportScheduled = false
    private var adjusting = false
    private let pass = PassToken()
    private var pendingPass: Task<Void, Never>?
    private var previewURLs: [URL] = []

    private let searchIndex = ChatSearchIndex()
    private var searchTask: Task<Void, Never>?
    private var searchScheduled = false
    private var searchRevealPending = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)

        jumpButton.bezelStyle = .circular
        jumpButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "Scroll to bottom")
        jumpButton.target = self
        jumpButton.action = #selector(jumpToBottom)
        jumpButton.isHidden = true
        addSubview(jumpButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Public API

    /// Replaces everything, including the chat-wide inputs, without invalidating
    /// the rows being replaced.
    func setMessages(_ messages: [ChatRowModel], context newContext: ChatRowContext) {
        if context != newContext {
            setMessages([])
            context = newContext
        }
        setMessages(messages)
    }

    func setMessages(_ messages: [ChatRowModel]) {
        for v in visibleViews.values { recycle(v) }
        visibleViews.removeAll()
        toggled.removeAll()
        renderedLRU.removeAll()
        rows = messages.map(makeRow)
        rebuildIndex()
        recomputeOffsets()
        pinnedToBottom = true
        updateJumpButton()
        scheduleSearch(delay: .zero)
        guard textWidth > 0 else { return }
        measureTail()
        scrollToBottom()
        layoutRows()
        startBackgroundPass()
    }

    func append(_ model: ChatRowModel) {
        let row = makeRow(model)
        indexByID[model.id] = rows.count
        rows.append(row)
        offsets.append(offsets[offsets.count - 1] + row.height)
        let i = rows.count - 1
        applyHeights([(i, ensureExact(i) ?? row.height)])
        layoutRows()
        scheduleSearch()
    }

    func insert(_ model: ChatRowModel, at index: Int) {
        guard index < rows.count else { return append(model) }
        let anchor = captureAnchor()
        rows.insert(makeRow(model), at: max(index, 0))
        rebuildIndex()
        recomputeOffsets()
        restore(anchor)
        layoutRows()
        schedulePass()
        scheduleSearch()
    }

    func update(_ model: ChatRowModel) {
        guard let i = indexByID[model.id], rows[i].model != model else { return }
        let row = rows[i]
        row.model = model
        row.version += 1
        row.rendered = nil
        row.heights = []
        row.measuredWidth = -1
        if let h = ensureExact(i) { applyHeights([(i, h)]) }
        layoutRows()
        scheduleSearch()
    }

    func delete(id: String) {
        guard let i = indexByID[id] else { return }
        var anchor = captureAnchor()
        let removed = rows.remove(at: i)
        renderedLRU.removeAll { $0 === removed }
        toggled = toggled.filter { !$0.hasPrefix(id + "/") }
        if let v = visibleViews.removeValue(forKey: id) { recycle(v) }
        rebuildIndex()
        recomputeOffsets()
        if anchor?.id == id, !rows.isEmpty {
            anchor = (rows[min(i, rows.count - 1)].model.id, 0)
        }
        restore(anchor)
        layoutRows()
        scheduleSearch()
    }

    /// Runs several edits as one, so the scroll position is settled once at the
    /// end. A row that was removed (a branch switch replaces a whole tail) hands
    /// the anchor to whatever now sits at its index.
    func performEdits(_ body: () -> Void) {
        guard !rows.isEmpty else { return body() }
        let top = scrollView.documentVisibleRect.minY
        let index = rowIndex(atY: top)
        let anchor = captureAnchor()
        body()
        guard var anchor, !rows.isEmpty else { return }
        if indexByID[anchor.id] == nil { anchor.id = rows[min(index, rows.count - 1)].model.id }
        restore(anchor)
        layoutRows()
        updateJumpButton()
    }

    func scrollToTop() {
        pinnedToBottom = false
        setScrollY(0)
        layoutRows()
        updateJumpButton()
    }

    @objc func jumpToBottom() {
        pinnedToBottom = true
        measureTail()
        scrollToBottom()
        layoutRows()
        updateJumpButton()
    }

    /// Scrolls so the message sits near the top of the viewport and flashes it.
    /// Works for rows that haven't been measured yet: the rows around the
    /// target are measured as they enter the viewport, and anchoring keeps the
    /// target where it was put.
    func scrollToMessage(id: String) {
        guard textWidth > 0, let i = indexByID[id] else { return }
        pinnedToBottom = false
        for _ in 0..<2 {
            if let h = ensureExact(i) { applyHeights([(i, h)]) }
            setScrollY(offsets[i] - rowLayout.blockGap)
            layoutRows()
        }
        updateJumpButton()
        visibleViews[id]?.flash()
    }

    // MARK: Search

    /// Sets the text to look for; empty clears the highlights. A new query
    /// scrolls to its first match at or after the current position.
    func setSearchQuery(_ query: String) {
        guard searchIndex.setQuery(query) else { return }
        if query.isEmpty {
            searchTask?.cancel()
            searchScheduled = false
            searchRevealPending = false
            applySearchHighlights()
            reportSearch()
        } else {
            scheduleSearch(reveal: true, delay: .zero)
        }
    }

    /// Moves to the next (1) or previous (-1) match, wrapping around.
    func stepSearch(_ direction: Int) {
        guard searchIndex.isActive, !searchIndex.matches.isEmpty else { return }
        searchIndex.step(direction)
        applySearchHighlights()
        reportSearch()
        if let match = searchIndex.currentMatch { revealSearchMatch(match) }
    }

    private func reportSearch() {
        onSearchChange?(searchIndex.status)
    }

    private func applySearchHighlights() {
        for (id, v) in visibleViews { v.search = searchIndex.highlight(forRow: id) }
    }

    /// Rescans soon. Changes arriving before the scan starts share it, which also
    /// caps the rescan rate while a reply streams in.
    private func scheduleSearch(reveal: Bool = false, delay: Duration = .milliseconds(120)) {
        guard searchIndex.isActive else { return }
        searchRevealPending = searchRevealPending || reveal
        guard !searchScheduled else { return }
        searchScheduled = true
        searchTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.searchScheduled = false
            await self.runSearch()
        }
    }

    private func runSearch() async {
        guard searchIndex.isActive else { return }
        let reveal = searchRevealPending
        searchRevealPending = false
        let inputs = rows.compactMap { row -> SearchRowInput? in
            ChatSearch.isSearchable(row.model) ? SearchRowInput(id: row.model.id, content: row.model.content) : nil
        }
        let applied = await searchIndex.refresh(
            inputs: inputs, theme: theme, rowIndex: indexByID, anchor: searchAnchor())
        guard applied else {
            searchRevealPending = searchRevealPending || reveal
            return
        }
        applySearchHighlights()
        reportSearch()
        if reveal, let match = searchIndex.currentMatch { revealSearchMatch(match) }
    }

    /// Where the next current match is looked for: the current match itself if
    /// it still exists, else the top of the viewport.
    private func searchAnchor() -> (row: Int, location: Int) {
        if let m = searchIndex.currentMatch, let i = indexByID[m.rowID] { return (i, m.range.location) }
        return (rowIndex(atY: scrollView.documentVisibleRect.minY), 0)
    }

    /// Brings a match into view, centered unless it's already comfortably visible.
    /// Rows far away are first scrolled to (measuring as they come into view)
    /// so the match's position inside the row can be read from its text view.
    private func revealSearchMatch(_ match: SearchMatch) {
        guard textWidth > 0, let i = indexByID[match.rowID] else { return }
        func matchRect() -> NSRect? {
            guard let view = visibleViews[match.rowID], let r = view.rect(ofSearchRange: match.range) else {
                return nil
            }
            return document.convert(r, from: view)
        }
        func comfortable(_ r: NSRect) -> Bool {
            let v = scrollView.documentVisibleRect
            return r.minY >= v.minY + searchTopMargin && r.maxY <= v.maxY - 24
        }
        if let r = matchRect(), comfortable(r) { return }
        pinnedToBottom = false
        for _ in 0..<2 {
            if let h = ensureExact(i) { applyHeights([(i, h)]) }
            setScrollY(offsets[i] - rowLayout.blockGap)
            layoutRows()
        }
        if let r = matchRect() {
            let height = scrollView.documentVisibleRect.height
            setScrollY(min(r.midY - height / 2, r.minY - searchTopMargin - 20))
            layoutRows()
        }
        pinnedToBottom = documentHeight - scrollView.contentView.bounds.maxY < 30
        updateJumpButton()
    }

    /// Room kept clear at the top of the viewport for the search bar floating over it.
    private var searchTopMargin: CGFloat { 56 }

    // MARK: Layout

    override func layout() {
        super.layout()
        let first = columnWidth == 0
        if updateColumn() {
            if first, !rows.isEmpty { measureTail() }
            schedulePass()
        }
        withAdjusting { document.setFrameSize(NSSize(width: bounds.width, height: documentHeight)) }
        if pinnedToBottom { scrollToBottom() }
        layoutRows()
        updateJumpButton()
        jumpButton.frame = NSRect(x: bounds.maxX - 32 - 20, y: 14, width: 32, height: 32)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        schedulePass()
    }

    /// Returns whether the text width changed.
    private func updateColumn() -> Bool {
        let column = rowLayout.column(forListWidth: bounds.width)
        columnX = floor((bounds.width - column) / 2)
        guard column != columnWidth else { return false }
        columnWidth = column
        textWidth = rowLayout.textWidth(column: column)
        return true
    }

    private var documentHeight: CGFloat { offsets[offsets.count - 1] + rowLayout.listPadBottom }

    private func makeRow(_ model: ChatRowModel) -> RowState {
        RowState(model, estimatedHeight: rowLayout.estimate(model, width: textWidth))
    }

    private func rebuildIndex() {
        indexByID = Dictionary(rows.enumerated().map { ($1.model.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func recomputeOffsets() {
        offsets = [CGFloat](repeating: 0, count: rows.count + 1)
        var y = rowLayout.listPadTop
        for (i, r) in rows.enumerated() {
            offsets[i] = y
            y += r.height
        }
        offsets[rows.count] = y
    }

    private func rowIndex(atY y: CGFloat) -> Int {
        var lo = 0
        var hi = rows.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offsets[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return max(lo, 0)
    }

    private func visibleRange() -> ClosedRange<Int>? {
        guard !rows.isEmpty else { return nil }
        let r = scrollView.documentVisibleRect
        let overscan = max(r.height * 0.75, 300)
        let lo = rowIndex(atY: r.minY - overscan)
        let hi = rowIndex(atY: r.maxY + overscan)
        return lo...hi
    }

    /// Renders and measures row `i` if needed; returns its new height when it changed.
    private func ensureExact(_ i: Int) -> CGFloat? {
        let row = rows[i]
        let layout = rowLayout
        let rendered: RenderedMessage
        if let existing = row.rendered {
            rendered = existing
        } else {
            rendered = RenderedMessage.render(row.model, theme: theme, streaming: context.isStreaming)
            row.rendered = rendered
            renderedLRU.append(row)
            if renderedLRU.count > renderedLimit * 2 { evictRendered() }
        }
        if row.measuredWidth != textWidth {
            row.heights = []
            row.measuredWidth = textWidth
        }
        let open = openPolicy.mask(for: rendered)
        row.heights = layout.measure(rendered, width: textWidth, existing: row.heights, open: open)
        let h = layout.height(rendered, heights: row.heights, open: open)
        return h != row.height ? h : nil
    }

    private func layoutRows() {
        guard textWidth > 0, var range = visibleRange() else {
            for v in visibleViews.values { recycle(v) }
            visibleViews.removeAll()
            return
        }
        // Measuring can shift the visible range (anchor corrections), so settle it.
        for _ in 0..<4 {
            var changes: [(Int, CGFloat)] = []
            for i in range { if let h = ensureExact(i) { changes.append((i, h)) } }
            if changes.isEmpty { break }
            applyHeights(changes)
            range = visibleRange() ?? range
        }

        var keep = Set<String>()
        let layout = rowLayout
        let policy = openPolicy
        let visibleTop = scrollView.documentVisibleRect.minY
        for i in range {
            let row = rows[i]
            let id = row.model.id
            keep.insert(id)
            let view = visibleViews[id] ?? dequeue()
            visibleViews[id] = view
            let frame = NSRect(x: columnX, y: offsets[i], width: columnWidth, height: row.height)
            if view.frame != frame { view.frame = frame }
            view.configure(
                row, context: context, isFirst: i == 0, textWidth: textWidth,
                open: row.rendered.map(policy.mask) ?? [], layout: layout, contextVersion: contextVersion)
            view.search = searchIndex.highlight(forRow: id)
            let headerBottom = offsets[i] + layout.top + layout.header
            view.showsBottomActions = headerBottom <= visibleTop && offsets[i + 1] > visibleTop
        }
        for (id, v) in visibleViews where !keep.contains(id) {
            recycle(v)
            visibleViews[id] = nil
        }
        updateHover()
    }

    private func evictRendered() {
        let keep = Set(visibleViews.keys)
        var kept: [RowState] = []
        let excess = renderedLRU.count - renderedLimit
        for (n, row) in renderedLRU.enumerated() {
            if n < excess, !keep.contains(row.model.id) {
                row.rendered = nil
            } else {
                kept.append(row)
            }
        }
        renderedLRU = kept
    }

    private func hasToggled(_ row: RowState) -> Bool {
        let prefix = row.model.id + "/"
        return toggled.contains { $0.hasPrefix(prefix) }
    }

    /// Invalidates whatever the changed context affects: heights of rows whose
    /// blocks depend on a preference or on the streaming flag; everything else
    /// only reconfigures its view.
    private func contextChanged(from old: ChatRowContext) {
        guard context != old else { return }
        contextVersion += 1

        let toolsChanged = old.expandToolUse != context.expandToolUse
        let streamingChanged = old.isStreaming != context.isStreaming
        var invalidated = false
        if toolsChanged || streamingChanged {
            for row in rows {
                let m = row.model
                let opens = toolsChanged && !m.toolCalls.isEmpty
                let streams = streamingChanged && m.dependsOnStreaming
                guard opens || streams else { continue }
                if streams {
                    row.rendered = nil
                    row.version += 1
                }
                row.heights = []
                row.measuredWidth = -1
                invalidated = true
            }
        }
        guard textWidth > 0 else { return }
        if invalidated {
            pendingPass?.cancel()
            _ = pass.next()
            if pinnedToBottom { measureTail() }
        }
        layoutRows()
        if invalidated { schedulePass() }
    }

    // MARK: Scroll anchoring

    /// The row under the viewport's top edge and the offset of the edge from the row's top.
    private func captureAnchor() -> (id: String, delta: CGFloat)? {
        guard !rows.isEmpty else { return nil }
        let top = scrollView.documentVisibleRect.minY
        let i = rowIndex(atY: top)
        return (rows[i].model.id, top - offsets[i])
    }

    private func restore(_ anchor: (id: String, delta: CGFloat)?) {
        withAdjusting { document.setFrameSize(NSSize(width: bounds.width, height: documentHeight)) }
        if pinnedToBottom {
            scrollToBottom()
        } else if let anchor, let i = indexByID[anchor.id] {
            setScrollY(offsets[i] + anchor.delta)
        }
    }

    /// Applies height changes while keeping the first visible row's top edge
    /// fixed on screen (or keeping the list pinned to the bottom).
    private func applyHeights(_ changes: [(Int, CGFloat)]) {
        guard !changes.isEmpty, !rows.isEmpty else { return }
        let anchor = captureAnchor()
        for (i, h) in changes { rows[i].height = h }
        recomputeOffsets()
        restore(anchor)
    }

    private func applyTheme(_ new: Theme) {
        let anchor = captureAnchor()
        let ratio = new.scale / theme.scale
        theme = new
        pendingPass?.cancel()
        _ = pass.next()
        for v in visibleViews.values { recycle(v) }
        visibleViews.removeAll()
        renderedLRU.removeAll()
        for row in rows {
            row.rendered = nil
            row.heights = []
            row.measuredWidth = -1
            row.version += 1
        }
        _ = updateColumn()
        let layout = rowLayout
        for row in rows { row.height = layout.estimate(row.model, width: textWidth) }
        recomputeOffsets()
        if textWidth > 0, pinnedToBottom { measureTail() }
        restore(anchor.map { ($0.id, $0.delta * ratio) })
        layoutRows()
        schedulePass()
    }

    private func measureTail() {
        guard textWidth > 0, !rows.isEmpty else { return }
        let target = max(scrollView.contentView.bounds.height, 600) * 1.75
        var acc: CGFloat = 0
        var changes: [(Int, CGFloat)] = []
        var i = rows.count - 1
        while i >= 0, acc < target {
            if let h = ensureExact(i) {
                changes.append((i, h))
                acc += h
            } else {
                acc += rows[i].height
            }
            i -= 1
        }
        for (i, h) in changes { rows[i].height = h }
        recomputeOffsets()
        withAdjusting { document.setFrameSize(NSSize(width: bounds.width, height: documentHeight)) }
    }

    private func scrollToBottom() {
        setScrollY(max(0, documentHeight - scrollView.contentView.bounds.height))
    }

    private func setScrollY(_ y: CGFloat) {
        withAdjusting {
            let clip = scrollView.contentView
            let maxY = max(0, documentHeight - clip.bounds.height)
            clip.setBoundsOrigin(NSPoint(x: 0, y: min(max(0, y), maxY)))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private func withAdjusting(_ body: () -> Void) {
        let was = adjusting
        adjusting = true
        body()
        adjusting = was
    }

    @objc private func boundsChanged() {
        guard !adjusting else { return }
        let clip = scrollView.contentView
        pinnedToBottom = documentHeight - clip.bounds.maxY < 30
        updateJumpButton()
        layoutRows()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredID = nil
        applyHover()
    }

    private var hoveredID: String?

    private func updateHover() {
        hoveredID = nil
        if let window, window.isKeyWindow, !rows.isEmpty {
            let p = document.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if scrollView.documentVisibleRect.contains(p), p.x >= columnX, p.x <= columnX + columnWidth {
                let i = rowIndex(atY: p.y)
                if p.y >= offsets[i], p.y < offsets[i + 1] { hoveredID = rows[i].model.id }
            }
        }
        applyHover()
    }

    private func applyHover() {
        for (id, v) in visibleViews { v.isHovered = id == hoveredID }
    }

    private func updateJumpButton() {
        jumpButton.isHidden = pinnedToBottom
    }

    private func schedulePinnedReport() {
        guard !pinnedReportScheduled else { return }
        pinnedReportScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            pinnedReportScheduled = false
            guard pinnedToBottom != reportedPinned else { return }
            reportedPinned = pinnedToBottom
            onPinnedChange?(pinnedToBottom)
        }
    }

    private func dequeue() -> MessageRowView {
        if let v = pool.popLast() {
            v.isHidden = false
            return v
        }
        let v = MessageRowView()
        v.onEvent = { [weak self] event in self?.handle(event) }
        document.addSubview(v)
        return v
    }

    private func handle(_ event: RowEvent) {
        switch event {
        case .action(let action): onAction?(action)
        case .toggle(let key): toggle(key)
        case .collapse(let key): collapse(key)
        case .openAttachment(let info): openAttachment(info)
        case .previewAttachment(let messageID, let filename):
            previewAttachment(messageID: messageID, filename: filename)
        }
    }

    private func recycle(_ v: MessageRowView) {
        v.isHidden = true
        v.isHovered = false
        v.search = nil
        v.cancelFlash()
        pool.append(v)
    }

    /// The rendered collapsible block with this key (`messageID/...`).
    private func collapsibleBlock(_ key: String) -> (row: Int, block: Int, value: CollapsibleBlock)? {
        guard let id = key.split(separator: "/").first.map(String.init), let i = indexByID[id],
            let rendered = rows[i].rendered
        else { return nil }
        for (b, block) in rendered.blocks.enumerated() {
            if case .collapsible(let c) = block, c.key == key { return (i, b, c) }
        }
        return nil
    }

    private func toggle(_ key: String) {
        guard let found = collapsibleBlock(key), !found.value.forcedOpen else { return }
        setOpen(key, !openPolicy.isOpen(found.value))
    }

    /// Expanding or collapsing keeps the row's top edge where it is, so the
    /// header that was clicked stays under the cursor.
    private func setOpen(_ key: String, _ open: Bool) {
        guard let found = collapsibleBlock(key), !found.value.forcedOpen, openPolicy.isOpen(found.value) != open
        else { return }
        if toggled.contains(key) { toggled.remove(key) } else { toggled.insert(key) }
        let i = found.row
        let wasPinned = pinnedToBottom
        pinnedToBottom = false
        if let h = ensureExact(i) { applyHeights([(i, h)]) }
        pinnedToBottom = wasPinned && documentHeight - scrollView.contentView.bounds.maxY < 30
        layoutRows()
    }

    /// Collapsing from the link at a block's bottom: bring the block's header
    /// into view if it's above the viewport.
    private func collapse(_ key: String) {
        guard let found = collapsibleBlock(key) else { return }
        setOpen(key, false)
        guard let rendered = rows[found.row].rendered else { return }
        let layout = rowLayout
        let frames = layout.blockFrames(
            rendered, heights: rows[found.row].heights, open: openPolicy.mask(for: rendered)
        ).frames
        let y = offsets[found.row] + frames[found.block].y
        guard y < scrollView.documentVisibleRect.minY else { return }
        pinnedToBottom = false
        setScrollY(y - layout.blockGap)
        layoutRows()
        updateJumpButton()
    }

    // MARK: Attachments

    private func attachmentURL(_ info: ChatRowModel.AttachmentInfo) -> URL? {
        guard let directory = context.attachmentsDirectory else { return nil }
        let url = directory.appendingPathComponent(info.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func openAttachment(_ info: ChatRowModel.AttachmentInfo) {
        guard let url = attachmentURL(info) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Shows the message's previewable attachments in the shared Quick Look panel. The panel is
    /// driven directly through its data source rather than the responder chain
    /// (`acceptsPreviewPanelControl`), which never presented in the real window.
    private func previewAttachment(messageID: String, filename: String) {
        guard let i = indexByID[messageID] else { return }
        let urls = rows[i].model.attachments
            .filter { QuickLookSupport.canPreview(filename: $0.filename, kind: $0.kind) }
            .compactMap { attachmentURL($0) }
        guard let start = urls.firstIndex(where: { $0.lastPathComponent == filename }) else { return }
        previewURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = start
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Background pass

    private func schedulePass() {
        pendingPass?.cancel()
        pendingPass = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, !self.inLiveResize else { return }
            self.startBackgroundPass()
        }
    }

    private struct PassInput: Sendable {
        let index: Int
        let version: Int
        let model: ChatRowModel
        let rendered: RenderedMessage?
        let heights: [CGFloat?]
    }

    private struct PassOutput: Sendable {
        let index: Int
        let version: Int
        let heights: [CGFloat?]
        let height: CGFloat
    }

    private func startBackgroundPass() {
        guard textWidth > 0, !rows.isEmpty else { return }
        let gen = pass.next()
        let width = textWidth
        let theme = theme
        let layout = rowLayout
        let center = rowIndex(atY: scrollView.documentVisibleRect.midY)
        let todo = rows.indices
            .filter { rows[$0].measuredWidth != width }
            .sorted { abs($0 - center) < abs($1 - center) }
            .map { i in
                let r = rows[i]
                return PassInput(
                    index: i, version: r.version, model: r.model, rendered: r.rendered,
                    heights: r.measuredWidth == width ? r.heights : [])
            }
        guard !todo.isEmpty else { return }
        let policy = openPolicy
        let streaming = context.isStreaming
        let token = pass
        DispatchQueue.global(qos: .userInitiated).async {
            let chunkSize = 128
            var start = 0
            while start < todo.count, token.current == gen {
                let chunk = Array(todo[start..<min(start + chunkSize, todo.count)])
                let slots = ResultSlots<PassOutput>(count: chunk.count)
                DispatchQueue.concurrentPerform(iterations: chunk.count) { k in
                    autoreleasepool {
                        let input = chunk[k]
                        let rendered =
                            input.rendered ?? RenderedMessage.render(input.model, theme: theme, streaming: streaming)
                        let open = policy.mask(for: rendered)
                        let heights = layout.measure(
                            rendered, width: width, existing: input.heights, open: open)
                        slots.set(
                            k,
                            PassOutput(
                                index: input.index, version: input.version, heights: heights,
                                height: layout.height(rendered, heights: heights, open: open)))
                    }
                }
                start += chunk.count
                let output = slots.collect()
                Task { @MainActor [weak self] in
                    self?.applyPass(output, gen: gen, width: width)
                }
            }
        }
    }

    private func applyPass(_ results: [PassOutput], gen: Int, width: CGFloat) {
        guard pass.current == gen, width == textWidth else { return }
        var changes: [(Int, CGFloat)] = []
        for r in results where r.index < rows.count {
            let row = rows[r.index]
            guard row.version == r.version, row.measuredWidth != width else { continue }
            row.heights = r.heights
            row.measuredWidth = width
            if hasToggled(row) {
                // Blocks may have been flipped after the snapshot; measure on demand.
                if let h = ensureExact(r.index) { changes.append((r.index, h)) }
            } else if r.height != row.height {
                changes.append((r.index, r.height))
            }
        }
        applyHeights(changes)
        layoutRows()
    }
}

extension ChatListView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { previewURLs[index] as NSURL }
    }
}

/// Fixed-size output buffer for `concurrentPerform`: every iteration writes a
/// distinct index, so no locking is needed.
private final class ResultSlots<T: Sendable>: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<T?>
    private let count: Int

    init(count: Int) {
        self.count = count
        buffer = .allocate(capacity: count)
        buffer.initialize(repeating: nil, count: count)
    }

    deinit {
        buffer.deinitialize(count: count)
        buffer.deallocate()
    }

    func set(_ index: Int, _ value: T) { buffer[index] = value }
    func collect() -> [T] { (0..<count).compactMap { buffer[$0] } }
}

/// Generation counter shared with the background pass; a pass stops as soon as
/// a newer one has started.
final class PassToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

#if DEBUG
    extension ChatListView {
        var testIsPinned: Bool { pinnedToBottom }
        var testRowCount: Int { rows.count }
        var testJumpButtonVisible: Bool { !jumpButton.isHidden }
        var testDocumentHeight: CGFloat { documentHeight }
        var testTextWidth: CGFloat { textWidth }
        var testExactCount: Int { rows.filter { $0.measuredWidth == textWidth }.count }
        var testDistanceFromBottom: CGFloat { documentHeight - scrollView.contentView.bounds.maxY }

        /// The row under the viewport's top edge and its top's position relative to that edge.
        func testAnchor() -> (id: String, y: CGFloat) {
            let top = scrollView.documentVisibleRect.minY
            let i = rowIndex(atY: top)
            return (rows[i].model.id, offsets[i] - top)
        }

        func testScroll(toRow i: Int) {
            pinnedToBottom = false
            setScrollY(offsets[i] - 40)
            layoutRows()
        }

        func testScreenY(of id: String) -> CGFloat? {
            guard let i = indexByID[id] else { return nil }
            return offsets[i] - scrollView.documentVisibleRect.minY
        }

        /// Checks that every visible row view sits exactly at its computed frame.
        func testViewsConsistent() -> Bool {
            visibleViews.allSatisfy { id, v in
                guard let i = indexByID[id] else { return false }
                return v.frame.minY == offsets[i] && v.frame.height == rows[i].height
                    && v.signature?.row == rows[i].uid
            }
        }

        func testScroll(by dy: CGFloat) {
            pinnedToBottom = false
            setScrollY(scrollView.documentVisibleRect.minY + dy)
            layoutRows()
            updateJumpButton()
        }

        func testBottomActionsVisible(of id: String) -> Bool? { visibleViews[id]?.showsBottomActions }
        func testToggle(_ key: String) { toggle(key) }
        func testCollapse(_ key: String) { collapse(key) }
        func testIsOpen(_ key: String) -> Bool? { collapsibleBlock(key).map { openPolicy.isOpen($0.value) } }
        func testHandle(_ event: RowEvent) { handle(event) }
        var testToggledKeys: Set<String> { toggled }
        func testHeight(of id: String) -> CGFloat? { indexByID[id].map { rows[$0].height } }
        var testVisibleIDs: Set<String> { Set(visibleViews.keys) }
        var testRowIDs: [String] { rows.map(\.model.id) }
        var testSearchStatus: ChatSearchStatus { searchIndex.status }
        var testSearchMatches: [SearchMatch] { searchIndex.matches }
        var testViewHighlight: [String: SearchHighlight] {
            visibleViews.compactMapValues { $0.search }
        }

        /// Whether the current match is inside the viewport (and clear of the search bar).
        var testCurrentMatchVisible: Bool {
            guard let m = searchIndex.currentMatch, let v = visibleViews[m.rowID],
                let r = v.rect(ofSearchRange: m.range)
            else { return false }
            let rect = document.convert(r, from: v)
            let visible = scrollView.documentVisibleRect
            return rect.minY >= visible.minY + searchTopMargin && rect.maxY <= visible.maxY
        }
    }
#endif
