import Foundation
import Testing
import AppKit
@testable import iCanHazAI

// `AppAttachment` (an alias for `iCanHazAI.Attachment` that avoids the
// `Testing.Attachment` collision) is declared in `AttachmentTests.swift`.

/// Tests for the image text-fallback: the synthesizer shape (labels + OCR,
/// always both, with the 0.01 label floor and the no-text / fully-empty
/// variants) and the per-connection representation in the request builders
/// (image block on vision-capable connections, fallback text block on
/// vision-incapable connections).
extension AllAppTests {

@Suite("Image Text-Fallback")
struct ImageFallbackTests {

    // MARK: - Synthesizer shape

    @Test("The fallback always carries both labels and OCR")
    func fallbackCarriesBothSignals() {
        let labels = [
            ImageLabel(identifier: "landscape_garden", confidence: 0.9),
            ImageLabel(identifier: "building_house", confidence: 0.5),
        ]
        let ocr = "Hello World"
        let s = ImageFallbackSynthesizer.synthesize(labels: labels, ocr: ocr)
        #expect(s.hasPrefix("This user-attached image can't be processed visually here."))
        #expect(s.contains("Image classification:"))
        #expect(s.contains("landscape_garden (0.90)"))
        #expect(s.contains("building_house (0.50)"))
        #expect(s.contains("Text on the image: Hello World."))
    }

    @Test("The 0.01 label floor drops low-confidence labels")
    func labelFloor() {
        let labels = [
            ImageLabel(identifier: "keep_me", confidence: 0.02),
            ImageLabel(identifier: "drop_me", confidence: 0.009),
            ImageLabel(identifier: "also_keep", confidence: 0.5),
        ]
        let s = ImageFallbackSynthesizer.synthesize(labels: labels, ocr: "txt")
        #expect(s.contains("keep_me"))
        #expect(s.contains("also_keep"))
        #expect(!s.contains("drop_me"))
    }

    @Test("No OCR text yields the explicit no-text variant")
    func noTextVariant() {
        let labels = [ImageLabel(identifier: "animal_bird", confidence: 0.8)]
        let s = ImageFallbackSynthesizer.synthesize(labels: labels, ocr: nil)
        #expect(s.contains("The image contains no readable text."))
        #expect(!s.contains("Text on the image:"))
        #expect(s.contains("animal_bird"))
    }

    @Test("Empty OCR string is treated as no text")
    func emptyOcrVariant() {
        let labels = [ImageLabel(identifier: "animal_bird", confidence: 0.8)]
        let s = ImageFallbackSynthesizer.synthesize(labels: labels, ocr: "")
        #expect(s.contains("The image contains no readable text."))
    }

    @Test("No labels and no text yields the fully-empty variant")
    func fullyEmptyVariant() {
        let s = ImageFallbackSynthesizer.synthesize(labels: [], ocr: nil)
        #expect(s.contains("Image classification: none recognized."))
        #expect(s.contains("The image contains no readable text."))
    }

    @Test("Labels present but no text keeps the labels and states no text")
    func labelsButNoText() {
        let labels = [ImageLabel(identifier: "food_fruit", confidence: 0.7)]
        let s = ImageFallbackSynthesizer.synthesize(labels: labels, ocr: nil)
        #expect(s.contains("food_fruit"))
        #expect(s.contains("The image contains no readable text."))
        #expect(!s.contains("none recognized"))
    }

    // MARK: - Per-connection representation

    /// A throwaway temp chat filename so attachment data lands in the system
    /// temp dir (via `EnvironmentManager.shared`) and never touches the user's
    /// chats folder.
    private let tempChatFilename = EnvironmentManager.shared.newTemporaryChatFilename()

    private func saveImageBytes() -> AppAttachment {
        // A tiny real PNG so the provider can load it for the image block path.
        // The fallback text mirrors what `ImageFallbackSynthesizer` would store
        // on a real image attachment.
        let png = makePNG(text: "X")
        let fallback = ImageFallbackSynthesizer.synthesize(
            labels: [ImageLabel(identifier: "screenshot", confidence: 0.9)],
            ocr: "X"
        )
        let att = AppAttachment(kind: .image, ext: "png", originalName: "shot.png", text: fallback, status: .ok)
        _ = EnvironmentManager.shared.saveAttachment(data: png, filename: att.filename, chatFilename: tempChatFilename)
        return att
    }

