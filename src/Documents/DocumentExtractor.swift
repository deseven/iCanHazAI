// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import AppKit
import PDFKit
import CoreGraphics

/// Stateless document-to-text extractor. One entry point for the document
/// bucket only; returns a typed result (never throws into callers) so the UI
/// can surface failures instead of crashing.
///
/// Office/RTF formats go through `NSAttributedString(data:options:documentAttributes:)`
/// with auto-detected document type; PDF goes through PDFKit with per-page
/// OCR fallback for scanned pages; standalone image OCR is exposed for the
/// `read_file` tool.
enum DocumentExtractor {

    /// Hard ceiling on input size before parsing. AppKit/PDFKit can be made
    /// to allocate absurd amounts on hostile inputs; refuse up front.
    static let maxInputBytes: Int = 256 * 1024 * 1024 // 256 MB

    /// Maximum PDF pages processed (text + OCR). Beyond this the document is
    /// truncated with a note, so a 5000-page scan can't hang the chat.
    static let maxPDFPages: Int = 200

    /// Longest side (px) at which a scanned PDF page is rendered for OCR.
    static let ocrRenderMaxSide: CGFloat = 2000

    // MARK: - Result

    /// Typed extraction outcome. Failures are reported, not thrown, so the UI
    /// can surface them.
    enum Result: Sendable, Equatable {
        case success(Extraction)
        case unsupported(format: String?, reason: String)
        case failed(reason: String)
    }

    /// Extracted text plus metadata about how it was produced.
    struct Extraction: Sendable, Equatable {
        let text: String
        let pageCount: Int?
        let ocrUsed: Bool
        let ocrPageCount: Int
        let truncated: Bool
    }

    // MARK: - Entry point

    /// Extracts text from a known document binary. The caller is responsible
    /// for classification — this only handles the document bucket.
    static func extract(data: Data, format: DocumentFormat) -> Result {
        guard data.count <= maxInputBytes else {
            return .failed(reason: "document is \(data.count) bytes; exceeds the \(maxInputBytes) byte limit")
        }
        switch format {
        case .pdf:
            return extractPDF(data)
        case .docx, .doc, .odt, .rtf, .rtfd, .wordml, .webarchive:
            return extractOffice(data: data, format: format)
        }
    }

    // MARK: - PDF

