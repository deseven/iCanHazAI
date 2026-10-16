import AppKit

struct ChatRowFeatures: Sendable, Equatable {
    var responseRegen = false
    var chatTrees = false
}

/// Chat-wide inputs that affect how rows look. Changing them reconfigures
/// views; heights are invalidated only for rows whose block structure depends
/// on the changed value.
struct ChatRowContext: Equatable {
    var roleName: String?
    /// SF Symbol shown as the assistant's avatar.
    var roleIcon: String?
    var roleAccent: NSColor?
    var features = ChatRowFeatures()
    var isStreaming = false
    var expandThinking = false
    var expandToolUse = false
    /// Where the chat's attachment files live.
    var attachmentsDirectory: URL?

    var assistantLabel: String { roleName ?? "Assistant" }
}

/// What the user can ask the host to do from a row.
enum ChatRowAction: Equatable {
    case copy(messageID: String)
    case edit(messageID: String)
    case delete(messageID: String)
    case retry
    case regenerate(messageID: String)
    /// `direction` is -1 (previous sibling) or +1 (next sibling).
    case switchBranch(messageID: String, direction: Int)
    case allowToolCall(callID: String)
    case allowToolCallForChat(callID: String)
    case denyToolCall(callID: String)
}

/// Everything a row view can report to its list.
enum RowEvent {
    case action(ChatRowAction)
    case toggle(key: String)
    case collapse(key: String)
    case openAttachment(ChatRowModel.AttachmentInfo)
    case previewAttachment(messageID: String, filename: String)
}

/// Which collapsible blocks are open. Defaults come from the preferences, so
/// only the blocks the user flipped are stored: changing a preference flips
/// everything that wasn't touched.
struct OpenPolicy: Sendable, Equatable {
    var thinkingByDefault = false
    var toolsByDefault = false
    var toggled: Set<String> = []

    func isOpen(_ block: CollapsibleBlock) -> Bool {
        if block.forcedOpen { return true }
        let byDefault = block.kind == .thinking ? thinkingByDefault : toolsByDefault
        return byDefault != toggled.contains(block.key)
    }

    /// Parallel to `r.blocks`; false for blocks that can't be opened.
    func mask(for r: RenderedMessage) -> [Bool] {
        r.blocks.map {
            if case .collapsible(let block) = $0 { return isOpen(block) }
            return false
        }
    }
}
