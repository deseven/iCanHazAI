import Testing

@testable import iCanHazAI

extension AllAppTests {

    @Suite("Quick Look support")
    struct QuickLookSupportTests {

        @Test(arguments: [
            "a.pdf", "a.docx", "a.XLSX", "a.pptx", "a.odt", "a.pages", "a.numbers", "a.key",
            "a.csv", "a.txt", "a.md", "a.json", "a.swift", "a.rtf", "a.html",
        ])
        func previewsKnownDocuments(filename: String) {
            #expect(QuickLookSupport.canPreview(filename: filename, kind: .document))
        }

        @Test(arguments: ["a.zip", "a.app", "a.pkg", "a.dmg", "a.exe", "a.unknownext", "noext", "a.bin"])
        func opensUnknownExternally(filename: String) {
            #expect(!QuickLookSupport.canPreview(filename: filename, kind: .document))
        }

        @Test func imagesAlwaysPreview() {
            #expect(QuickLookSupport.canPreview(filename: "x.bin", kind: .image))
        }
    }
}