    private static func extractPDF(_ data: Data) -> Result {
        guard let doc = PDFDocument(data: data) else {
            return .failed(reason: "PDFKit could not open the PDF")
        }
        let total = doc.pageCount
        let limit = min(total, maxPDFPages)
        var blocks: [String] = []
        var ocrPages = 0
        var ocrUsed = false
        for i in 0..<limit {
            guard let page = doc.page(at: i) else { continue }
            let raw = page.string ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                blocks.append("--- Page \(i + 1) ---")
                blocks.append(raw)
                continue
            }
            // Textless page — likely scanned. Render and OCR.
            if let ocrText = ocrPDFPage(page), !ocrText.isEmpty {
                ocrUsed = true
                ocrPages += 1
                blocks.append("[Page \(i + 1) — OCR]")
                blocks.append(ocrText)
            } else {
                // No text layer and OCR found nothing — record the page so
                // the reader knows it existed but was empty.
                blocks.append("--- Page \(i + 1) ---")
                blocks.append("(no extractable text)")
            }
        }
        var truncated = false
        if total > limit {
            truncated = true
            blocks.append("... (truncated at \(maxPDFPages) pages of \(total))")
        }
        let text = blocks.joined(separator: "\n")
        return .success(Extraction(
            text: text,
            pageCount: total,
            ocrUsed: ocrUsed,
            ocrPageCount: ocrPages,
            truncated: truncated
        ))
    }

    /// Renders a PDFPage to a thumbnail and OCRs it. Returns nil on any
    /// rendering or recognition failure.
    private static func ocrPDFPage(_ page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height)
        let scale: CGFloat = longest > 0 ? ocrRenderMaxSide / longest : 1
        // `thumbnail(of:for:)` returns a non-optional NSImage; the optional
        // steps are the TIFF/bitmap conversion.
        let nsImage = page.thumbnail(of: bounds.size, for: .mediaBox)
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cgImage = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        // The thumbnail is rendered at the bounds size; rescale to the OCR
        // target by drawing into a context at the desired pixel size.
        let scaled = rescaleCGImage(cgImage, scale: scale) ?? cgImage
        return TextRecognizer.recognize(cgImage: scaled)
    }

    /// Rescales a CGImage by `scale` (relative to its current size). Returns
    /// nil on any error.
    private static func rescaleCGImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
        guard scale > 0, scale != 1 else { return image }
        let newW = Int((CGFloat(image.width) * scale).rounded())
        let newH = Int((CGFloat(image.height) * scale).rounded())
        guard newW > 0, newH > 0 else { return nil }
        guard let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: newW, height: newH,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    // MARK: - Office / RTF

    private static func extractOffice(data: Data, format: DocumentFormat) -> Result {
        let docType = format.attributedStringDocumentType
        var attrs: NSDictionary?
        let attributed: NSAttributedString?
        do {
            attributed = try NSAttributedString(
                data: data,
                options: [
                    .documentType: docType,
                    .defaultAttributes: [:],
                ],
                documentAttributes: &attrs
            )
        } catch {
            // AppKit failed — try the textutil fallback before giving up.
            if let text = textutilFallback(data: data, format: format) {
                return .success(Extraction(
                    text: text, pageCount: nil,
                    ocrUsed: false, ocrPageCount: 0, truncated: false
                ))
            }
            return .failed(reason: "AppKit could not parse \(format.rawValue): \(error.localizedDescription)")
        }
        guard let attributed else {
            if let text = textutilFallback(data: data, format: format) {
                return .success(Extraction(
                    text: text, pageCount: nil,
                    ocrUsed: false, ocrPageCount: 0, truncated: false
                ))
            }
            return .failed(reason: "AppKit returned no content for \(format.rawValue)")
        }
        let text = attributed.string
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // AppKit parsed but produced nothing — try textutil before
            // reporting an empty extraction.
            if let fallback = textutilFallback(data: data, format: format),
               !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .success(Extraction(
                    text: fallback, pageCount: nil,
                    ocrUsed: false, ocrPageCount: 0, truncated: false
                ))
            }
            return .success(Extraction(
                text: text, pageCount: nil,
                ocrUsed: false, ocrPageCount: 0, truncated: false
            ))
        }
        return .success(Extraction(
            text: text, pageCount: nil,
            ocrUsed: false, ocrPageCount: 0, truncated: false
        ))
    }

    /// `textutil -convert txt -stdout` fallback, used only when AppKit proves
    /// unreliable for a format (notably `.odt` on some macOS builds). Writes
    /// the input to a temp file with the right extension so textutil detects
    /// the format, then converts to plain text on stdout.
    private static func textutilFallback(data: Data, format: DocumentFormat) -> String? {
        let ext = format.textutilExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ichai-doc-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try data.write(to: tmp, options: .atomic)
        } catch {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", tmp.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: out, encoding: .utf8)
    }

    // MARK: - Standalone image OCR (for read_file only)

    /// OCRs a standalone image and returns the recognized text. Intended for
    /// the `read_file` tool so a screenshot/scanned image returns
    /// text instead of the bare `[image: …]` placeholder. Chat attachments
    /// still treat images as images (base64, not OCR).
    static func ocrImage(_ data: Data) -> Result {
        guard data.count <= maxInputBytes else {
            return .failed(reason: "image is \(data.count) bytes; exceeds the \(maxInputBytes) byte limit")
        }
        guard ImageProcessor.isSupported(data) else {
            return .unsupported(format: ImageProcessor.typeIdentifier(for: data), reason: "not a supported image format for OCR")
        }
        guard let text = TextRecognizer.recognize(data: data),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .success(Extraction(
                text: "(no text recognized in image)",
                pageCount: nil, ocrUsed: true, ocrPageCount: 0, truncated: false
            ))
        }
        return .success(Extraction(
            text: text, pageCount: nil,
            ocrUsed: true, ocrPageCount: 1, truncated: false
        ))
    }
}
