import Foundation

/// Everything the list needs to know about one message. Produced off the main
/// thread, so it's a plain value type. Chat-wide inputs (role name, features,
/// streaming, preferences) live in `ChatRowContext` instead.
struct ChatRowModel: Sendable, Equatable, Identifiable {
    enum Role: String, Sendable {
        case system, user, assistant, tool
    }

    struct AttachmentInfo: Sendable, Equatable {
        var kind: AttachmentKind
        /// The file's name inside the chat's attachment directory.
        var filename: String
        /// The name the user knew the file by; nil for pasted images.
        var originalName: String?
        var status: AttachmentStatus = .ok
        var failureReason: String?
    }

    struct ToolCall: Sendable, Equatable {
        var id: String
        var name: String
        var arguments: String
        /// The collapsed one-line argument summary, computed by the engine.
        var summary: String?
        /// True while the engine waits for the user to approve this call.
        var pendingApproval = false
        var diff: String?
    }

    struct ToolResult: Sendable, Equatable {
        var callID: String
        var content: String
        var isError: Bool
        var isStreaming = false
        var isDenied = false
        var isCancelled = false
        var summary: ToolSummary.Status?
        var image: ToolResultImage?
    }

    struct Siblings: Sendable, Equatable {
        /// 0-based index within the fork group.
        var index: Int
        var count: Int
    }

    var id: String
    var role: Role
    var content: String
    var thinking: String?
    /// Seconds spent thinking; nil when it wasn't recorded.
    var thinkingDuration: TimeInterval?
    var error: String?
    var timestamp: Date
    var model: String?
    var attachments: [AttachmentInfo] = []
    var toolCalls: [ToolCall] = []
    /// Results folded onto the assistant message that issued the calls. On a
    /// standalone `tool` row they have no matching call.
    var toolResults: [ToolResult] = []
    var siblings: Siblings?
}

extension ChatRowModel {
    var hasThinking: Bool { thinking.map(\.hasVisibleCharacters) ?? false }
    var hasContent: Bool { content.hasVisibleCharacters }
    var hasError: Bool { error.map(\.hasVisibleCharacters) ?? false }
    var hasSiblings: Bool { (siblings?.count ?? 0) > 1 }

    /// The request was sent but nothing has arrived yet: show a spinner
    /// instead of a blank message.
    func isPending(streaming: Bool) -> Bool {
        streaming && role == .assistant && !hasThinking && !hasContent && toolCalls.isEmpty && !hasError
    }

    /// Thinking is the only thing that has arrived so far, and more may follow.
    func isThinkingOnly(streaming: Bool) -> Bool {
        streaming && role == .assistant && hasThinking && !hasContent && toolCalls.isEmpty && !hasError
    }

    /// Whether what the row shows (and so its height) changes with the chat's
    /// streaming flag: the pending spinner, the open thinking block, and "running" tool statuses.
    var dependsOnStreaming: Bool {
        guard role == .assistant else { return false }
        if isThinkingOnly(streaming: true) { return true }
        if toolCalls.contains(where: { call in !toolResults.contains { $0.callID == call.id } }) { return true }
        return isPending(streaming: true)
    }

    /// Regenerate is offered on assistant messages other than the first one,
    /// when the role enables it, and never while a stream is running.
    func canRegenerate(isFirst: Bool, features: ChatRowFeatures, streaming: Bool) -> Bool {
        role == .assistant && !isFirst && features.responseRegen && !streaming
    }

    func result(for call: ToolCall) -> ToolResult? {
        toolResults.first { $0.callID == call.id }
    }
}

extension ChatRowModel.AttachmentInfo {
    var displayName: String { originalName ?? (kind == .image ? "image" : "document") }

    /// Inline notice on a document chip; nil when everything went fine.
    var statusText: String? {
        switch status {
        case .truncated: return "truncated to 64 KB"
        case .failed:
            let reason = failureReason ?? ""
            return reason.isEmpty ? "extraction failed" : "extraction failed: \(reason)"
        case .ok: return nil
        }
    }
}

extension String {
    /// Cheaper than trimming: stops at the first visible character.
    var hasVisibleCharacters: Bool {
        contains { !$0.isWhitespace }
    }
}
