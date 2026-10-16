import Foundation
import Testing

@testable import iCanHazAI

/// Tests for response regeneration: the feature-flag resolution and the
/// follow-on message count helper used by the delete/edit sheets.
extension AllAppTests {
    @Suite("Response regen")
    struct ResponseRegenTests {

        // MARK: - Feature flag resolution

        @Test("supportsResponseRegen is false for a role without features")
        func noFeaturesFlag() {
            let role = Role(name: "Test", config: RoleConfig())
            #expect(AppViewModel.supportsResponseRegen(role: role) == false)
        }

        @Test("supportsResponseRegen is false for nil role")
        func nilRoleFlag() {
            #expect(AppViewModel.supportsResponseRegen(role: nil) == false)
        }

        @Test("supportsResponseRegen is true when with_response_regen is set")
        func regenFlagSet() {
            var features = RoleFeatures()
            features.withResponseRegen = true
            var config = RoleConfig()
            config.features = features
            let role = Role(name: "Test", config: config)
            #expect(AppViewModel.supportsResponseRegen(role: role) == true)
        }

        @Test("supportsResponseRegen is false when only with_attachments is set")
        func onlyAttachmentsSet() {
            var features = RoleFeatures()
            features.withAttachments = true
            var config = RoleConfig()
            config.features = features
            let role = Role(name: "Test", config: config)
            #expect(AppViewModel.supportsResponseRegen(role: role) == false)
        }

        // MARK: - Follow-on message count

        @Test("followOnMessageCount is 0 for the last message")
        func lastMessageFollowOn() {
            let chat = Fixtures.simpleChat()
            let lastID = chat.messages.last!.id
            #expect(ChatView.followOnMessageCount(for: lastID, in: chat) == 0)
        }

        @Test("followOnMessageCount counts messages after the target")
        func middleMessageFollowOn() {
            let chat = Fixtures.chat(messages: [
                Fixtures.message(role: .user, content: "q1"),
                Fixtures.message(role: .assistant, content: "a1"),
                Fixtures.message(role: .user, content: "q2"),
                Fixtures.message(role: .assistant, content: "a2"),
            ])
            let firstAssistant = chat.messages[1].id
            #expect(ChatView.followOnMessageCount(for: firstAssistant, in: chat) == 2)
        }

        @Test("followOnMessageCount is 0 for nil chat")
        func nilChatFollowOn() {
            #expect(ChatView.followOnMessageCount(for: UUID(), in: nil) == 0)
        }

        @Test("followOnMessageCount is 0 for a missing message id")
        func missingMessageFollowOn() {
            let chat = Fixtures.simpleChat()
            #expect(ChatView.followOnMessageCount(for: UUID(), in: chat) == 0)
        }
    }
}
