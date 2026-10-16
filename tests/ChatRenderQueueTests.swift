import Foundation
import Testing

@testable import iCanHazAI

/// Tests for `ChatRenderQueue`: the off-main pipeline that diffs chat state
/// against the last rendered state and emits typed ops for the list. Covers the
/// diff behavior (full snapshot vs incremental ops), the ordering-critical
/// coalescing/drop rules, and the tool-result projection.
///
/// Nested under `AllAppTests` so its `.serialized` trait keeps these
/// sequential with the rest of the app suites.
extension AllAppTests {

    @Suite("ChatRenderQueue")
    struct ChatRenderQueueTests {

        // MARK: - Helpers

        /// Collects delivered op batches; can park deliveries on a gate so
        /// tests can queue more jobs while the queue is mid-processing.
        private actor DeliveryRecorder {
            private(set) var batches: [[RenderOp]] = []
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
            func deliver(_ ops: [RenderOp]) async {
                entered += 1
                if gateArmed {
                    await withCheckedContinuation { gate = $0 }
                }
                batches.append(ops)
            }

            func waitForCount(_ n: Int) async -> Bool {
                for _ in 0..<500 {
                    if batches.count >= n { return true }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return batches.count >= n
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
            ChatRenderQueue { ops in await recorder.deliver(ops) }
        }

        private func msg(_ id: UUID, role: MessageRole = .user, content: String) -> ChatMessage {
            ChatMessage(id: id, role: role, content: content, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        }

        private func job(
            _ chatId: String, _ messages: [ChatMessage], streaming: Bool = false,
            features: ChatRowFeatures = ChatRowFeatures(), roleName: String? = nil
        ) -> RenderJob {
            .snapshot(
                chatId: chatId, chat: Chat(messages: messages),
                state: ChatRenderState(roleName: roleName, features: features, isStreaming: streaming))
        }

        // MARK: - Diff behavior

        @Test("first push for a chat sends a full snapshot")
        func firstSnapshotIsFull() async {
            let recorder = DeliveryRecorder()
            let queue = makeQueue(recorder)
            let a = UUID()
            await queue.enqueue(job("chat-a", [msg(a, content: "hello")]))
            #expect(await recorder.waitForCount(1))
            let batches = await recorder.batches
            guard case .snapshot(let chatID, let rows, _) = batches[0].first else {
                Issue.record("expected a snapshot, got \(batches[0])")
                return
            }
            #expect(chatID == "chat-a")
            #expect(rows.map(\.id) == [a.uuidString])
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
            #expect(await recorder.batches.count == 1)
        }

        @Test("appended message sends an insert with its index")
        func appendedMessageSendsInsert() async {
            let recorder = DeliveryRecorder()
            let queue = makeQueue(recorder)
            let a = UUID()
            let b = UUID()
            await queue.enqueue(job("chat-a", [msg(a, content: "one")]))
            #expect(await recorder.waitForCount(1))
            await queue.enqueue(job("chat-a", [msg(a, content: "one"), msg(b, content: "two")]))
            #expect(await recorder.waitForCount(2))
            let ops = await recorder.batches[1]
            #expect(ops.count == 1)
            guard case .insert(let row, let index) = ops[0] else {
                Issue.record("expected an insert, got \(ops)")
                return
            }
            #expect(index == 1)
            #expect(row.id == b.uuidString)
        }

        @Test("edited message sends an update")
        func editedMessageSendsUpdate() async {
            let recorder = DeliveryRecorder()
            let queue = makeQueue(recorder)
            let a = UUID()
            await queue.enqueue(job("chat-a", [msg(a, content: "before")]))
            #expect(await recorder.waitForCount(1))
            await queue.enqueue(job("chat-a", [msg(a, content: "after")]))
            #expect(await recorder.waitForCount(2))
            let ops = await recorder.batches[1]
            #expect(ops.count == 1)
            guard case .update(let row) = ops[0] else {
                Issue.record("expected an update, got \(ops)")
                return
            }
            #expect(row.content == "after")
        }

        @Test("removed message sends a delete")
        func removedMessageSendsDelete() async {
            let recorder = DeliveryRecorder()
            let queue = makeQueue(recorder)
            let a = UUID()
            let b = UUID()
            await queue.enqueue(job("chat-a", [msg(a, content: "one"), msg(b, content: "two")]))
            #expect(await recorder.waitForCount(1))
            await queue.enqueue(job("chat-a", [msg(a, content: "one")]))
            #expect(await recorder.waitForCount(2))
            #expect(await recorder.batches[1] == [.delete(id: b.uuidString)])
        }

        @Test("a message added in the middle is inserted at its index")
        func middleInsert() async {
            let recorder = DeliveryRecorder()
            let queue = makeQueue(recorder)
            let a = UUID()
            let b = UUID()
            let c = UUID()
            await queue.enqueue(job("chat-a", [msg(a, content: "one"), msg(c, content: "three")]))
            #expect(await recorder.waitForCount(1))
            await queue.enqueue(
                job("chat-a", [msg(a, content: "one"), msg(b, content: "two"), msg(c, content: "three")]))
            #expect(await recorder.waitForCount(2))
            let ops = await recorder.batches[1]
            #expect(ops.count == 1)
            guard case .insert(let row, let index) = ops[0] else {
                Issue.record("expected an insert, got \(ops)")
                return
            }
            #expect(index == 1)
            #expect(row.id == b.uuidString)
        }

        @Test("switching chats sends a fresh full snapshot")
        func chatSwitchSendsFreshSnapshot() async {
            let recorder = DeliveryRecorder()
            let queue = makeQueue(recorder)
            await queue.enqueue(job("chat-a", [msg(UUID(), content: "a")]))
            #expect(await recorder.waitForCount(1))
            await queue.enqueue(job("chat-b", [msg(UUID(), content: "b")]))
            #expect(await recorder.waitForCount(2))
            guard case .snapshot(let chatID, _, _) = await recorder.batches[1].first else {
                Issue.record("expected a snapshot")
                return
            }
            #expect(chatID == "chat-b")
        }

        @Test("a change touching many messages is sent as a snapshot")
        func bulkChangeSendsSnapshot() async {
            let recorder = DeliveryRecorder()
            let queue = makeQueue(recorder)
            let old = (0..<30).map { msg(UUID(), content: "old \($0)") }
            let new = (0..<30).map { msg(UUID(), content: "new \($0)") }
            await queue.enqueue(job("chat-a", old))
            #expect(await recorder.waitForCount(1))
            await queue.enqueue(job("chat-a", new))
            #expect(await recorder.waitForCount(2))
            let ops = await recorder.batches[1]
            #expect(ops.count == 1)
            guard case .snapshot(_, let rows, _) = ops[0] else {
                Issue.record("expected a snapshot, got \(ops)")
                return
            }
            #expect(rows.count == 30)
        }

        @Test("role and feature changes send the new state without touching the rows")
        func stateChange() async {
            let recorder = DeliveryRecorder()
            let queue = makeQueue(recorder)
            let a = UUID()
            await queue.enqueue(job("chat-a", [msg(a, content: "hello")]))
            #expect(await recorder.waitForCount(1))
            let features = ChatRowFeatures(responseRegen: true, chatTrees: false)
            await queue.enqueue(job("chat-a", [msg(a, content: "hello")], features: features, roleName: "Coder"))
            #expect(await recorder.waitForCount(2))
            let expected = ChatRenderState(roleName: "Coder", features: features)
            #expect(await recorder.batches[1] == [.state(expected)])
        }

        @Test("streaming start sends the state first; streaming end sends it after the final content")
        func streamingTransitions() async {
            let recorder = DeliveryRecorder()
            let queue = makeQueue(recorder)
            let a = UUID()
            await queue.enqueue(job("chat-a", [msg(a, role: .assistant, content: "")], streaming: false))
            #expect(await recorder.waitForCount(1))

            await queue.enqueue(job("chat-a", [msg(a, role: .assistant, content: "")], streaming: true))
            #expect(await recorder.waitForCount(2))
            #expect(await recorder.batches[1] == [.state(ChatRenderState(isStreaming: true))])

            // Content growth mid-stream is an incremental update.
            await queue.enqueue(job("chat-a", [msg(a, role: .assistant, content: "partial")], streaming: true))
            #expect(await recorder.waitForCount(3))
            guard case .update(let row) = await recorder.batches[2].first else {
                Issue.record("expected an update")
                return
            }
            #expect(row.content == "partial")

            await queue.enqueue(job("chat-a", [msg(a, role: .assistant, content: "done")], streaming: false))
            #expect(await recorder.waitForCount(4))
            let end = await recorder.batches[3]
            #expect(end.count == 2)
            guard case .update(let final) = end[0] else {
                Issue.record("expected the final update first, got \(end)")
                return
            }
            #expect(final.content == "done")
            #expect(end[1] == .state(ChatRenderState(isStreaming: false)))
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
            // the second one brings the list to v3 (an incremental update,
            // since the queue's diff state already advanced to v1).
            try? await Task.sleep(for: .milliseconds(100))
            let batches = await recorder.batches
            #expect(batches.count == 2)
            guard case .update(let row) = batches[1].first else {
                Issue.record("expected an update, got \(batches[1])")
                return
            }
            #expect(row.content == "v3")
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
            let batches = await recorder.batches
            #expect(batches[1] == [.unload])
            guard case .snapshot(_, let rows, _) = batches[2].first else {
                Issue.record("expected a snapshot, got \(batches[2])")
                return
            }
            #expect(rows.first?.content == "fresh")
        }

        @Test("scrollTo is delivered after the snapshot queued before it")
        func scrollToIsOrdered() async {
            let recorder = DeliveryRecorder()
            let queue = makeQueue(recorder)
            let a = UUID()
            await queue.enqueue(job("chat-a", [msg(a, content: "one")]))
            await queue.enqueue(.scrollTo(messageID: a.uuidString))
            #expect(await recorder.waitForCount(2))
            let batches = await recorder.batches
            guard case .snapshot = batches[0].first else {
                Issue.record("expected the snapshot first, got \(batches[0])")
                return
            }
            #expect(batches[1] == [.scrollTo(messageID: a.uuidString)])
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
            let out = ChatRenderQueue.projectActiveMessages(Chat(messages: [assistant, tool]))
            #expect(out.count == 1)
            #expect(out[0].role == .assistant)
            #expect(out[0].toolCalls.map(\.id) == ["c1"])
            #expect(out[0].toolResults.count == 1)
            #expect(out[0].toolResults.first?.content == "4")
        }

        @Test("a later result for the same call replaces the earlier one")
        func toolResultReplacement() {
            let assistant = ChatMessage(
                id: UUID(), role: .assistant, content: "",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                toolCalls: [ToolCall(id: "c1", name: "calc", arguments: "{}")]
            )
            let streaming = ChatMessage(
                id: UUID(), role: .tool, content: "", timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                toolResults: [ToolResult(callID: "c1", content: "par", isError: false, isStreaming: true)])
            let final = ChatMessage(
                id: UUID(), role: .tool, content: "", timestamp: Date(timeIntervalSince1970: 1_700_000_002),
                toolResults: [ToolResult(callID: "c1", content: "partial", isError: false)])
            let out = ChatRenderQueue.projectActiveMessages(Chat(messages: [assistant, streaming, final]))
            #expect(out.count == 1)
            #expect(out[0].toolResults.map(\.content) == ["partial"])
            #expect(out[0].toolResults.first?.isStreaming == false)
        }

        @Test("orphan tool messages (no preceding assistant) are dropped")
        func orphanToolMessageDropped() {
            let tool = ChatMessage(
                id: UUID(), role: .tool, content: "",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                toolResults: [ToolResult(callID: "c1", content: "4", isError: false)]
            )
            #expect(ChatRenderQueue.projectActiveMessages(Chat(messages: [tool])).isEmpty)
        }

        @Test("rows carry attachments, tool call state and the message timestamp")
        func rowFields() {
            let attachment = iCanHazAI.Attachment(
                kind: .text, ext: "txt", filename: "notes.txt", originalName: "notes.txt", status: .truncated)
            let user = ChatMessage(
                id: UUID(), role: .user, content: "see file", timestamp: Date(timeIntervalSince1970: 42),
                attachments: [attachment])
            let assistant = ChatMessage(
                id: UUID(), role: .assistant, content: "", timestamp: Date(timeIntervalSince1970: 43),
                connectionName: "Local",
                toolCalls: [ToolCall(id: "c1", name: "write_file", arguments: "{}", pendingApproval: true, diff: "+x")])
            let out = ChatRenderQueue.projectActiveMessages(Chat(messages: [user, assistant]))
            #expect(out[0].attachments.map(\.filename) == ["notes.txt"])
            #expect(out[0].attachments.first?.status == .truncated)
            #expect(out[0].timestamp == Date(timeIntervalSince1970: 42))
            #expect(out[1].connectionName == "Local")
            #expect(out[1].toolCalls.first?.pendingApproval == true)
            #expect(out[1].toolCalls.first?.diff == "+x")
        }
    }
}
