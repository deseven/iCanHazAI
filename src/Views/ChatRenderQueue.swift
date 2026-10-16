// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Chat-wide inputs that travel with the rows. `roleAccent` is the role's
/// accent alias; the main actor resolves it to a dynamic color.
struct ChatRenderState: Sendable, Equatable {
    var roleName: String?
    var roleIcon: String?
    var roleAccent: String?
    var features = ChatRowFeatures()
    var isStreaming = false
}

/// What the list has to do to reach the state a job describes.
enum RenderOp: Sendable, Equatable {
    /// Chat switch in progress: drop everything that's shown.
    case unload
    /// Replace everything.
    case snapshot(chatID: String, rows: [ChatRowModel], state: ChatRenderState)
    /// Chat-wide inputs changed without a change of chat.
    case state(ChatRenderState)
    case insert(ChatRowModel, at: Int)
    case update(ChatRowModel)
    case delete(id: String)
    /// Bring a message into view and highlight it.
    case scrollTo(messageID: String)
}

/// A unit of work for `ChatRenderQueue`.
enum RenderJob: Sendable {
    /// Blank the list (chat switch in progress). Drops any queued snapshots, a
    /// blanked list has no use for them, and makes the next snapshot a full one.
    case unload
    /// Render the given chat state, diffed against the last rendered state.
    /// A snapshot is self-contained: it supersedes an earlier queued (not yet
    /// processed) snapshot, so only the latest one is kept. The full `Chat`
    /// is passed so the queue can project the active path and compute
    /// per-message sibling metadata for branch switching.
    case snapshot(chatId: String, chat: Chat, state: ChatRenderState)
    /// Scroll to a message once everything queued before has been applied.
    case scrollTo(messageID: String)
}

