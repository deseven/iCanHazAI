// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A reference to a processed image file stored on disk alongside a chat.
/// Persisted as part of a `ChatMessage` so the renderer and the request
/// builder can both reach the image by UUID + extension.
struct ImageAttachment: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Stable unique identifier (also used as the on-disk filename stem).
    let id: UUID
    /// File extension of the processed image, e.g. "png" or "jpg".
    let ext: String
    /// Original filename the user supplied (for display only). May be nil
    /// for pasted images.
    var originalName: String?

    var id_uuid: UUID { id }

    /// The filename on disk, e.g. "A1B2...-....png".
    var filename: String { "\(id.uuidString).\(ext)" }

    /// The media type used when sending to the model, e.g. "image/png".
    var mimeType: String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "image/jpeg"
        }
    }

    /// Whether this attachment is a lossless (PNG) image.
    var isLossless: Bool { ext.lowercased() == "png" }
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
              let uti = CGImageSourceGetType(source) else {
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
        guard let ctx = CGContext(
            data: nil,
            width: Int(newW),
            height: Int(newH),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
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
