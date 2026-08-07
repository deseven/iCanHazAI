import Testing
import Foundation
@testable import iCanHazAI

/// Tests for `ChatRenderQueue`: the off-main pipeline that diffs chat state
/// against the last rendered state and emits JS bridge statements. Covers the
/// diff behavior (full snapshot vs incremental updates), the ordering-critical
/// coalescing/drop rules, and the tool-result projection.
///
/// Nested under `AllAppTests` so its `.serialized` trait keeps these
/// sequential with the rest of the app suites.
extension AllAppTests {

@Suite("ChatRenderQueue")
struct ChatRenderQueueTests {

    // MARK: - Helpers

    /// Collects delivered JS statements; can park deliveries on a gate so
    /// tests can queue more jobs while the queue is mid-processing.
    private actor DeliveryRecorder {
        private(set) var scripts: [String] = []
        /// Number of deliveries entered (including ones parked on the gate).
        private(set) var entered: Int = 0
        private var gateArmed = false
        private var gate: CheckedContinuation<Void, Never>? = nil

        func armGate() { gateArmed = true }

        func openGate() {
            gateArmed = false
            gate?.resume()
            gate = nil
        }

        /// Entry point used as the queue's `deliver` closure.
        func deliver(_ js: String) async {
            entered += 1
            if gateArmed {
                await withCheckedContinuation { gate = $0 }
            }
            scripts.append(js)
        }

        func waitForCount(_ n: Int) async -> Bool {
            for _ in 0..<500 {
                if scripts.count >= n { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return scripts.count >= n
        }

        func waitForEntered(_ n: Int) async -> Bool {
            for _ in 0..<500 {
                if entered >= n { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return entered >= n
        }
    }

    private func makeQueue(_ recorder: DeliveryRecorder) -> ChatRenderQueue {
        ChatRenderQueue { js in await recorder.deliver(js) }
    }

    /// Extracts the `HostMessage` JSON out of a delivered JS statement.
    private func decode(_ js: String) -> [String: Any]? {
        let prefix = "window.chatHost && window.chatHost.postMessage('"
        guard js.hasPrefix(prefix), js.hasSuffix("');") else { return nil }
        var s = String(js.dropFirst(prefix.count).dropLast(3))
        // Undo the JS-string escaping (mirror of ChatRenderQueue.encodeToJS).
        s = s.replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
    }

    private func msg(_ id: UUID, role: MessageRole = .user, content: String) -> ChatMessage {
        ChatMessage(id: id, role: role, content: content, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func job(_ chatId: String, _ messages: [ChatMessage], streaming: Bool = false) -> RenderJob {
        .snapshot(chatId: chatId, messages: messages, isStreaming: streaming, roleName: nil, roleAccent: nil)
    }

    // MARK: - Diff behavior

    @Test("first push for a chat sends a full snapshot")
    func firstSnapshotIsFull() async {
        let recorder = DeliveryRecorder()
        let queue = makeQueue(recorder)
        let a = UUID()
        await queue.enqueue(job("chat-a", [msg(a, content: "hello")]))
        #expect(await recorder.waitForCount(1))
        let scripts = await recorder.scripts
        let decoded = decode(scripts[0])
        #expect(decoded?["type"] as? String == "snapshot")
        let snapshot = decoded?["snapshot"] as? [String: Any]
        #expect(snapshot?["chatId"] as? String == "chat-a")
        #expect((snapshot?["messages"] as? [[String: Any]])?.count == 1)
    }

    @Test("unchanged re-push sends nothing")
    func unchangedRepushSendsNothing() async {
        let recorder = DeliveryRecorder()
        let queue = makeQueue(recorder)
        let a = UUID()
        await queue.enqueue(job("chat-a", [msg(a, content: "hello")]))
        #expect(await recorder.waitForCount(1))
        await queue.enqueue(job("chat-a", [msg(a, content: "hello")]))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await recorder.scripts.count == 1)
    }

    @Test("appended message sends addMessage with its index")
    func appendedMessageSendsAdd() async {
        let recorder = DeliveryRecorder()
        let queue = makeQueue(recorder)
        let a = UUID(), b = UUID()
        await queue.enqueue(job("chat-a", [msg(a, content: "one")]))
        #expect(await recorder.waitForCount(1))
        await queue.enqueue(job("chat-a", [msg(a, content: "one"), msg(b, content: "two")]))
        #expect(await recorder.waitForCount(2))
        let scripts = await recorder.scripts
        let decoded = decode(scripts[1])
        #expect(decoded?["type"] as? String == "addMessage")
        #expect(decoded?["index"] as? Int == 1)
        #expect((decoded?["message"] as? [String: Any])?["id"] as? String == b.uuidString)
    }

    @Test("edited message sends updateMessage")
    func editedMessageSendsUpdate() async {
        let recorder = DeliveryRecorder()
        let queue = makeQueue(recorder)
        let a = UUID()
        await queue.enqueue(job("chat-a", [msg(a, content: "before")]))
        #expect(await recorder.waitForCount(1))
        await queue.enqueue(job("chat-a", [msg(a, content: "after")]))
        #expect(await recorder.waitForCount(2))
        let scripts = await recorder.scripts
        let decoded = decode(scripts[1])
        #expect(decoded?["type"] as? String == "updateMessage")
        #expect((decoded?["message"] as? [String: Any])?["content"] as? String == "after")
    }

    @Test("removed message sends deleteMessage")
    func removedMessageSendsDelete() async {
        let recorder = DeliveryRecorder()
        let queue = makeQueue(recorder)
        let a = UUID(), b = UUID()
        await queue.enqueue(job("chat-a", [msg(a, content: "one"), msg(b, content: "two")]))
        #expect(await recorder.waitForCount(1))
        await queue.enqueue(job("chat-a", [msg(a, content: "one")]))
        #expect(await recorder.waitForCount(2))
        let scripts = await recorder.scripts
        let decoded = decode(scripts[1])
        #expect(decoded?["type"] as? String == "deleteMessage")
        #expect(decoded?["messageId"] as? String == b.uuidString)
    }

    @Test("switching chats sends a fresh full snapshot")
    func chatSwitchSendsFreshSnapshot() async {
        let recorder = DeliveryRecorder()
        let queue = makeQueue(recorder)
        await queue.enqueue(job("chat-a", [msg(UUID(), content: "a")]))
        #expect(await recorder.waitForCount(1))
        await queue.enqueue(job("chat-b", [msg(UUID(), content: "b")]))
        #expect(await recorder.waitForCount(2))
        let scripts = await recorder.scripts
        let decoded = decode(scripts[1])
        #expect(decoded?["type"] as? String == "snapshot")
        #expect((decoded?["snapshot"] as? [String: Any])?["chatId"] as? String == "chat-b")
    }

    @Test("streaming start sends a streaming flag; streaming end sends a full snapshot")
    func streamingTransitions() async {
        let recorder = DeliveryRecorder()
        let queue = makeQueue(recorder)
        let a = UUID()
        await queue.enqueue(job("chat-a", [msg(a, role: .assistant, content: "")], streaming: false))
        #expect(await recorder.waitForCount(1))
        await queue.enqueue(job("chat-a", [msg(a, role: .assistant, content: "")], streaming: true))
        #expect(await recorder.waitForCount(2))
        var scripts = await recorder.scripts
        #expect(decode(scripts[1])?["type"] as? String == "streaming")
        // Content growth mid-stream is an incremental update.
        await queue.enqueue(job("chat-a", [msg(a, role: .assistant, content: "partial")], streaming: true))
        #expect(await recorder.waitForCount(3))
        scripts = await recorder.scripts
        #expect(decode(scripts[2])?["type"] as? String == "updateMessage")
        // Stream end forces a full snapshot.
        await queue.enqueue(job("chat-a", [msg(a, role: .assistant, content: "done")], streaming: false))
        #expect(await recorder.waitForCount(4))
        scripts = await recorder.scripts
        let end = decode(scripts[3])
        #expect(end?["type"] as? String == "snapshot")
        #expect((end?["snapshot"] as? [String: Any])?["isStreaming"] as? Bool == false)
    }

    // MARK: - Queue rules

    @Test("queued snapshots coalesce to the latest one")
    func coalescingKeepsOnlyLatest() async {
        let recorder = DeliveryRecorder()
        let queue = makeQueue(recorder)
        let a = UUID()
        await recorder.armGate()
        await queue.enqueue(job("chat-a", [msg(a, content: "v1")]))
        // The first job is being processed (parked in delivery), so the next
        // two queue up and coalesce into one.
        #expect(await recorder.waitForEntered(1))
        await queue.enqueue(job("chat-a", [msg(a, content: "v2")]))
        await queue.enqueue(job("chat-a", [msg(a, content: "v3")]))
        await recorder.openGate()
        #expect(await recorder.waitForCount(2))
        // v2 was dropped entirely: exactly two deliveries for three jobs, and
        // the second one brings the renderer to v3 (an incremental update,
        // since the queue's diff state already advanced to v1).
        try? await Task.sleep(for: .milliseconds(100))
        let scripts = await recorder.scripts
        #expect(scripts.count == 2)
        let second = decode(scripts[1])
        #expect(second?["type"] as? String == "updateMessage")
        #expect((second?["message"] as? [String: Any])?["content"] as? String == "v3")
    }

    @Test("unload drops queued snapshots and forces the next one to be full")
    func unloadDropsAndResets() async {
        let recorder = DeliveryRecorder()
        let queue = makeQueue(recorder)
        let a = UUID()
        await recorder.armGate()
        await queue.enqueue(job("chat-a", [msg(a, content: "rendered")]))
        #expect(await recorder.waitForEntered(1))
        // Queue a stale snapshot, then unload: the stale one must be dropped.
        await queue.enqueue(job("chat-a", [msg(a, content: "stale")]))
        await queue.enqueue(.unload)
        // Same chat again after the unload — must be a full snapshot, not a diff.
        await queue.enqueue(job("chat-a", [msg(a, content: "fresh")]))
        await recorder.openGate()
        #expect(await recorder.waitForCount(3))
        let scripts = await recorder.scripts
        #expect(decode(scripts[1])?["type"] as? String == "unload")
        let third = decode(scripts[2])
        #expect(third?["type"] as? String == "snapshot")
        let messages = (third?["snapshot"] as? [String: Any])?["messages"] as? [[String: Any]]
        #expect(messages?.first?["content"] as? String == "fresh")
    }

    @Test("reset drops queued jobs and forces the next push to be a full snapshot")
    func resetForcesFullSnapshot() async {
        let recorder = DeliveryRecorder()
        let queue = makeQueue(recorder)
        let a = UUID()
        await queue.enqueue(job("chat-a", [msg(a, content: "before")]))
        #expect(await recorder.waitForCount(1))
        await queue.enqueue(.reset)
        // Same chat, same content — without the reset this would send nothing.
        await queue.enqueue(job("chat-a", [msg(a, content: "before")]))
        #expect(await recorder.waitForCount(2))
        let scripts = await recorder.scripts
        #expect(decode(scripts[1])?["type"] as? String == "snapshot")
    }

    // MARK: - Projection

    @Test("tool messages fold onto the preceding assistant message")
    func toolResultFolding() {
        let assistant = ChatMessage(
            id: UUID(), role: .assistant, content: "calling a tool",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            toolCalls: [ToolCall(id: "c1", name: "calc", arguments: "{\"expression\":\"2+2\"}")]
        )
        let tool = ChatMessage(
            id: UUID(), role: .tool, content: "",
            timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            toolResults: [ToolResult(callID: "c1", content: "4", isError: false)]
        )
        let out = ChatRenderQueue.projectToolResults([assistant, tool])
        #expect(out.count == 1)
        #expect(out[0].role == "assistant")
        #expect(out[0].toolResults?.count == 1)
        #expect(out[0].toolResults?.first?.content == "4")
    }

    @Test("orphan tool messages (no preceding assistant) are dropped")
    func orphanToolMessageDropped() {
        let tool = ChatMessage(
            id: UUID(), role: .tool, content: "",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            toolResults: [ToolResult(callID: "c1", content: "4", isError: false)]
        )
        let out = ChatRenderQueue.projectToolResults([tool])
        #expect(out.isEmpty)
    }
}
}