/// Moves the expensive part of feeding the list off the main actor:
/// projecting `ChatMessage`s into rows and diffing them against the last
/// rendered state. All of that used to run on the main actor inside
/// `pushSnapshot()` and visibly froze the UI on large chats.
///
/// Jobs are processed strictly in enqueue order; each resulting batch of ops
/// hops to the main actor via the injected `deliver` closure, and the queue
/// awaits that hop before processing the next job, so the list receives ops in
/// exactly this order.
actor ChatRenderQueue {
    /// Replacing the list is cheaper than applying this many structural edits
    /// one by one (a branch switch changes a whole tail of messages at once).
    static let bulkEditThreshold = 16

    private let deliver: @Sendable ([RenderOp]) async -> Void

    // Diff state: what the list has been told so far.
    private var renderedChatId: String?
    private var lastRows: [String: ChatRowModel] = [:]
    private var lastIds: [String] = []
    private var lastState = ChatRenderState()

    private var pending: [RenderJob] = []
    private var draining = false

    init(deliver: @escaping @Sendable ([RenderOp]) async -> Void) {
        self.deliver = deliver
    }

    func enqueue(_ job: RenderJob) {
        switch job {
        case .unload:
            pending.removeAll { if case .snapshot = $0 { return true } else { return false } }
            pending.append(job)
        case .snapshot:
            if case .snapshot = pending.last {
                pending[pending.count - 1] = job
            } else {
                pending.append(job)
            }
        case .scrollTo:
            pending.append(job)
        }
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let job = pending.removeFirst()
            await process(job)
        }
        // No await between the loop exit and this assignment, so no enqueue
        // can slip in and find `draining` true with no drain running.
        draining = false
    }

    private func process(_ job: RenderJob) async {
        switch job {
        case .unload:
            clearDiffState()
            await deliver([.unload])
        case .snapshot(let chatId, let chat, let state):
            let ops = diff(chatId: chatId, chat: chat, state: state)
            if !ops.isEmpty { await deliver(ops) }
        case .scrollTo(let messageID):
            await deliver([.scrollTo(messageID: messageID)])
        }
    }

    private func clearDiffState() {
        renderedChatId = nil
        lastRows = [:]
        lastIds = []
        lastState = ChatRenderState()
    }

    private func remember(_ rows: [ChatRowModel]) {
        lastRows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        lastIds = rows.map(\.id)
    }

    /// Diffs the given chat state against the last rendered state. A chat
    /// switch, or a change too big to apply piecemeal, is a full snapshot;
    /// anything else is incremental. Chat-wide inputs (role, features,
    /// streaming) are separate from the rows: the list reconfigures instead of
    /// re-rendering.
    private func diff(chatId: String, chat: Chat, state: ChatRenderState) -> [RenderOp] {
        let rows = Self.projectActiveMessages(chat)
        let ids = rows.map(\.id)

        func fullSnapshot() -> [RenderOp] {
            renderedChatId = chatId
            lastState = state
            remember(rows)
            return [.snapshot(chatID: chatId, rows: rows, state: state)]
        }

        guard chatId == renderedChatId else { return fullSnapshot() }

        let oldIds = Set(lastIds)
        let newIds = Set(ids)
        let removed = lastIds.filter { !newIds.contains($0) }
        let added = ids.indices.filter { !oldIds.contains(ids[$0]) }
        // Insert-by-index relies on the survivors keeping their relative order.
        let survivorsKeepOrder = lastIds.filter(newIds.contains) == ids.filter(oldIds.contains)
        if removed.count + added.count > Self.bulkEditThreshold || !survivorsKeepOrder { return fullSnapshot() }

        var ops: [RenderOp] = []
        let stateChanged = state != lastState
        // Streaming ends after the final content is in, so rows that only
        // looked "running" are re-rendered once with their settled content.
        let streamingEnded = lastState.isStreaming && !state.isStreaming
        if stateChanged && !streamingEnded { ops.append(.state(state)) }
        for id in removed { ops.append(.delete(id: id)) }
        for (index, row) in rows.enumerated() {
            if !oldIds.contains(row.id) {
                ops.append(.insert(row, at: index))
            } else if let old = lastRows[row.id], old != row {
                ops.append(.update(row))
            }
        }
        if stateChanged && streamingEnded { ops.append(.state(state)) }

        lastState = state
        remember(rows)
        return ops
    }

    // MARK: - Projection

    /// Projects the chat's active messages into rows, folding `tool`-role
    /// result messages onto the preceding assistant message's `toolResults`
    /// (matched by `callID`) so the list shows each result in the same inline
    /// tool block as the call that issued it. The folded `tool` messages are
    /// dropped from the returned list. Also stamps per-message sibling metadata
    /// (index/count within a fork group) for branch switching. This is a pure
    /// view projection — storage keeps the natural provider shape (one
    /// `tool`-role message per result).
    static func projectActiveMessages(_ chat: Chat) -> [ChatRowModel] {
        var out: [ChatRowModel] = []
        var lastAssistantOutIndex: Int? = nil
        for msg in chat.activeMessages {
            if msg.role == .tool, let results = msg.toolResults, !results.isEmpty {
                if let aIdx = lastAssistantOutIndex {
                    var folded = out[aIdx].toolResults
                    for r in results.map(ChatRowModel.ToolResult.init) {
                        if let i = folded.firstIndex(where: { $0.callID == r.callID }) {
                            folded[i] = r
                        } else {
                            folded.append(r)
                        }
                    }
                    out[aIdx].toolResults = folded
                }
                continue
            }
            var row = ChatRowModel(msg)
            if msg.role == .assistant {
                row.toolResults = []
                lastAssistantOutIndex = out.count
            }
            let siblings = chat.siblings(of: msg.id)
            if siblings.count > 1 {
                row.siblings = ChatRowModel.Siblings(index: siblings.index, count: siblings.count)
            }
            out.append(row)
        }
        return out
    }

    // MARK: - Tree overview

    /// Builds the tree overview projection: a nested tree mirroring the chat's
    /// structure. Each node is a drawn card (the conversation root or one
    /// branch-head of a split); everything between drawn nodes collapses into
    /// the node's `messageCount`. Returns nil for an empty chat. For a linear
    /// chat (no forks) the projection is a single root node whose segment runs
    /// to the end of the conversation.
    static func buildTreeOverview(_ chat: Chat) -> TreeNodeData? {
        guard !chat.messages.isEmpty else { return nil }
        let activeIDSet = Set(chat.activeMessages.map(\.id))
        return node(forSegment: chat.messages, activeIDSet: activeIDSet)
    }

    /// Builds the node for the segment that *starts* with `msgs[0]` and runs
    /// to the next split (the first message with `branches`) or to the end of
    /// `msgs`. The segment's message count includes the head and the split
    /// owner; the split's branches become child nodes.
    private static func node(forSegment msgs: [ChatMessage], activeIDSet: Set<UUID>) -> TreeNodeData {
        let head = msgs[0]
        // Find the split owner: the first message in the segment (including
        // the head itself) that carries `branches`. The segment's count runs
        // from the head up to and including that owner.
        var count = 0
        var splitMsg: ChatMessage? = nil
        for m in msgs {
            count += 1
            if m.branches != nil {
                splitMsg = m
                break
            }
        }
        let split = splitMsg?.branches.map { branches in
            TreeSplitData(branches: branches.map { node(forSegment: $0, activeIDSet: activeIDSet) })
        }
        return TreeNodeData(
            id: head.id.uuidString,
            role: head.role.rawValue,
            snippet: snippet(of: head),
            messageCount: count,
            isActive: activeIDSet.contains(head.id),
            split: split
        )
    }

    /// A short snippet (≤100 chars) of a message's content, for the node card,
    /// with the markdown markup stripped.
    private static func snippet(of msg: ChatMessage) -> String {
        let trimmed = MarkdownRenderer.plainText(msg.content)
        if trimmed.isEmpty {
            if msg.error != nil { return "(error)" }
            if let calls = msg.toolCalls, !calls.isEmpty { return "tool call: \(calls.first?.name ?? "")" }
            if msg.role == .assistant { return "(empty)" }
            return ""
        }
        if trimmed.count <= 100 { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 100)
        return String(trimmed[..<endIndex]) + "…"
    }
}

/// A node in the tree overview projection: the conversation root, or one
/// branch-head of a split. The projection mirrors the chat's tree structure
/// directly — each node is a drawn card, and its `split` (when present) holds
/// the alternative continuations, each headed by its own node. Everything
/// between drawn nodes collapses into the node's `messageCount` (shown as a
/// "{n} messages" badge).
struct TreeNodeData: Equatable, Sendable {
    /// The message id this node represents (used for goto-on-click).
    let id: String
    /// The message role ("user", "assistant", "tool", "system").
    let role: String
    /// A short snippet of the message content (≤100 chars), for the node card.
    let snippet: String
    /// Number of messages in this branch segment: from this node up to (and
    /// including) the next split's owner, or to the end of the branch.
    let messageCount: Int
    /// Whether this node lies on the active path (root → active leaf).
    let isActive: Bool
    /// The split this node's segment ends in. Absent → the segment runs to a
    /// leaf (the end of the branch).
    let split: TreeSplitData?
}

/// A fork point: the alternative continuations after a node's segment, each
/// headed by its own node. Exactly one branch is active (has `isActive`).
struct TreeSplitData: Equatable, Sendable {
    /// The branch heads, in order.
    let branches: [TreeNodeData]
}
