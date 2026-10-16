import AppKit

/// Geometry of the list and its rows. Every metric follows the interface scale.
/// Fixed-size chrome (headers, buttons, thumbnails) is arithmetic; only text
/// goes through TextKit, and collapsed bodies are never measured.
struct RowLayout: Sendable {
    let theme: Theme

    struct Frame: Equatable {
        var y: CGFloat
        var height: CGFloat
        var maxY: CGFloat { y + height }
    }

    /// Where the parts of an expanded or collapsed collapsible block sit,
    /// relative to the block's top.
    struct CollapsibleGeometry: Equatable {
        var header: CGFloat
        var body: Frame
        var approvalY: CGFloat?
        var collapseLinkY: CGFloat?
        var total: CGFloat
    }

    var listPadTop: CGFloat { theme.scaled(12) }
    var listPadBottom: CGFloat { theme.scaled(24) }
    var hPad: CGFloat { theme.scaled(20) }
    var maxColumn: CGFloat { theme.scaled(860) }
    var rowInset: CGFloat { theme.scaled(14) }
    var top: CGFloat { theme.scaled(12) }
    var bottom: CGFloat { theme.scaled(8) }
    var header: CGFloat { theme.scaled(20) }
    var headerGap: CGFloat { theme.scaled(6) }
    var blockGap: CGFloat { theme.scaled(8) }
    var panelPad: CGFloat { theme.scaled(10) }

    /// Room for the action bar shown at the bottom of a row whose header has
    /// scrolled away. It is always reserved so showing it never moves anything.
    var actionBarGap: CGFloat { theme.scaled(2) }
    var actionBar: CGFloat { theme.scaled(20) }

    var collapsibleHeader: CGFloat { theme.scaled(28) }
    /// A collapsed tool block also shows its status on a second line.
    var collapsibleHeaderWithStatus: CGFloat { theme.scaled(46) }
    var pendingHeight: CGFloat { theme.scaled(22) }
    var segmentGap: CGFloat { theme.scaled(10) }
    var resultImageHeight: CGFloat { theme.scaled(240) }
    var approvalHeight: CGFloat { theme.scaled(52) }
    var collapseLinkHeight: CGFloat { theme.scaled(20) }
    /// Bodies at least this tall get a "collapse" link at their bottom.
    var collapseThreshold: CGFloat { theme.scaled(360) }

    var thumbnailSide: CGFloat { theme.scaled(256) }
    var thumbnailGap: CGFloat { theme.scaled(8) }
    var chipHeight: CGFloat { theme.scaled(26) }
    var chipGap: CGFloat { theme.scaled(6) }

    var errorIconWidth: CGFloat { theme.scaled(22) }
    var retryHeight: CGFloat { theme.scaled(26) }
    var retryGap: CGFloat { theme.scaled(8) }

    /// Everything of a row that isn't a block.
    var chrome: CGFloat { top + header + headerGap + actionBarGap + actionBar + bottom }

    func column(forListWidth width: CGFloat) -> CGFloat {
        floor(max(0, min(width - hPad * 2, maxColumn)))
    }

    func textWidth(column: CGFloat) -> CGFloat { column - rowInset * 2 }

    // MARK: Blocks

    func fittedThumbnailSide(width: CGFloat) -> CGFloat { max(1, min(thumbnailSide, width)) }

    func thumbnailsPerRow(width: CGFloat) -> Int {
        let side = fittedThumbnailSide(width: width)
        return max(1, Int((width + thumbnailGap) / (side + thumbnailGap)))
    }

    func attachmentsHeight(_ a: AttachmentsBlock, width: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        if !a.images.isEmpty {
            let perRow = thumbnailsPerRow(width: width)
            let rows = (a.images.count + perRow - 1) / perRow
            h += CGFloat(rows) * fittedThumbnailSide(width: width) + CGFloat(rows - 1) * thumbnailGap
        }
        if !a.documents.isEmpty {
            if h > 0 { h += thumbnailGap }
            h += CGFloat(a.documents.count) * chipHeight + CGFloat(a.documents.count - 1) * chipGap
        }
        return h
    }

    func errorTextWidth(_ width: CGFloat) -> CGFloat { width - panelPad * 2 - errorIconWidth }

    func errorHeight(text: CGFloat) -> CGFloat { panelPad * 2 + text + retryGap + retryHeight }

    struct BodyLayout: Equatable {
        var frames: [Frame]
        var total: CGFloat
    }

    /// Lays out the segments of a collapsible body; `width` is the body's own width.
    func bodyLayout(_ body: LazyBody, width: CGFloat) -> BodyLayout {
        var y: CGFloat = 0
        var frames: [Frame] = []
        for (i, segment) in body.segments.enumerated() {
            if i > 0 { y += segmentGap }
            let h: CGFloat =
                switch segment {
                case .text(let t): t.height(forWidth: width)
                case .image: resultImageHeight
                }
            frames.append(Frame(y: y, height: h))
            y += h
        }
        return BodyLayout(frames: frames, total: y)
    }

