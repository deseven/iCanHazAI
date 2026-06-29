// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import AppKit

/// An image the user has attached to a message but not yet sent. Holds the
/// raw source data in memory; nothing is written to disk until the message is
/// actually sent (see `commit`).
///
/// `id` is a stable in-memory UUID used for UI list identity and removal; it
/// is *not* the final on-disk filename (a fresh UUID is assigned at commit
/// time so re-adding the same image never collides).
struct PendingImageAttachment: Identifiable, Equatable, Hashable {
    let id: UUID
    /// Raw source bytes (already validated as a supported image format).
    let data: Data
    /// Display name for the chip (original filename, or nil for pasted).
    var originalName: String?

    init(id: UUID = UUID(), data: Data, originalName: String? = nil) {
        self.id = id
        self.data = data
        self.originalName = originalName
    }
}

/// Processes incoming images (from paste, drag-and-drop, or the file picker)
/// into in-memory `PendingImageAttachment` values, and commits them to disk
/// (resize + re-encode + save) only when a message is actually sent.
enum ImageManager {

    // MARK: - Intake (no disk I/O)

    /// Creates a pending attachment from raw `Data` if it is a supported
    /// image format. Returns nil (and does nothing) for unsupported data.
    static func intake(data: Data, originalName: String?) -> PendingImageAttachment? {
        guard ImageProcessor.isSupported(data) else { return nil }
        return PendingImageAttachment(data: data, originalName: originalName)
    }

    /// Creates a pending attachment from a file URL if it is a supported
    /// image format. The file is read into memory; no copy is written yet.
    static func intake(fileURL: URL) -> PendingImageAttachment? {
        guard ImageProcessor.isSupportedFile(fileURL) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return PendingImageAttachment(data: data, originalName: fileURL.lastPathComponent)
    }

    /// Creates a pending attachment from an `NSImage` (e.g. pasteboard).
    static func intake(nsImage: NSImage, originalName: String?) -> PendingImageAttachment? {
        guard let tiff = nsImage.tiffRepresentation else { return nil }
        return intake(data: tiff, originalName: originalName)
    }

    // MARK: - Commit (called on send)

    /// Processes a pending attachment: resizes to 1024px max side, re-encodes
    /// to PNG (lossless sources) or JPEG 85% (lossy sources), assigns a fresh
    /// UUID, and saves the file into the chat's image folder. Returns the
    /// persistent `ImageAttachment` reference, or nil on failure.
    static func commit(_ pending: PendingImageAttachment, chatFilename: String) -> ImageAttachment? {
        guard let processed = ImageProcessor.process(pending.data) else { return nil }
        let id = UUID()
        let filename = "\(id.uuidString).\(processed.ext)"
        _ = EnvironmentManager.shared.saveImage(data: processed.data, filename: filename, chatFilename: chatFilename)
        return ImageAttachment(id: id, ext: processed.ext, originalName: pending.originalName)
    }

    // MARK: - Pasteboard helpers

    /// Extracts image data from a pasteboard, returning the first supported
    /// image found. Handles both file URLs and direct image representations.
    static func imageFromPasteboard(_ pb: NSPasteboard) -> (data: Data, name: String?)? {
        // File URLs first (e.g. dragged image files).
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if ImageProcessor.isSupportedFile(url),
                   let data = try? Data(contentsOf: url) {
                    return (data, url.lastPathComponent)
                }
            }
        }
        // Direct image data (e.g. screenshot copy).
        if let png = pb.data(forType: .png) {
            return (png, nil)
        }
        if let tiff = pb.data(forType: .tiff) {
            return (tiff, nil)
        }
        return nil
    }

    /// Whether a pasteboard contains any supported image.
    static func pasteboardHasImage(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            if urls.contains(where: { ImageProcessor.isSupportedFile($0) }) { return true }
        }
        if pb.data(forType: .png) != nil { return true }
        if pb.data(forType: .tiff) != nil { return true }
        return false
    }
}
