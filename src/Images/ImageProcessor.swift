// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The kind of an attachment, mirroring the classifier buckets. Images are
/// processed to base64; text and documents are extracted to plain text.
enum AttachmentKind: String, Codable, Sendable, Equatable, Hashable {
    case image
    case text
    case document
}

/// The outcome of extracting text from a text/document attachment. Carried on
/// the persisted record so the UI can surface notices (truncation, failure)
/// without re-running extraction.
enum AttachmentStatus: String, Codable, Sendable, Equatable, Hashable {
    case ok
    case truncated
    case failed
}

/// A reference to an attachment stored on disk alongside a chat. Persisted as
/// part of a `ChatMessage` so the renderer and the request builder can both
/// reach the file. For text/document kinds the extracted text is embedded
/// directly on the record so the chat JSON is self-sufficient; the on-disk
/// file is a user-facing backup.
struct Attachment: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Stable unique identifier.
    let id: UUID
    /// The kind bucket: `.image` (processed to base64), `.text` (plain-text
    /// passthrough), or `.document` (docx/odt/rtf/pdf… extracted to text).
    let kind: AttachmentKind
    /// File extension of the stored file, e.g. "png", "docx", "txt".
    let ext: String
    /// The actual filename on disk (sanitized original name, possibly with a
    /// dedup suffix like `(1)`). Falls back to `"\(id.uuidString).\(ext)"` for
    /// records loaded from old chats that predate this field.
    let filename: String
    /// Original filename the user supplied (for display only). May be nil
    /// for pasted images.
    var originalName: String?
    /// For text/document kinds: the extracted text content (or the raw text
    /// for `.text`). Nil for images and when extraction failed.
    var text: String?
    /// Extraction status for text/document kinds. `.ok` for images (not
    /// applicable) and successful text extractions; `.failed` when extraction
    /// produced no usable text.
    var status: AttachmentStatus
    /// Short human-readable reason when `status == .failed`. Nil otherwise.
    var failureReason: String?

    /// The media type used when sending an image to the model, e.g.
    /// "image/png". Only meaningful for `.image` kinds.
    var mimeType: String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "image/jpeg"
        }
    }

    /// Whether this attachment is a lossless (PNG) image. Only meaningful for
    /// `.image` kinds.
    var isLossless: Bool { ext.lowercased() == "png" }

    init(
        id: UUID = UUID(), kind: AttachmentKind, ext: String, filename: String? = nil, originalName: String?,
        text: String? = nil, status: AttachmentStatus = .ok, failureReason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.ext = ext
        self.filename = filename ?? "\(id.uuidString).\(ext)"
        self.originalName = originalName
        self.text = text
        self.status = status
        self.failureReason = failureReason
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, ext, filename, originalName, text, status, failureReason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decode(AttachmentKind.self, forKey: .kind)) ?? .image
        ext = (try? c.decode(String.self, forKey: .ext)) ?? "bin"
        filename = (try? c.decode(String.self, forKey: .filename)) ?? "\(id.uuidString).\(ext)"
        originalName = try? c.decode(String.self, forKey: .originalName)
        text = try? c.decode(String.self, forKey: .text)
        status = (try? c.decode(AttachmentStatus.self, forKey: .status)) ?? .ok
        failureReason = try? c.decode(String.self, forKey: .failureReason)
    }
}

/// Builds the text block injected into outbound requests for text/document
/// attachments. The extracted content is wrapped with a filename header and a
/// fenced code block so the model can tell it apart from the user's message
/// text. Truncation (64 KB cap) is applied here at request-build time, not at
/// extraction — the stored chat data keeps the full extraction.
enum AttachmentRequestBuilder {

    /// Per-extracted-document UTF-8 byte cap applied at request-build time.
    static let maxBytes: Int = 64 * 1024

    /// Size information about an attachment's extracted text, computable
    /// without building the full block. Lets the UI surface truncation notices
    /// and byte/char counts without ever sending the body to the renderer.
    struct SizeInfo: Equatable, Sendable {
        /// UTF-8 byte length of the full extracted text.
        let byteCount: Int
        /// Character count of the full extracted text.
        let charCount: Int
        /// True when the 64 KB cap would truncate the text at request time.
        let truncated: Bool
    }

    /// Computes size info for an attachment's extracted text. Returns nil when
    /// the attachment has no text (e.g. a failed extraction or an image).
    static func sizeInfo(for attachment: Attachment) -> SizeInfo? {
        guard let text = attachment.text, !text.isEmpty else { return nil }
        let bytes = text.utf8.count
        return SizeInfo(byteCount: bytes, charCount: text.count, truncated: bytes > maxBytes)
    }

    /// Wraps an attachment's extracted text into a request-ready text block.
    /// Returns nil when the attachment has no text (e.g. a failed extraction
    /// or an image). When the text exceeds the 64 KB cap it is truncated on a
    /// character boundary and the body ends with a visible marker so the model
    /// knows it isn't seeing the whole file.
    static func block(for attachment: Attachment) -> String? {
        guard let text = attachment.text, !text.isEmpty else { return nil }
        let name = attachment.originalName ?? attachment.filename
        let truncated = truncate(text)
        let wasTruncated = truncated.byteCount != text.utf8.count
        var header = "Attached file: \(name)"
        if wasTruncated {
            header += " (truncated to \(maxBytes) bytes)"
        }
        var body = truncated.text
        if wasTruncated {
            body += "\n[… truncated — full file attached as \(name)]"
        }
        return "\(header)\n```\n\(body)\n```"
    }

