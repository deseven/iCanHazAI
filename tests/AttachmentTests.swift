import Foundation
import Testing
import AppKit
import PDFKit
@testable import iCanHazAI

// `Attachment` collides with `Testing.Attachment`; alias the app type so the
// tests can refer to it unambiguously.
typealias AppAttachment = iCanHazAI.Attachment

/// Tests for the generalized attachment pipeline: intake classification,
/// commit-on-send (copy original + extract text), persistence in the chat
/// JSON, and the request-builder text block (with 64 KB truncation).
extension AllAppTests {

@Suite("Attachments")
struct AttachmentTests {

    // MARK: - Intake classification

    @Test("Intake routes bytes through the classifier and rejects unsupported binaries")
    func intakeClassification() throws {
        // Plain text → .text
        let text = Data("hello world".utf8)
        let textAtt = AttachmentManager.intake(data: text, originalName: "note.txt", hint: .init(filename: "note.txt"))
        #expect(textAtt?.kind == .text)

        // RTF → .document(.rtf)
        let rtfAttr = NSAttributedString(string: "Hello RTF")
        let rtfData = try rtfAttr.data(
            from: NSRange(location: 0, length: rtfAttr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let rtfAtt = AttachmentManager.intake(data: rtfData, originalName: "doc.rtf", hint: .init(filename: "doc.rtf"))
        #expect(rtfAtt?.kind == .document(.rtf))

        // PNG → .image
        let png = makePNG(text: "IMG")
        let imgAtt = AttachmentManager.intake(data: png, originalName: "shot.png", hint: .init(filename: "shot.png"))
        #expect(imgAtt?.kind == .image)

        // Unknown binary → nil
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00])
        let unsupported = AttachmentManager.intake(data: zip, originalName: "a.zip", hint: .init(filename: "a.zip"))
        #expect(unsupported == nil)
    }

    // MARK: - Commit-on-send logic

    @Test("Committing a text attachment embeds the text and sets status ok")
    func commitTextEmbedsText() throws {
        let text = Data("plain text content".utf8)
        let pending = PendingAttachment(data: text, kind: .text, originalName: "note.txt")
        let committed = AttachmentManager.commit(pending, chatFilename: "test.json")
        #expect(committed != nil)
        guard let committed else { return }
        #expect(committed.kind == .text)
        #expect(committed.status == .ok)
        #expect(committed.text == "plain text content")
        #expect(committed.ext == "txt")
    }

    @Test("Committing a document attachment extracts text and sets status ok")
    @MainActor
    func commitDocumentExtractsText() throws {
        let rtfAttr = NSAttributedString(string: "Hello RTF\nSecond line.")
        let rtfData = try rtfAttr.data(
            from: NSRange(location: 0, length: rtfAttr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let pending = PendingAttachment(data: rtfData, kind: .document(.rtf), originalName: "doc.rtf")
        let committed = AttachmentManager.commit(pending, chatFilename: "test.json")
        #expect(committed != nil)
        guard let committed else { return }
        #expect(committed.kind == .document)
        #expect(committed.status == .ok)
        #expect(committed.text?.contains("Hello RTF") == true)
        #expect(committed.ext == "rtf")
    }

    @Test("Committing an image attachment produces an image record with a text fallback")
    @MainActor
    func commitImageRecord() throws {
        let png = makePNG(text: "IMG")
        let pending = PendingAttachment(data: png, kind: .image, originalName: "shot.png")
        let committed = AttachmentManager.commit(pending, chatFilename: "test.json")
        #expect(committed != nil)
        guard let committed else { return }
        #expect(committed.kind == .image)
        #expect(committed.status == .ok)
        // The fallback is synthesized from classification + OCR and stored on
        // the record so a vision-incapable connection can send it as text.
        #expect(committed.text != nil)
        #expect(committed.text?.contains("can't be processed visually here") == true)
    }

    @Test("Committing an unsupported binary returns nil")
    func commitUnsupportedReturnsNil() {
        let pending = PendingAttachment(data: Data([0x00]), kind: .unsupportedBinary, originalName: "x.bin")
        #expect(AttachmentManager.commit(pending, chatFilename: "test.json") == nil)
    }

    // MARK: - Persistence

    @Test("An attachment round-trips through the chat JSON")
    func attachmentCodableRoundTrip() throws {
        let attachment = AppAttachment(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            kind: .document,
            ext: "docx",
            originalName: "report.docx",
            text: "extracted text here",
            status: .ok
        )
        let msg = ChatMessage(role: .user, content: "see attached", attachments: [attachment])
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded == msg)
        #expect(decoded.attachments?.first?.text == "extracted text here")
        #expect(decoded.attachments?.first?.kind == .document)
    }

    @Test("A failed extraction is preserved through the chat JSON")
    func failedExtractionCodableRoundTrip() throws {
        let attachment = AppAttachment(
            kind: .document, ext: "docx",
            originalName: "bad.docx",
            text: nil, status: .failed, failureReason: "corrupt file"
        )
        let msg = ChatMessage(role: .user, content: "see attached", attachments: [attachment])
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded.attachments?.first?.status == .failed)
        #expect(decoded.attachments?.first?.failureReason == "corrupt file")
        #expect(decoded.attachments?.first?.text == nil)
    }

