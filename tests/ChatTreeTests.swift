import Foundation
import Testing

@testable import iCanHazAI

/// Tests for the chat tree data model: the nested `branches`/`activeBranch`
/// structure, the structural tree operations (append/fork/switch/delete),
/// invariant normalization, and Codable round-trips.
extension AllAppTests {
    @Suite("Chat trees")
    struct ChatTreeTests {

        // MARK: - Data model reads

        @Test("linear chat has no forks and activeMessages == messages")
        func linearChatNoForks() {
            let chat = Fixtures.simpleChat()
            #expect(chat.hasForks == false)
            #expect(chat.activeMessages.map(\.id) == chat.messages.map(\.id))
        }

        @Test("activeMessages follows the recorded active branch")
        func activePathFollowsActiveBranch() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]], active: 0)])
            #expect(chat.hasForks == true)
            #expect(chat.activeMessages.map(\.id) == [user.id, a1.id])
        }

        @Test("activeMessages defaults to the last branch when no choice is recorded")
        func activePathDefaultsToLastBranch() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]])])
            #expect(chat.activeMessages.map(\.id) == [user.id, a2.id])
        }

        @Test("activeMessages returns detached messages (no branches)")
        func activePathIsDetached() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]])])
            #expect(chat.activeMessages.allSatisfy { $0.branches == nil && $0.activeBranch == nil })
        }

        @Test("siblings returns index and count for branch heads, (0, 1) for mid-branch messages")
        func siblingsForBranchHeads() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 4))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1, u2], [a2]])])
            #expect(chat.siblings(of: a1.id) == (0, 2))
            #expect(chat.siblings(of: a2.id) == (1, 2))
            #expect(chat.siblings(of: u2.id) == (0, 1))
            #expect(chat.siblings(of: user.id) == (0, 1))
        }

        @Test("siblings returns (0, 1) for linear chats")
        func siblingsLinearChat() {
            let chat = Fixtures.simpleChat()
            let s = chat.siblings(of: chat.messages.last!.id)
            #expect(s == (0, 1))
        }

        @Test("parent resolves branch heads, mid-branch messages, and the root")
        func parentResolution() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 4))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1, u2], [a2]])])
            #expect(chat.parent(of: a1.id)?.id == user.id)
            #expect(chat.parent(of: a2.id)?.id == user.id)
            #expect(chat.parent(of: u2.id)?.id == a1.id)
            #expect(chat.parent(of: user.id) == nil)
        }

        @Test("subtreeIDs collects the message and all its descendants")
        func subtreeIDsCollects() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let tool1 = Fixtures.message(role: .tool, content: "", timestamp: Date(timeIntervalSince1970: 3))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 4))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1, tool1], [a2]])])
            let subtree = chat.subtreeIDs(of: a1.id)
            #expect(subtree == [a1.id, tool1.id])
        }

        @Test("mostRecentTimestamp covers all branches")
        func mostRecentTimestampAcrossBranches() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 10))
            // a2 is the newest but on the inactive branch.
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]], active: 0)])
            #expect(chat.mostRecentTimestamp == a2.timestamp)
        }

        @Test("allMessages flattens every branch, detached")
        func allMessagesFlattens() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]])])
            let all = chat.allMessages
            #expect(Set(all.map(\.id)) == [user.id, a1.id, a2.id])
            #expect(all.allSatisfy { $0.branches == nil })
        }

        // MARK: - appendToActiveLeaf

        @Test("appending to a linear chat appends at the end")
        func appendLinear() {
            var chat = Fixtures.simpleChat()
            let followUp = Fixtures.message(role: .user, content: "more", timestamp: Date(timeIntervalSince1970: 20))
            chat.appendToActiveLeaf(followUp)
            #expect(chat.messages.last?.id == followUp.id)
            #expect(chat.hasForks == false)
        }

        @Test("appending after a branch switch lands on the active branch")
        func appendAfterBranchSwitchLandsOnActiveBranch() {
            // Regression: a follow-up sent after switching back to the first
            // regen branch must attach to that branch's leaf — not to the
            // most recently appended message of the other branch (which used
            // to mix tool calls of one branch with results of another).
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(
                role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3),
                toolCalls: [ToolCall(id: "c1", name: "ls", arguments: "{}")])
            let toolRes = Fixtures.message(
                role: .tool, content: "", timestamp: Date(timeIntervalSince1970: 4),
                toolResults: [ToolResult(callID: "c1", content: "out", isError: false)])
            let a2final = Fixtures.message(
                role: .assistant, content: "a2 final", timestamp: Date(timeIntervalSince1970: 5))
            var chat = Fixtures.chat(messages: [
                Fixtures.forking(user, branches: [[a1], [a2, toolRes, a2final]], active: 1)
            ])
            // Switch back to the first answer and send a follow-up.
            chat.switchActiveBranch(parentID: user.id, to: a1.id)
            let followUp = Fixtures.message(
                role: .user, content: "follow-up", timestamp: Date(timeIntervalSince1970: 6))
            let answer = Fixtures.message(
                role: .assistant, content: "a1 follow-up answer", timestamp: Date(timeIntervalSince1970: 7))
            chat.appendToActiveLeaf(followUp)
            chat.appendToActiveLeaf(answer)
            // The follow-up turn is a continuation of the FIRST branch.
            #expect(chat.activeMessages.map(\.id) == [user.id, a1.id, followUp.id, answer.id])
            #expect(chat.parent(of: followUp.id)?.id == a1.id)
            // The second branch is structurally untouched.
            #expect(chat.messages[0].branches?[1].map(\.id) == [a2.id, toolRes.id, a2final.id])
            #expect(chat.allMessages.count == 7)
        }

        @Test("appending descends nested active forks")
        func appendDescendsNestedForks() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let x = Fixtures.message(role: .user, content: "x", timestamp: Date(timeIntervalSince1970: 4))
            let y = Fixtures.message(role: .user, content: "y", timestamp: Date(timeIntervalSince1970: 5))
            let a2Forked = Fixtures.forking(a2, branches: [[x], [y]], active: 1)
            var chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2Forked]], active: 1)])
            let z = Fixtures.message(role: .assistant, content: "z", timestamp: Date(timeIntervalSince1970: 6))
            chat.appendToActiveLeaf(z)
            #expect(chat.activeMessages.map(\.id) == [user.id, a2.id, y.id, z.id])
        }

        // MARK: - forkRegenerating

        @Test("regen fork keeps the target and its subtree as an inactive branch")
        func regenForkPreservesSubtree() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            let a1b = Fixtures.message(role: .assistant, content: "a1b", timestamp: Date(timeIntervalSince1970: 4))
            var chat = Fixtures.chat(messages: [user, a1, u2, a1b])
            let placeholder = Fixtures.message(role: .assistant, content: "", timestamp: Date(timeIntervalSince1970: 5))
            #expect(chat.forkRegenerating(a1.id, adding: placeholder) == true)
            #expect(chat.activeMessages.map(\.id) == [user.id, placeholder.id])
            let branches = chat.messages[0].branches
            #expect(branches?.count == 2)
            #expect(branches?[0].map(\.id) == [a1.id, u2.id, a1b.id])
            #expect(branches?[1].map(\.id) == [placeholder.id])
            #expect(chat.messages[0].activeBranch == 1)
        }

        @Test("regen fork on an existing branch head adds another branch")
        func regenForkOnBranchHead() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            var chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]], active: 1)])
            let a3 = Fixtures.message(role: .assistant, content: "", timestamp: Date(timeIntervalSince1970: 4))
            #expect(chat.forkRegenerating(a2.id, adding: a3) == true)
            #expect(chat.messages[0].branches?.count == 3)
            #expect(chat.messages[0].activeBranch == 2)
            #expect(chat.activeMessages.map(\.id) == [user.id, a3.id])
        }

        @Test("regen fork on the first message is rejected")
        func regenForkOnFirstMessageRejected() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            var chat = Fixtures.chat(messages: [user])
            let placeholder = Fixtures.message(role: .assistant, content: "", timestamp: Date(timeIntervalSince1970: 2))
            #expect(chat.forkRegenerating(user.id, adding: placeholder) == false)
            #expect(chat.hasForks == false)
        }

        // MARK: - forkContinuing

        @Test("edit fork splits the inline continuation into a sibling branch")
        func editForkSplitsInlineTail() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 4))
            var chat = Fixtures.chat(messages: [user, a1, u2, a2])
            let placeholder = Fixtures.message(role: .assistant, content: "", timestamp: Date(timeIntervalSince1970: 5))
            #expect(chat.forkContinuing(after: a1.id, adding: placeholder) == true)
            #expect(chat.activeMessages.map(\.id) == [user.id, a1.id, placeholder.id])
            #expect(chat.messages[1].branches?.map { $0.map(\.id) } == [[u2.id, a2.id], [placeholder.id]])
            #expect(chat.messages[1].activeBranch == 1)
        }

        @Test("edit fork on a leaf is a plain append")
        func editForkOnLeafAppends() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            var chat = Fixtures.chat(messages: [user, a1])
            let placeholder = Fixtures.message(role: .assistant, content: "", timestamp: Date(timeIntervalSince1970: 3))
            #expect(chat.forkContinuing(after: a1.id, adding: placeholder) == true)
            #expect(chat.hasForks == false)
            #expect(chat.messages.map(\.id) == [user.id, a1.id, placeholder.id])
        }

        @Test("edit fork on an existing fork owner adds another branch")
        func editForkOnForkOwnerAddsBranch() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            var chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]], active: 0)])
            let u3 = Fixtures.message(role: .user, content: "q3", timestamp: Date(timeIntervalSince1970: 4))
            #expect(chat.forkContinuing(after: user.id, adding: u3) == true)
            #expect(chat.messages[0].branches?.count == 3)
            #expect(chat.messages[0].activeBranch == 2)
        }

        // MARK: - Branch switching

        @Test("switchActiveBranch re-derives the path below")
        func switchBranchNestedForks() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            let a2a = Fixtures.message(role: .assistant, content: "a2a", timestamp: Date(timeIntervalSince1970: 4))
            let a2b = Fixtures.message(role: .assistant, content: "a2b", timestamp: Date(timeIntervalSince1970: 5))
            var chat = Fixtures.chat(messages: [user, a1, Fixtures.forking(u2, branches: [[a2a], [a2b]], active: 1)])
            #expect(chat.switchActiveBranch(parentID: u2.id, to: a2a.id) == true)
            #expect(chat.activeMessages.map(\.id) == [user.id, a1.id, u2.id, a2a.id])
            // A child that doesn't head a branch of the parent is rejected.
            #expect(chat.switchActiveBranch(parentID: u2.id, to: a1.id) == false)
        }

        @Test("siblingID wraps around in both directions")
        func siblingIDWraps() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]])])
            #expect(chat.siblingID(of: a1.id, direction: 1) == a2.id)
            #expect(chat.siblingID(of: a1.id, direction: -1) == a2.id)
            #expect(chat.siblingID(of: a2.id, direction: 1) == a1.id)
            #expect(chat.siblingID(of: user.id, direction: 1) == nil)
        }

        @Test("activatePath switches every fork on the way to the target")
        func activatePathSwitchesForks() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            let a2a = Fixtures.message(role: .assistant, content: "a2a", timestamp: Date(timeIntervalSince1970: 4))
            let a2b = Fixtures.message(role: .assistant, content: "a2b", timestamp: Date(timeIntervalSince1970: 5))
            let a3 = Fixtures.message(role: .assistant, content: "a3", timestamp: Date(timeIntervalSince1970: 6))
            let u2Forked = Fixtures.forking(u2, branches: [[a2a], [a2b]], active: 1)
            // user → branches: [a1 → u2 → {a2a, a2b}], [a3]; active: a3's branch.
            let trunk = Fixtures.forking(user, branches: [[a1, u2Forked], [a3]], active: 1)
            var chat = Fixtures.chat(messages: [trunk])
            #expect(chat.activatePath(to: a2a.id) == true)
            #expect(chat.activeMessages.map(\.id) == [user.id, a1.id, u2.id, a2a.id])
            #expect(chat.activatePath(to: UUID()) == false)
        }

        // MARK: - Deletion

        @Test("deleting the active branch head drops the branch, survivor becomes active")
        func deleteActiveBranchHead() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            var chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]], active: 1)])
            let removed = chat.deleteSubtree(of: a2.id)
            #expect(removed.map(\.id) == [a2.id])
            // One branch left → the fork unwraps to a linear chat.
            #expect(chat.hasForks == false)
            #expect(chat.activeMessages.map(\.id) == [user.id, a1.id])
        }

        @Test("deleting a mid-branch message truncates it and its descendants only")
        func deleteMidBranchTruncates() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            let a2a = Fixtures.message(role: .assistant, content: "a2a", timestamp: Date(timeIntervalSince1970: 4))
            let u2b = Fixtures.message(role: .user, content: "q2b", timestamp: Date(timeIntervalSince1970: 5))
            var chat = Fixtures.chat(messages: [user, Fixtures.forking(a1, branches: [[u2, a2a], [u2b]], active: 0)])
            let removed = chat.deleteSubtree(of: u2.id)
            #expect(Set(removed.map(\.id)) == [u2.id, a2a.id])
            // The emptied branch is dropped; the single surviving branch
            // unwraps inline.
            #expect(chat.hasForks == false)
            #expect(chat.messages.map(\.id) == [user.id, a1.id, u2b.id])
        }

        @Test("deleting from a linear chat truncates")
        func deleteLinearTruncates() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let u2 = Fixtures.message(role: .user, content: "q2", timestamp: Date(timeIntervalSince1970: 3))
            var chat = Fixtures.chat(messages: [user, a1, u2])
            let removed = chat.deleteSubtree(of: a1.id)
            #expect(removed.map(\.id) == [a1.id, u2.id])
            #expect(chat.messages.map(\.id) == [user.id])
        }

        @Test("deleting a branch before the recorded active one shifts the selection")
        func deleteBranchShiftsActiveIndex() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let a3 = Fixtures.message(role: .assistant, content: "a3", timestamp: Date(timeIntervalSince1970: 4))
            var chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2], [a3]], active: 2)])
            chat.deleteSubtree(of: a1.id)
            #expect(chat.messages[0].branches?.count == 2)
            #expect(chat.messages[0].activeBranch == 1)
            #expect(chat.activeMessages.map(\.id) == [user.id, a3.id])
        }

        // MARK: - CLI leaf resolution

        @Test("setActivePathToMostRecentLeaf picks the freshest branch")
        func setActivePathToMostRecentLeafPicksFreshest() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 10))
            var chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]], active: 0)])
            chat.setActivePathToMostRecentLeaf()
            #expect(chat.messages[0].activeBranch == 1)
            #expect(chat.activeMessages.map(\.id) == [user.id, a2.id])
        }

        // MARK: - finalizeActiveStoppedTurn

        @Test("finalize removes trailing placeholders and synthesizes cancelled results on the active branch only")
        func finalizeStoppedTurnOnFork() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let call = ToolCall(id: "c1", name: "ls", arguments: "{}")
            let a2 = Fixtures.message(
                role: .assistant, content: "working…", timestamp: Date(timeIntervalSince1970: 3), toolCalls: [call])
            let placeholder = Fixtures.message(role: .assistant, content: "", timestamp: Date(timeIntervalSince1970: 4))
            var chat = Fixtures.chat(messages: [
                Fixtures.forking(user, branches: [[a1], [a2, placeholder]], active: 1)
            ])
            chat.finalizeActiveStoppedTurn()
            // The placeholder is gone; a2's unanswered call got a synthesized
            // cancelled result; the first branch is untouched.
            #expect(chat.messages[0].branches?[0].map(\.id) == [a1.id])
            let branch2 = chat.messages[0].branches?[1] ?? []
            #expect(branch2.count == 2)
            #expect(branch2[0].id == a2.id)
            #expect(branch2[1].role == .tool)
            #expect(branch2[1].toolResults?.first?.callID == "c1")
            #expect(branch2[1].toolResults?.first?.isCancelled == true)
            #expect(chat.activeMessages.map(\.id) == [user.id, a2.id, branch2[1].id])
        }

        // MARK: - updateMessage

        @Test("updateMessage mutates a nested message and preserves structure")
        func updateMessageNested() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            var chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]])])
            chat.updateMessage(id: a1.id) { $0.content = "a1 edited" }
            #expect(chat.message(id: a1.id)?.content == "a1 edited")
            #expect(chat.messages[0].branches?.count == 2)
            // Updating a fork owner via applyContent keeps its branches.
            chat.updateMessage(id: user.id) { $0.applyContent(from: user.detached) }
            #expect(chat.messages[0].branches?.count == 2)
        }

        // MARK: - Codable

        @Test("nested tree round-trips through Codable")
        func treeCodableRoundTrip() throws {
            let user = Fixtures.message(role: .user, content: "q")
            let a1 = Fixtures.message(role: .assistant, content: "a1")
            let a2 = Fixtures.message(role: .assistant, content: "a2")
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]], active: 0)])
            let data = try JSONEncoder().encode(chat)
            let decoded = try JSONDecoder().decode(Chat.self, from: data)
            #expect(decoded.hasForks == true)
            #expect(decoded.messages[0].branches?.map { $0.map(\.id) } == [[a1.id], [a2.id]])
            #expect(decoded.messages[0].activeBranch == 0)
            #expect(decoded.activeMessages.map(\.id) == [user.id, a1.id])
        }

        @Test("legacy children/activeChild keys are ignored on decode")
        func legacyKeysIgnored() throws {
            let user = Fixtures.message(role: .user, content: "q")
            let assistant = Fixtures.message(role: .assistant, content: "a")
            let json = """
                {"id":"00000000-0000-0000-0000-000000000001","messages":[
                {"id":"\(user.id.uuidString)","role":"user","content":"q","timestamp":0},
                {"id":"\(assistant.id.uuidString)","role":"assistant","content":"a","timestamp":1}
                ],"children":{"nonexistent":["also-nonexistent"]},"activeChild":{"x":"y"}}
                """
            let chat = try JSONDecoder().decode(Chat.self, from: Data(json.utf8))
            #expect(chat.hasForks == false)
            #expect(chat.activeMessages.count == 2)
        }

        @Test("a single-branch fork unwraps on decode")
        func singleBranchForkUnwraps() throws {
            let user = Fixtures.message(role: .user, content: "q")
            let a1 = Fixtures.message(role: .assistant, content: "a1")
            let json = """
                {"id":"00000000-0000-0000-0000-000000000001","messages":[
                {"id":"\(user.id.uuidString)","role":"user","content":"q","timestamp":0,
                 "branches":[[{"id":"\(a1.id.uuidString)","role":"assistant","content":"a1","timestamp":1}]],"activeBranch":0}
                ]}
                """
            let chat = try JSONDecoder().decode(Chat.self, from: Data(json.utf8))
            #expect(chat.hasForks == false)
            #expect(chat.messages.map(\.id) == [user.id, a1.id])
        }

        @Test("an out-of-range activeBranch falls back to the last branch")
        func invalidActiveBranchFallsBack() throws {
            let user = Fixtures.message(role: .user, content: "q")
            let a1 = Fixtures.message(role: .assistant, content: "a1")
            let a2 = Fixtures.message(role: .assistant, content: "a2")
            let json = """
                {"id":"00000000-0000-0000-0000-000000000001","messages":[
                {"id":"\(user.id.uuidString)","role":"user","content":"q","timestamp":0,
                 "branches":[[{"id":"\(a1.id.uuidString)","role":"assistant","content":"a1","timestamp":1}],
                             [{"id":"\(a2.id.uuidString)","role":"assistant","content":"a2","timestamp":2}]],
                 "activeBranch":7}
                ]}
                """
            let chat = try JSONDecoder().decode(Chat.self, from: Data(json.utf8))
            #expect(chat.hasForks == true)
            #expect(chat.activeMessages.map(\.id) == [user.id, a2.id])
        }

        @Test("an inline tail after a fork owner folds into a branch on decode")
        func inlineTailFoldsIntoBranch() throws {
            let user = Fixtures.message(role: .user, content: "q")
            let a1 = Fixtures.message(role: .assistant, content: "a1")
            let a2 = Fixtures.message(role: .assistant, content: "a2")
            let tail = Fixtures.message(role: .user, content: "tail")
            let json = """
                {"id":"00000000-0000-0000-0000-000000000001","messages":[
                {"id":"\(user.id.uuidString)","role":"user","content":"q","timestamp":0,
                 "branches":[[{"id":"\(a1.id.uuidString)","role":"assistant","content":"a1","timestamp":1}]]},
                {"id":"\(a2.id.uuidString)","role":"assistant","content":"a2","timestamp":2},
                {"id":"\(tail.id.uuidString)","role":"user","content":"tail","timestamp":3}
                ]}
                """
            let chat = try JSONDecoder().decode(Chat.self, from: Data(json.utf8))
            #expect(chat.hasForks == true)
            // The inline tail became the first branch; default active = last
            // branch (the original explicit one).
            #expect(chat.activeMessages.map(\.id) == [user.id, a1.id])
            #expect(chat.messages.count == 1)
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

        @Test("projectActiveMessages stamps siblings for branch heads")
        func projectActiveMessagesStampsSiblings() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]], active: 1)])
            let projected = ChatRenderQueue.projectActiveMessages(chat)
            #expect(projected.count == 2)
            // The active assistant (a2) heads a branch → siblings stamped.
            #expect(projected[1].siblings?.index == 1)
            #expect(projected[1].siblings?.count == 2)
            // The user message is the fork owner, not a branch head.
            #expect(projected[0].siblings == nil)
        }

        @Test("projectActiveMessages returns nil siblings for linear chats")
        func projectActiveMessagesLinearNoSiblings() {
            let chat = Fixtures.simpleChat()
            let projected = ChatRenderQueue.projectActiveMessages(chat)
            #expect(projected.count == 2)
            #expect(projected.allSatisfy { $0.siblings == nil })
        }

        // MARK: - followOnMessageCount with active path

        @Test("followOnMessageCount counts messages after the target on the active path")
        func followOnCountActivePath() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]], active: 1)])
            // The active path is [user, a2], so followOn for user is 1 (a2).
            #expect(ChatView.followOnMessageCount(for: user.id, in: chat) == 1)
            // a2 is the last on the active path, so followOn is 0.
            #expect(ChatView.followOnMessageCount(for: a2.id, in: chat) == 0)
            // a1 is not on the active path, so followOn is 0.
            #expect(ChatView.followOnMessageCount(for: a1.id, in: chat) == 0)
        }
    }
}
