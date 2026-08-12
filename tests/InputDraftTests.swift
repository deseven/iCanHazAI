import Foundation
import Testing

@testable import iCanHazAI

extension AllAppTests {
    @Suite struct InputDraftTests {

        private func makeAttachment() -> PendingAttachment {
            // 1x1 PNG; the bytes only need to be non-empty for draft storage.
            PendingAttachment(data: Data([0x89, 0x50, 0x4E, 0x47]), kind: .image, originalName: "dot.png")
        }

        @Test("A draft with no text and no attachments is empty")
        func emptyDraft() {
            #expect(ChatInputDraft().isEmpty)
            #expect(ChatInputDraft(text: "", attachments: []).isEmpty)
        }

        @Test("Text or attachments alone make a draft non-empty")
        func nonEmptyDraft() {
            #expect(!ChatInputDraft(text: "hi").isEmpty)
            #expect(!ChatInputDraft(attachments: [makeAttachment()]).isEmpty)
        }

        @Test("Setting a draft stores it per chat, independently")
        func setPerChat() {
            var store = InputDraftStore()
            store.set(ChatInputDraft(text: "draft A"), for: "a.json")
            store.set(ChatInputDraft(text: "draft B"), for: "b.json")

            #expect(store.draft(for: "a.json")?.text == "draft A")
            #expect(store.draft(for: "b.json")?.text == "draft B")
        }

        @Test("Setting an empty draft prunes an existing entry")
        func emptySetPrunes() {
            var store = InputDraftStore()
            store.set(ChatInputDraft(text: "wip"), for: "a.json")
            store.set(ChatInputDraft(), for: "a.json")

            #expect(store.draft(for: "a.json") == nil)
        }

        @Test("Setting an empty draft for an unknown chat is a no-op")
        func emptySetUnknown() {
            var store = InputDraftStore()
            store.set(ChatInputDraft(), for: "ghost.json")

            #expect(store.draft(for: "ghost.json") == nil)
        }

        @Test("remove(for:) drops only the targeted chat's draft")
        func removeTargeted() {
            var store = InputDraftStore()
            store.set(ChatInputDraft(text: "draft A"), for: "a.json")
            store.set(ChatInputDraft(text: "draft B"), for: "b.json")
            store.remove(for: "a.json")

            #expect(store.draft(for: "a.json") == nil)
            #expect(store.draft(for: "b.json")?.text == "draft B")
        }
    }
}
