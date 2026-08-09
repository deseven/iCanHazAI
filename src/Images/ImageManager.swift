// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import AppKit

/// An attachment the user has added to a message but not yet sent. Holds the
/// raw source bytes in memory plus the classifier's detected kind; nothing is
/// written to disk until the message is actually sent (see `commit`).
///
/// `id` is a stable in-memory UUID used for UI list identity and removal; it
/// is *not* the final on-disk filename (a fresh UUID is assigned at commit
/// time so re-adding the same file never collides).
struct PendingAttachment: Identifiable, Equatable, Hashable {
    let id: UUID
    /// Raw source bytes.
    let data: Data
    /// The classifier's bucket for these bytes.
    let kind: DocumentKind
    /// Display name for the chip (original filename, or nil for pasted).
    var originalName: String?

    init(id: UUID = UUID(), data: Data, kind: DocumentKind, originalName: String? = nil) {
        self.id = id
        self.data = data
        self.kind = kind
        self.originalName = originalName
    }
}

/// Processes incoming attachments (from paste, drag-and-drop, or the file
/// picker) into in-memory `PendingAttachment` values, and commits them to disk
/// only when a message is actually sent. Images are resized/re-encoded; text
/// and documents have their original copied and text extracted.
enum AttachmentManager {

    // MARK: - Intake (no disk I/O)

    /// Creates a pending attachment from raw `Data` + a type hint, routing
    /// through the document classifier. Returns nil (and does nothing) for
    /// unsupported binaries.
    static func intake(data: Data, originalName: String?, hint: DocumentTypeHint = .none) -> PendingAttachment? {
        let kind = DocumentClassifier.classify(data: data, hint: hint)
        guard kind != .unsupportedBinary else { return nil }
        return PendingAttachment(data: data, kind: kind, originalName: originalName)
    }

    /// Creates a pending attachment from a file URL. The file is read into
    /// memory; no copy is written yet. Returns nil for unsupported files.
    static func intake(fileURL: URL) -> PendingAttachment? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let hint = DocumentTypeHint(filename: fileURL.lastPathComponent)
        return intake(data: data, originalName: fileURL.lastPathComponent, hint: hint)
    }

    /// Creates a pending attachment from an `NSImage` (e.g. pasteboard). The
    /// image is converted to TIFF and classified (always `.image`).
    static func intake(nsImage: NSImage, originalName: String?) -> PendingAttachment? {
        guard let tiff = nsImage.tiffRepresentation else { return nil }
        return PendingAttachment(data: tiff, kind: .image, originalName: originalName)
    }

    // MARK: - Commit (called on send)

    /// Processes a pending attachment and saves it into the chat's attachment
    /// directory. For images: resize + re-encode + save. For text/documents:
    /// copy the original bytes, then extract text (documents only) and embed
    /// it on the returned record. Returns the persistent `Attachment`, or nil
    /// on failure.
    static func commit(_ pending: PendingAttachment, chatFilename: String) -> Attachment? {
        switch pending.kind {
        case .image:
            return commitImage(pending, chatFilename: chatFilename)
        case .text:
            return commitText(pending, chatFilename: chatFilename)
        case .document(let format):
            return commitDocument(pending, chatFilename: chatFilename, format: format)
        case .unsupportedBinary:
            return nil
        }
    }

    /// Resizes/re-encodes an image and saves it.
    private static func commitImage(_ pending: PendingAttachment, chatFilename: String) -> Attachment? {
        guard let processed = ImageProcessor.process(pending.data) else { return nil }
        let id = UUID()
        let filename = "\(id.uuidString).\(processed.ext)"
        _ = EnvironmentManager.shared.saveAttachment(data: processed.data, filename: filename, chatFilename: chatFilename)
        return Attachment(id: id, kind: .image, ext: processed.ext, originalName: pending.originalName)
    }

    /// Copies a plain-text file as-is; the text is embedded on the record.
    private static func commitText(_ pending: PendingAttachment, chatFilename: String) -> Attachment? {
        let id = UUID()
        let ext = pending.originalName.map { ($0 as NSString).pathExtension.lowercased() } ?? "txt"
        let safeExt = ext.isEmpty ? "txt" : ext
        let filename = "\(id.uuidString).\(safeExt)"
        _ = EnvironmentManager.shared.saveAttachment(data: pending.data, filename: filename, chatFilename: chatFilename)
        let text = String(data: pending.data, encoding: .utf8) ?? ""
        return Attachment(id: id, kind: .text, ext: safeExt, originalName: pending.originalName, text: text, status: .ok)
    }

    /// Copies a document's original bytes and extracts its text.
    private static func commitDocument(_ pending: PendingAttachment, chatFilename: String, format: DocumentFormat) -> Attachment? {
        let id = UUID()
        let ext = format.fileExtensions.first ?? "bin"
        let filename = "\(id.uuidString).\(ext)"
        _ = EnvironmentManager.shared.saveAttachment(data: pending.data, filename: filename, chatFilename: chatFilename)
        let result = DocumentExtractor.extract(data: pending.data, format: format)
        switch result {
        case .success(let extraction):
            return Attachment(
                id: id, kind: .document, ext: ext,
                originalName: pending.originalName,
                text: extraction.text,
                status: extraction.truncated ? .truncated : .ok
            )
        case .unsupported(_, let reason), .failed(let reason):
            return Attachment(
                id: id, kind: .document, ext: ext,
                originalName: pending.originalName,
                text: nil, status: .failed, failureReason: reason
            )
        }
    }

    // MARK: - Pasteboard helpers

    /// Extracts attachment data from a pasteboard, returning the first
    /// supported file found. Handles both file URLs and direct image
    /// representations.
    static func attachmentFromPasteboard(_ pb: NSPasteboard) -> (data: Data, name: String?)? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let data = try? Data(contentsOf: url) {
                    let kind = DocumentClassifier.classify(data: data, hint: .init(filename: url.lastPathComponent))
                    if kind != .unsupportedBinary {
                        return (data, url.lastPathComponent)
                    }
                }
            }
        }
        if let png = pb.data(forType: .png) {
            return (png, nil)
        }
        if let tiff = pb.data(forType: .tiff) {
            return (tiff, nil)
        }
        return nil
    }

    /// Whether a pasteboard contains any supported attachment.
    static func pasteboardHasAttachment(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let data = try? Data(contentsOf: url) {
                    let kind = DocumentClassifier.classify(data: data, hint: .init(filename: url.lastPathComponent))
                    if kind != .unsupportedBinary { return true }
                }
            }
        }
        if pb.data(forType: .png) != nil { return true }
        if pb.data(forType: .tiff) != nil { return true }
        return false
    }
}
