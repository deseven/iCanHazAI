// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Testing

@testable import iCanHazAI

/// Tests for the OCR engine choice in
/// [`TextRecognizer`](src/Documents/TextRecognizer.swift): Vision below
/// macOS 27, Live Text's `ImageAnalyzer` from there on.
extension AllAppTests {

    @Suite("Text recognizer engine")
    struct TextRecognizerTests {

        private static var hostUsesImageAnalyzer: Bool { TextRecognizer.isImageAnalyzerOS() }

        private static func version(_ major: Int, _ minor: Int = 0) -> OperatingSystemVersion {
            OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
        }

        @Test("ImageAnalyzer is for macOS 27 and later only")
        func osThreshold() {
            #expect(!TextRecognizer.isImageAnalyzerOS(Self.version(15)))
            #expect(!TextRecognizer.isImageAnalyzerOS(Self.version(26, 9)))
            #expect(TextRecognizer.isImageAnalyzerOS(Self.version(27)))
            #expect(TextRecognizer.isImageAnalyzerOS(Self.version(28, 1)))
        }

        @Test("an override pins the engine, and clearing it restores the OS-based choice")
        func override() {
            defer { TextRecognizer.engineOverride = nil }
            let natural = TextRecognizer.engine
            TextRecognizer.engineOverride = .vision
            #expect(TextRecognizer.engine == .vision)
            TextRecognizer.engineOverride = .imageAnalyzer
            #expect(TextRecognizer.engine == .imageAnalyzer)
            TextRecognizer.engineOverride = nil
            #expect(TextRecognizer.engine == natural)
        }

        @Test("below macOS 27 Vision is the natural engine")
        func naturalEngineBelow27() {
            TextRecognizer.engineOverride = nil
            if !Self.hostUsesImageAnalyzer { #expect(TextRecognizer.engine == .vision) }
        }

        @Test(
            "ImageAnalyzer reads text off the main thread without waiting on Vision",
            .enabled(if: TextRecognizerTests.hostUsesImageAnalyzer))
        @MainActor
        func imageAnalyzerReadsText() async throws {
            defer { TextRecognizer.engineOverride = nil }
            TextRecognizer.engineOverride = .imageAnalyzer
            let image = try #require(Self.renderText("IMAGE ANALYZER TEXT"))
            let started = Date()
            let text = await TextRecognizer.recognize(cgImage: image)
            // A cold Vision start takes 30+ seconds; the analyzer answers in
            // moments, so a long wait would mean the fallback kicked in.
            #expect(Date().timeIntervalSince(started) < 15)
            let recognized = try #require(text)
            #expect(recognized.uppercased().contains("ANALYZER") || recognized.uppercased().contains("TEXT"))
        }

        @Test(
            "an image without text yields nil from ImageAnalyzer",
            .enabled(if: TextRecognizerTests.hostUsesImageAnalyzer))
        @MainActor
        func imageAnalyzerBlank() async throws {
            defer { TextRecognizer.engineOverride = nil }
            TextRecognizer.engineOverride = .imageAnalyzer
            let blank = try #require(Self.renderText(""))
            #expect(await TextRecognizer.recognize(cgImage: blank) == nil)
        }

        /// Black `text` on white, big enough to be read reliably.
        @MainActor
        private static func renderText(_ text: String) -> CGImage? {
            let size = NSSize(width: 600, height: 120)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            (text as NSString).draw(
                at: NSPoint(x: 20, y: 36),
                withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.cgImage
        }
    }
}