    @Test("A chat with mixed attachments reloads correctly")
    func mixedAttachmentReload() throws {
        let temp = try TempEnv()
        let chatFilename = "2026-08-09 12-00-03.json"
        let attachment = AppAttachment(
            kind: .text, ext: "txt",
            originalName: "note.txt",
            text: "text file body",
            status: .ok
        )
        var chat = Chat()
        chat.messages.append(ChatMessage(role: .user, content: "hi", attachments: [attachment]))
        temp.env.saveChat(chat, filename: chatFilename)

        let loaded = temp.env.loadSingleChat(filename: chatFilename)
        #expect(loaded != nil)
        let reloaded = loaded!.messages.first?.attachments?.first
        #expect(reloaded?.text == "text file body")
        #expect(reloaded?.kind == .text)
    }

    // MARK: - Request builder

    @Test("The request builder wraps text in a fenced block with a filename header")
    func requestBuilderBlock() {
        let attachment = AppAttachment(
            kind: .document, ext: "docx",
            originalName: "report.docx",
            text: "extracted content",
            status: .ok
        )
        let block = AttachmentRequestBuilder.block(for: attachment)
        #expect(block != nil)
        #expect(block!.contains("Attached file: report.docx"))
        #expect(block!.contains("```"))
        #expect(block!.contains("extracted content"))
    }

    @Test("The request builder returns nil for attachments with no text")
    func requestBuilderNoText() {
        let image = AppAttachment(kind: .image, ext: "png", originalName: "shot.png")
        #expect(AttachmentRequestBuilder.block(for: image) == nil)

        let failed = AppAttachment(kind: .document, ext: "docx", originalName: "bad.docx", text: nil, status: .failed, failureReason: "corrupt")
        #expect(AttachmentRequestBuilder.block(for: failed) == nil)
    }

    @Test("The request builder truncates content over 64 KB and ends with a visible marker")
    func requestBuilderTruncation() {
        // Build a string just over 64 KB.
        let chunk = String(repeating: "x", count: 1024)
        let big = (0..<70).map { _ in chunk }.joined() // 70 KB
        let attachment = AppAttachment(
            kind: .text, ext: "txt",
            originalName: "big.txt",
            text: big,
            status: .ok
        )
        let block = AttachmentRequestBuilder.block(for: attachment)
        #expect(block != nil)
        #expect(block!.contains("truncated"))
        // The body ends with a model-visible marker naming the file.
        #expect(block!.contains("[… truncated — full file attached as big.txt]"))
        // The block must be under 64 KB + overhead.
        #expect(block!.utf8.count < 70_000)
    }