    /// Extracts the content blocks of the first message in a request body.
    private func contentBlocks(of body: [String: Any]) -> [[String: Any]] {
        guard let messages = body["messages"] as? [[String: Any]],
              let first = messages.first,
              let content = first["content"] as? [[String: Any]] else {
            return []
        }
        return content
    }

    /// True if the content blocks contain a block of the given type.
    private func hasBlockType(_ blocks: [[String: Any]], _ type: String) -> Bool {
        blocks.contains { ($0["type"] as? String) == type }
    }

    /// True if the content blocks contain a text block whose text contains
    /// the given substring.
    private func hasTextBlock(containing needle: String, in blocks: [[String: Any]]) -> Bool {
        blocks.contains { ($0["type"] as? String) == "text" && (($0["text"] as? String) ?? "").contains(needle) }
    }

    @Test("Anthropic sends an image block on a vision-capable connection")
    @MainActor
    func anthropicImageBlockOnVisionConnection() throws {
        let att = saveImageBytes()
        let msg = ChatMessage(role: .user, content: "see this", attachments: [att])
        let connection = Connection(provider: .anthropic, name: "vision", baseUrl: nil, apiKey: "k", model: "m", imageInput: true, requestParameters: nil)
        let body = AnthropicProvider().buildRequestBody(connection: connection, messages: [msg], chatFilename: tempChatFilename, tools: nil, stream: false)
        let blocks = contentBlocks(of: body)
        #expect(hasBlockType(blocks, "image"))
        #expect(!hasTextBlock(containing: "can't be processed visually", in: blocks))
    }

    @Test("Anthropic sends the fallback text block on a vision-incapable connection")
    @MainActor
    func anthropicFallbackOnTextOnlyConnection() throws {
        let att = saveImageBytes()
        let msg = ChatMessage(role: .user, content: "see this", attachments: [att])
        let connection = Connection(provider: .anthropic, name: "textonly", baseUrl: nil, apiKey: "k", model: "m", imageInput: false, requestParameters: nil)
        let body = AnthropicProvider().buildRequestBody(connection: connection, messages: [msg], chatFilename: tempChatFilename, tools: nil, stream: false)
        let blocks = contentBlocks(of: body)
        #expect(!hasBlockType(blocks, "image"))
        #expect(hasTextBlock(containing: "can't be processed visually", in: blocks))
    }

    @Test("OpenAI sends an image_url part on a vision-capable connection")
    @MainActor
    func openaiImagePartOnVisionConnection() throws {
        let att = saveImageBytes()
        let msg = ChatMessage(role: .user, content: "see this", attachments: [att])
        let connection = Connection(provider: .openai, name: "vision", baseUrl: nil, apiKey: "k", model: "m", imageInput: true, requestParameters: nil)
        let body = OpenAIProvider().buildRequestBody(connection: connection, messages: [msg], chatFilename: tempChatFilename, tools: nil, stream: false)
        let blocks = contentBlocks(of: body)
        #expect(hasBlockType(blocks, "image_url"))
        #expect(!hasTextBlock(containing: "can't be processed visually", in: blocks))
    }

    @Test("OpenAI sends the fallback text part on a vision-incapable connection")
    @MainActor
    func openaiFallbackOnTextOnlyConnection() throws {
        let att = saveImageBytes()
        let msg = ChatMessage(role: .user, content: "see this", attachments: [att])
        let connection = Connection(provider: .openai, name: "textonly", baseUrl: nil, apiKey: "k", model: "m", imageInput: false, requestParameters: nil)
        let body = OpenAIProvider().buildRequestBody(connection: connection, messages: [msg], chatFilename: tempChatFilename, tools: nil, stream: false)
        let blocks = contentBlocks(of: body)
        #expect(!hasBlockType(blocks, "image_url"))
        #expect(hasTextBlock(containing: "can't be processed visually", in: blocks))
    }

