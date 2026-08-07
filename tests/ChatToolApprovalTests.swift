import Testing
import Foundation
@testable import iCanHazAI

/// Tests for the per-chat tool auto-approval overrides: the effective-state
/// resolution ([`Chat.isToolAutoApproved`](src/Chat/Models.swift)) and the
/// toggle/set mutations that keep `auto_allow` / `auto_deny` minimal (no
/// entry is persisted when the state matches the role default).
extension AllAppTests {
    @Suite("Chat tool approval")
    struct ChatToolApprovalTests {

        // MARK: - isToolAutoApproved

        @Test("role default applies when the chat has no overrides")
        func roleDefaultApplies() {
            let chat = Chat()
            #expect(chat.isToolAutoApproved(namespacedName: "shell", roleDefault: false) == false)
            #expect(chat.isToolAutoApproved(namespacedName: "shell", roleDefault: true) == true)
        }

        @Test("auto_allow upgrades a role-denied tool")
        func autoAllowUpgrades() {
            let chat = Chat(autoAllow: ["shell"])
            #expect(chat.isToolAutoApproved(namespacedName: "shell", roleDefault: false) == true)
        }

        @Test("auto_deny downgrades a role-allowed tool")
        func autoDenyDowngrades() {
            let chat = Chat(autoDeny: ["read_file"])
            #expect(chat.isToolAutoApproved(namespacedName: "read_file", roleDefault: true) == false)
        }

        @Test("auto_deny wins over both role default and auto_allow")
        func denyWins() {
            let chat = Chat(autoAllow: ["shell"], autoDeny: ["shell"])
            #expect(chat.isToolAutoApproved(namespacedName: "shell", roleDefault: true) == false)
            #expect(chat.isToolAutoApproved(namespacedName: "shell", roleDefault: false) == false)
        }

        // MARK: - setToolAutoApproval

        @Test("approving a role-denied tool writes auto_allow")
        func approveWritesAllow() {
            var chat = Chat()
            chat.setToolAutoApproval(namespacedName: "shell", approved: true, roleDefault: false)
            #expect(chat.autoAllow == ["shell"])
            #expect(chat.autoDeny == nil)
        }

        @Test("denying a role-allowed tool writes auto_deny")
        func denyWritesDeny() {
            var chat = Chat()
            chat.setToolAutoApproval(namespacedName: "read_file", approved: false, roleDefault: true)
            #expect(chat.autoDeny == ["read_file"])
            #expect(chat.autoAllow == nil)
        }

        @Test("state matching the role default writes nothing and cleans existing entries")
        func matchingDefaultWritesNothing() {
            var chat = Chat(autoAllow: ["shell", "read_file"], autoDeny: ["write_file"])
            chat.setToolAutoApproval(namespacedName: "shell", approved: false, roleDefault: false)
            chat.setToolAutoApproval(namespacedName: "write_file", approved: true, roleDefault: true)
            #expect(chat.autoAllow == ["read_file"])
            #expect(chat.autoDeny == nil)
        }

        @Test("setting approval does not duplicate an existing entry")
        func noDuplicates() {
            var chat = Chat()
            chat.setToolAutoApproval(namespacedName: "shell", approved: true, roleDefault: false)
            chat.setToolAutoApproval(namespacedName: "shell", approved: true, roleDefault: false)
            #expect(chat.autoAllow == ["shell"])
        }

        @Test("re-denying a role-denied tool just removes the auto_allow entry")
        func reDenyCleansAllow() {
            var chat = Chat()
            chat.setToolAutoApproval(namespacedName: "shell", approved: true, roleDefault: false)
            chat.setToolAutoApproval(namespacedName: "shell", approved: false, roleDefault: false)
            #expect(chat.autoAllow == nil)
            #expect(chat.autoDeny == nil)
        }

        @Test("switching a tool from deny to allow moves the entry between lists")
        func movesBetweenLists() {
            var chat = Chat()
            chat.setToolAutoApproval(namespacedName: "read_file", approved: false, roleDefault: true)
            #expect(chat.autoDeny == ["read_file"])
            chat.setToolAutoApproval(namespacedName: "read_file", approved: true, roleDefault: true)
            #expect(chat.autoAllow == nil)
            #expect(chat.autoDeny == nil)
        }

        // MARK: - toggleToolAutoApproval

        @Test("toggle round-trips back to the role default with no persisted override")
        func toggleRoundTrip() {
            var chat = Chat()
            chat.toggleToolAutoApproval(namespacedName: "shell", roleDefault: false)
            #expect(chat.isToolAutoApproved(namespacedName: "shell", roleDefault: false) == true)
            #expect(chat.autoAllow == ["shell"])
            chat.toggleToolAutoApproval(namespacedName: "shell", roleDefault: false)
            #expect(chat.isToolAutoApproved(namespacedName: "shell", roleDefault: false) == false)
            #expect(chat.autoAllow == nil)
            #expect(chat.autoDeny == nil)
        }

        @Test("toggle on a role-allowed tool writes auto_deny, then cleans up")
        func toggleRoleAllowed() {
            var chat = Chat()
            chat.toggleToolAutoApproval(namespacedName: "read_file", roleDefault: true)
            #expect(chat.autoDeny == ["read_file"])
            chat.toggleToolAutoApproval(namespacedName: "read_file", roleDefault: true)
            #expect(chat.autoDeny == nil)
        }

        // MARK: - Persistence shape

        @Test("auto_deny round-trips through JSON and stays absent when nil")
        func autoDenyPersistence() throws {
            var chat = Chat()
            chat.setToolAutoApproval(namespacedName: "read_file", approved: false, roleDefault: true)
            let data = try JSONEncoder().encode(chat)
            let raw = String(decoding: data, as: UTF8.self)
            #expect(raw.contains("\"auto_deny\""))

            let decoded = try JSONDecoder().decode(Chat.self, from: data)
            #expect(decoded.autoDeny == ["read_file"])
            #expect(decoded.autoAllow == nil)

            // A chat with no overrides encodes neither key.
            let clean = try JSONEncoder().encode(Chat())
            let cleanRaw = String(decoding: clean, as: UTF8.self)
            #expect(!cleanRaw.contains("\"auto_deny\""))
            #expect(!cleanRaw.contains("\"auto_allow\""))
        }

        @Test("a chat file without auto_deny decodes tolerantly")
        func legacyDecodeToleratesMissingKey() throws {
            let json = #"{"id":"00000000-0000-0000-0000-000000000000","messages":[],"auto_allow":["shell"]}"#
            let chat = try JSONDecoder().decode(Chat.self, from: Data(json.utf8))
            #expect(chat.autoAllow == ["shell"])
            #expect(chat.autoDeny == nil)
        }
    }
}
