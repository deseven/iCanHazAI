import AppKit

/// Pure display logic for tool blocks.
enum ToolPresentation {
    /// Strips the `mcp__{server}__` namespace prefix.
    static func shortName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let rest = name.dropFirst("mcp__".count)
        guard let range = rest.range(of: "__") else { return name }
        return String(rest[range.upperBound...])
    }

    /// The status badge of a tool call. Final states come persisted on the
    /// result; only the live ones (approval pending, running) are derived here.
    static func status(for result: ChatRowModel.ToolResult?, running: Bool, pending: Bool) -> ToolSummary.Status? {
        result?.summary ?? transientStatus(for: result, running: running, pending: pending) ?? localStatus(for: result)
    }

    static func transientStatus(for result: ChatRowModel.ToolResult?, running: Bool, pending: Bool)
        -> ToolSummary.Status?
    {
        if pending { return .init(kind: .pending, label: "approval", description: "") }
        if let result, result.isStreaming {
            return .init(kind: .running, label: "running", description: firstLine(result.content))
        }
        if result == nil, running { return .init(kind: .running, label: "running", description: "") }
        return nil
    }

    /// Results from before summaries were persisted: only "cancelled" is
    /// derived, since its content is a fixed sentence.
    static func localStatus(for result: ChatRowModel.ToolResult?) -> ToolSummary.Status? {
        guard let result, result.isCancelled, !result.isStreaming else { return nil }
        return .init(kind: .cancelled, label: "cancelled", description: "")
    }

    static func firstLine(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return ""
    }
}

enum DiffLineKind {
    case added, removed, hunk, header, context

    /// `inHeader` is true until the first hunk, where `---`/`+++` name files
    /// instead of changing lines.
    static func classify(_ line: Substring, inHeader: Bool) -> DiffLineKind {
        if line.hasPrefix("@@") { return .hunk }
        if inHeader, line.hasPrefix("---") || line.hasPrefix("+++") { return .header }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }

    var color: NSColor? {
        switch self {
        case .added: return .systemGreen
        case .removed: return .systemRed
        case .hunk, .header: return .secondaryLabelColor
        case .context: return nil
        }
    }
}

/// Collects the text of an expanded tool block into one attributed string
/// (labels, key/value lists, monospaced output, diffs). Images split the text
/// into separate segments.
struct ToolBodyBuilder {
    private let theme: Theme
    private var segments: [LazyBody.Segment] = []
    private var text = NSMutableAttributedString()

    init(theme: Theme) {
        self.theme = theme
    }

    private func style(before: CGFloat = 0, after: CGFloat = 0, lineSpacing: CGFloat = 0, wrap: NSLineBreakMode)
        -> NSParagraphStyle
    {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineSpacing = lineSpacing
        p.lineBreakMode = wrap
        return p
    }

    private var monoFont: NSFont { FontCache.shared.font(size: theme.codeFontSize, mono: true) }

    mutating func label(_ title: String, hint: String? = nil) {
        let p = style(
            before: text.length > 0 ? theme.sectionGap : 0, after: theme.labelGap, wrap: .byWordWrapping)
        let bold = FontCache.shared.font(size: theme.toolLabelSize, bold: true)
        text.append(
            NSAttributedString(
                string: title,
                attributes: [.font: bold, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]
            ))
        if let hint, !hint.isEmpty {
            text.append(
                NSAttributedString(
                    string: "  " + hint,
                    attributes: [
                        .font: FontCache.shared.font(size: theme.toolLabelSize),
                        .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: p,
                    ]))
        }
        text.append(NSAttributedString(string: "\n", attributes: [.font: bold, .paragraphStyle: p]))
    }

    /// One `key` line followed by its monospaced value. Line breaks inside a
    /// value are U+2028, so the spacing after the entry applies once.
    mutating func entries(_ entries: [ToolSummary.ArgEntry]) {
        let keyStyle = style(after: theme.scaled(1), wrap: .byWordWrapping)
        let valueStyle = style(after: theme.entryGap, lineSpacing: theme.monoLineSpacing, wrap: .byCharWrapping)
        let keyFont = FontCache.shared.font(size: theme.toolLabelSize + theme.scaled(0.5), bold: true)
        for e in entries {
            text.append(
                NSAttributedString(
                    string: e.key + "\n",
                    attributes: [
                        .font: keyFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: keyStyle,
                    ]
                ))
            let value = MarkdownRenderer.clipped(e.value, theme: theme).replacingOccurrences(of: "\n", with: "\u{2028}")
            text.append(
                NSAttributedString(
                    string: value + "\n",
                    attributes: [.font: monoFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: valueStyle]))
        }
    }

    mutating func monospaced(_ string: String, color: NSColor = .labelColor) {
        let value = MarkdownRenderer.clipped(string, theme: theme)
        guard !value.isEmpty else { return }
        let p = style(lineSpacing: theme.monoLineSpacing, wrap: .byCharWrapping)
        text.append(
            NSAttributedString(
                string: value + "\n", attributes: [.font: monoFont, .foregroundColor: color, .paragraphStyle: p]))
    }

    /// Monospaced text with each line colored by its diff prefix.
    mutating func diff(_ string: String) {
        let value = MarkdownRenderer.clipped(string, theme: theme)
        guard !value.isEmpty else { return }
        let p = style(lineSpacing: theme.monoLineSpacing, wrap: .byCharWrapping)
        let block = NSMutableAttributedString(
            string: value + "\n",
            attributes: [.font: monoFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: p])
        var location = 0
        var inHeader = true
        for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
            let length = line.utf16.count
            let kind = DiffLineKind.classify(line, inHeader: inHeader)
            if kind == .hunk { inHeader = false }
            if let color = kind.color, length > 0 {
                block.addAttribute(
                    .foregroundColor, value: color, range: NSRange(location: location, length: length))
            }
            location += length + 1
        }
        text.append(block)
    }

    mutating func image(key: String, _ image: ToolResultImage) {
        flush()
        segments.append(.image(key: key, image: image))
    }

    mutating func finish() -> [LazyBody.Segment] {
        flush()
        return segments
    }

    private mutating func flush() {
        guard text.length > 0 else { return }
        if (text.string as NSString).character(at: text.length - 1) == 10 {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
        if text.length > 0 {
            segments.append(.text(RenderedText(string: text, topInset: 0, bottomInset: 0)))
        }
        text = NSMutableAttributedString()
    }
}