    func collapsible(_ c: CollapsibleBlock, open: Bool, bodyHeight: CGFloat?) -> CollapsibleGeometry {
        guard open else {
            let header = c.kind == .tool && c.status != nil ? collapsibleHeaderWithStatus : collapsibleHeader
            return CollapsibleGeometry(
                header: header, body: Frame(y: header, height: 0), approvalY: nil, collapseLinkY: nil, total: header)
        }
        let body = bodyHeight ?? 0
        var y = collapsibleHeader + body
        var approvalY: CGFloat?
        if c.hasApproval {
            if body > 0 { y += segmentGap }
            approvalY = y
            y += approvalHeight
        }
        var linkY: CGFloat?
        if body >= collapseThreshold, !c.forcedOpen {
            linkY = y
            y += collapseLinkHeight
        }
        return CollapsibleGeometry(
            header: collapsibleHeader, body: Frame(y: collapsibleHeader, height: body), approvalY: approvalY,
            collapseLinkY: linkY, total: y + panelPad)
    }

    func blockHeight(_ block: RenderedMessage.Block, measured: CGFloat?, open: Bool) -> CGFloat {
        switch block {
        case .pending: return pendingHeight
        case .attachments: return measured ?? 0
        case .text(_, let panel): return (measured ?? 0) + (panel ? panelPad * 2 : 0)
        case .error: return errorHeight(text: measured ?? 0)
        case .collapsible(let c): return collapsible(c, open: open, bodyHeight: measured).total
        }
    }

    /// Block frames relative to the row's top, and where the blocks end.
    func blockFrames(_ r: RenderedMessage, heights: [CGFloat?], open: [Bool]) -> (frames: [Frame], end: CGFloat) {
        var y = top + header + headerGap
        var frames: [Frame] = []
        frames.reserveCapacity(r.blocks.count)
        for (i, block) in r.blocks.enumerated() {
            if i > 0 { y += blockGap }
            let measured = i < heights.count ? heights[i] : nil
            let h = blockHeight(block, measured: measured, open: i < open.count && open[i])
            frames.append(Frame(y: y, height: h))
            y += h
        }
        return (frames, y)
    }

    func height(_ r: RenderedMessage, heights: [CGFloat?], open: [Bool]) -> CGFloat {
        ceil(blockFrames(r, heights: heights, open: open).end + actionBarGap + actionBar + bottom)
    }

    /// Measures every block that needs it. Collapsed bodies are skipped — most
    /// thinking/tool blocks are never opened, so measuring them is wasted work.
    func measure(_ r: RenderedMessage, width: CGFloat, existing: [CGFloat?], open: [Bool]) -> [CGFloat?] {
        var out = existing.count == r.blocks.count ? existing : Array(repeating: nil, count: r.blocks.count)
        for (i, block) in r.blocks.enumerated() where out[i] == nil {
            switch block {
            case .pending:
                out[i] = 0
            case .attachments(let a):
                out[i] = attachmentsHeight(a, width: width)
            case .text(let t, let panel):
                out[i] = t.height(forWidth: panel ? width - panelPad * 2 : width)
            case .error(let t):
                out[i] = t.height(forWidth: errorTextWidth(width))
            case .collapsible(let c):
                if i < open.count, open[i] { out[i] = bodyLayout(c.body, width: width - panelPad * 2).total }
            }
        }
        return out
    }

    /// Cheap guess used until a row is actually measured.
    func estimate(_ m: ChatRowModel, width: CGFloat) -> CGFloat {
        let charsPerLine = max(20, Double(width / theme.scaled(7.2)))
        var lines = 0.0
        var paragraphs = 0.0
        for line in m.content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                paragraphs += 1
            } else {
                lines += max(1, (Double(line.count) / charsPerLine).rounded(.up))
            }
        }
        var h = chrome + CGFloat(lines) * theme.scaled(18.5) + CGFloat(paragraphs) * theme.scaled(4)
        let collapsibles = (m.hasThinking ? 1 : 0) + m.toolCalls.count
        h += CGFloat(collapsibles) * (collapsibleHeader + blockGap)
        if m.role == .tool, m.toolCalls.isEmpty {
            h += CGFloat(m.toolResults.count) * (theme.scaled(40) + blockGap)
        }
        if m.attachments.contains(where: { $0.kind == .image }) { h += thumbnailSide + blockGap }
        h += CGFloat(m.attachments.filter { $0.kind != .image }.count) * (chipHeight + chipGap)
        if m.hasError { h += errorHeight(text: theme.scaled(18)) + blockGap }
        return ceil(h)
    }
}

/// List-side state of one message: its model, what's been rendered and measured.
final class RowState {
    /// Identity that outlives the object: views remember what they were configured
    /// for, and a freed row's address can be handed to the next one.
    let uid = UUID()
    var model: ChatRowModel
    var version = 0
    var rendered: RenderedMessage?
    var heights: [CGFloat?] = []
    var measuredWidth: CGFloat = -1
    var height: CGFloat

    init(_ model: ChatRowModel, estimatedHeight: CGFloat) {
        self.model = model
        height = estimatedHeight
    }
}
