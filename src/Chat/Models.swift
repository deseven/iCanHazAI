// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - Message

enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    /// Tool-result message (OpenAI `tool` role). For Anthropic, rendered as a
    /// `tool_result` content block on a `user` message — handled in ChatService.
    case tool
}

struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var role: MessageRole
    var content: String
    /// Optional thinking/reasoning content (for thinking models).
    var thinking: String?
    /// Optional error text captured while streaming this assistant message.
    /// When non-nil, the message is rendered as an error block with a retry button.
    var error: String?
    /// Wall-clock time the message was created (set once, when the message is
    /// first added to a chat; never updated thereafter). Encoded as a JSON date
    /// so it persists to disk.
    var timestamp: Date
    /// For assistant messages: the display name of the connection that produced
    /// this response. Persisted so it survives reloads. Nil for non-assistant
    /// messages or messages produced before this field existed.
    var connectionName: String?
    /// Attachments on this message (user messages only). Each entry is a
    /// reference to a file stored in the chat's attachment directory: images
    /// (processed to base64), text, or documents (extracted to text). Nil/empty
    /// for messages without attachments.
    var attachments: [Attachment]?
    /// For assistant messages: tool calls issued by the model. Nil for messages
    /// without tool calls.
    var toolCalls: [ToolCall]?
    /// For `tool`-role messages: the result of a tool call. Nil otherwise.
    var toolResults: [ToolResult]?
    /// For assistant messages: token usage reported by the provider for this
    /// response. Nil when the provider didn't report usage (shown as N/A in
    /// the UI) or for non-assistant messages.
    var tokenUsage: TokenUsage?
    /// Fork: alternative continuations after this message. Non-nil only on
    /// the last message of a branch array and always holds ≥2 non-empty
    /// branches. The visible continuation is `branches[activeBranch ?? last]`.
    /// Because the structure is nested, a message physically lives in exactly
    /// one place — no cross-referenced ids that can drift out of sync.
    var branches: [[ChatMessage]]?
    /// Which continuation branch is active. Nil → the last (most recently
    /// added) branch.
    var activeBranch: Int?

    init(
        id: UUID = UUID(), role: MessageRole, content: String, thinking: String? = nil, error: String? = nil,
        timestamp: Date = Date(), connectionName: String? = nil, attachments: [Attachment]? = nil,
        toolCalls: [ToolCall]? = nil, toolResults: [ToolResult]? = nil, tokenUsage: TokenUsage? = nil,
        branches: [[ChatMessage]]? = nil, activeBranch: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.error = error
        self.timestamp = timestamp
        self.connectionName = connectionName
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.tokenUsage = tokenUsage
        self.branches = branches
        self.activeBranch = activeBranch
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, thinking, error, timestamp, connectionName
        case attachments, toolCalls, toolResults, tokenUsage
        case branches, activeBranch
    }

    /// Tolerant decode: every field is optional at the JSON level. A missing or
    /// wrong-typed field falls back to a default instead of throwing, so
    /// externally-edited chat files stay loadable. Only a structurally invalid
    /// object (not a JSON object at all) throws, which lets `Chat` skip the
    /// individual message.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        role = (try? c.decode(MessageRole.self, forKey: .role)) ?? .user
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        thinking = try? c.decode(String.self, forKey: .thinking)
        error = try? c.decode(String.self, forKey: .error)
        timestamp = (try? c.decode(Date.self, forKey: .timestamp)) ?? Date()
        connectionName = try? c.decode(String.self, forKey: .connectionName)
        attachments = try? c.decode([Attachment].self, forKey: .attachments)
        toolCalls = try? c.decode([ToolCall].self, forKey: .toolCalls)
        toolResults = try? c.decode([ToolResult].self, forKey: .toolResults)
        tokenUsage = try? c.decode(TokenUsage.self, forKey: .tokenUsage)
        branches = try? c.decode([[ChatMessage]].self, forKey: .branches)
        activeBranch = try? c.decode(Int.self, forKey: .activeBranch)
    }
}

extension ChatMessage {
    /// A copy detached from the tree (no `branches`/`activeBranch`).
    var detached: ChatMessage {
        var copy = self
        copy.branches = nil
        copy.activeBranch = nil
        return copy
    }

    /// Copies content fields from another message with the same id, keeping
    /// the receiver's tree structure (`branches`/`activeBranch`).
    mutating func applyContent(from other: ChatMessage) {
        role = other.role
        content = other.content
        thinking = other.thinking
        error = other.error
        timestamp = other.timestamp
        connectionName = other.connectionName
        attachments = other.attachments
        toolCalls = other.toolCalls
        toolResults = other.toolResults
        tokenUsage = other.tokenUsage
    }
}

// MARK: - Stopped-turn finalizing

extension ChatMessage {
    /// True when the message carries nothing worth keeping: no content, no
    /// thinking, no error, no tool calls. These are the placeholder assistant
    /// messages created before a stream starts.
    var isEmptyPlaceholder: Bool {
        role == .assistant
            && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (thinking?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && error == nil
            && (toolCalls?.isEmpty ?? true)
    }
}

extension Array where Element == ChatMessage {
    /// The canned result content synthesized for tool calls that never
    /// executed because the stream was stopped.
    static let cancelledToolResultContent = "Tool call was cancelled by the user before it was executed."

