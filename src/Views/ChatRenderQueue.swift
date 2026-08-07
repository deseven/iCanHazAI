// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A unit of work for `ChatRenderQueue`.
enum RenderJob: Sendable {
    /// Wipe the diff state (the renderer was reloaded/blanked); the next
    /// snapshot for any chat is sent in full. Drops every queued job — they
    /// were computed against the pre-reset state.
    case reset
    /// Tell the renderer to blank itself (chat switch in progress). Drops any
    /// queued snapshots — a blanked renderer has no use for them.
    case unload
    /// Render the given chat state, diffed against the last rendered state.
    /// A snapshot is self-contained: it supersedes an earlier queued (not yet
    /// processed) snapshot, so only the latest one is kept.
    case snapshot(chatId: String, messages: [ChatMessage], isStreaming: Bool, roleName: String?, roleAccent: String?)
}

/// Serializes and off-loads the expensive part of the Swift → renderer bridge:
/// projecting `ChatMessage`s into their wire shape, diffing against the last
/// rendered state, JSON-encoding, and JS-escaping. All of that used to run on
/// the main actor inside `pushSnapshot()` and visibly froze the UI on large
/// chats.
///
/// Jobs are processed strictly in enqueue order; each resulting JS statement
/// hops to the main actor via the injected `deliver` closure, and the queue
/// awaits that hop before processing the next job, so the renderer receives
/// messages in exactly this order.
actor ChatRenderQueue {
    private let deliver: @Sendable (String) async -> Void

    // Diff state — the last state we generated bridge messages for.
    private var renderedChatId: String?
    private var lastMessages: [String: ChatMessageData] = [:]
    private var lastMessageIds: [String] = []
    private var lastStreamingState: Bool = false
    private var lastRoleName: String? = nil
    private var lastRoleAccent: String? = nil

    private var pending: [RenderJob] = []
    private var draining = false

    init(deliver: @escaping @Sendable (String) async -> Void) {
        self.deliver = deliver
    }

    func enqueue(_ job: RenderJob) {
        switch job {
        case .reset:
            pending.removeAll()
            pending.append(job)
        case .unload:
            pending.removeAll { if case .snapshot = $0 { return true } else { return false } }
            pending.append(job)
        case .snapshot:
            if case .snapshot = pending.last {
                pending[pending.count - 1] = job
            } else {
                pending.append(job)
            }
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
        case .reset:
            clearDiffState()
        case .unload:
            // The renderer blanks itself, so the next snapshot must be full.
            clearDiffState()
            await send(.unload)
        case .snapshot(let chatId, let messages, let isStreaming, let roleName, let roleAccent):
            await processSnapshot(chatId: chatId, messages: messages, isStreaming: isStreaming, roleName: roleName, roleAccent: roleAccent)
        }
    }

    private func clearDiffState() {
        renderedChatId = nil
        lastMessages = [:]
        lastMessageIds = []
        lastStreamingState = false
        lastRoleName = nil
        lastRoleAccent = nil
    }

    /// Diffs the given chat state against the last rendered state and sends
    /// incremental updates (updateMessage / addMessage / deleteMessage) when
    /// possible. Falls back to a full snapshot on chat switch, role/accent
    /// change, or streaming end.
    private func processSnapshot(chatId: String, messages: [ChatMessage], isStreaming: Bool, roleName: String?, roleAccent: String?) async {
        let currentMessages = Self.projectToolResults(messages)
        let currentIds = currentMessages.map(\.id)

        // A role/accent change only affects the assistant message title, which
        // the renderer derives from the snapshot — incremental message diffs
        // wouldn't reflect it, so force a fresh full snapshot.
        if chatId != renderedChatId || roleName != lastRoleName || roleAccent != lastRoleAccent {
            renderedChatId = chatId
            lastStreamingState = isStreaming
            lastRoleName = roleName
            lastRoleAccent = roleAccent
            remember(currentMessages, ids: currentIds)
            await send(.snapshot(snapshot: ChatSnapshotData(chatId: chatId, messages: currentMessages, isStreaming: isStreaming, roleName: roleName, roleAccent: roleAccent)))
            return
        }

        if isStreaming != lastStreamingState {
            lastStreamingState = isStreaming
            if !isStreaming {
                remember(currentMessages, ids: currentIds)
                await send(.snapshot(snapshot: ChatSnapshotData(chatId: chatId, messages: currentMessages, isStreaming: false, roleName: roleName, roleAccent: roleAccent)))
                return
            } else {
                await send(.streaming(chatId: chatId, isStreaming: true))
            }
        }

        let oldIds = Set(lastMessageIds)
        let newIds = Set(currentIds)

        for id in lastMessageIds where !newIds.contains(id) {
            await send(.deleteMessage(chatId: chatId, messageId: id))
        }

        for (index, msg) in currentMessages.enumerated() {
            if !oldIds.contains(msg.id) {
                await send(.addMessage(chatId: chatId, message: msg, index: index))
            } else if let old = lastMessages[msg.id], old != msg {
                await send(.updateMessage(chatId: chatId, message: msg))
            }
        }

        remember(currentMessages, ids: currentIds)
    }

    private func remember(_ messages: [ChatMessageData], ids: [String]) {
        lastMessages = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        lastMessageIds = ids
    }

    // MARK: - Encoding

    private func send(_ message: HostMessageData) async {
        guard let js = Self.encodeToJS(message) else { return }
        await deliver(js)
    }

    /// Encodes a host message as a `window.chatHost.postMessage('...')` JS
    /// statement. Pure and thread-safe; small messages are encoded on the
    /// main actor directly via this helper.
    static func encodeToJS(_ message: HostMessageData) -> String? {
        guard let json = try? JSONEncoder().encode(message),
              let jsonString = String(data: json, encoding: .utf8) else { return nil }
        let escaped = jsonString.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "window.chatHost && window.chatHost.postMessage('\(escaped)');"
    }

    // MARK: - Projection

    /// Projects the stored message list into the wire shape, folding
    /// `tool`-role result messages onto the preceding assistant message's
    /// `toolResults` (matched by `callID`) so the renderer shows each result
    /// in the same inline tool block as the call that issued it. The folded
    /// `tool` messages are dropped from the returned list. This is a pure view
    /// projection — storage keeps the natural provider shape (one `tool`-role
    /// message per result).
    static func projectToolResults(_ messages: [ChatMessage]) -> [ChatMessageData] {
        var out: [ChatMessageData] = []
        var lastAssistantOutIndex: Int? = nil
        for msg in messages {
            if msg.role == .tool, let results = msg.toolResults, !results.isEmpty {
                if let aIdx = lastAssistantOutIndex {
                    var folded = out[aIdx].toolResults ?? []
                    for r in results {
                        if let i = folded.firstIndex(where: { $0.callID == r.callID }) {
                            folded[i] = ChatMessageData.ToolResultData(callID: r.callID, content: r.content, isError: r.isError, isStreaming: r.isStreaming, isDenied: r.isDenied, isCancelled: r.isCancelled, summary: r.summary)
                        } else {
                            folded.append(ChatMessageData.ToolResultData(callID: r.callID, content: r.content, isError: r.isError, isStreaming: r.isStreaming, isDenied: r.isDenied, isCancelled: r.isCancelled, summary: r.summary))
                        }
                    }
                    out[aIdx].toolResults = folded
                }
                continue
            }
            var data = msg.webData
            if msg.role == .assistant {
                // Assistant messages no longer carry folded toolResults in
                // storage; clear any stale value so the projection is the
                // single source of truth for the fold.
                data.toolResults = nil
                lastAssistantOutIndex = out.count
            }
            out.append(data)
        }
        return out
    }
}
