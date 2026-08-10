import Testing
import Foundation
@testable import iCanHazAI

/// Tests for the chat tree data model and engine operations: branching regen,
/// edit-forking, branch switching, tree-aware deletion, and CLI leaf resolution.
extension AllAppTests {
    @Suite("Chat trees")
    struct ChatTreeTests {

        // MARK: - Data model helpers

        @Test("linear chat has no forks and activeMessages == messages")
        func linearChatNoForks() {
            let chat = Fixtures.simpleChat()
            #expect(chat.hasForks == false)
            #expect(chat.activeMessages.map(\.id) == chat.messages.map(\.id))
        }

        @Test("activeMessages walks the active path following activeChild")
        func activePathWalksActiveChild() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString, a2.id.uuidString]]
            let activeChild: [String: String] = [userKey: a2.id.uuidString]
            let chat = Fixtures.chat(messages: [user, a1, a2], children: children, activeChild: activeChild)
            #expect(chat.hasForks == true)
            let active = chat.activeMessages
            #expect(active.count == 2)
            #expect(active[0].id == user.id)
            #expect(active[1].id == a2.id)
        }

        @Test("activeMessages defaults to last child when no activeChild is set")
        func activePathDefaultsToLastChild() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString, a2.id.uuidString]]
            let chat = Fixtures.chat(messages: [user, a1, a2], children: children)
            let active = chat.activeMessages
            #expect(active.count == 2)
            #expect(active[1].id == a2.id)
        }

        @Test("siblings returns correct index and count for fork members")
        func siblingsForForkMembers() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString, a2.id.uuidString]]
            let chat = Fixtures.chat(messages: [user, a1, a2], children: children)
            let s1 = chat.siblings(of: a1.id)
            #expect(s1.index == 0)
            #expect(s1.count == 2)
            let s2 = chat.siblings(of: a2.id)
            #expect(s2.index == 1)
            #expect(s2.count == 2)
        }

        @Test("siblings returns (0, 1) for linear chats")
        func siblingsLinearChat() {
            let chat = Fixtures.simpleChat()
            let lastID = chat.messages.last!.id
            let s = chat.siblings(of: lastID)
            #expect(s.index == 0)
            #expect(s.count == 1)
        }

        @Test("parent returns the parent message for forked chats")
        func parentForForkedChat() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString]]
            let chat = Fixtures.chat(messages: [user, a1], children: children)
            let parent = chat.parent(of: a1.id)
            #expect(parent?.id == user.id)
        }

        @Test("materializeTree builds children from the flat array")
        func materializeTreeBuildsChildren() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            var chat = Fixtures.chat(messages: [user, a1])
            #expect(chat.hasForks == false)
            chat.materializeTree()
            #expect(chat.hasForks == true)
            #expect(chat.children?[user.id.uuidString] == [a1.id.uuidString])
        }

        @Test("setActiveChild updates the active child for a parent")
        func setActiveChildUpdates() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString, a2.id.uuidString]]
            var chat = Fixtures.chat(messages: [user, a1, a2], children: children)
            chat.setActiveChild(parentID: user.id, childID: a1.id)
            #expect(chat.activeChild?[userKey] == a1.id.uuidString)
            let active = chat.activeMessages
            #expect(active[1].id == a1.id)
        }

        @Test("subtreeIDs collects the message and all descendants")
        func subtreeIDsCollects() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let tool1 = Fixtures.message(role: .tool, content: "", timestamp: Date(timeIntervalSince1970: 3))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 4))
            let userKey = user.id.uuidString
            let a1Key = a1.id.uuidString
            let children: [String: [String]] = [
                userKey: [a1.id.uuidString, a2.id.uuidString],
                a1Key: [tool1.id.uuidString],
            ]
            let chat = Fixtures.chat(messages: [user, a1, tool1, a2], children: children)
            let subtree = chat.subtreeIDs(of: a1.id)
            #expect(subtree.contains(a1.id))
            #expect(subtree.contains(tool1.id))
            #expect(!subtree.contains(a2.id))
            #expect(!subtree.contains(user.id))
        }

        @Test("mostRecentLeafPath returns the path to the most recent leaf")
        func mostRecentLeafPathResolves() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 10))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString, a2.id.uuidString]]
            let activeChild: [String: String] = [userKey: a1.id.uuidString]
            let chat = Fixtures.chat(messages: [user, a1, a2], children: children, activeChild: activeChild)
            let path = chat.mostRecentLeafPath()
            #expect(path.count == 2)
            #expect(path[0].id == user.id)
            #expect(path[1].id == a2.id)
        }

        @Test("setActivePathToMostRecentLeaf updates activeChild to the most recent leaf")
        func setActivePathToMostRecentLeaf() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 10))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString, a2.id.uuidString]]
            let activeChild: [String: String] = [userKey: a1.id.uuidString]
            var chat = Fixtures.chat(messages: [user, a1, a2], children: children, activeChild: activeChild)
            chat.setActivePathToMostRecentLeaf()
            #expect(chat.activeChild?[userKey] == a2.id.uuidString)
        }

        @Test("pruneTreeMetadata removes entries for deleted ids")
        func pruneTreeMetadataRemovesDeleted() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString, a2.id.uuidString]]
            var chat = Fixtures.chat(messages: [user, a1, a2], children: children)
            chat.pruneTreeMetadata(deletedIDs: [a1.id])
            #expect(chat.children?[userKey] == [a2.id.uuidString])
        }

        @Test("reassignActiveChildAfterDeletion picks the most recent surviving sibling")
        func reassignActiveChildAfterDeletion() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 10))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString, a2.id.uuidString]]
            let activeChild: [String: String] = [userKey: a1.id.uuidString]
            var chat = Fixtures.chat(messages: [user, a1, a2], children: children, activeChild: activeChild)
            chat.reassignActiveChildAfterDeletion(parentID: user.id, deletedChildID: a1.id)
            #expect(chat.activeChild?[userKey] == a2.id.uuidString)
        }

        @Test("reassignActiveChildAfterDeletion collapses when no siblings survive")
        func reassignActiveChildCollapses() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString]]
            var chat = Fixtures.chat(messages: [user, a1], children: children)
            chat.reassignActiveChildAfterDeletion(parentID: user.id, deletedChildID: a1.id)
            #expect(chat.children == nil)
            #expect(chat.activeChild == nil)
        }

        // MARK: - Tolerant decode

        @Test("malformed children falls back to linear")
        func malformedChildrenFallsBackToLinear() throws {
            let user = Fixtures.message(role: .user, content: "q")
            let assistant = Fixtures.message(role: .assistant, content: "a")
            let json = """
            {"id":"00000000-0000-0000-0000-000000000001","messages":[
            {"id":"\(user.id.uuidString)","role":"user","content":"q","timestamp":0},
            {"id":"\(assistant.id.uuidString)","role":"assistant","content":"a","timestamp":1}
            ],"children":{"nonexistent":["also-nonexistent"]}}
            """
            let chat = try JSONDecoder().decode(Chat.self, from: Data(json.utf8))
            #expect(chat.hasForks == false)
            #expect(chat.activeMessages.count == 2)
        }

        @Test("chat with children and activeChild round-trips through Codable")
        func treeCodableRoundTrip() throws {
            let user = Fixtures.message(role: .user, content: "q")
            let a1 = Fixtures.message(role: .assistant, content: "a1")
            let a2 = Fixtures.message(role: .assistant, content: "a2")
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString, a2.id.uuidString]]
            let activeChild: [String: String] = [userKey: a2.id.uuidString]
            let chat = Fixtures.chat(messages: [user, a1, a2], children: children, activeChild: activeChild)
            let data = try JSONEncoder().encode(chat)
            let decoded = try JSONDecoder().decode(Chat.self, from: data)
            #expect(decoded.hasForks == true)
            #expect(decoded.children?[userKey] == [a1.id.uuidString, a2.id.uuidString])
            #expect(decoded.activeChild?[userKey] == a2.id.uuidString)
            let active = decoded.activeMessages
            #expect(active[1].id == a2.id)
        }

        // MARK: - Bridge message encode/decode

        @Test("switchBranch bridge message round-trips")
        func switchBranchBridgeRoundTrip() throws {
            let id = UUID().uuidString
            let original = BridgeMessageData.switchBranch(messageId: id, direction: -1)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(BridgeMessageData.self, from: data)
            guard case .switchBranch(let decodedId, let dir) = decoded else {
                Issue.record("expected .switchBranch, got \(decoded)")
                return
            }
            #expect(decodedId == id)
            #expect(dir == -1)
        }

        @Test("switchBranch bridge message encodes the correct type tag")
        func switchBranchBridgeTypeTag() throws {
            let original = BridgeMessageData.switchBranch(messageId: "abc-123", direction: 1)
            let data = try JSONEncoder().encode(original)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["type"] as? String == "switchBranch")
            #expect(json["messageId"] as? String == "abc-123")
            #expect(json["direction"] as? Int == 1)
        }

        // MARK: - Snapshot siblings projection

        @Test("projectActiveMessages stamps siblings for fork members")
        func projectActiveMessagesStampsSiblings() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString, a2.id.uuidString]]
            let activeChild: [String: String] = [userKey: a2.id.uuidString]
            let chat = Fixtures.chat(messages: [user, a1, a2], children: children, activeChild: activeChild)
            let projected = ChatRenderQueue.projectActiveMessages(chat)
            #expect(projected.count == 2)
            // The active assistant (a2) should have siblings stamped.
            #expect(projected[1].siblings?.index == 1)
            #expect(projected[1].siblings?.count == 2)
            // The user message has no siblings (it's the root, not a fork member).
            #expect(projected[0].siblings == nil)
        }

        @Test("projectActiveMessages returns nil siblings for linear chats")
        func projectActiveMessagesLinearNoSiblings() {
            let chat = Fixtures.simpleChat()
            let projected = ChatRenderQueue.projectActiveMessages(chat)
            #expect(projected.count == 2)
            #expect(projected.allSatisfy { $0.siblings == nil })
        }

        // MARK: - Nested forks

        @Test("activeMessages resolves nested forks correctly")
        func nestedForksResolve() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            let a2a = Fixtures.message(role: .assistant, content: "a2a", timestamp: Date(timeIntervalSince1970: 4))
            let a2b = Fixtures.message(role: .assistant, content: "a2b", timestamp: Date(timeIntervalSince1970: 5))
            let userKey = user.id.uuidString
            let a1Key = a1.id.uuidString
            let children: [String: [String]] = [
                userKey: [a1.id.uuidString],
                a1Key: [u2.id.uuidString],
                u2.id.uuidString: [a2a.id.uuidString, a2b.id.uuidString],
            ]
            let activeChild: [String: String] = [
                u2.id.uuidString: a2b.id.uuidString,
            ]
            let chat = Fixtures.chat(messages: [user, a1, u2, a2a, a2b], children: children, activeChild: activeChild)
            let active = chat.activeMessages
            #expect(active.count == 4)
            #expect(active[0].id == user.id)
            #expect(active[1].id == a1.id)
            #expect(active[2].id == u2.id)
            #expect(active[3].id == a2b.id)
        }

        @Test("branch switch with nested forks re-derives the path below")
        func branchSwitchNestedForks() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            let a2a = Fixtures.message(role: .assistant, content: "a2a", timestamp: Date(timeIntervalSince1970: 4))
            let a2b = Fixtures.message(role: .assistant, content: "a2b", timestamp: Date(timeIntervalSince1970: 5))
            let u2Key = u2.id.uuidString
            let children: [String: [String]] = [
                user.id.uuidString: [a1.id.uuidString],
                a1.id.uuidString: [u2.id.uuidString],
                u2Key: [a2a.id.uuidString, a2b.id.uuidString],
            ]
            let activeChild: [String: String] = [u2Key: a2b.id.uuidString]
            var chat = Fixtures.chat(messages: [user, a1, u2, a2a, a2b], children: children, activeChild: activeChild)
            // Switch to a2a
            chat.setActiveChild(parentID: u2.id, childID: a2a.id)
            let active = chat.activeMessages
            #expect(active[3].id == a2a.id)
        }

        // MARK: - Delete single-branch

        @Test("delete removes only the active path continuation, siblings survive")
        func deleteSingleBranch() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString, a2.id.uuidString]]
            let activeChild: [String: String] = [userKey: a2.id.uuidString]
            var chat = Fixtures.chat(messages: [user, a1, a2], children: children, activeChild: activeChild)
            // Delete a2 (the active child)
            let toRemove = chat.subtreeIDs(of: a2.id)
            chat.messages.removeAll(where: { toRemove.contains($0.id) })
            if let parent = chat.parent(of: a2.id) {
                chat.reassignActiveChildAfterDeletion(parentID: parent.id, deletedChildID: a2.id)
            }
            chat.pruneTreeMetadata(deletedIDs: toRemove)
            // a1 should survive and become the active child
            #expect(chat.messages.contains(where: { $0.id == a1.id }))
            #expect(chat.activeChild?[userKey] == a1.id.uuidString)
            let active = chat.activeMessages
            #expect(active.count == 2)
            #expect(active[1].id == a1.id)
        }

        // MARK: - followOnMessageCount with active path

        @Test("followOnMessageCount counts messages after the target on the active path")
        func followOnCountActivePath() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let userKey = user.id.uuidString
            let children: [String: [String]] = [userKey: [a1.id.uuidString, a2.id.uuidString]]
            let activeChild: [String: String] = [userKey: a2.id.uuidString]
            let chat = Fixtures.chat(messages: [user, a1, a2], children: children, activeChild: activeChild)
            // The active path is [user, a2], so followOn for user is 1 (a2).
            #expect(ChatView.followOnMessageCount(for: user.id, in: chat) == 1)
            // a2 is the last on the active path, so followOn is 0.
            #expect(ChatView.followOnMessageCount(for: a2.id, in: chat) == 0)
            // a1 is not on the active path, so followOn is 0.
            #expect(ChatView.followOnMessageCount(for: a1.id, in: chat) == 0)
        }
    }
}