    /// Finalizes the incomplete trailing turn left behind when a stream is
    /// stopped mid-flight, so the history stays provider-valid *and* truthful
    /// about side effects that already happened:
    ///
    /// 1. Trailing placeholder assistant messages (nothing streamed into them
    ///    yet) are removed.
    /// 2. If the remaining tail is an assistant message with tool calls:
    ///    - stream-truncated calls (stop arrived while arguments were still
    ///      streaming — empty id/name, never executable) are dropped;
    ///    - every remaining call without a result gets a synthesized
    ///      "cancelled" tool result appended, so the model knows the action
    ///      did *not* happen (and providers get the required one-result-per-
    ///      call shape);
    ///    - calls that did execute keep their real results — the model must
    ///      know those side effects happened.
    ///
    /// Complete tool turns and assistant messages with partial content are
    /// kept untouched.
    mutating func finalizeStoppedTurn() {
        while last?.isEmptyPlaceholder == true {
            removeLast()
        }
        guard let aIdx = indices.reversed().first(where: { self[$0].role == .assistant }),
            var calls = self[aIdx].toolCalls, !calls.isEmpty
        else { return }

        // Drop calls that were cut off mid-stream and never became real.
        calls.removeAll { $0.id.isEmpty || $0.name.isEmpty }
        guard !calls.isEmpty else {
            // Nothing executable was ever issued. The message keeps whatever
            // content/thinking it streamed; if that's nothing, remove it too.
            self[aIdx].toolCalls = nil
            if self[aIdx].isEmptyPlaceholder { remove(at: aIdx) }
            return
        }

        let answered = Set(self[(aIdx + 1)...].flatMap { $0.toolResults ?? [] }.map(\.callID))
        for i in calls.indices {
            // The stream is over: no approval UI should linger, and a diff
            // preview for a call that never ran must not survive.
            calls[i].pendingApproval = false
            if !answered.contains(calls[i].id) {
                calls[i].diff = nil
                var result = ToolResult(
                    callID: calls[i].id, content: Self.cancelledToolResultContent, isError: true, isCancelled: true)
                // Synthesized results bypass the engine's stamping path, so
                // stamp the persisted status summary here — otherwise no
                // surface can show the "cancelled" badge.
                result.summary = ToolSummary.resultStatus(name: calls[i].name, result: result)
                append(ChatMessage(role: .tool, content: "", toolResults: [result]))
            }
        }
        self[aIdx].toolCalls = calls
    }
}

// MARK: - Chat

/// How a chat's responses will be rendered, persisted per chat. The chat
/// inherits the capabilities of the surface that created it: a chat created
/// in the GUI advertises the full renderer; a chat created via the CLI
/// advertises plain-text-only output. Drives the `{output_rendering}` prompt
/// variable at request-build time.
enum ChatOutputRendering: String, Codable, Sendable {
    case rich
    case plain
}

struct Chat: Codable, Identifiable, Equatable {
    var id: UUID
    /// The conversation tree. Linear chats are a plain flat array. Forks are
    /// nested: a message's `branches` holds the alternative continuations
    /// after it (see `ChatMessage.branches`), so tree structure needs no
    /// separate cross-referencing maps. The visible conversation is derived
    /// via `activeMessages`.
    var messages: [ChatMessage]
    /// Selected connection identifier in the form "provider/name", e.g. "openai/myconn".
    /// When the chat's role allows connection overrides this is the per-chat
    /// override; otherwise the role's connection is used and this is ignored.
    /// If role connection is not defined, a default model will be used.
    var connection: String?
    /// Selected role name.
    var role: String?
    /// Per-chat prompt override (name of a prompt file, without extension).
    /// Only honored when the role's `prompt_override_allowed` is true.
    var prompt: String?
    /// The chat's working directory: seeded from the role's
    /// `working_directory` at creation, or picked by the user (picker or CLI)
    /// when the role doesn't pre-set one. Permanent once set — a directory
    /// swap mid-chat confuses the model, so a different directory requires a
    /// new chat.
    var workingDirectory: String?
    /// Names of the custom MCP servers active for this chat. Seeded from the
    /// role's `[[mcps]]` entries when the chat is created (or the role is
    /// assigned); editable per chat only when the role's
    /// `mcps_override_allowed` is true. Nil for chats that predate the field —
    /// they use the role's MCP selection.
    var mcps: [String]?
    /// Optional user-defined display title. When nil the UI derives a title
    /// from the first user message (or "New chat").
    var title: String?
    /// When true, the chat is archived: hidden from the chat list and excluded
    /// from the default sidebar view. Completely optional in the JSON — older
    /// hand-edited or externally-written chat files without this key decode as non-archived.
    var archive: Bool?
    /// Tool call names (namespaced, as advertised to the model) the user chose
    /// to auto-approve for this chat only, via the "Allow for this chat"
    /// button. Appends to the role's auto-allow rules. Completely optional.
    var autoAllow: [String]?
    /// Tool call names (namespaced) the user explicitly requires approval for
    /// in this chat, overriding a role-level auto-allow. Together with
    /// `autoAllow` this lets a chat deviate from role defaults in both
    /// directions; entries matching the role defaults are never written.
    /// Completely optional.
    var autoDeny: [String]?
    /// The rendering target this chat was created from. Nil (and `.rich`)
    /// means the full chat-renderer capabilities; `.plain` means terminal
    /// plain text (CLI-created chats). Completely optional — a chat file
    /// without this key decodes as rich.
    var outputRendering: ChatOutputRendering?
    init(
        id: UUID = UUID(), messages: [ChatMessage] = [], connection: String? = nil, role: String? = nil,
        prompt: String? = nil, workingDirectory: String? = nil, mcps: [String]? = nil, title: String? = nil,
        archive: Bool? = nil, autoAllow: [String]? = nil, autoDeny: [String]? = nil,
        outputRendering: ChatOutputRendering? = nil
    ) {
        self.id = id
        self.messages = messages
        self.connection = connection
        self.role = role
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.mcps = mcps
        self.title = title
        self.archive = archive
        self.autoAllow = autoAllow
        self.autoDeny = autoDeny
        self.outputRendering = outputRendering
    }

    enum CodingKeys: String, CodingKey {
        case id, messages, connection, role, prompt, workingDirectory, mcps, title, archive
        case autoAllow = "auto_allow"
        case autoDeny = "auto_deny"
        case outputRendering = "output_rendering"
    }

    /// Tolerant decode: all scalar fields are optional at the JSON level (a
    /// missing/wrong-typed field falls back to a default), and messages are
    /// recovered one-by-one so a single malformed message is dropped instead of
    /// failing the whole chat. This keeps externally-edited chat files loadable
    /// even when a field's shape is off. Only a structurally invalid JSON document (not an
    /// object, or `messages` not an array) throws, which the loader reports.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        connection = try? c.decode(String.self, forKey: .connection)
        role = try? c.decode(String.self, forKey: .role)
        prompt = try? c.decode(String.self, forKey: .prompt)
        workingDirectory = try? c.decode(String.self, forKey: .workingDirectory)
        mcps = try? c.decode([String].self, forKey: .mcps)
        title = try? c.decode(String.self, forKey: .title)
        archive = try? c.decode(Bool.self, forKey: .archive)
        autoAllow = try? c.decode([String].self, forKey: .autoAllow)
        autoDeny = try? c.decode([String].self, forKey: .autoDeny)
        outputRendering = try? c.decode(ChatOutputRendering.self, forKey: .outputRendering)
        let wrappers = (try? c.decode([SafeMessage].self, forKey: .messages)) ?? []
        let recovered = wrappers.compactMap(\.message)
        let dropped = wrappers.count - recovered.count
        if dropped > 0 {
            debugLog("ChatDecode", "⚠️ skipped \(dropped) undecodable message(s) in a chat")
        }
        messages = recovered
        // Enforce tree invariants (fork owner is last in its array, ≥2
        // non-empty branches, valid active selection) so externally-edited
        // files can't put the tree helpers into weird states.
        Self.normalize(&messages)
    }

    /// Decodes a single message, yielding nil if the element can't be decoded,
    /// so a bad entry is skipped instead of failing the whole `messages` array.
    private struct SafeMessage: Decodable {
        let message: ChatMessage?
        init(from decoder: Decoder) throws { message = try? ChatMessage(from: decoder) }
    }

    /// Wall-clock time of the most recent message, used to order chats in the
    /// sidebar by last activity. Falls back to `Date.distantPast` for empty chats.
    var lastActivity: Date {
        lastActivity(fallback: .distantPast)
    }

    /// Same as [`lastActivity`](src/Chat/Models.swift) but with an explicit fallback
    /// for chats with no messages (or messages lacking timestamps). Used by the
    /// cache so an empty chat sorts by its file modification time rather than
    /// `distantPast` (which would pin it to the very bottom of the list).
    func lastActivity(fallback: Date) -> Date {
        mostRecentTimestamp ?? fallback
    }
}

// MARK: - Chat tree (branches)

extension Chat {

    // MARK: Reads

    /// Whether this chat has any forks. Forks live on messages (`branches`),
    /// and every fork owner's chain bottoms out at a trunk message, so a
    /// top-level scan finds them all.
    var hasForks: Bool { messages.contains { $0.branches != nil } }

    /// The visible conversation: the trunk, descending into the active
    /// branch of each fork (the last branch when no choice is recorded).
    /// Returned messages are detached from the tree (no `branches`).
    var activeMessages: [ChatMessage] {
        var out: [ChatMessage] = []
        var current = messages
        descend: while true {
            for msg in current {
                out.append(msg.detached)
                if let branches = msg.branches, !branches.isEmpty {
                    // Invariant: a fork owner is the last message of its array.
                    current = branches[Self.clampedActive(msg.activeBranch, branchCount: branches.count)]
                    continue descend
                }
            }
            break
        }
        return out
    }

    /// The id of the active leaf (last message on the active path). Nil for
    /// empty chats.
    var activeLeafID: UUID? { activeMessages.last?.id }

    /// Every message in the tree (each branch pre-order), detached.
    var allMessages: [ChatMessage] { Self.flatten(messages) }

    private static func flatten(_ msgs: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for msg in msgs {
            out.append(msg.detached)
            if let branches = msg.branches {
                for branch in branches { out.append(contentsOf: flatten(branch)) }
            }
        }
        return out
    }

    /// The most recent message timestamp anywhere in the tree. Message
    /// creation is append-ordered, so this is the latest activity across
    /// all branches.
    var mostRecentTimestamp: Date? { Self.maxTimestamp(in: messages) }

    private static func maxTimestamp(in msgs: [ChatMessage]) -> Date? {
        var best: Date?
        for msg in msgs {
            if best == nil || msg.timestamp > best! { best = msg.timestamp }
            if let branches = msg.branches {
                for branch in branches {
                    if let t = maxTimestamp(in: branch), best == nil || t > best! { best = t }
                }
            }
        }
        return best
    }