    @Test("The truncation marker uses the stored filename when no original name is set")
    func requestBuilderTruncationFallbackName() {
        let chunk = String(repeating: "x", count: 1024)
        let big = (0..<70).map { _ in chunk }.joined()
        let attachment = AppAttachment(
            kind: .text, ext: "txt",
            originalName: nil,
            text: big,
            status: .ok
        )
        let block = AttachmentRequestBuilder.block(for: attachment)
        #expect(block != nil)
        // The marker falls back to the on-disk filename stem.
        #expect(block!.contains("[… truncated — full file attached as \(attachment.filename)]"))
    }

    @Test("sizeInfo reports byte/char counts and the truncated flag")
    func sizeInfoReportsCounts() {
        // Small content: not truncated.
        let small = AppAttachment(kind: .text, ext: "txt", originalName: "s.txt", text: "tiny", status: .ok)
        let smallInfo = AttachmentRequestBuilder.sizeInfo(for: small)
        #expect(smallInfo != nil)
        #expect(smallInfo?.byteCount == 4)
        #expect(smallInfo?.charCount == 4)
        #expect(smallInfo?.truncated == false)

        // Large content: truncated, byte/char counts reflect the full text.
        let chunk = String(repeating: "x", count: 1024)
        let big = (0..<70).map { _ in chunk }.joined() // 70 KB
        let bigAtt = AppAttachment(kind: .text, ext: "txt", originalName: "big.txt", text: big, status: .ok)
        let bigInfo = AttachmentRequestBuilder.sizeInfo(for: bigAtt)
        #expect(bigInfo != nil)
        #expect(bigInfo?.byteCount == big.utf8.count)
        #expect(bigInfo?.charCount == big.count)
        #expect(bigInfo?.truncated == true)
    }

    @Test("sizeInfo returns nil for attachments with no text")
    func sizeInfoNoText() {
        let image = AppAttachment(kind: .image, ext: "png", originalName: "shot.png")
        #expect(AttachmentRequestBuilder.sizeInfo(for: image) == nil)

        let failed = AppAttachment(kind: .document, ext: "docx", originalName: "bad.docx", text: nil, status: .failed, failureReason: "corrupt")
        #expect(AttachmentRequestBuilder.sizeInfo(for: failed) == nil)
    }

    @Test("The request builder leaves small content intact")
    func requestBuilderSmallContent() {
        let attachment = AppAttachment(
            kind: .text, ext: "txt",
            originalName: "small.txt",
            text: "tiny",
            status: .ok
        )
        let block = AttachmentRequestBuilder.block(for: attachment)
        #expect(block != nil)
        #expect(!block!.contains("truncated"))
        #expect(block!.contains("tiny"))
    }

    // MARK: - Filename sanitization

    @Test("Sanitize strips illegal characters but keeps the name readable")
    func sanitizeStripsIllegalChars() {
        // Slashes, colons, control chars are stripped.
        #expect(AttachmentManager.sanitize(filename: "a/b/c.txt") == "abc.txt")
        #expect(AttachmentManager.sanitize(filename: "report:final.docx") == "reportfinal.docx")
        #expect(AttachmentManager.sanitize(filename: "name\nwith\r\tnewlines.txt") == "namewithnewlines.txt")
        // Spaces and unicode are preserved.
        #expect(AttachmentManager.sanitize(filename: "my report.docx") == "my report.docx")
        #expect(AttachmentManager.sanitize(filename: "café résumé.pdf") == "café résumé.pdf")
    }

    @Test("Sanitize trims leading dots and whitespace")
    func sanitizeTrimsLeadingDots() {
        #expect(AttachmentManager.sanitize(filename: "  .hidden.txt") == "hidden.txt")
        #expect(AttachmentManager.sanitize(filename: "...secret.txt") == "secret.txt")
        #expect(AttachmentManager.sanitize(filename: "  spaced.txt  ") == "spaced.txt")
    }

