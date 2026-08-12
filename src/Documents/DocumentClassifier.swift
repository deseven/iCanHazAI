// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import UniformTypeIdentifiers

/// A supported document binary format that the extractor knows how to turn
/// into plain text. Everything else is either plain text (passed through),
/// an image (image-processing path), or unsupported.
enum DocumentFormat: String, Sendable {
    case pdf
    case docx
    case doc
    case odt
    case rtf
    case rtfd
    case wordml
    case webarchive

    /// Lowercase filename extensions (no dot) that identify this format.
    /// Generic textual extensions (`.xml`, `.html`) are deliberately NOT
    /// mapped here — they stay plain text unless a UTI hint or content sniff
    /// says otherwise, so HTML/XML/source never get accidentally "extracted".
    var fileExtensions: [String] {
        switch self {
        case .pdf: return ["pdf"]
        case .docx: return ["docx"]
        case .doc: return ["doc"]
        case .odt: return ["odt"]
        case .rtf: return ["rtf"]
        case .rtfd: return ["rtfd"]
        case .wordml: return ["wordml"]
        case .webarchive: return ["webarchive", "webarch"]
        }
    }

    /// UTI identifiers that identify this format.
    var typeIdentifiers: [String] {
        switch self {
        case .pdf: return ["com.adobe.pdf"]
        case .docx: return ["org.openxmlformats.wordprocessingml.document"]
        case .doc: return ["com.microsoft.word.doc"]
        case .odt: return ["org.oasis.opendocument.text"]
        case .rtf: return ["public.rtf"]
        case .rtfd: return ["com.apple.rtfd"]
        case .wordml: return ["com.microsoft.word.wordml"]
        case .webarchive: return ["com.apple.webarchive"]
        }
    }

    /// The extension used when materializing a temp file for the `textutil`
    /// fallback (textutil keys its input detection off the extension).
    var textutilExtension: String {
        switch self {
        case .wordml: return "xml"  // textutil detects WordML from .xml content
        default: return fileExtensions.first ?? "txt"
        }
    }

    /// The AppKit attributed-string document type for this format. ODT maps
    /// to `.openDocument` (OASIS Open Document text), available since macOS
    /// 10.0 and still present on macOS 26.
    var attributedStringDocumentType: NSAttributedString.DocumentType {
        switch self {
        case .docx: return .officeOpenXML
        case .doc: return .docFormat
        case .odt: return .openDocument
        case .rtf: return .rtf
        case .rtfd: return .rtfd
        case .wordml: return .wordML
        case .webarchive: return .webArchive
        case .pdf: return .plain  // PDF has its own extractor; never reaches here
        }
    }
}

/// A type hint carried alongside raw document bytes — a UTI and/or a filename
/// extension and/or a filename. At least one field should be set for reliable
/// document classification; without a hint only PDF (magic bytes) and WordML
/// (content sniff) can be recognized as documents.
struct DocumentTypeHint: Sendable {
    let uti: String?
    let filenameExtension: String?
    let filename: String?

    init(uti: String? = nil, filenameExtension: String? = nil, filename: String? = nil) {
        self.uti = uti?.lowercased()
        self.filenameExtension = (filenameExtension ?? filename.map { ($0 as NSString).pathExtension })?.lowercased()
        self.filename = filename
    }

    init(filename: String) {
        self.uti = nil
        self.filename = filename
        self.filenameExtension = (filename as NSString).pathExtension.lowercased()
    }

    static let none = DocumentTypeHint()
}

/// The four classification buckets. Detection runs document-hint-first so that
/// text-bytes formats that are really documents (RTF, WordML, WebArchive) get
/// extracted instead of passed through raw; plain text (HTML, JSON, XML,
/// source, proprietary-but-textual) is accepted as-is.
enum DocumentKind: Sendable, Equatable, Hashable {
    case text
    case document(DocumentFormat)
    case image
    case unsupportedBinary
}

/// Stateless classifier: raw `Data` + optional type hint → one of the four
/// buckets. Text detection reuses [`BuiltinTools.isText`](src/Tools/BuiltinTools.swift);
/// document vs. image by UTI/extension (plus PDF magic-byte and WordML
/// content sniffs as hintless fallbacks); image detection reuses
/// [`ImageProcessor.isSupported`](src/Images/ImageProcessor.swift).
enum DocumentClassifier {

    static func classify(data: Data, hint: DocumentTypeHint = .none) -> DocumentKind {
        // 1. Known document format (by hint, or by PDF/WordML content sniff).
        //    Takes precedence over text detection: RTF/WordML/WebArchive are
        //    text-bytes but must be extracted, not passed raw.
        if let format = documentFormat(data: data, hint: hint) {
            return .document(format)
        }
        // 2. Plain text — html, json, xml, csv, source, proprietary-but-textual.
        if BuiltinTools.isText(data) {
            return .text
        }
        // 3. Image binary — image-processing path (resize/re-encode), not text.
        if ImageProcessor.isSupported(data) {
            return .image
        }
        // 4. Anything else (xlsx, pptx, zip, executables…) — unsupported.
        return .unsupportedBinary
    }

    /// Resolves a document format from the hint, falling back to PDF
    /// magic-byte sniffing and WordML content sniffing. Returns nil for
    /// non-document inputs.
    static func documentFormat(data: Data, hint: DocumentTypeHint) -> DocumentFormat? {
        // Hint UTI.
        if let uti = hint.uti {
            for format in DocumentFormat.allCases where format.typeIdentifiers.contains(uti) {
                return format
            }
        }
        // Hint extension.
        if let ext = hint.filenameExtension, !ext.isEmpty {
            for format in DocumentFormat.allCases where format.fileExtensions.contains(ext) {
                return format
            }
        }
        // PDF magic bytes (unambiguous; safe to sniff without a hint).
        // `%PDF` is 4 bytes — use starts(with:) so the length check is exact.
        if data.starts(with: Data("%PDF".utf8)) {
            return .pdf
        }
        // WordML content sniff: text data carrying the WordprocessingML
        // namespace. Catches flat-OPC .xml Word files that have no UTI hint.
        if BuiltinTools.isText(data), looksLikeWordML(data) {
            return .wordml
        }
        return nil
    }

    /// True if the data sample carries the WordprocessingML namespace marker.
    private static func looksLikeWordML(_ data: Data) -> Bool {
        let sample = data.prefix(65536)
        return sample.range(of: Data("schemas.microsoft.com/office/word".utf8)) != nil
    }
}

extension DocumentFormat: CaseIterable {}
