import Foundation

// `ChatRowModel` has nested types named like the stored ones; these aliases
// keep the stored types addressable from inside its extensions.
typealias StoredToolCall = ToolCall
typealias StoredToolResult = ToolResult

extension ChatRowModel {
    /// The row for a stored message. Tool results are not folded here, see
    /// `ChatRenderQueue.projectActiveMessages`.
    init(_ message: ChatMessage) {
        self.init(
            id: message.id.uuidString,
            role: Role(rawValue: message.role.rawValue) ?? .user,
            content: message.content,
            thinking: message.thinking,
            thinkingDuration: message.thinkingDuration,
            error: message.error,
            timestamp: message.timestamp,
            connectionName: message.connectionName,
            attachments: (message.attachments ?? []).map(AttachmentInfo.init),
            toolCalls: (message.toolCalls ?? []).map(ToolCall.init),
            toolResults: (message.toolResults ?? []).map(ToolResult.init)
        )
    }
}

extension ChatRowModel.AttachmentInfo {
    init(_ attachment: Attachment) {
        self.init(
            kind: attachment.kind, filename: attachment.filename, originalName: attachment.originalName,
            status: attachment.status, failureReason: attachment.failureReason)
    }
}

extension ChatRowModel.ToolCall {
    init(_ call: StoredToolCall) {
        self.init(
            id: call.id, name: call.name, arguments: call.arguments, summary: call.summary,
            pendingApproval: call.pendingApproval, diff: call.diff)
    }
}

extension ChatRowModel.ToolResult {
    init(_ result: StoredToolResult) {
        self.init(
            callID: result.callID, content: result.content, isError: result.isError,
            isStreaming: result.isStreaming, isDenied: result.isDenied, isCancelled: result.isCancelled,
            summary: result.summary, image: result.image)
    }
}