    @Test("Sanitize falls back to a UUID stem when the name is empty")
    func sanitizeEmptyFallback() {
        let result = AttachmentManager.sanitize(filename: "")
        #expect(!result.isEmpty)
        // No extension when none was provided.
        #expect(!result.contains("."))
        let result2 = AttachmentManager.sanitize(filename: "///:::")
        #expect(!result2.isEmpty)
    }

    @Test("Sanitize lowercases the extension")
    func sanitizeLowercasesExt() {
        #expect(AttachmentManager.sanitize(filename: "photo.PNG") == "photo.png")
        #expect(AttachmentManager.sanitize(filename: "doc.DOCX") == "doc.docx")
    }

    // MARK: - Filename deduplication

    /// A throwaway temp chat filename so attachment data lands in the system
    /// temp dir (via `EnvironmentManager.shared`) and never touches the user's
    /// chats folder.
    private let dedupChatFilename = EnvironmentManager.shared.newTemporaryChatFilename()

    @Test("Dedup returns the proposed name when no collision exists")
    func dedupNoCollision() {
        let result = AttachmentManager.deduplicatedFilename(proposed: "report.docx", chatFilename: dedupChatFilename)
        #expect(result == "report.docx")
    }

    @Test("Dedup appends (1), (2) on collision")
    func dedupAppendsSuffix() throws {
        let dir = EnvironmentManager.shared.attachmentsDirectory(for: dedupChatFilename)
        // Pre-create the first file.
        try Data("first".utf8).write(to: dir.appendingPathComponent("report.docx"))
        let r1 = AttachmentManager.deduplicatedFilename(proposed: "report.docx", chatFilename: dedupChatFilename)
        #expect(r1 == "report (1).docx")
        // Pre-create the (1) file too.
        try Data("second".utf8).write(to: dir.appendingPathComponent("report (1).docx"))
        let r2 = AttachmentManager.deduplicatedFilename(proposed: "report.docx", chatFilename: dedupChatFilename)
        #expect(r2 == "report (2).docx")
    }

    @Test("Dedup handles names without extension")
    func dedupNoExtension() throws {
        let dir = EnvironmentManager.shared.attachmentsDirectory(for: dedupChatFilename)
        try Data("first".utf8).write(to: dir.appendingPathComponent("README"))
        let r = AttachmentManager.deduplicatedFilename(proposed: "README", chatFilename: dedupChatFilename)
        #expect(r == "README (1)")
    }

    // MARK: - Commit uses original names

    @Test("Committing a text attachment keeps the original filename on disk")
    func commitTextKeepsOriginalName() {
        let chatFilename = EnvironmentManager.shared.newTemporaryChatFilename()
        let text = Data("hello".utf8)
        let pending = PendingAttachment(data: text, kind: .text, originalName: "notes.txt")
        let committed = AttachmentManager.commit(pending, chatFilename: chatFilename)
        #expect(committed != nil)
        guard let committed else { return }
        #expect(committed.filename == "notes.txt")
        // The file exists on disk under the original name.
        let dir = EnvironmentManager.shared.attachmentsDirectory(for: chatFilename)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
    }

    @Test("Committing two attachments with the same name deduplicates")
    func commitDeduplicatesSameName() {
        let chatFilename = EnvironmentManager.shared.newTemporaryChatFilename()
        let text = Data("hello".utf8)
        let p1 = PendingAttachment(data: text, kind: .text, originalName: "notes.txt")
        let c1 = AttachmentManager.commit(p1, chatFilename: chatFilename)
        let p2 = PendingAttachment(data: text, kind: .text, originalName: "notes.txt")
        let c2 = AttachmentManager.commit(p2, chatFilename: chatFilename)
        #expect(c1?.filename == "notes.txt")
        #expect(c2?.filename == "notes (1).txt")
        let dir = EnvironmentManager.shared.attachmentsDirectory(for: chatFilename)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes (1).txt").path))
    }

