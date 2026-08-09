// imageprobe — classify + OCR an image using macOS Vision.
// Scratch tool for tuning the image text-fallback.
//
// Build:  swiftc -O -o imageprobe tools/imageprobe.swift
// Usage:  imageprobe <image-path>
//
// Prints classification labels (with confidence) and OCR text.

import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers

// MARK: - Image loading

func loadCGImage(_ path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// MARK: - Classification

struct Label {
    let identifier: String
    let confidence: Float
}

/// Top labels from the built-in ~1000-category classifier.
func classify(_ cgImage: CGImage) -> [Label] {
    var out: [Label] = []
    autoreleasepool {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        let results = (request.results ?? [])
            .filter { $0.hasMinimumPrecision(0.1, forRecall: 0.7) }
            .prefix(8)
        out = results.map { Label(identifier: $0.identifier, confidence: $0.confidence) }
    }
    return out
}

// MARK: - OCR

/// Recognized text lines at .accurate with language correction + auto language detect.
func ocr(_ cgImage: CGImage) -> [String] {
    var lines: [String] = []
    autoreleasepool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13, *) { request.automaticallyDetectsLanguage = true }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
    return lines
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else {
    FileHandle.standardError.write(Data("usage: imageprobe <image-path>\n".utf8))
    exit(2)
}
guard let cg = loadCGImage(path) else {
    FileHandle.standardError.write(Data("imageprobe: cannot decode image: \(path)\n".utf8))
    exit(1)
}

let labels = classify(cg)
let ocrLines = ocr(cg)

print("== Labels ==")
if labels.isEmpty { print("(none)") }
for l in labels { print(String(format: "  %-30s %.2f", (l.identifier as NSString).utf8String!, l.confidence)) }

print("\n== OCR (\(ocrLines.count) lines) ==")
if ocrLines.isEmpty { print("(none)") }
for line in ocrLines { print("  \(line)") }