    /// Finds a message by id anywhere in the tree (detached copy).
    func message(id: UUID) -> ChatMessage? { Self.find(id: id, in: messages) }

    private static func find(id: UUID, in msgs: [ChatMessage]) -> ChatMessage? {
        for msg in msgs {
            if msg.id == id { return msg.detached }
            if let branches = msg.branches {
                for branch in branches {
                    if let found = find(id: id, in: branch) { return found }
                }
            }
        }
        return nil
    }

    /// The parent of a message: the previous message in its branch array, or
    /// the fork owner when the message heads a branch. Nil for the very
    /// first message of the chat.
    func parent(of messageID: UUID) -> ChatMessage? { Self.findParent(of: messageID, in: messages) }

    private static func findParent(of id: UUID, in msgs: [ChatMessage]) -> ChatMessage? {
        for i in msgs.indices {
            if msgs[i].id == id { return i > 0 ? msgs[i - 1].detached : nil }
            if let branches = msgs[i].branches {
                for branch in branches {
                    if branch.first?.id == id { return msgs[i].detached }
                    if let p = findParent(of: id, in: branch) { return p }
                }
            }
        }
        return nil
    }

    /// The sibling index and count for a message: its position among the
    /// branch heads of its fork. `(0, 1)` for messages that don't head a
    /// branch (linear chats and mid-branch messages) — the switcher UI only
    /// appears when `count > 1`.
    func siblings(of messageID: UUID) -> (index: Int, count: Int) {
        Self.findSiblings(of: messageID, in: messages) ?? (0, 1)
    }

    private static func findSiblings(of id: UUID, in msgs: [ChatMessage]) -> (Int, Int)? {
        for msg in msgs {
            if let branches = msg.branches {
                for (b, branch) in branches.enumerated() {
                    if branch.first?.id == id { return (b, branches.count) }
                    if let s = findSiblings(of: id, in: branch) { return s }
                }
            }
        }
        return nil
    }

    /// The path from the root to the given message, as an array of message
    /// ids. Walks up via parent links.
    func leafPath(to messageID: UUID) -> [UUID] {
        var path: [UUID] = [messageID]
        var current = messageID
        var visited = Set<UUID>([messageID])
        while let parent = parent(of: current), visited.insert(parent.id).inserted {
            path.insert(parent.id, at: 0)
            current = parent.id
        }
        return path
    }

    /// All message ids in the subtree rooted at `messageID`: the message and
    /// everything after it in its branch array, including nested branches.
    func subtreeIDs(of messageID: UUID) -> Set<UUID> {
        guard let suffix = Self.suffixFrom(id: messageID, in: messages) else { return [messageID] }
        return Set(Self.flatten(suffix).map(\.id))
    }

    private static func suffixFrom(id: UUID, in msgs: [ChatMessage]) -> [ChatMessage]? {
        for i in msgs.indices {
            if msgs[i].id == id { return Array(msgs[i...]) }
            if let branches = msgs[i].branches {
                for branch in branches {
                    if let s = suffixFrom(id: id, in: branch) { return s }
                }
            }
        }
        return nil
    }

    /// The id of the most recent `tool`-role message carrying a result for
    /// `callID`, bounded to the current turn on the active path (messages
    /// after the last assistant message). Older turns are excluded on
    /// purpose: provider-issued call IDs are only unique per response, so a
    /// previous turn may carry the same ID, and touching its message would
    /// corrupt persisted history.
    func activeToolResultMessageID(callID: String) -> UUID? {
        let active = activeMessages
        let turnStart = active.indices.reversed().first(where: { active[$0].role == .assistant }).map { $0 + 1 } ?? 0
        return active.indices.reversed().first(where: {
            $0 >= turnStart
                && active[$0].role == .tool
                && active[$0].toolResults?.contains(where: { $0.callID == callID }) ?? false
        }).map { active[$0].id }
    }

    // MARK: Mutations

    /// Applies `transform` to the message with the given id, wherever it
    /// lives in the tree. No-op when the id doesn't exist.
    mutating func updateMessage(id: UUID, _ transform: (inout ChatMessage) -> Void) {
        Self.update(id: id, in: &messages, transform)
    }

