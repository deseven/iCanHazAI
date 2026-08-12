import Foundation
import Testing

@testable import iCanHazAI

/// Tests for response regeneration: the feature-flag resolution, the
/// follow-on message count helper used by the delete/edit sheets, and the
/// `regenerate` bridge message encode/decode round-trip.
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

        // MARK: - Bridge message encode/decode

        @Test("regenerate bridge message round-trips")
        func regenerateBridgeRoundTrip() throws {
            let id = UUID().uuidString
            let original = BridgeMessageData.regenerate(messageId: id)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(BridgeMessageData.self, from: data)
            guard case .regenerate(let decodedId) = decoded else {
                Issue.record("expected .regenerate, got \(decoded)")
                return
            }
            #expect(decodedId == id)
        }

        @Test("regenerate bridge message encodes the correct type tag")
        func regenerateBridgeTypeTag() throws {
            let original = BridgeMessageData.regenerate(messageId: "abc-123")
            let data = try JSONEncoder().encode(original)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["type"] as? String == "regenerate")
            #expect(json["messageId"] as? String == "abc-123")
        }

        // MARK: - Snapshot features encode/decode

        @Test("snapshot features round-trip with regen enabled")
        func featuresRoundTripRegen() throws {
            let features = ChatSnapshotFeaturesData(responseRegen: true, chatTrees: false)
            let snapshot = ChatSnapshotData(
                chatId: "test",
                messages: [],
                isStreaming: false,
                roleName: nil,
                roleAccent: nil,
                features: features
            )
            let data = try JSONEncoder().encode(snapshot)
            let decoded = try JSONDecoder().decode(ChatSnapshotData.self, from: data)
            #expect(decoded.features.responseRegen == true)
            #expect(decoded.features.chatTrees == false)
        }

        @Test("snapshot features round-trip with both flags enabled")
        func featuresRoundTripBoth() throws {
            let features = ChatSnapshotFeaturesData(responseRegen: true, chatTrees: true)
            let snapshot = ChatSnapshotData(
                chatId: "test",
                messages: [],
                isStreaming: false,
                roleName: "Assistant",
                roleAccent: "#FF0000",
                features: features
            )
            let data = try JSONEncoder().encode(snapshot)
            let decoded = try JSONDecoder().decode(ChatSnapshotData.self, from: data)
            #expect(decoded.features.responseRegen == true)
            #expect(decoded.features.chatTrees == true)
        }

        @Test("snapshot features default to false when absent")
        func featuresDefaultFalse() throws {
            // Encode a snapshot without the features key by manually building JSON.
            let json = #"{"chatId":"x","messages":[],"isStreaming":false}"#
            let decoded = try JSONDecoder().decode(ChatSnapshotData.self, from: Data(json.utf8))
            #expect(decoded.features.responseRegen == false)
            #expect(decoded.features.chatTrees == false)
        }
    }
}