    @Test("An image + a document coexist correctly on both providers")
    @MainActor
    func imageAndDocumentCoexist() throws {
        let imgAtt = saveImageBytes()
        let docAtt = AppAttachment(kind: .document, ext: "docx", originalName: "r.docx", text: "doc body", status: .ok)
        let msg = ChatMessage(role: .user, content: "both", attachments: [imgAtt, docAtt])

        // Vision connection: image block + document text block.
        let visionConn = Connection(provider: .anthropic, name: "v", baseUrl: nil, apiKey: "k", model: "m", imageInput: true, requestParameters: nil)
        let visionBody = AnthropicProvider().buildRequestBody(connection: visionConn, messages: [msg], chatFilename: tempChatFilename, tools: nil, stream: false)
        let visionBlocks = contentBlocks(of: visionBody)
        #expect(hasBlockType(visionBlocks, "image"))
        #expect(hasTextBlock(containing: "doc body", in: visionBlocks))

        // Text-only connection: fallback text block + document text block.
        let textConn = Connection(provider: .anthropic, name: "t", baseUrl: nil, apiKey: "k", model: "m", imageInput: false, requestParameters: nil)
        let textBody = AnthropicProvider().buildRequestBody(connection: textConn, messages: [msg], chatFilename: tempChatFilename, tools: nil, stream: false)
        let textBlocks = contentBlocks(of: textBody)
        #expect(!hasBlockType(textBlocks, "image"))
        #expect(hasTextBlock(containing: "can't be processed visually", in: textBlocks))
        #expect(hasTextBlock(containing: "doc body", in: textBlocks))
    }

    // MARK: - Document truncation through providers

    @Test("A >64 KB document extraction is truncated and marked in the request body")
    @MainActor
    func documentTruncationThroughProvider() throws {
        // Build a document extraction just over 64 KB.
        let chunk = String(repeating: "x", count: 1024)
        let big = (0..<70).map { _ in chunk }.joined() // 70 KB
        let docAtt = AppAttachment(kind: .document, ext: "docx", originalName: "big.docx", text: big, status: .ok)
        let msg = ChatMessage(role: .user, content: "see doc", attachments: [docAtt])

        // Anthropic: the text block carries the truncation header + marker.
        let anthropicConn = Connection(provider: .anthropic, name: "t", baseUrl: nil, apiKey: "k", model: "m", imageInput: false, requestParameters: nil)
        let anthropicBody = AnthropicProvider().buildRequestBody(connection: anthropicConn, messages: [msg], chatFilename: tempChatFilename, tools: nil, stream: false)
        let anthropicBlocks = contentBlocks(of: anthropicBody)
        #expect(hasTextBlock(containing: "truncated to", in: anthropicBlocks))
        #expect(hasTextBlock(containing: "[… truncated — full file attached as big.docx]", in: anthropicBlocks))

        // OpenAI: same truncation header + marker.
        let openaiConn = Connection(provider: .openai, name: "t", baseUrl: nil, apiKey: "k", model: "m", imageInput: false, requestParameters: nil)
        let openaiBody = OpenAIProvider().buildRequestBody(connection: openaiConn, messages: [msg], chatFilename: tempChatFilename, tools: nil, stream: false)
        let openaiBlocks = contentBlocks(of: openaiBody)
        #expect(hasTextBlock(containing: "truncated to", in: openaiBlocks))
        #expect(hasTextBlock(containing: "[… truncated — full file attached as big.docx]", in: openaiBlocks))
    }

    @Test("A small document passes through intact on both providers")
    @MainActor
    func smallDocumentIntactThroughProvider() throws {
        let docAtt = AppAttachment(kind: .document, ext: "docx", originalName: "small.docx", text: "tiny doc body", status: .ok)
        let msg = ChatMessage(role: .user, content: "see doc", attachments: [docAtt])

        let anthropicConn = Connection(provider: .anthropic, name: "t", baseUrl: nil, apiKey: "k", model: "m", imageInput: false, requestParameters: nil)
        let anthropicBody = AnthropicProvider().buildRequestBody(connection: anthropicConn, messages: [msg], chatFilename: tempChatFilename, tools: nil, stream: false)
        let anthropicBlocks = contentBlocks(of: anthropicBody)
        #expect(hasTextBlock(containing: "tiny doc body", in: anthropicBlocks))
        #expect(!hasTextBlock(containing: "truncated", in: anthropicBlocks))
        #expect(!hasTextBlock(containing: "[… truncated", in: anthropicBlocks))

        let openaiConn = Connection(provider: .openai, name: "t", baseUrl: nil, apiKey: "k", model: "m", imageInput: false, requestParameters: nil)
        let openaiBody = OpenAIProvider().buildRequestBody(connection: openaiConn, messages: [msg], chatFilename: tempChatFilename, tools: nil, stream: false)
        let openaiBlocks = contentBlocks(of: openaiBody)
        #expect(hasTextBlock(containing: "tiny doc body", in: openaiBlocks))
        #expect(!hasTextBlock(containing: "truncated", in: openaiBlocks))
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
