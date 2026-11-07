// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import Vision
import VisionKit

/// A classification label from `VNClassifyImageRequest` — the built-in
/// ~1000-category multi-label image classifier.
struct ImageLabel: Sendable, Equatable {
    /// The Vision category identifier (e.g. "animal_bird", "landscape_garden").
    let identifier: String
    /// Confidence in [0, 1].
    let confidence: Float
}

/// OCR and image classification helpers.
///
/// Text recognition has two engines. Below macOS 27 it is Vision's
/// `VNRecognizeTextRequest` (not the macOS 26-only `RecognizeDocumentsRequest`,
/// which silently drops code-like lines) at `.accurate` level with language
/// correction and automatic language detection.
///
/// On macOS 27 and later that request compiles its models for the Neural
/// Engine inside the calling process, and a cold start takes 30-40 seconds
/// (keyed by the executable's path, and again for new input shapes). Live
/// Text's `ImageAnalyzer` (what Preview uses) hands the work to the system's
/// long-running `mediaanalysisd`, whose models are already compiled, so it
/// answers in well under a second. It is used there, with Vision as the
/// fallback when it is unsupported, fails or stalls.
///
/// Recognition may block its thread for a long time (Vision) — call it off the
/// main actor and off `ChatEngine`.
///
/// Each Vision request is wrapped in an `autoreleasepool` because repeated
/// Vision calls on macOS 26 have been reported to leak memory aggressively.
enum TextRecognizer {

    enum Engine: Sendable, Equatable {
        case vision
        case imageAnalyzer
    }

    /// Forces an engine; tests use it to pin the OS-dependent choice.
    nonisolated(unsafe) static var engineOverride: Engine?

    /// How long `ImageAnalyzer` may take before Vision takes over.
    nonisolated(unsafe) static var imageAnalyzerTimeout: TimeInterval = 30

    static func isImageAnalyzerOS(_ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion)
        -> Bool
    {
        version.majorVersion >= 27
    }

    /// The engine recognition starts with.
    static var engine: Engine {
        if let engineOverride { return engineOverride }
        return isImageAnalyzerOS() && ImageAnalyzer.isSupported ? .imageAnalyzer : .vision
    }

    /// Recognizes text in a `CGImage`. Returns the recognized lines joined by
    /// newlines, or nil if no text was found (or recognition failed).
    static func recognize(cgImage: CGImage) async -> String? {
        if engine == .imageAnalyzer, case .text(let text) = await recognizeWithImageAnalyzer(cgImage) {
            return text
        }
        if Task.isCancelled { return nil }
        return recognizeWithVision(cgImage: cgImage)
    }

    /// Recognizes text in raw image `Data` (any ImageIO-decodable format).
    /// Returns nil if the data can't be decoded or nothing was recognized.
    static func recognize(data: Data) async -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return await recognize(cgImage: cgImage)
    }

    // MARK: - ImageAnalyzer

    private static let analyzer = ImageAnalyzer()

    private enum AnalyzerOutcome {
        /// The analyzer answered; nil when the image has no text.
        case text(String?)
        /// It failed, stalled or was cancelled: the caller falls back.
        case unavailable
    }

    private struct AnalyzerTimeout: Error {}

    /// Raced against a deadline, and abandonable on cancellation, so a wedged
    /// analyzer can't hold the caller up.
    private static func recognizeWithImageAnalyzer(_ cgImage: CGImage) async -> AnalyzerOutcome {
        let work = Task.detached(priority: .userInitiated) {
            try await analyzer.analyze(
                cgImage, orientation: .up, configuration: ImageAnalyzer.Configuration([.text])
            ).transcript
        }
        let outcome = OneShotResult<String>()
        let timeout = imageAnalyzerTimeout
        let timer = Task {
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
            outcome.finish(.failure(AnalyzerTimeout()))
        }
        defer { timer.cancel() }
        do {
            let transcript = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    outcome.install(continuation)
                    Task { outcome.finish(await work.result) }
                }
            } onCancel: {
                work.cancel()
                outcome.finish(.failure(CancellationError()))
            }
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return .text(text.isEmpty ? nil : text)
        } catch {
            work.cancel()
            debugLog("OCR", "ImageAnalyzer unavailable (\(error)) — falling back to Vision")
            return .unavailable
        }
    }

    // MARK: - Vision

    /// `VNRecognizeTextRequest` at `.accurate` level; blocks until done.
    static func recognizeWithVision(cgImage: CGImage) -> String? {
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