    @discardableResult
    private static func update(id: UUID, in msgs: inout [ChatMessage], _ transform: (inout ChatMessage) -> Void) -> Bool
    {
        for i in msgs.indices {
            if msgs[i].id == id {
                transform(&msgs[i])
                return true
            }
            if var branches = msgs[i].branches {
                for b in branches.indices {
                    if update(id: id, in: &branches[b], transform) {
                        msgs[i].branches = branches
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Appends a message at the end of the active path. This is the only way
    /// new messages enter the tree, so a message can never land on a
    /// non-active branch.
    mutating func appendToActiveLeaf(_ message: ChatMessage) {
        Self.appendToActive(message, in: &messages)
    }

    private static func appendToActive(_ message: ChatMessage, in msgs: inout [ChatMessage]) {
        if var branches = msgs.last?.branches, !branches.isEmpty {
            let lastIdx = msgs.count - 1
            let activeIdx = clampedActive(msgs[lastIdx].activeBranch, branchCount: branches.count)
            appendToActive(message, in: &branches[activeIdx])
            msgs[lastIdx].branches = branches
        } else {
            msgs.append(message)
        }
    }

    /// Regen-style fork: the message (with its whole subtree) stays stored as
    /// an inactive sibling branch and `new` becomes the active branch head.
    /// When the message already heads a branch of an existing fork, another
    /// branch is simply added to that fork. Returns false when the message
    /// isn't found or is the first message of the chat (no parent to hang a
    /// fork on).
    @discardableResult
    mutating func forkRegenerating(_ messageID: UUID, adding new: ChatMessage) -> Bool {
        Self.forkRegen(messageID, adding: new, in: &messages)
    }

    private static func forkRegen(_ target: UUID, adding new: ChatMessage, in msgs: inout [ChatMessage]) -> Bool {
        for i in msgs.indices {
            if msgs[i].id == target {
                guard i > 0 else { return false }
                let suffix = Array(msgs[i...])
                msgs.removeLast(msgs.count - i)
                // By invariant msgs[i-1] was not the array tail before the
                // truncation, so it carries no branches yet.
                msgs[i - 1].branches = [suffix, [new]]
                msgs[i - 1].activeBranch = 1
                return true
            }
            if var branches = msgs[i].branches {
                for b in branches.indices {
                    if branches[b].first?.id == target {
                        branches.append([new])
                        msgs[i].branches = branches
                        msgs[i].activeBranch = branches.count - 1
                        return true
                    }
                    if forkRegen(target, adding: new, in: &branches[b]) {
                        msgs[i].branches = branches
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Edit-style fork: makes `new` the active continuation right after
    /// `afterID`. The existing continuation (the inline tail or the existing
    /// branches) is preserved as inactive sibling branch(es). When the
    /// message is a leaf, this is a plain append.
    @discardableResult
    mutating func forkContinuing(after afterID: UUID, adding new: ChatMessage) -> Bool {
        Self.forkContinue(afterID, adding: new, in: &messages)
    }

    private static func forkContinue(_ target: UUID, adding new: ChatMessage, in msgs: inout [ChatMessage]) -> Bool {
        for i in msgs.indices {
            if msgs[i].id == target {
                if var branches = msgs[i].branches {
                    branches.append([new])
                    msgs[i].branches = branches
                    msgs[i].activeBranch = branches.count - 1
                } else if i + 1 < msgs.count {
                    let suffix = Array(msgs[(i + 1)...])
                    msgs.removeLast(msgs.count - i - 1)
                    msgs[i].branches = [suffix, [new]]
                    msgs[i].activeBranch = 1
                } else {
                    msgs.append(new)
                }
                return true
            }
            if var branches = msgs[i].branches {
                for b in branches.indices {
                    if forkContinue(target, adding: new, in: &branches[b]) {
                        msgs[i].branches = branches
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Sets the active continuation branch of `parentID` to the branch
    /// starting with `childID`. No-op (false) when either id is unknown or
    /// the child doesn't head one of the parent's branches.
    @discardableResult
    mutating func switchActiveBranch(parentID: UUID, to childID: UUID) -> Bool {
        Self.setActive(parentID: parentID, childID: childID, in: &messages)
    }

    private static func setActive(parentID: UUID, childID: UUID, in msgs: inout [ChatMessage]) -> Bool {
        for i in msgs.indices {
            if var branches = msgs[i].branches {
                if msgs[i].id == parentID {
                    guard let b = branches.firstIndex(where: { $0.first?.id == childID }) else { return false }
                    msgs[i].activeBranch = b
                    return true
                }
                for b in branches.indices {
                    if setActive(parentID: parentID, childID: childID, in: &branches[b]) {
                        msgs[i].branches = branches
                        return true
                    }
                }
            }
        }
        return false
    }

    /// The sibling to switch to when the user clicks ◀ or ▶ on a branch
    /// head: `direction` -1 (previous) or +1 (next), wrapping around. Nil
    /// when the message doesn't head a branch or the fork has <2 branches.
    func siblingID(of messageID: UUID, direction: Int) -> UUID? {
        Self.findSiblingSwitch(of: messageID, direction: direction, in: messages)
    }

    private static func findSiblingSwitch(of id: UUID, direction: Int, in msgs: [ChatMessage]) -> UUID? {
        for msg in msgs {
            if let branches = msg.branches {
                for (b, branch) in branches.enumerated() {
                    if branch.first?.id == id {
                        guard branches.count > 1 else { return nil }
                        return branches[(b + direction + branches.count) % branches.count].first?.id
                    }
                    if let r = findSiblingSwitch(of: id, direction: direction, in: branch) { return r }
                }
            }
        }
        return nil
    }

    /// Removes a message and its entire subtree (everything after it in its
    /// branch, including nested forks), returning the removed messages
    /// (detached) so the caller can clean up attachments. For linear chats
    /// this is a plain truncation. Invariants are restored afterwards: a
    /// branch emptied by the removal is dropped (a removed active selection
    /// falls back to the most recent survivor) and a fork reduced to a
    /// single branch is unwrapped inline.
    @discardableResult
    mutating func deleteSubtree(of messageID: UUID) -> [ChatMessage] {
        let removed = Self.delete(messageID, in: &messages).map { Self.flatten($0) } ?? []
        Self.normalize(&messages)
        return removed
    }

    private static func delete(_ target: UUID, in msgs: inout [ChatMessage]) -> [ChatMessage]? {
        for i in msgs.indices {
            if msgs[i].id == target {
                let removed = Array(msgs[i...])
                msgs.removeLast(msgs.count - i)
                return removed
            }
            if var branches = msgs[i].branches {
                for b in branches.indices {
                    if let removed = delete(target, in: &branches[b]) {
                        if branches[b].isEmpty {
                            branches.remove(at: b)
                            // The recorded active branch is gone → fall back
                            // to the most recent survivor (nil = last); a
                            // removal before it shifts the index.
                            if let a = msgs[i].activeBranch {
                                if a == b { msgs[i].activeBranch = nil } else if a > b { msgs[i].activeBranch = a - 1 }
                            }
                        }
                        msgs[i].branches = branches
                        return removed
                    }
                }
            }
        }
        return nil
    }

    /// Points every fork on the way to `messageID` at the branch containing
    /// it, so the message lands on the active path. No-op (false) for
    /// unknown ids.
    @discardableResult
    mutating func activatePath(to messageID: UUID) -> Bool {
        Self.activate(messageID, in: &messages)
    }

    private static func activate(_ target: UUID, in msgs: inout [ChatMessage]) -> Bool {
        for i in msgs.indices {
            if msgs[i].id == target { return true }
            if var branches = msgs[i].branches {
                for b in branches.indices {
                    if containsID(target, in: branches[b]) {
                        msgs[i].activeBranch = b
                        _ = activate(target, in: &branches[b])
                        msgs[i].branches = branches
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func containsID(_ id: UUID, in msgs: [ChatMessage]) -> Bool {
        for msg in msgs {
            if msg.id == id { return true }
            if let branches = msg.branches, branches.contains(where: { containsID(id, in: $0) }) {
                return true
            }
        }
        return false
    }

    /// Points every fork's active branch at the path to the leaf with the
    /// most recent timestamp, ignoring recorded choices. Used by the CLI,
    /// which appends to the freshest branch.
    mutating func setActivePathToMostRecentLeaf() {
        guard let (_, choices) = Self.freshestLeaf(in: messages) else { return }
        Self.applyChoices(choices, in: &messages)
    }

    /// The newest leaf timestamp in the array and the branch choices leading
    /// to it. Only the array's last message can lead to leaves (invariant:
    /// fork owners are last).
    private static func freshestLeaf(in msgs: [ChatMessage]) -> (Date, [Int])? {
        guard let last = msgs.last else { return nil }
        guard let branches = last.branches, !branches.isEmpty else { return (last.timestamp, []) }
        var best: (Date, [Int])?
        for (b, branch) in branches.enumerated() {
            if let candidate = freshestLeaf(in: branch), best == nil || candidate.0 > best!.0 {
                best = (candidate.0, [b] + candidate.1)
            }
        }
        return best
    }

    private static func applyChoices(_ choices: [Int], in msgs: inout [ChatMessage]) {
        guard let choice = choices.first, var branches = msgs.last?.branches,
            (0..<branches.count).contains(choice)
        else { return }
        msgs[msgs.count - 1].activeBranch = choice
        applyChoices(Array(choices.dropFirst()), in: &branches[choice])
        msgs[msgs.count - 1].branches = branches
    }

    /// Finalizes the incomplete trailing turn on the active path (see
    /// [`Array.finalizeStoppedTurn`](src/Chat/Models.swift) for the turn
    /// semantics). Operates directly on the tree: removed trailing
    /// placeholders form a contiguous active-path tail (they never carry
    /// branches), so deleting the first one's subtree covers them all;
    /// modified messages are written back by id (structure preserved);
    /// synthesized results append to the active leaf.
    mutating func finalizeActiveStoppedTurn() {
        var active = activeMessages
        let before = active
        active.finalizeStoppedTurn()
        guard active != before else { return }
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let afterIDs = Set(active.map(\.id))
        if let firstRemoved = before.first(where: { !afterIDs.contains($0.id) }) {
            deleteSubtree(of: firstRemoved.id)
        }
        for msg in active {
            if let original = beforeByID[msg.id], original != msg {
                updateMessage(id: msg.id) { $0.applyContent(from: msg) }
            }
        }
        for msg in active where beforeByID[msg.id] == nil {
            appendToActiveLeaf(msg)
        }
    }

    // MARK: Invariants

    /// The branch index to follow when none (or an invalid one) is recorded:
    /// the last branch — the most recently added continuation.
    private static func clampedActive(_ active: Int?, branchCount: Int) -> Int {
        guard let active, (0..<branchCount).contains(active) else { return branchCount - 1 }
        return active
    }

    /// Restores tree invariants, recursing into branches:
    /// - a fork owner must be the last message of its array (a trailing
    ///   inline tail is folded into a new first branch);
    /// - forks need ≥2 non-empty branches (fewer → unwrapped inline);
    /// - `activeBranch` must be a valid index (else nil = last).
    static func normalize(_ msgs: inout [ChatMessage]) {
        var i = 0
        while i < msgs.count {
            if var branches = msgs[i].branches {
                for b in branches.indices { normalize(&branches[b]) }
                branches.removeAll { $0.isEmpty }
                if i + 1 < msgs.count {
                    var tail = Array(msgs[(i + 1)...])
                    msgs.removeLast(msgs.count - i - 1)
                    normalize(&tail)
                    branches.insert(tail, at: 0)
                }
                if branches.count >= 2 {
                    if let a = msgs[i].activeBranch, !(0..<branches.count).contains(a) {
                        msgs[i].activeBranch = nil
                    }
                    msgs[i].branches = branches
                } else {
                    // Degenerate fork: unwrap the surviving branch inline.
                    msgs[i].branches = nil
                    msgs[i].activeBranch = nil
                    if let single = branches.first {
                        msgs.insert(contentsOf: single, at: i + 1)
                    }
                }
            } else if msgs[i].activeBranch != nil {
                msgs[i].activeBranch = nil
            }
            i += 1
        }
    }
}

// MARK: - Per-chat tool approval overrides

extension Chat {
    /// Whether a tool (by namespaced name, as advertised to the model) is
    /// effectively auto-approved for this chat: the role default, adjusted by
    /// the chat's own `autoAllow` / `autoDeny` lists. A deny entry always wins.
    func isToolAutoApproved(namespacedName: String, roleDefault: Bool) -> Bool {
        if autoDeny?.contains(namespacedName) == true { return false }
        return roleDefault || (autoAllow?.contains(namespacedName) ?? false)
    }

    /// Sets the per-chat auto-approval state for a tool, relative to the
    /// role's default. When the target state matches the role default, both
    /// override lists are cleaned of the entry (nothing extra is persisted);
    /// otherwise the entry lands in `autoAllow` (approved) or `autoDeny`
    /// (requires approval). Empty lists are normalized back to nil.
    mutating func setToolAutoApproval(namespacedName: String, approved: Bool, roleDefault: Bool) {
        autoAllow?.removeAll { $0 == namespacedName }
        autoDeny?.removeAll { $0 == namespacedName }
        if approved != roleDefault {
            if approved {
                autoAllow = (autoAllow ?? []) + [namespacedName]
            } else {
                autoDeny = (autoDeny ?? []) + [namespacedName]
            }
        }
        if autoAllow?.isEmpty == true { autoAllow = nil }
        if autoDeny?.isEmpty == true { autoDeny = nil }
    }

    /// Flips the effective per-chat auto-approval state for a tool.
    mutating func toggleToolAutoApproval(namespacedName: String, roleDefault: Bool) {
        let current = isToolAutoApproved(namespacedName: namespacedName, roleDefault: roleDefault)
        setToolAutoApproval(namespacedName: namespacedName, approved: !current, roleDefault: roleDefault)
    }
}

// MARK: - ChatRecord

/// A chat plus its live runtime status, as owned by `ChatEngine`.
/// This is the UI-facing representation that flows through `AppViewModel`.
///
/// `chat` is nil when the chat is not loaded — the full message history is
/// only in memory while the chat is needed (the user has it open, or agentic
/// work is in flight). It is dropped the instant neither holds, via
/// `ChatEngine.releaseChat`. Cached metadata (`cachedName`,
/// `cachedModificationTime`) comes from the SwiftData cache and is always
/// available, even when the chat is unloaded, so the sidebar can display and
/// sort chats without touching disk.
struct ChatRecord: Identifiable, Equatable, Sendable {
    var id: String { filename }
    let filename: String
    /// Full chat data, or nil when unloaded. Loaded on demand via
    /// `ChatStore.loadChat` when the user opens the chat or streaming starts.
    var chat: Chat?
    /// Per-chat snapshot store of what file content the model has seen,
    /// derived from the chat's message history. `nil` when the chat is
    /// unloaded; rebuilt at the start of a request (see
    /// [`BuiltinTools.rebuildSnapshots`](src/Tools/BuiltinTools.swift)) and
    /// kept alive for the request's duration, updated live as tools execute.
    /// Transient runtime state — never persisted. Excluded from `Equatable`
    /// (it is a reference type and does not affect the UI-facing snapshot).
    var snapshotStore: SnapshotStore?
    /// Whether a streaming request is currently in flight for this chat.
    var isStreaming: Bool
    /// Whether a "stop after current iteration" request is pending: the
    /// stream finishes the in-flight model response and any tool calls it
    /// emitted, then stops without sending the results back to the model.
    var stopAfterIteration: Bool
    /// Whether this chat has new activity (a finished stream or new message)
    /// since the user last viewed it.
    var hasUnreadActivity: Bool
    /// Last error captured for this chat, if any.
    var lastError: String?
    /// In-memory creation time. Used to order empty chats (which have no
    /// messages yet) in the sidebar; once a message exists the chat switches
    /// to ordering by the last message timestamp.
    var createdAt: Date
    /// Cached display name from SwiftData. Available even when `chat` is nil.
    var cachedName: String?
    /// Cached role name from SwiftData. Mirrors `Chat.role` so the sidebar
    /// can badge each chat with its role without loading the full chat.
    var cachedRole: String?
    /// Cached file modification time from SwiftData. Used only for cache
    /// invalidation (comparing against the on-disk mod time). NOT used for
    /// sorting — see `cachedLastActivity`.
    var cachedModificationTime: Date
    /// Cached archive flag from SwiftData. Mirrors `Chat.archive` so the
    /// sidebar can hide archived chats without loading the full chat.
    var cachedArchive: Bool
    /// Cached working directory from SwiftData. Mirrors
    /// `Chat.workingDirectory` so the sidebar can filter chats by directory
    /// without loading the full chat.
    var cachedWorkingDirectory: String?
    /// Cached last-activity time from SwiftData (the most recent message
    /// timestamp, or `distantPast` for empty chats). Used as the sidebar
    /// sort key when the chat is unloaded, so the sidebar order reflects
    /// real chat activity rather than file-touch events.
    var cachedLastActivity: Date
    /// Whether this is a temporary chat: it exists only in memory (never
    /// persisted to disk, never listed in the sidebar) and is destroyed
    /// irreversibly as soon as another chat is selected or created.
    var isTemporary: Bool

    init(
        filename: String, chat: Chat? = nil, snapshotStore: SnapshotStore? = nil, cachedName: String? = nil,
        cachedRole: String? = nil, cachedModificationTime: Date = Date(), cachedArchive: Bool = false,
        cachedWorkingDirectory: String? = nil, cachedLastActivity: Date = .distantPast, isStreaming: Bool = false,
        stopAfterIteration: Bool = false, hasUnreadActivity: Bool = false, lastError: String? = nil,
        createdAt: Date = Date(), isTemporary: Bool = false
    ) {
        self.filename = filename
        self.chat = chat
        self.snapshotStore = snapshotStore
        self.cachedName = cachedName
        self.cachedRole = cachedRole
        self.cachedModificationTime = cachedModificationTime
        self.cachedArchive = cachedArchive
        self.cachedWorkingDirectory = cachedWorkingDirectory
        self.cachedLastActivity = cachedLastActivity
        self.isStreaming = isStreaming
        self.stopAfterIteration = stopAfterIteration
        self.hasUnreadActivity = hasUnreadActivity
        self.lastError = lastError
        self.createdAt = createdAt
        self.isTemporary = isTemporary
    }

    /// The role name to display for this chat: the live chat's role when
    /// loaded (authoritative), otherwise the cached role. Nil when neither
    /// is set.
    var effectiveRoleName: String? {
        chat?.role ?? cachedRole
    }

    /// The working directory for this chat: the live chat's value when
    /// loaded (authoritative), otherwise the cached value. Nil when neither
    /// is set.
    var effectiveWorkingDirectory: String? {
        chat?.workingDirectory ?? cachedWorkingDirectory
    }

    /// Whether this chat is archived: the live chat's `archive` flag when
    /// loaded (authoritative), otherwise the cached flag. Archived chats are
    /// hidden from the chat list.
    var isArchived: Bool {
        chat?.archive ?? cachedArchive
    }

    /// Cumulative token usage across all assistant responses in this chat.
    /// Nil when the chat is unloaded or has no usage data.
    var tokenUsage: TokenUsage? {
        guard let chat = chat else { return nil }
        let usages = chat.activeMessages.compactMap { $0.tokenUsage }
        guard !usages.isEmpty else { return nil }
        return TokenUsage(
            tokensUsed: usages.reduce(0) { $0 + $1.tokensUsed },
            inputTokens: usages.reduce(0) { $0 + $1.inputTokens },
            outputTokens: usages.reduce(0) { $0 + $1.outputTokens },
            cachedInputTokens: usages.reduce(0) { $0 + $1.cachedInputTokens },
            cacheCreationTokens: usages.reduce(0) { $0 + $1.cacheCreationTokens }
        )
    }

    /// Total token count (input + output + cached) across all assistant
    /// responses. Convenience alias of `tokenUsage?.tokensUsed`.
    var tokenCount: Int? {
        tokenUsage?.tokensUsed
    }

    /// Key used to order chats in the sidebar. When the chat is loaded, uses
    /// the last message timestamp (or `createdAt` for empty chats). When
    /// unloaded, falls back to the cached last-activity time (the most recent
    /// message timestamp, captured at cache-upsert time). This is distinct
    /// from `cachedModificationTime` (the file's mod time, used only for cache
    /// invalidation) so a file touch without new messages doesn't re-order.
    var sortKey: Date {
        if let chat = chat {
            return chat.activeMessages.last?.timestamp ?? createdAt
        }
        return cachedLastActivity
    }

    /// Display title derived from the loaded chat's title / first user
    /// message, or from the cached name when the chat is unloaded.
    var displayTitle: String {
        let emptyTitle = isTemporary ? "Temporary chat" : "New chat"
        if let chat = chat {
            if let title = chat.title, !title.isEmpty {
                return title
            }
            if let firstUser = chat.activeMessages.first(where: { $0.role == .user }) {
                return String(firstUser.content.prefix(40))
            }
            return emptyTitle
        }
        if let name = cachedName, !name.isEmpty {
            return name
        }
        return emptyTitle
    }

    static func == (lhs: ChatRecord, rhs: ChatRecord) -> Bool {
        // `snapshotStore` is transient runtime state (a reference type) and
        // must not participate in equality — the engine mutates it live during
        // a request, which would otherwise churn the UI diff for every tool
        // call. Compare everything else field-by-field.
        if lhs.filename != rhs.filename { return false }
        if lhs.chat != rhs.chat { return false }
        if lhs.isStreaming != rhs.isStreaming { return false }
        if lhs.stopAfterIteration != rhs.stopAfterIteration { return false }
        if lhs.hasUnreadActivity != rhs.hasUnreadActivity { return false }
        if lhs.lastError != rhs.lastError { return false }
        if lhs.createdAt != rhs.createdAt { return false }
        if lhs.cachedName != rhs.cachedName { return false }
        if lhs.cachedRole != rhs.cachedRole { return false }
        if lhs.cachedModificationTime != rhs.cachedModificationTime { return false }
        if lhs.cachedArchive != rhs.cachedArchive { return false }
        if lhs.cachedWorkingDirectory != rhs.cachedWorkingDirectory { return false }
        if lhs.cachedLastActivity != rhs.cachedLastActivity { return false }
        if lhs.isTemporary != rhs.isTemporary { return false }
        return true
    }
}

// MARK: - ChatSummary

/// A cheap, message-free projection of a `ChatRecord` for the sidebar list.
/// The sidebar only needs a handful of scalars (title, streaming/unread/error
/// flags, sort key) — it never inspects `chat.messages`. Diffing it is
/// O(1)-per-chat, so a busy chat's per-token emits don't force the sidebar
/// to re-diff full message arrays for every chat.
struct ChatSummary: Identifiable, Hashable, Sendable {
    var id: String { filename }
    let filename: String
    let displayTitle: String
    /// Role name for this chat (live role when loaded, else cached). The
    /// sidebar badges each row with this. Nil when no role is set.
    let roleName: String?
    /// Working directory for this chat (live value when loaded, else cached).
    /// The sidebar filters by this in "By Directory" mode. Nil when no
    /// directory is set.
    let workingDirectory: String?
    let isStreaming: Bool
    let hasUnreadActivity: Bool
    let lastError: String?
    /// Sort key (last message timestamp or in-memory creation time). The
    /// sidebar uses this to keep its ordering in sync with the engine without
    /// needing the message arrays.
    let sortKey: Date
    /// Whether this chat is archived (hidden from the chat list).
    let isArchived: Bool
    /// Whether this is a temporary chat (never listed in the sidebar).
    let isTemporary: Bool

    init(record: ChatRecord) {
        self.filename = record.filename
        self.displayTitle = record.displayTitle
        self.roleName = record.effectiveRoleName
        self.workingDirectory = record.effectiveWorkingDirectory
        self.isStreaming = record.isStreaming
        self.hasUnreadActivity = record.hasUnreadActivity
        self.lastError = record.lastError
        self.sortKey = record.sortKey
        self.isArchived = record.isArchived
        self.isTemporary = record.isTemporary
    }
}

// MARK: - One-shot (CLI) requests

/// A stream event for a CLI one-shot request, tapped directly from the
/// engine's chunk pipeline (unlike `chatsChanged`, these are not coalesced —
/// the CLI sees tokens as they arrive).
enum OneShotEvent: Sendable {
    /// A content chunk appended to the current assistant message.
    case delta(String)
    /// A tool call began execution. `summary` is the collapsed one-line
    /// argument summary (see `ToolCall.summary`).
    case toolCall(name: String, summary: String)
    /// A tool call produced its final result. `summary` is the persisted
    /// one-line status summary (see `ToolResult.summary`).
    case toolResult(name: String, summary: ToolSummary.Status)
    /// A tool call of an interactive CLI session awaits the user's
    /// confirmation. `summary` is the collapsed one-line argument summary
    /// (see `ToolCall.summary`). The CLI answers out of band; the stream
    /// resumes with the corresponding `toolResult`.
    case toolApprovalRequest(callID: String, name: String, summary: String?)
    /// A warning worth surfacing to the CLI user (e.g. an ignored --workdir,
    /// a tool call skipped for lack of --allow-all). Not part of the chat.
    case notice(String)
    /// The stream settled (success, error, or cancellation). `error` carries
    /// the failure text when the stream failed; nil on success/cancel.
    /// `chatName` is the chat's current display name (best effort — the
    /// generated title may not have landed yet).
    case finished(error: String?, chatName: String?)
}

/// The outcome of asking the engine to perform a one-shot request.
enum OneShotStart: Sendable {
    /// The chat was created (or reused) and streaming has begun. `filename`
    /// identifies the chat so the CLI user can find it in the GUI.
    case started(filename: String, events: AsyncStream<OneShotEvent>)
    /// The request was rejected before anything was sent (bad role/connection/
    /// chat selector, or no usable connection configured).
    case failed(String)
}

// MARK: - EngineEvent

/// Events emitted by `ChatEngine` to its subscribers.
enum EngineEvent: Sendable {
    /// The full set of chat records changed (load, add, edit, delete, streaming state).
    case chatsChanged([ChatRecord])
    case rolesChanged([Role])
    case promptsChanged([Prompt])
    case connectionsChanged([Connection])
    /// The set of configured MCP servers changed (load, add, edit, delete).
    case mcpsChanged([MCPServer])
    /// The live MCP configuration status changed (a server's connect/listTools
    /// step started, succeeded, or failed). The UI uses this to drive the
    /// configuration overlay. Carries the full snapshot so the overlay always
    /// reflects the current state.
    case mcpConfiguration(MCPConfigurationState)
    /// A batch of external Application-resource reloads (config / connections /
    /// prompts / roles) just started. Carries the per-resource totals the
    /// loader shows in its labels. The corresponding "completed" signal is the
    /// existing `.configChanged` / `.rolesChanged` / `.promptsChanged` /
    /// `.connectionsChanged` event for each resource.
    case loaderActivity(LoaderActivity)
    /// `config.toml` was reloaded from disk (external edit picked up via FSEvents).
    /// The UI should refresh its cached preferences from `ConfigManager`.
    case configChanged
    /// The engine is waiting for the user to approve a tool call. The UI uses
    /// this to draw attention: blink the chat in the sidebar (if it isn't the
    /// active one) and bounce the dock icon (if the window isn't key/front).
    /// Note: the chat remains in its streaming state — this is a pause, not a
    /// stop.
    case toolApprovalRequested(filename: String, callID: String)
    /// A previously-requested tool approval was resolved (allowed, denied, or
    /// cancelled by a stop). The UI clears any attention it drew for it.
    case toolApprovalResolved(filename: String, callID: String)
    case error(String)
    /// The set of gathered configuration errors changed (a connection/role/MCP
    /// config failed to load, or an MCP server failed at runtime, or a
    /// previously-broken entity was fixed/removed on disk). The UI shows a
    /// warning button in the title bar while the array is non-empty. Carries
    /// the full snapshot so subscribers always reflect the current state.
    case configErrorsChanged([ConfigError])
}

// MARK: - Config errors

/// A configuration problem surfaced to the user (and the Configurator) for
/// manual repair. Each entry identifies the failing entity by `kind` and
/// `entityName`, plus a human-readable `message`. The set is rebuilt by
/// [`ChatEngine`](src/Chat/ChatEngine.swift) whenever the on-disk configuration is
/// reloaded, so it naturally shrinks as broken entities are fixed or removed.
///
/// `id` is `"<kind>:<entityName>"` — stable across rebuilds so the UI diffs the
/// list without flicker, and so the engine can replace/clear a single entity's
/// entry without touching the rest.
struct ConfigError: Identifiable, Equatable, Sendable, Hashable {
    var id: String { "\(kind.rawValue):\(entityName)" }
    let kind: Kind
    let entityName: String
    let message: String

    enum Kind: String, Sendable {
        /// A connection `.jsonc` file failed to parse/validate.
        case connection
        /// A role `.toml` file failed to parse/validate.
        case role
        /// A custom MCP `.toml` config failed to parse/validate.
        case mcpConfig
        /// A custom MCP server failed to connect / list tools at runtime.
        case mcpFailure
        /// A prompt `.md` file failed to validate (e.g. unknown variables).
        case prompt
    }

    /// Human-readable label for the entity kind, shown in the errors window.
    var kindLabel: String {
        switch kind {
        case .connection: return "Connection"
        case .role: return "Role"
        case .mcpConfig: return "MCP config"
        case .mcpFailure: return "MCP server"
        case .prompt: return "Prompt"
        }
    }

    /// One-line description used when pasting errors into a Configurator chat,
    /// e.g. `Connection `openai/gpt-5` is invalid (error: "Missing model").`.
    var configuratorLine: String {
        switch kind {
        case .connection:
            return "Connection `\(entityName)` is invalid (error: \"\(message)\")."
        case .role:
            return "Role `\(entityName)` is invalid (error: \"\(message)\")."
        case .mcpConfig:
            return "MCP server `\(entityName)` has an invalid config (error: \"\(message)\")."
        case .mcpFailure:
            return "MCP server `\(entityName)` failed on startup (error: \"\(message)\")."
        case .prompt:
            return "Prompt `\(entityName)` is invalid (error: \"\(message)\")."
        }
    }
}

// MARK: - MCP configuration status

/// The status of a single MCP server during the configuration flow.
enum MCPConfigStatus: String, Sendable, Equatable {
    /// Not yet started (queued).
    case pending
    /// Currently connecting / listing tools.
    case inProgress
    /// Connected and tools listed successfully.
    case success
    /// Failed to connect or list tools; the server was discarded.
    case failed
}

/// A single row in the MCP configuration overlay: the server name and its
/// current status. `toolCount` is shown for successful servers.
struct MCPConfigurationEntry: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    var status: MCPConfigStatus
    /// Number of tools discovered, for successful entries. Nil otherwise.
    var toolCount: Int?
    /// Human-readable error message for failed entries. Nil otherwise.
    var errorMessage: String?
}

/// The full state of an MCP configuration pass. Drives the overlay UI.
struct MCPConfigurationState: Sendable, Equatable {
    /// Whether a configuration pass is currently in progress. The overlay is
    /// shown while this is true (and there is at least one entry).
    var isConfiguring: Bool
    /// One entry per configured server, in the order they were started.
    var entries: [MCPConfigurationEntry]

    static let empty = MCPConfigurationState(isConfiguring: false, entries: [])
}

// MARK: - Prompt

/// A prompt file (`~/iCanHazAI/prompts/<name>.md`). The system prompt sent to
/// the model is the content of the prompt referenced by the chat's role (or
/// the chat's per-chat prompt override when allowed).
struct Prompt: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let content: String
    /// True for built-in prompts served from the app bundle (never
    /// user-editable). Derived from the protected built-in name set.
    var isBuiltin: Bool { EnvironmentManager.protectedBundleNames.contains(name) }
}

// MARK: - Role config (TOML)

/// One custom MCP entry within a role config. Built-in tool groups
/// (Utils/Filesystem/Code/Shell) are described as top-level TOML groups
/// (`[utils]`, `[filesystem]`, …) and decoded into `RoleConfig` directly;
/// only custom MCP servers use `[[mcps]]` array-of-tables entries.
struct RoleMCP: Codable, Equatable, Hashable, Sendable {
    var mcp: String
    /// Tool selection from this MCP. Empty/nil means all available tools.
    var tools: [String]?
    /// Tools to auto-approve (raw tool names, without prefix). Empty/nil = none.
    var autoAllow: [String]?
    /// When true, all available tools from this MCP are auto-approved.
    var autoAllowAll: Bool?

    enum CodingKeys: String, CodingKey {
        case mcp
        case tools
        case autoAllow = "auto_allow"
        case autoAllowAll = "auto_allow_all"
    }
}

/// Configuration for a single built-in tool group (`[utils]`, `[filesystem]`,
/// `[code]`, `[shell]`). An empty group (just `[utils]` with no keys) enables
/// the group with all defaults: all tools allowed, none auto-approved.
struct RoleToolGroup: Codable, Equatable, Hashable, Sendable {
    /// Tool selection from this group. Empty/nil means all available tools.
    var tools: [String]?
    /// Tools to auto-approve (raw tool names). Empty/nil = none.
    var autoAllow: [String]?
    /// When true, all tools from this group are auto-approved.
    var autoAllowAll: Bool?
    /// Shell-only: commands that bypass the approval prompt. When the shell
    /// tool requires confirmation, a command is auto-approved only if every
    /// command name in it is present in this list. Commands too complex to
    /// parse (subshells, command substitution, loops, etc.) always require
    /// confirmation. No-op when the shell tool is already auto-approved.
    var shellWhitelist: [String]?

    enum CodingKeys: String, CodingKey {
        case tools
        case autoAllow = "auto_allow"
        case autoAllowAll = "auto_allow_all"
        case shellWhitelist = "shell_whitelist"
    }
}

/// Per-role UI capability flags. All keys optional; an omitted key means the
/// feature is off. A missing `[features]` table entirely leaves every feature
/// off — the role behaves as a plain chat with no attachments, no regen, no
/// trees.
struct RoleFeatures: Codable, Equatable, Hashable, Sendable {
    /// Whether chats with this role accept attachments (paperclip, drop, paste).
    var withAttachments: Bool?
    /// Whether assistant messages get a Regen button (re-stream the response).
    var withResponseRegen: Bool?
    /// Whether regen/edit create sibling branches instead of deleting the old
    /// continuation. Validation requires this to come with `withResponseRegen`.
    var withChatTrees: Bool?

    enum CodingKeys: String, CodingKey {
        case withAttachments = "with_attachments"
        case withResponseRegen = "with_response_regen"
        case withChatTrees = "with_chat_trees"
    }
}

/// Raw structure decoded from a role TOML file (`~/iCanHazAI/roles/<name>.toml`).
struct RoleConfig: Codable, Equatable, Hashable {
    var description: String?
    var prompt: String?
    var promptOverrideAllowed: Bool?
    var workingDirectory: String?
    var connection: String?
    var connectionOverrideAllowed: Bool?
    /// When true, Filesystem and Code tools run isolated to the working
    /// directory (chroot-like). A role-level switch: either the whole role is
    /// isolated or it isn't — partial isolation would be escapable.
    var directoryIsolation: Bool?
    /// Built-in tool groups. A group key is present (non-nil) when its `[group]`
    /// table appears in the TOML — even an empty table enables the group with
    /// defaults. Nil means the group is disabled.
    var utils: RoleToolGroup?
    var filesystem: RoleToolGroup?
    var code: RoleToolGroup?
    var shell: RoleToolGroup?
    var web: RoleToolGroup?
    /// Custom MCP servers selected by this role.
    var mcps: [RoleMCP]?
    /// When true, chats with this role may add/remove custom MCP servers via
    /// the chat toolbar picker. Defaults to false: the chat simply uses the
    /// role's MCP selection.
    var mcpsOverrideAllowed: Bool?
    /// SF Symbol name used to badge this role's chats in the sidebar and the
    /// role picker. Nil → falls back to `Role.defaultIcon`.
    var icon: String?
    /// Accent color alias for this role (e.g. "blue", "purple"). Resolved by
    /// `RoleAccent` to an adaptive system color. Nil/unknown → falls back to
    /// the macOS accent color (system setting).
    var accent: String?
    /// Per-role UI capability flags (attachments, response regen, chat trees).
    /// Nil when the `[features]` table is absent — every feature off.
    var features: RoleFeatures?

    enum CodingKeys: String, CodingKey {
        case description
        case prompt
        case promptOverrideAllowed = "prompt_override_allowed"
        case workingDirectory = "working_directory"
        case connection
        case connectionOverrideAllowed = "connection_override_allowed"
        case directoryIsolation = "directory_isolation"
        case utils
        case filesystem
        case code
        case shell
        case web
        case mcps
        case mcpsOverrideAllowed = "mcps_override_allowed"
        case icon
        case accent
        case features
    }
}

// MARK: - Role

/// A role: a TOML config combining a prompt, connection, working directory, and
/// a set of MCPs (with per-MCP tool selection and auto-allow rules). Roles live
/// in `~/iCanHazAI/roles/<name>.toml`; bundled defaults are seeded from
/// `default/roles` on startup and are fully user-editable.
struct Role: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let config: RoleConfig

    /// Generic SF Symbol used when a role doesn't define its own `icon`.
    static let defaultIcon = "brain"

    /// True for built-in roles served from the app bundle (never
    /// user-editable). Derived from the protected built-in name set.
    var isBuiltin: Bool { EnvironmentManager.protectedBundleNames.contains(name) }
    var description: String { config.description ?? "No description." }
    var promptName: String? { config.prompt }
    var promptOverrideAllowed: Bool { config.promptOverrideAllowed ?? false }
    var connectionOverrideAllowed: Bool { config.connectionOverrideAllowed ?? false }
    var mcpsOverrideAllowed: Bool { config.mcpsOverrideAllowed ?? false }
    var workingDirectory: String? { config.workingDirectory }
    var connection: String? { config.connection }
    /// SF Symbol for this role, falling back to `defaultIcon`.
    var icon: String { config.icon ?? Role.defaultIcon }

    /// The enabled built-in tool groups, in canonical order. A group is
    /// enabled when its `[group]` table is present in the role TOML.
    var enabledGroups: [String] {
        BuiltinTools.groupOrder.filter { group in
            switch group {
            case BuiltinTools.utilsGroup: return config.utils != nil
            case BuiltinTools.filesystemGroup: return config.filesystem != nil
            case BuiltinTools.codeGroup: return config.code != nil
            case BuiltinTools.shellGroup: return config.shell != nil
            case BuiltinTools.webGroup: return config.web != nil
            default: return false
            }
        }
    }

    /// The `RoleToolGroup` config for a built-in group, or nil when the group
    /// is not enabled.
    func groupConfig(_ group: String) -> RoleToolGroup? {
        switch group {
        case BuiltinTools.utilsGroup: return config.utils
        case BuiltinTools.filesystemGroup: return config.filesystem
        case BuiltinTools.codeGroup: return config.code
        case BuiltinTools.shellGroup: return config.shell
        case BuiltinTools.webGroup: return config.web
        default: return nil
        }
    }

    /// Number of custom MCP servers selected by this role. Built-in tool
    /// groups (Utils/Filesystem/Code/Shell) are not MCP servers and are not
    /// counted. Used by the chat header indicator.
    var mcpCount: Int { config.mcps?.count ?? 0 }

    /// Whether this role selects at least one workdir-capable built-in group
    /// (Filesystem, Code, or Shell) — i.e. anything that consumes a working
    /// directory at all. Drives the `current_directory` prompt variable and
    /// whether the CLI applies its working directory to chats.
    var hasWorkdirCapableMCP: Bool {
        enabledGroups.contains { BuiltinTools.workdirCapableGroups.contains($0) }
    }

    /// Whether this role selects at least one directory-relevant built-in
    /// group (Filesystem or Code) — tools that operate on files and therefore
    /// need a working directory. When the role doesn't pre-set one, the user
    /// must pick a directory once per chat (permanent). Shell is excluded:
    /// without a directory it simply defaults to the user's home.
    var hasDirectoryRelevantTools: Bool {
        enabledGroups.contains { BuiltinTools.directoryRelevantGroups.contains($0) }
    }

    /// Whether this role enables `directory_isolation`: Filesystem and Code
    /// tools run confined to the working directory. When true, a working
    /// directory is required for the chat: either pre-set by the role or
    /// picked by the user. Drives the red "No directory" placeholder and the
    /// send gate when no directory is set.
    var hasDirectoryIsolation: Bool { config.directoryIsolation ?? false }

    /// Whether this role binds to a working directory: it selects at least one
    /// workdir-capable tool group (Filesystem, Code, or Shell). Drives the
    /// folder badge in the role picker. A pre-set `working_directory` without
    /// such a group is a validation error, so the badge is purely tool-based.
    var bindsToDirectory: Bool { hasWorkdirCapableMCP }

    /// Whether this role enables the Shell built-in tool group. Drives the
    /// terminal badge in the role picker.
    var hasShellTools: Bool { config.shell != nil }

    /// Whether this role enables the Web built-in tool group. Drives the
    /// globe badge in the role picker.
    var hasWebTools: Bool { config.web != nil }

    /// Whether chats with this role accept attachments (paperclip, drop,
    /// paste). Off when the role has no `[features]` table or omits the key.
    var hasAttachments: Bool { config.features?.withAttachments ?? false }

    /// Whether assistant messages in this role's chats get a Regen button.
    /// Off when the role has no `[features]` table or omits the key.
    var hasResponseRegen: Bool { config.features?.withResponseRegen ?? false }

    /// Whether regen/edit create sibling branches instead of deleting the old
    /// continuation. Off when the role has no `[features]` table or omits the
    /// key. Validation requires this to come with `withResponseRegen`.
    var hasChatTrees: Bool { config.features?.withChatTrees ?? false }
}

// MARK: - Connection

enum ConnectionProvider: String, Codable {
    case openai
    case anthropic
}

struct Connection: Identifiable, Equatable, @unchecked Sendable {
    var id: String { "\(provider.rawValue)/\(name)" }
    let provider: ConnectionProvider
    let name: String
    /// Base URL of the endpoint. nil → provider default.
    let baseUrl: String?
    /// API key. nil when the endpoint doesn't require one.
    let apiKey: String?
    /// Model identifier.
    let model: String
    /// Meta flag: whether the model accepts image input. Decides how image
    /// attachments are sent — as a native image block when true, or as a
    /// synthesized text fallback when false. NOT sent to the API. Defaults
    /// to false.
    let imageInput: Bool
    /// Extra parameters inserted into every request body's root. Fully optional.
    let requestParameters: [String: LLMJSONValue]?
    /// Custom HTTP headers applied **last** over the provider's defaults, so
    /// any header can be overridden (including auth and `User-Agent`). An
    /// empty-string value removes the header entirely. May carry secrets, so
    /// it is redacted wherever the API key is. Fully optional.
    let headers: [String: String]?

    /// Explicit init so `headers` defaults to nil — keeps call sites that
    /// don't care about headers (tests, wizard) concise.
    init(
        provider: ConnectionProvider,
        name: String,
        baseUrl: String?,
        apiKey: String?,
        model: String,
        imageInput: Bool,
        requestParameters: [String: LLMJSONValue]?,
        headers: [String: String]? = nil
    ) {
        self.provider = provider
        self.name = name
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.model = model
        self.imageInput = imageInput
        self.requestParameters = requestParameters
        self.headers = headers
    }

    /// Display name shown in the UI.
    var displayName: String { name }
}

/// Raw structure decoded from a connection `.jsonc` file.
struct ConnectionConfig: Codable {
    var baseUrl: String?
    var apiKey: String?
    var model: String
    var imageInput: Bool?
    var requestParameters: [String: LLMJSONValue]?
    var headers: [String: String]?
}
