// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import Vision

/// A classification label from `VNClassifyImageRequest` — the built-in
/// ~1000-category multi-label image classifier.
struct ImageLabel: Sendable, Equatable {
    /// The Vision category identifier (e.g. "animal_bird", "landscape_garden").
    let identifier: String
    /// Confidence in [0, 1].
    let confidence: Float
}

/// Stateless Vision helpers for OCR and image classification. Uses
/// `VNRecognizeTextRequest` (not the macOS 26-only `RecognizeDocumentsRequest`,
/// which silently drops code-like lines) at `.accurate` recognition level with
/// language correction and automatic language detection.
///
/// Each request is wrapped in an `autoreleasepool` because repeated Vision
/// calls on macOS 26 have been reported to leak memory aggressively.
enum TextRecognizer {

    /// Recognizes text in a `CGImage`. Returns the candidate strings joined
    /// by newlines (one per observation, highest-confidence candidate each),
    /// or nil if Vision could not produce any observations.
    static func recognize(cgImage: CGImage) -> String? {
        var result: String?
        autoreleasepool {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            do {
                try handler.perform([request])
            } catch {
                result = nil
                return
            }
            let observations = request.results ?? []
            if observations.isEmpty {
                result = nil
                return
            }
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            if lines.isEmpty {
                result = nil
                return
            }
            result = lines.joined(separator: "\n")
        }
        return result
    }

    /// Recognizes text in raw image `Data` (any ImageIO-decodable format).
    /// Returns nil if the data can't be decoded or Vision produces nothing.
    static func recognize(data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return recognize(cgImage: cgImage)
    }

    // MARK: - Image classification

    /// Classifies an image using the built-in ~1000-category classifier.
    /// Returns the top labels filtered to a precision/recall threshold that
    /// keeps useful labels while cutting noise. The caller (the fallback
    /// synthesizer) applies an additional confidence floor.
    static func classifyImage(cgImage: CGImage) -> [ImageLabel] {
        var out: [ImageLabel] = []
        autoreleasepool {
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            do {
                try handler.perform([request])
            } catch {
                return
            }
            let results = (request.results ?? [])
                .filter { $0.hasMinimumPrecision(0.1, forRecall: 0.7) }
            out = results.prefix(8).map { ImageLabel(identifier: $0.identifier, confidence: $0.confidence) }
        }
        return out
    }

    /// Classifies raw image `Data` (any ImageIO-decodable format). Returns
    /// an empty array if the data can't be decoded.
    static func classifyImage(data: Data) -> [ImageLabel] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return []
        }
        return classifyImage(cgImage: cgImage)
    }
}
