import Testing
import Foundation
@testable import iCanHazAI

/// Tests for the tree overview projection builder and the gotoMessage path
/// resolution. The projection walks the chat's tree metadata and emits only
/// splitting points (branch roots) and the active leaf, as a nested tree.
extension AllAppTests {
    @Suite("Tree overview")
    struct TreeOverviewTests {

        // MARK: - Projection builder

        @Test("linear chat projects to a single root node with no split")
        func linearChatSingleNode() {
            let chat = Fixtures.simpleChat()
            let root = ChatRenderQueue.buildTreeOverview(chat)
            #expect(root != nil)
            #expect(root?.split == nil)
            #expect(root?.isActive == true)
            // The whole linear conversation collapses into the root segment.
            #expect(root?.messageCount == chat.activeMessages.count)
        }

        @Test("empty chat projects to nil")
        func emptyChatEmptyProjection() {
            let chat = Fixtures.chat(messages: [])
            #expect(ChatRenderQueue.buildTreeOverview(chat) == nil)
        }

        @Test("forked chat nests branch heads under the root's split")
        func forkedChatProjectsBranchRoots() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]], active: 1)])
            let root = ChatRenderQueue.buildTreeOverview(chat)

            #expect(root?.id == user.id.uuidString)
            #expect(root?.isActive == true)
            // The root's segment is just the user message (it owns the fork).
            #expect(root?.messageCount == 1)

            let branches = root?.split?.branches
            #expect(branches?.count == 2)

            // Branch 0 (a1) is inactive; branch 1 (a2) is the active one.
            #expect(branches?[0].id == a1.id.uuidString)
            #expect(branches?[0].isActive == false)
            #expect(branches?[0].split == nil)
            #expect(branches?[1].id == a2.id.uuidString)
            #expect(branches?[1].isActive == true)
            #expect(branches?[1].split == nil)
        }

        @Test("messages between splits collapse into the branch segment count")
        func segmentCountCollapsesMessages() {
            // user → a1 → u2(fork) → [a2a, a2b]. The active branch is a2a.
            // The root segment runs user → a1 → u2 (3 messages); a1 is not a
            // splitting point so it's folded into the root's count.
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            let a2a = Fixtures.message(role: .assistant, content: "a2a", timestamp: Date(timeIntervalSince1970: 4))
            let a2b = Fixtures.message(role: .assistant, content: "a2b", timestamp: Date(timeIntervalSince1970: 5))
            let chat = Fixtures.chat(messages: [user, a1, Fixtures.forking(u2, branches: [[a2a], [a2b]], active: 0)])
            let root = ChatRenderQueue.buildTreeOverview(chat)

            // Root segment: user, a1, u2 = 3 messages.
            #expect(root?.id == user.id.uuidString)
            #expect(root?.messageCount == 3)
            #expect(root?.isActive == true)

            let branches = root?.split?.branches
            #expect(branches?.count == 2)
            #expect(branches?[0].id == a2a.id.uuidString)
            #expect(branches?[0].isActive == true)
            #expect(branches?[1].id == a2b.id.uuidString)
            #expect(branches?[1].isActive == false)
        }

        @Test("a branch head that is itself a fork owner draws its nested branches")
        func branchHeadForkOwnerDrawsNestedBranches() {
            // user → branches: [[a1Forked], [a1new]]
            //   a1Forked → branches: [[u2], [a2a], [a2b, u3, a3]]  (active: 0 → u2)
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            let a2a = Fixtures.message(role: .assistant, content: "a2a", timestamp: Date(timeIntervalSince1970: 4))
            let a2b = Fixtures.message(role: .assistant, content: "a2b", timestamp: Date(timeIntervalSince1970: 5))
            let u3 = Fixtures.message(role: .user, content: "q3", timestamp: Date(timeIntervalSince1970: 6))
            let a3 = Fixtures.message(role: .assistant, content: "a3", timestamp: Date(timeIntervalSince1970: 7))
            let a1new = Fixtures.message(role: .assistant, content: "a1new", timestamp: Date(timeIntervalSince1970: 8))
            let a1Forked = Fixtures.forking(a1, branches: [[u2], [a2a], [a2b, u3, a3]], active: 0)
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1Forked], [a1new]], active: 0)])
            let root = ChatRenderQueue.buildTreeOverview(chat)

            // Root (user) → split [[a1Forked], [a1new]].
            #expect(root?.id == user.id.uuidString)
            let top = root?.split?.branches
            #expect(top?.count == 2)
            let a1Node = top?[0]
            #expect(a1Node?.id == a1.id.uuidString)
            #expect(a1Node?.isActive == true)
            #expect(top?[1].id == a1new.id.uuidString)
            #expect(top?[1].isActive == false)
            #expect(top?[1].split == nil)

            // a1Forked's segment is just a1 (it owns the nested fork), and its
            // nested split has three branch heads.
            #expect(a1Node?.messageCount == 1)
            let nested = a1Node?.split?.branches
            #expect(nested?.count == 3)
            #expect(nested?[0].id == u2.id.uuidString)
            #expect(nested?[0].isActive == true)
            #expect(nested?[1].id == a2a.id.uuidString)
            #expect(nested?[2].id == a2b.id.uuidString)
            // a2b's segment runs a2b → u3 → a3 = 3 messages.
            #expect(nested?[2].messageCount == 3)
        }

        @Test("snippet truncates to 100 characters")
        func snippetTruncation() {
            let longContent = String(repeating: "x", count: 200)
            let user = Fixtures.message(role: .user, content: longContent, timestamp: Date(timeIntervalSince1970: 1))
            let chat = Fixtures.chat(messages: [user])
            let root = ChatRenderQueue.buildTreeOverview(chat)
            // 100 chars + ellipsis.
            #expect(root?.snippet.count == 101)
            #expect(root?.snippet.hasSuffix("…") == true)
        }

        @Test("snippet falls back to (empty) for a message with empty content")
        func snippetEmptyContent() {
            let assistant = Fixtures.message(role: .assistant, content: "", timestamp: Date(timeIntervalSince1970: 1))
            let chat = Fixtures.chat(messages: [assistant])
            let root = ChatRenderQueue.buildTreeOverview(chat)
            #expect(root?.snippet == "(empty)")
        }

        @Test("linear chat folds the whole conversation into the root segment")
        func linearChatFoldsIntoRoot() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let assistant = Fixtures.message(role: .assistant, content: "", timestamp: Date(timeIntervalSince1970: 2))
            let chat = Fixtures.chat(messages: [user, assistant])
            // The linear chat's root is the user message; the assistant is
            // folded into its segment count.
            let root = ChatRenderQueue.buildTreeOverview(chat)
            #expect(root?.messageCount == 2)
            #expect(root?.split == nil)
        }

        // MARK: - gotoMessage path resolution

        @Test("leafPath returns the path from root to the target")
        func leafPathReturnsPath() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]])])
            let path = chat.leafPath(to: a2.id)
            #expect(path.count == 2)
            #expect(path[0] == user.id)
            #expect(path[1] == a2.id)
        }

        @Test("leafPath for a nested fork target")
        func leafPathNestedFork() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            let a2a = Fixtures.message(role: .assistant, content: "a2a", timestamp: Date(timeIntervalSince1970: 4))
            let a2b = Fixtures.message(role: .assistant, content: "a2b", timestamp: Date(timeIntervalSince1970: 5))
            let chat = Fixtures.chat(messages: [user, a1, Fixtures.forking(u2, branches: [[a2a], [a2b]])])
            let path = chat.leafPath(to: a2b.id)
            #expect(path.count == 4)
            #expect(path[0] == user.id)
            #expect(path[1] == a1.id)
            #expect(path[2] == u2.id)
            #expect(path[3] == a2b.id)
        }

        // MARK: - Bridge message encode/decode

        @Test("gotoMessage bridge message round-trips")
        func gotoMessageBridgeRoundTrip() throws {
            let id = UUID().uuidString
            let original = BridgeMessageData.gotoMessage(messageId: id)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(BridgeMessageData.self, from: data)
            guard case .gotoMessage(let decodedId) = decoded else {
                Issue.record("expected .gotoMessage, got \(decoded)")
                return
            }
            #expect(decodedId == id)
        }

        @Test("gotoMessage bridge message encodes the correct type tag")
        func gotoMessageBridgeTypeTag() throws {
            let original = BridgeMessageData.gotoMessage(messageId: "abc-123")
            let data = try JSONEncoder().encode(original)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["type"] as? String == "gotoMessage")
            #expect(json["messageId"] as? String == "abc-123")
        }

        @Test("treeOverview host message round-trips")
        func treeOverviewHostRoundTrip() throws {
            let root = TreeNodeData(
                id: "n1", role: "user", snippet: "hello", messageCount: 1, isActive: true,
                split: TreeSplitData(branches: [
                    TreeNodeData(id: "n2", role: "assistant", snippet: "world", messageCount: 1, isActive: true, split: nil),
                    TreeNodeData(id: "n3", role: "assistant", snippet: "other", messageCount: 2, isActive: false, split: nil),
                ])
            )
            let original = HostMessageData.treeOverview(root: root)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(HostMessageData.self, from: data)
            guard case .treeOverview(let decodedRoot) = decoded else {
                Issue.record("expected .treeOverview, got \(decoded)")
                return
            }
            #expect(decodedRoot?.id == "n1")
            #expect(decodedRoot?.split?.branches.count == 2)
            #expect(decodedRoot?.split?.branches[1].isActive == false)
        }

        @Test("exitTreeOverview host message round-trips")
        func exitTreeOverviewRoundTrip() throws {
            let original = HostMessageData.exitTreeOverview
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(HostMessageData.self, from: data)
            guard case .exitTreeOverview = decoded else {
                Issue.record("expected .exitTreeOverview, got \(decoded)")
                return
            }
        }

        @Test("scrollToMessage host message round-trips")
        func scrollToMessageRoundTrip() throws {
            let original = HostMessageData.scrollToMessage(messageId: "msg-1")
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(HostMessageData.self, from: data)
            guard case .scrollToMessage(let id) = decoded else {
                Issue.record("expected .scrollToMessage, got \(decoded)")
                return
            }
            #expect(id == "msg-1")
        }
    }
}
