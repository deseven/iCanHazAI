import AppKit

/// The body of a collapsible block, built the first time it's needed: most
/// thinking and tool blocks are never opened, so rendering them eagerly would
/// be wasted work in the background pass.
final class LazyBody: @unchecked Sendable {
    enum Segment: Sendable {
        case text(RenderedText)
        case image(key: String, image: ToolResultImage)
    }

    private let make: @Sendable () -> [Segment]
    private let lock = NSLock()
    private var cached: [Segment]?

    init(_ make: @escaping @Sendable () -> [Segment]) {
        self.make = make
    }

    var segments: [Segment] {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let built = make()
        lock.lock()
        defer { lock.unlock() }
        if cached == nil { cached = built }
        return cached!
    }
}

/// A thinking or tool block: a header that opens a body.
struct CollapsibleBlock: Sendable {
    enum Kind: Sendable {
        case thinking, tool
    }

    let key: String
    let kind: Kind
    let symbol: String
    let title: String
    /// Collapsed one-line argument summary of a tool call.
    let summary: String
    let status: ToolSummary.Status?
    /// The block stays open and can't be toggled: a pending approval the user must see,
    /// or thinking that is still streaming in.
    let forcedOpen: Bool
    let approvalCallID: String?
    /// Thinking is still the only thing streaming in.
    let showsSpinner: Bool
    let body: LazyBody

    var hasApproval: Bool { approvalCallID != nil }
}

struct AttachmentsBlock: Sendable {
    let images: [ChatRowModel.AttachmentInfo]
    let documents: [ChatRowModel.AttachmentInfo]
}

/// The blocks of one message, ready to be measured and shown. Immutable after
/// construction (`NSColor` is the only non-value member), so it can cross threads.
struct RenderedMessage: @unchecked Sendable {
    enum Block {
        /// Request sent, nothing received yet.
        case pending
        case collapsible(CollapsibleBlock)
        case attachments(AttachmentsBlock)
        case text(RenderedText, panel: Bool)
        /// Error text with a Retry button.
        case error(RenderedText)
    }

    let blocks: [Block]

    static func render(_ m: ChatRowModel, theme: Theme, streaming: Bool = false) -> RenderedMessage {
        var blocks: [Block] = []
        if m.isPending(streaming: streaming) { blocks.append(.pending) }

        if m.hasThinking, let thinking = m.thinking {
            let thinkingStreams = m.isThinkingOnly(streaming: streaming)
            blocks.append(
                .collapsible(
                    CollapsibleBlock(
                        key: "\(m.id)/thinking", kind: .thinking, symbol: "brain",
                        title: thinkingStreams ? "Thinking" : Self.thinkingTitle(m.thinkingDuration), summary: "",
                        status: nil, forcedOpen: thinkingStreams, approvalCallID: nil,
                        showsSpinner: thinkingStreams,
                        body: LazyBody {
                            [
                                .text(
                                    MarkdownRenderer.plain(
                                        thinking, theme: theme, mono: false, color: .secondaryLabelColor))
                            ]
                        })))
        }

        if !m.attachments.isEmpty {
            blocks.append(
                .attachments(
                    AttachmentsBlock(
                        images: m.attachments.filter { $0.kind == .image },
                        documents: m.attachments.filter { $0.kind != .image })))
        }

        if m.hasContent {
            blocks.append(.text(MarkdownRenderer.render(m.content, theme: theme), panel: false))
        }

        for call in m.toolCalls {
            blocks.append(.collapsible(toolBlock(m, call: call, streaming: streaming, theme: theme)))
        }

        if m.role == .tool, m.toolCalls.isEmpty {
            for result in m.toolResults {
                let failed = result.isError && !result.isDenied && !result.isCancelled
                blocks.append(
                    .text(
                        MarkdownRenderer.plain(result.content, theme: theme, color: failed ? .systemRed : .labelColor),
                        panel: true))
            }
        }

        if m.hasError, let error = m.error {
            blocks.append(.error(MarkdownRenderer.plain(error, theme: theme, mono: false, color: .systemRed)))
        }
        return RenderedMessage(blocks: blocks)
    }

    /// "Thought for 5 seconds"; without a recorded duration just "Thinking".
    static func thinkingTitle(_ duration: TimeInterval?) -> String {
        guard let duration, duration > 0 else { return "Thinking" }
        let seconds = max(1, Int(duration.rounded()))
        if seconds < 60 { return "Thought for \(seconds) second\(seconds == 1 ? "" : "s")" }
        let (m, s) = seconds.quotientAndRemainder(dividingBy: 60)
        return s == 0 ? "Thought for \(m)m" : "Thought for \(m)m \(s)s"
    }

    private static func toolBlock(_ m: ChatRowModel, call: ChatRowModel.ToolCall, streaming: Bool, theme: Theme)
        -> CollapsibleBlock
    {
        let result = m.result(for: call)
        let running = (result == nil && streaming) || (result?.isStreaming ?? false)
        let pending = call.pendingApproval
        return CollapsibleBlock(
            key: "\(m.id)/call/\(call.id)", kind: .tool, symbol: "wrench", title: ToolPresentation.shortName(call.name),
            summary: call.summary ?? "",
            status: ToolPresentation.status(for: result, running: running, pending: pending),
            forcedOpen: pending, approvalCallID: pending ? call.id : nil, showsSpinner: false,
            body: LazyBody { toolBody(call: call, result: result, theme: theme) })
    }

    private static func toolBody(call: ChatRowModel.ToolCall, result: ChatRowModel.ToolResult?, theme: Theme)
        -> [LazyBody.Segment]
    {
        var b = ToolBodyBuilder(theme: theme)
        if let diff = call.diff, !diff.isEmpty {
            b.label("Diff")
            b.diff(diff)
        } else if !(call.name == "shell" && appendShellCommand(&b, call.arguments)),
            !ToolSummary.isEmptyArgs(call.arguments)
        {
            b.label("Arguments")
            appendEntries(&b, call.arguments)
        }

        if let result {
            if let image = result.image {
                b.label("Image", hint: "vision-capable models")
                b.image(key: "toolresult/\(result.callID)", image)
                b.label("Fallback", hint: "vision-incapable models")
                b.monospaced(result.content)
            } else {
                b.label(result.isStreaming ? "Result (streaming…)" : "Result")
                let failed = result.isError && !result.isDenied && !result.isCancelled
                if result.content.drop(while: \.isWhitespace).first == "{",
                    let entries = ToolSummary.argumentEntries(result.content)
                {
                    b.entries(entries)
                } else {
                    b.monospaced(result.content, color: failed ? .systemRed : .labelColor)
                }
            }
        }
        return b.finish()
    }

    /// The command of a `shell` call gets its own labeled block; the other
    /// arguments trail the label as a muted suffix. Returns false when the
    /// arguments have no `command`, so the generic view takes over.
    private static func appendShellCommand(_ b: inout ToolBodyBuilder, _ arguments: String) -> Bool {
        guard let entries = ToolSummary.argumentEntries(arguments),
            let command = entries.first(where: { $0.key == "command" })
        else { return false }
        let rest = entries.filter { $0.key != "command" }
            .map { "\($0.key): \($0.value.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: " · ")
        b.label("Command", hint: rest)
        b.monospaced(command.value)
        return true
    }

    private static func appendEntries(_ b: inout ToolBodyBuilder, _ arguments: String) {
        if let entries = ToolSummary.argumentEntries(arguments) {
            b.entries(entries)
        } else {
            b.monospaced(arguments)
        }
    }
}
