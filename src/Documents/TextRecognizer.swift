// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Vision
import ImageIO
import CoreGraphics

/// Stateless Vision OCR helper. Uses `VNRecognizeTextRequest` (not the
/// macOS 26-only `RecognizeDocumentsRequest`, which silently drops code-like
/// lines) at `.accurate` recognition level with language correction and
/// automatic language detection.
///
/// Each recognition is wrapped in an `autoreleasepool` because repeated
/// `VNRecognizeTextRequest` calls on macOS 26 have been reported to leak
/// memory aggressively.
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
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return recognize(cgImage: cgImage)
    }
}
