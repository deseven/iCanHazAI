import Testing
import Foundation
@testable import iCanHazAI

/// Tests for the role-assignment decision logic: when a chat's role is missing
/// (deleted or never set) the role picker should be presented so the user can
/// assign a new one. The pure helper
/// [`AppViewModel.chatNeedsRoleAssignment(_:availableRoles:)`](src/AppViewModel.swift)
/// is the decision function; these tests lock down its behavior without driving
/// the full UI.
extension AllAppTests {
    @Suite("Role assignment")
    struct RoleAssignmentTests {

        // MARK: - Fixtures

        /// A role named "Assistant" with a minimal config.
        private func assistantRole() -> Role {
            Role(name: "Assistant", config: RoleConfig())
        }

        // MARK: - chatNeedsRoleAssignment

        @Test("needs assignment when the chat has no role at all (loaded)")
        func needsAssignmentNoRoleLoaded() {
            let rec = ChatRecord(filename: "a.json", chat: Fixtures.chat(role: nil))
            #expect(AppViewModel.chatNeedsRoleAssignment(rec, availableRoles: [assistantRole()]) == true)
        }

        @Test("needs assignment when the chat has no role at all (unloaded, no cached role)")
        func needsAssignmentNoRoleUnloaded() {
            let rec = ChatRecord(filename: "a.json", chat: nil, cachedRole: nil)
            #expect(AppViewModel.chatNeedsRoleAssignment(rec, availableRoles: [assistantRole()]) == true)
        }

        @Test("needs assignment when the role name is empty")
        func needsAssignmentEmptyRole() {
            let rec = ChatRecord(filename: "a.json", chat: Fixtures.chat(role: ""))
            #expect(AppViewModel.chatNeedsRoleAssignment(rec, availableRoles: [assistantRole()]) == true)
        }

        @Test("needs assignment when the assigned role no longer exists (deleted)")
        func needsAssignmentDeletedRole() {
            // The chat references "Ghost", but only "Assistant" is available.
            let rec = ChatRecord(filename: "a.json", chat: Fixtures.chat(role: "Ghost"))
            #expect(AppViewModel.chatNeedsRoleAssignment(rec, availableRoles: [assistantRole()]) == true)
        }

        @Test("needs assignment when the cached role no longer exists (unloaded chat)")
        func needsAssignmentDeletedRoleUnloaded() {
            let rec = ChatRecord(filename: "a.json", chat: nil, cachedRole: "Ghost")
            #expect(AppViewModel.chatNeedsRoleAssignment(rec, availableRoles: [assistantRole()]) == true)
        }

        @Test("does not need assignment when the role exists (loaded)")
        func noAssignmentRoleExistsLoaded() {
            let rec = ChatRecord(filename: "a.json", chat: Fixtures.chat(role: "Assistant"))
            #expect(AppViewModel.chatNeedsRoleAssignment(rec, availableRoles: [assistantRole()]) == false)
        }

        @Test("does not need assignment when the cached role exists (unloaded)")
        func noAssignmentRoleExistsUnloaded() {
            let rec = ChatRecord(filename: "a.json", chat: nil, cachedRole: "Assistant")
            #expect(AppViewModel.chatNeedsRoleAssignment(rec, availableRoles: [assistantRole()]) == false)
        }

        @Test("does not need assignment when no roles are available but the chat has no role")
        func noRolesAvailableStillNeedsAssignment() {
            // Even with no roles to pick from, a chat with no role still
            // "needs" assignment (the picker just can't be shown). The helper
            // reports the need; the presentation gates on roles being non-empty.
            let rec = ChatRecord(filename: "a.json", chat: Fixtures.chat(role: nil))
            #expect(AppViewModel.chatNeedsRoleAssignment(rec, availableRoles: []) == true)
        }

        @Test("live role takes precedence over a stale cached role")
        func liveRolePrecedence() {
            // The chat is loaded with role "Assistant" but the cache says
            // "Ghost". The live role wins, so no assignment is needed.
            let rec = ChatRecord(
                filename: "a.json",
                chat: Fixtures.chat(role: "Assistant"),
                cachedRole: "Ghost"
            )
            #expect(AppViewModel.chatNeedsRoleAssignment(rec, availableRoles: [assistantRole()]) == false)
        }

        @Test("live missing role takes precedence over a valid cached role")
        func liveMissingRolePrecedence() {
            // The chat is loaded with role "Ghost" (deleted) but the cache
            // still says "Assistant". The live role wins, so assignment IS
            // needed even though the cached role is valid.
            let rec = ChatRecord(
                filename: "a.json",
                chat: Fixtures.chat(role: "Ghost"),
                cachedRole: "Assistant"
            )
            #expect(AppViewModel.chatNeedsRoleAssignment(rec, availableRoles: [assistantRole()]) == true)
        }
    }
}
