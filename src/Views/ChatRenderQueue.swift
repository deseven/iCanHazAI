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
    /// processed) snapshot, so only the latest one is kept. The full `Chat`
    /// is passed so the queue can project the active path and compute
    /// per-message sibling metadata for branch switching.
    case snapshot(chatId: String, chat: Chat, isStreaming: Bool, roleName: String?, roleAccent: String?, features: ChatSnapshotFeaturesData)
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
    private var lastFeatures: ChatSnapshotFeaturesData? = nil

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
        case .snapshot(let chatId, let chat, let isStreaming, let roleName, let roleAccent, let features):
            await processSnapshot(chatId: chatId, chat: chat, isStreaming: isStreaming, roleName: roleName, roleAccent: roleAccent, features: features)
        }
    }

    private func clearDiffState() {
        renderedChatId = nil
        lastMessages = [:]
        lastMessageIds = []
        lastStreamingState = false
        lastRoleName = nil
        lastRoleAccent = nil
        lastFeatures = nil
    }

    /// Diffs the given chat state against the last rendered state and sends
    /// incremental updates (updateMessage / addMessage / deleteMessage) when
    /// possible. Falls back to a full snapshot on chat switch, role/accent
    /// change, feature-flag change, or streaming end. Projects the active
    /// path (for forked chats) and computes per-message sibling metadata.
    private func processSnapshot(chatId: String, chat: Chat, isStreaming: Bool, roleName: String?, roleAccent: String?, features: ChatSnapshotFeaturesData) async {
        let currentMessages = Self.projectActiveMessages(chat)

        // A role/accent/features change affects things the renderer derives
        // from the snapshot (assistant title, regen button visibility), which
        // incremental message diffs wouldn't reflect, so force a fresh full
        // snapshot. A branch switch changes many message ids — the existing
        // delete/add diffing handles it, but verify efficiency on deep chats
        // and fall back to a forced full snapshot on switches if the diff
        // gets pathological.
        if chatId != renderedChatId || roleName != lastRoleName || roleAccent != lastRoleAccent || features != lastFeatures {
            renderedChatId = chatId
            lastStreamingState = isStreaming
            lastRoleName = roleName
            lastRoleAccent = roleAccent
            lastFeatures = features
            remember(currentMessages, ids: currentMessages.map(\.id))
            await send(.snapshot(snapshot: ChatSnapshotData(chatId: chatId, messages: currentMessages, isStreaming: isStreaming, roleName: roleName, roleAccent: roleAccent, features: features)))
            return
        }

        if isStreaming != lastStreamingState {
            lastStreamingState = isStreaming
            if !isStreaming {
                remember(currentMessages, ids: currentMessages.map(\.id))
                await send(.snapshot(snapshot: ChatSnapshotData(chatId: chatId, messages: currentMessages, isStreaming: false, roleName: roleName, roleAccent: roleAccent, features: features)))
                return
            } else {
                await send(.streaming(chatId: chatId, isStreaming: true))
            }
        }

        let currentIds = currentMessages.map(\.id)
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

    /// Projects the chat's active messages into the wire shape, folding
    /// `tool`-role result messages onto the preceding assistant message's
    /// `toolResults` (matched by `callID`) so the renderer shows each result
    /// in the same inline tool block as the call that issued it. The folded
    /// `tool` messages are dropped from the returned list. Also stamps
    /// per-message sibling metadata (index/count within a fork group) for
    /// branch switching. This is a pure view projection — storage keeps the
    /// natural provider shape (one `tool`-role message per result).
    static func projectActiveMessages(_ chat: Chat) -> [ChatMessageData] {
        let activeMessages = chat.activeMessages
        var out: [ChatMessageData] = []
        var lastAssistantOutIndex: Int? = nil
        for msg in activeMessages {
            if msg.role == .tool, let results = msg.toolResults, !results.isEmpty {
                if let aIdx = lastAssistantOutIndex {
                    var folded = out[aIdx].toolResults ?? []
                    for r in results {
                        let imageData = r.image.map { ChatMessageData.ToolResultData.ToolResultImageData(mimeType: $0.mimeType, fallback: $0.fallback) }
                        if let i = folded.firstIndex(where: { $0.callID == r.callID }) {
                            folded[i] = ChatMessageData.ToolResultData(callID: r.callID, content: r.content, isError: r.isError, isStreaming: r.isStreaming, isDenied: r.isDenied, isCancelled: r.isCancelled, summary: r.summary, image: imageData)
                        } else {
                            folded.append(ChatMessageData.ToolResultData(callID: r.callID, content: r.content, isError: r.isError, isStreaming: r.isStreaming, isDenied: r.isDenied, isCancelled: r.isCancelled, summary: r.summary, image: imageData))
                        }
                    }
                    out[aIdx].toolResults = folded
                }
                continue
            }
            var data = msg.webData
            if msg.role == .assistant {
                data.toolResults = nil
                lastAssistantOutIndex = out.count
            }
            // Stamp sibling metadata for fork members (count > 1).
            let siblings = chat.siblings(of: msg.id)
            if siblings.count > 1 {
                data.siblings = ChatMessageData.SiblingsData(index: siblings.index, count: siblings.count)
            }
            out.append(data)
        }
        return out
    }

    /// Legacy projection for tests that pass a flat message array. Used only
    /// by tests that don't need tree metadata.
    static func projectToolResults(_ messages: [ChatMessage]) -> [ChatMessageData] {
        var out: [ChatMessageData] = []
        var lastAssistantOutIndex: Int? = nil
        for msg in messages {
            if msg.role == .tool, let results = msg.toolResults, !results.isEmpty {
                if let aIdx = lastAssistantOutIndex {
                    var folded = out[aIdx].toolResults ?? []
                    for r in results {
                        let imageData = r.image.map { ChatMessageData.ToolResultData.ToolResultImageData(mimeType: $0.mimeType, fallback: $0.fallback) }
                        if let i = folded.firstIndex(where: { $0.callID == r.callID }) {
                            folded[i] = ChatMessageData.ToolResultData(callID: r.callID, content: r.content, isError: r.isError, isStreaming: r.isStreaming, isDenied: r.isDenied, isCancelled: r.isCancelled, summary: r.summary, image: imageData)
                        } else {
                            folded.append(ChatMessageData.ToolResultData(callID: r.callID, content: r.content, isError: r.isError, isStreaming: r.isStreaming, isDenied: r.isDenied, isCancelled: r.isCancelled, summary: r.summary, image: imageData))
                        }
                    }
                    out[aIdx].toolResults = folded
                }
                continue
            }
            var data = msg.webData
            if msg.role == .assistant {
                data.toolResults = nil
                lastAssistantOutIndex = out.count
            }
            out.append(data)
        }
        return out
    }
}