    @Test("Committing sanitizes illegal characters in the original name")
    func commitSanitizesName() {
        let chatFilename = EnvironmentManager.shared.newTemporaryChatFilename()
        let text = Data("hello".utf8)
        let pending = PendingAttachment(data: text, kind: .text, originalName: "a/b:notes.txt")
        let committed = AttachmentManager.commit(pending, chatFilename: chatFilename)
        #expect(committed?.filename == "abnotes.txt")
    }

    @Test("Committing a pasted image with no original name uses a UUID stem")
    func commitImageNoOriginalName() {
        let chatFilename = EnvironmentManager.shared.newTemporaryChatFilename()
        let png = makePNG(text: "IMG")
        let pending = PendingAttachment(data: png, kind: .image, originalName: nil)
        let committed = AttachmentManager.commit(pending, chatFilename: chatFilename)
        #expect(committed != nil)
        guard let committed else { return }
        // No original name → UUID stem + .png extension.
        #expect(committed.filename.hasSuffix(".png"))
        #expect(!committed.filename.contains(" "))
    }

    // MARK: - URL encoding round-trip

    @Test("URL encode/decode round-trips filenames with special characters")
    func urlEncodingRoundTrip() {
        let names = [
            "report.docx",
            "my report.docx",
            "café résumé.pdf",
            "100%done.png",
            "weird:name.txt",
        ]
        for name in names {
            let encoded = ImageSchemeHandler.encodeResource(name)
            let decoded = ImageSchemeHandler.decodeResource(encoded)
            #expect(decoded == name, "round-trip failed for \(name): encoded=\(encoded) decoded=\(decoded)")
            // The encoded form must produce a valid URL.
            let url = URL(string: "ichai://\(encoded)")
            #expect(url != nil, "encoded form did not produce a valid URL for \(name)")
        }
    }

    @Test("An attachment with spaces in the name produces a valid ichai URL")
    func attachmentProducesValidURL() {
        let attachment = AppAttachment(
            kind: .image, ext: "png", filename: "my screenshot.png",
            originalName: "my screenshot.png"
        )
        let encoded = ImageSchemeHandler.encodeResource(attachment.filename)
        let urlStr = "ichai://\(encoded)"
        let url = URL(string: urlStr)
        #expect(url != nil)
        // URL.host returns the decoded form; verify it round-trips.
        #expect(url?.host == "my screenshot.png")
        #expect(ImageSchemeHandler.decodeResource(encoded) == "my screenshot.png")
    }

    // MARK: - Backward compatibility

    @Test("An old attachment without a filename field decodes with a UUID fallback")
    func oldAttachmentWithoutFilenameDecodes() throws {
        // Simulate a chat JSON written before the `filename` field existed:
        // only id, kind, ext, originalName, text, status.
        let oldJSON = """
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "kind": "text",
            "ext": "txt",
            "originalName": "old.txt",
            "text": "legacy",
            "status": "ok"
        }
        """
        let data = Data(oldJSON.utf8)
        let decoded = try JSONDecoder().decode(AppAttachment.self, from: data)
        #expect(decoded.id == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        #expect(decoded.ext == "txt")
        // Falls back to the UUID + ext pattern.
        #expect(decoded.filename == "33333333-3333-3333-3333-333333333333.txt")
    }

    // MARK: - Helpers

    /// Renders `text` into an NSImage and returns PNG bytes.
    private func makePNG(text: String) -> Data {
        let size = NSSize(width: 400, height: 100)
        let image = NSImage(size: size)
        image.lockFocus()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 32),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: NSPoint(x: 20, y: 30), withAttributes: attrs)
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        return rep.representation(using: .png, properties: [:])!
    }
}
}
