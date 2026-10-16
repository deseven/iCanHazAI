import AppKit

enum MDAttr {
    /// `CodeBlockMarker` — fenced/indented code blocks and table fallbacks.
    static let codeBlock = NSAttributedString.Key("md.codeBlock")
    /// `InlineCodeMarker`.
    static let inlineCode = NSAttributedString.Key("md.inlineCode")
    /// `[QuoteMarker]` — one marker per enclosing blockquote.
    static let quote = NSAttributedString.Key("md.quote")
    /// `RuleMarker`.
    static let rule = NSAttributedString.Key("md.rule")
}

// Markers are NSObjects compared by identity, so adjacent blocks never merge
// into one attribute run. Each carries its character range so the layout
// manager can draw the complete decoration even when only part of it is visible.
// All of them are immutable once the attributed string has been built.

final class CodeBlockMarker: NSObject, @unchecked Sendable {
    let indent: CGFloat
    /// The fence's language marker as written.
    let language: String?
    /// The source as written (real newlines), for the copy button and language detection.
    let code: String
    var range = NSRange(location: 0, length: 0)
    /// Unlabeled code that wasn't colored while building: the showing view detects its
    /// language later and colors it itself (the cached string stays plain).
    let needsDetection: Bool
    /// Main-thread state: set by the view that completes the detection, so the header label
    /// survives the string being shown again.
    var detectedLanguage: String?

    init(indent: CGFloat, language: String?, code: String, needsDetection: Bool = false) {
        self.indent = indent
        self.language = language
        self.code = code
        self.needsDetection = needsDetection
    }

    /// Shown in the block's header.
    var label: String { language ?? detectedLanguage ?? "code" }
}

final class QuoteMarker: NSObject, @unchecked Sendable {
    let x: CGFloat
    var range = NSRange(location: 0, length: 0)
    init(x: CGFloat) { self.x = x }
}

final class RuleMarker: NSObject, Sendable {
    let indent: CGFloat
    init(indent: CGFloat) { self.indent = indent }
}

final class InlineCodeMarker: NSObject, Sendable {
    static let shared = InlineCodeMarker()
}

/// Font sizes and metrics of the chat renderer. Every value is derived from
/// `scale` (the interface scale as a factor), so a theme is all a renderer needs
/// to produce output for a given scale.
struct Theme: Sendable, Equatable {
    let scale: CGFloat

    init(scale: CGFloat = 1) {
        self.scale = scale
    }

    func scaled(_ value: CGFloat) -> CGFloat { value * scale }

    var fontSize: CGFloat { scaled(13) }
    var codeFontSize: CGFloat { scaled(12) }
    var lineSpacing: CGFloat { scaled(3) }
    var codeLineSpacing: CGFloat { scaled(2) }
    var blockSpacing: CGFloat { scaled(10) }
    var tightSpacing: CGFloat { scaled(3) }
    var headingTopExtra: CGFloat { scaled(6) }
    var bulletWidth: CGFloat { scaled(18) }
    var markerGap: CGFloat { scaled(6) }
    var tabInterval: CGFloat { scaled(28) }
    var quoteIndent: CGFloat { scaled(16) }
    var quoteBarWidth: CGFloat { scaled(3) }
    var codePadH: CGFloat { scaled(12) }
    var codePadV: CGFloat { scaled(9) }
    var codeLabelHeight: CGFloat { scaled(16) }
    var codeLabelFontSize: CGFloat { scaled(10.5) }
    var codeCornerRadius: CGFloat { scaled(6) }
    var inlineCodeGap: CGFloat { scaled(4) }
    var tableCellPadH: CGFloat { scaled(9) }
    var tableCellPadV: CGFloat { scaled(5) }
    var tableLineSpacing: CGFloat { scaled(2) }
    var monoLineSpacing: CGFloat { scaled(1) }
    var toolLabelSize: CGFloat { scaled(11) }
    var sectionGap: CGFloat { scaled(10) }
    var labelGap: CGFloat { scaled(3) }
    var entryGap: CGFloat { scaled(7) }

    /// Safety net only. Real tool results reach ~650 KB, which lays out in
    /// ~150 ms; that cost is paid only when the block is expanded.
    var maxPlainLength: Int { 2_000_000 }

    func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize * 1.6
        case 2: return fontSize * 1.35
        case 3: return fontSize * 1.15
        default: return fontSize
        }
    }

    static let codeBackground = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.04)
    }
    static let codeBorder = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.07)
    }
    static let inlineCodeBackground = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.06)
    }
    static let tableBorder = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12)
    }
    static let tableHeaderBackground = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.035)
    }
    static let userRowBackground = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.035) : NSColor(white: 0, alpha: 0.025)
    }
    static let panelBackground = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.045) : NSColor(white: 0, alpha: 0.035)
    }
}

/// Thread-safe font cache; renderers run concurrently on background threads.
final class FontCache: @unchecked Sendable {
    static let shared = FontCache()

    struct Key: Hashable {
        var size: CGFloat
        var bold: Bool
        var italic: Bool
        var mono: Bool
        var heading: Bool
    }

    private var cache: [Key: NSFont] = [:]
    private let lock = NSLock()

    func font(size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false, heading: Bool = false)
        -> NSFont
    {
        let key = Key(size: size, bold: bold, italic: italic, mono: mono, heading: heading)
        lock.lock()
        defer { lock.unlock() }
        if let f = cache[key] { return f }
        let weight: NSFont.Weight = heading ? (bold ? .heavy : .bold) : (bold ? .semibold : .regular)
        var font =
            mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        if italic {
            let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            font = NSFont(descriptor: d, size: size) ?? font
        }
        cache[key] = font
        return font
    }
}
