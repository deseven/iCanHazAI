import Foundation
import Testing
@testable import iCanHazAI

/// Tests for the temporary-chat support scattered across the model and
/// environment layers: filename conventions, image-directory routing (temp
/// chats keep attachments in the system temp dir, never in the chats folder),
/// the `isTemporary` projections on `ChatRecord`/`ChatSummary`, and stale
/// draft pruning. The engine's lifecycle itself (destroy-on-deselect) is not
/// covered here because `ChatEngine` is a singleton bound to the real
/// environment.
extension AllAppTests {

@Suite("TemporaryChat")
struct TemporaryChatTests {

    // MARK: - Filename conventions

    @Test("Temporary chat filenames carry the temp- prefix and a .json extension")
    func tempFilenameShape() {
        let env = try! TempEnv().env
        let filename = env.newTemporaryChatFilename()
        #expect(filename.hasPrefix(EnvironmentManager.temporaryChatPrefix))
        #expect(filename.hasSuffix(".json"))
        #expect(EnvironmentManager.isTemporaryChatFilename(filename))
    }

    @Test("Temporary chat filenames are unique across calls")
    func tempFilenamesUnique() {
        let env = try! TempEnv().env
        let names = Set((0..<100).map { _ in env.newTemporaryChatFilename() })
        #expect(names.count == 100)
    }

    @Test("Regular and temp filenames are distinguished by the prefix only")
    func tempFilenameDetection() {
        #expect(EnvironmentManager.isTemporaryChatFilename("temp-abc.json"))
        #expect(!EnvironmentManager.isTemporaryChatFilename("2026-08-05 20-00-00.json"))
        #expect(!EnvironmentManager.isTemporaryChatFilename("contemp-abc.json"))
        #expect(!EnvironmentManager.isTemporaryChatFilename(""))
    }

    // MARK: - Attachment directory routing

    @Test("Temp chat attachments live under the system temp dir, regular ones under the chats dir")
    func attachmentDirectoryRouting() throws {
        let temp = try TempEnv()
        let regularDir = temp.env.attachmentsDirectory(for: "2026-08-05 20-00-00.json")
        let tempDir = temp.env.attachmentsDirectory(for: "temp-\(UUID().uuidString).json")

        #expect(regularDir.path.hasPrefix(temp.env.chatsURL.path))
        #expect(!tempDir.path.hasPrefix(temp.env.chatsURL.path))
        #expect(tempDir.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).path))
    }

    @Test("Temp chat attachment save/load/delete round-trips through the temp dir")
    func tempAttachmentRoundTrip() throws {
        let temp = try TempEnv()
        let chatFilename = temp.env.newTemporaryChatFilename()
        let attachment = Attachment(id: UUID(), kind: .image, ext: "png", originalName: "cat.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])

        _ = temp.env.saveAttachment(data: bytes, filename: attachment.filename, chatFilename: chatFilename)
        // Nothing may appear in the chats directory.
        #expect(temp.diskFilenames().isEmpty)
        #expect(temp.env.loadAttachmentData(attachment, chatFilename: chatFilename) == bytes)

        temp.env.deleteAllAttachments(for: chatFilename)
        #expect(temp.env.loadAttachmentData(attachment, chatFilename: chatFilename) == nil)
    }

    @Test("deleteAllTemporaryAttachments wipes the whole temp attachment root")
    func wipeTemporaryAttachments() throws {
        let temp = try TempEnv()
        let chatFilename = temp.env.newTemporaryChatFilename()
        let attachment = Attachment(id: UUID(), kind: .image, ext: "png", originalName: nil)
        _ = temp.env.saveAttachment(data: Data([0x01]), filename: attachment.filename, chatFilename: chatFilename)
        #expect(temp.env.loadAttachmentData(attachment, chatFilename: chatFilename) != nil)

        temp.env.deleteAllTemporaryAttachments()
        // loadAttachmentData recreates the directory on demand, but the file is gone.
        #expect(temp.env.loadAttachmentData(attachment, chatFilename: chatFilename) == nil)
    }

    // MARK: - Model projections

    @Test("ChatRecord defaults to non-temporary and projects the flag into ChatSummary")
    func recordTemporaryProjection() {
        let regular = ChatRecord(filename: "a.json", chat: Chat())
        #expect(!regular.isTemporary)
        #expect(!ChatSummary(record: regular).isTemporary)

        let temp = ChatRecord(filename: "temp-\(UUID().uuidString).json", chat: Chat(), isTemporary: true)
        #expect(temp.isTemporary)
        #expect(ChatSummary(record: temp).isTemporary)
    }

    @Test("An empty temporary chat displays as 'Temporary chat'")
    func temporaryDisplayTitle() {
        let temp = ChatRecord(filename: "temp-x.json", chat: Chat(), isTemporary: true)
        #expect(temp.displayTitle == "Temporary chat")

        // A user-set title still wins.
        let titled = ChatRecord(filename: "temp-y.json", chat: Chat(title: "Secret"), isTemporary: true)
        #expect(titled.displayTitle == "Secret")
    }

    // MARK: - Draft pruning

    @Test("Stale temporary drafts are pruned, live and regular drafts survive")
    func staleTemporaryDraftPruning() {
        var store = InputDraftStore()
        store.set(ChatInputDraft(text: "regular"), for: "a.json")
        store.set(ChatInputDraft(text: "live temp"), for: "temp-live.json")
        store.set(ChatInputDraft(text: "dead temp"), for: "temp-dead.json")

        store.removeStaleTemporaryDrafts(validFilenames: ["a.json", "temp-live.json"])

        #expect(store.draft(for: "a.json")?.text == "regular")
        #expect(store.draft(for: "temp-live.json")?.text == "live temp")
        #expect(store.draft(for: "temp-dead.json") == nil)
    }
}
}
