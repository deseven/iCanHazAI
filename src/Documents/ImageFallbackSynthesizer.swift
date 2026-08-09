// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import ImageIO
import CoreGraphics

/// Synthesizes a text fallback for an image attachment, used when the active
/// connection can't process images visually. macOS 15 has no on-device "describe
/// this image" API, so the fallback is built from two on-device Vision signals:
/// image classification labels and OCR text. Both signals are always present
/// in the synthesized string (each addressed explicitly), so a text-only model
/// gets a consistent, predictable shape regardless of which signal produced
/// output.
///
/// The fallback is generated at commit-on-send time (behind the request
/// spinner) and stored on the attachment record, so switching a chat between a
/// vision-capable and a vision-incapable connection just picks the right
/// representation at request-build time — no reprocessing.
enum ImageFallbackSynthesizer {

    /// Confidence floor for classification labels. Labels below this are
    /// dropped; the floor is enough to cut noise while keeping useful labels.
    static let labelConfidenceFloor: Float = 0.01

    /// Builds the fallback string for a `CGImage` by running classification
    /// and OCR, then combining them into the locked shape:
    ///
    ///   `You are lacking the capabilities to digest images directly. Image
    ///   classification: {labels}. Text on the image: {ocr}.`
    ///
    /// Variants for no-text and fully-empty cases are handled explicitly.
    static func fallback(for cgImage: CGImage) -> String {
        let labels = TextRecognizer.classifyImage(cgImage: cgImage)
        let ocr = TextRecognizer.recognize(cgImage: cgImage)
        return synthesize(labels: labels, ocr: ocr)
    }

    /// Builds the fallback string for raw image `Data` (any ImageIO-decodable
    /// format). Returns a "no signals" fallback if the data can't be decoded.
    static func fallback(for data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return synthesize(labels: [], ocr: nil)
        }
        return fallback(for: cgImage)
    }

    /// Combines labels and OCR into the locked fallback string. Exposed for
    /// tests so the shape and the label floor can be asserted without running
    /// Vision.
    static func synthesize(labels: [ImageLabel], ocr: String?) -> String {
        let prefix = "You are lacking the capabilities to digest images directly."
        let filtered = labels.filter { $0.confidence >= labelConfidenceFloor }
        let labelPart: String
        if filtered.isEmpty {
            labelPart = "Image classification: none recognized."
        } else {
            let joined = filtered
                .map { "\($0.identifier) (\(String(format: "%.2f", $0.confidence)))" }
                .joined(separator: ", ")
            labelPart = "Image classification: \(joined)."
        }
        let ocrPart: String
        if let ocr, !ocr.isEmpty {
            ocrPart = "Text on the image: \(ocr)."
        } else {
            ocrPart = "The image contains no readable text."
        }
        return "\(prefix) \(labelPart) \(ocrPart)"
    }
}