    /// Truncates `text` to at most `maxBytes` UTF-8 bytes, ending on a
    /// character boundary.
    private static func truncate(_ text: String) -> (text: String, byteCount: Int) {
        let bytes = text.utf8
        if bytes.count <= maxBytes { return (text, bytes.count) }
        // Find the String.CharacterView index whose UTF-8 encoding fits within
        // the cap, so the cut lands on a character boundary.
        var cut = text.startIndex
        var consumed = 0
        for ch in text {
            let size = ch.utf8.count
            if consumed + size > maxBytes { break }
            consumed += size
            cut = text.index(after: cut)
        }
        return (String(text[..<cut]), consumed)
    }
}

/// Stateless image processing utilities built on ImageIO.
///
/// Responsibilities:
///  - Determine whether a given UTI/data is a supported input image format.
///  - Resize an image so its largest side is at most `maxSide`, preserving
///    aspect ratio (no-op if already within bounds).
///  - Re-encode to PNG (max lossless compression) for lossless source formats,
///    or to JPEG at 85% quality for everything else. Incoming PNG/JPEG are
///    always re-encoded as specified.
enum ImageProcessor {

    /// Maximum dimension (in pixels) of the longest side after resize.
    static let maxSide: CGFloat = 1024

    /// JPEG quality used when re-encoding lossy sources.
    static let jpegQuality: CGFloat = 0.85

    // MARK: - Supported formats

    /// The set of UTI identifiers we accept as input. Anything ImageIO can
    /// decode and that we can re-encode to PNG/JPEG is fine in practice, but
    /// we restrict to common raster formats to avoid surprises (e.g. raw,
    /// PSD, icon formats).
    static let supportedTypeIdentifiers: [String] = {
        // `CGImageSourceCopyTypeIdentifiers()` returns every UTI ImageIO
        // knows how to read. We filter to a curated allow-list of raster
        // image formats so we never accept something we can't sensibly
        // re-encode.
        let all = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        let allowed: Set<String> = [
            "public.jpeg",
            "public.png",
            "org.webmproject.webp",
            "public.heif",
            "public.heic",
            "public.tiff",
            "public.bitmap",
            "com.microsoft.bmp",
        ]
        // Always include the curated set even if ImageIO omits one.
        return Array(Set(all).union(allowed)).sorted()
    }()

    /// Returns the UTI string for the given data, or nil if ImageIO can't
    /// identify it.
    static func typeIdentifier(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let uti = CGImageSourceGetType(source) else { return nil }
        return uti as String
    }

    /// Whether the given data is a supported image format we can process.
    static func isSupported(_ data: Data) -> Bool {
        guard let uti = typeIdentifier(for: data) else { return false }
        return supportedTypeIdentifiers.contains(uti)
    }

    /// Whether the given file URL points to a supported image format.
    static func isSupportedFile(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        guard let uti = CGImageSourceGetType(source) else { return false }
        return supportedTypeIdentifiers.contains(uti as String)
    }

    // MARK: - Processing

    /// The result of processing an incoming image.
    struct Processed {
        /// Re-encoded image bytes.
        let data: Data
        /// Output extension ("png" or "jpg").
        let ext: String
    }

    /// Processes raw image data: resizes to `maxSide` on the longest side
    /// (preserving aspect ratio) and re-encodes to PNG (for lossless sources)
    /// or JPEG at 85% quality (for everything else).
    ///
    /// Returns nil if the data cannot be decoded.
    static func process(_ data: Data) -> Processed? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let uti = CGImageSourceGetType(source)
        else {
            return nil
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        // Determine whether the source is a lossless format. We treat PNG,
        // TIFF, BMP, HEIC/HEIF (lossless-ish) and GIF as lossless → PNG.
        // Everything else (JPEG, WebP lossy) → JPEG.
        let lossless = isLosslessUTI(uti as String)

        let resized = resize(cgImage: cgImage, maxSide: maxSide) ?? cgImage

        if lossless {
            if let png = encode(resized, type: "public.png") {
                return Processed(data: png, ext: "png")
            }
        }
        if let jpg = encode(resized, type: "public.jpeg", quality: jpegQuality) {
            return Processed(data: jpg, ext: "jpg")
        }
        // Last resort: try PNG even for lossy sources.
        if let png = encode(resized, type: "public.png") {
            return Processed(data: png, ext: "png")
        }
        return nil
    }

    // MARK: - Helpers

    /// Whether a UTI denotes a lossless raster format we re-encode to PNG.
    private static func isLosslessUTI(_ uti: String) -> Bool {
        let lossless: Set<String> = [
            "public.png",
            "public.tiff",
            "com.microsoft.bmp",
            "public.bitmap",
        ]
        return lossless.contains(uti)
    }

    /// Resizes a CGImage so its longest side is at most `maxSide`, preserving
    /// aspect ratio. Returns the original image unchanged if it's already
    /// within bounds (or on any error).
    private static func resize(cgImage: CGImage, maxSide: CGFloat) -> CGImage? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let longest = max(w, h)
        guard longest > maxSide else { return cgImage }
        let scale = maxSide / longest
        let newW = (w * scale).rounded()
        let newH = (h * scale).rounded()
        guard newW > 0, newH > 0 else { return cgImage }

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        guard
            let ctx = CGContext(
                data: nil,
                width: Int(newW),
                height: Int(newH),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    /// Encodes a CGImage to the given ImageIO output type. For JPEG, `quality`
    /// is applied; for PNG, maximum lossless compression is requested.
    private static func encode(_ cgImage: CGImage, type: String, quality: CGFloat = 1.0) -> Data? {
        let data = NSMutableData()
        let typeID = type as CFString
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, typeID, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [:]
        if type == "public.jpeg" {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        } else if type == "public.png" {
            props[kCGImagePropertyPNGCompressionFilter] = true
        }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
