import AppKit

/// A top-level block of a rendered text. `signature` fingerprints everything that is laid out or
/// drawn for its characters (fonts, colors, links, paragraph styles, markers), so two renders
/// that agree on a block's characters and signature produce the same block.
struct TextBlock: Equatable, Sendable {
    let start: Int
    let signature: Int
}

/// Works out how much of a text that is being replaced by a longer version of itself (a message
/// that is streaming in) can stay as it is, so TextKit only has to lay the tail out again.
enum StableText {
    /// Length, in UTF-16 units, of the characters two texts start with in common.
    static func sharedPrefix(_ a: NSString, _ b: NSString) -> Int {
        let count = min(a.length, b.length)
        let chunk = 2048
        var left = [unichar](repeating: 0, count: chunk)
        var right = [unichar](repeating: 0, count: chunk)
        var i = 0
        while i < count {
            let length = min(chunk, count - i)
            let range = NSRange(location: i, length: length)
            a.getCharacters(&left, range: range)
            b.getCharacters(&right, range: range)
            if memcmp(left, right, length * MemoryLayout<unichar>.size) != 0 {
                for k in 0..<length where left[k] != right[k] { return i + k }
            }
            i += length
        }
        return count
    }

    /// The start of the block the first difference falls in, provided every block before it is the
    /// same in both texts: a block's last paragraph is only touched by the block that follows it,
    /// and that one exists in both. 0 when nothing can be kept.
    static func keptLength(old: [TextBlock], new: [TextBlock], shared: Int) -> Int {

        var kept = 0
        var i = 0
        while i < min(old.count, new.count), old[i].start == new[i].start, new[i].start <= shared {
            if i > 0, old[i - 1].signature != new[i - 1].signature { break }
            kept = new[i].start
            i += 1
        }
        return kept
    }
}

/// Hash inputs for `TextBlock.signature`.
enum TextFingerprint {
    static func combine(_ style: NSParagraphStyle, into h: inout Hasher) {
        h.combine(style.alignment.rawValue)
        h.combine(style.lineSpacing)
        h.combine(style.paragraphSpacing)
        h.combine(style.paragraphSpacingBefore)
        h.combine(style.headIndent)
        h.combine(style.tailIndent)
        h.combine(style.firstLineHeadIndent)
        h.combine(style.minimumLineHeight)
        h.combine(style.maximumLineHeight)
        h.combine(style.lineHeightMultiple)
        h.combine(style.lineBreakMode.rawValue)
        h.combine(style.baseWritingDirection.rawValue)
        h.combine(style.defaultTabInterval)
        h.combine(style.hyphenationFactor)
        for tab in style.tabStops {
            h.combine(tab.location)
            h.combine(tab.alignment.rawValue)
        }
        h.combine(style.textBlocks.count)
    }

    static func combine(_ font: NSFont, into h: inout Hasher) {
        h.combine(font.fontName)
        h.combine(font.pointSize)
        h.combine(font.hash)
    }

    /// Colors are shared instances (`labelColor`, the syntax theme's), compared by identity.
    static func combine(_ color: NSColor, into h: inout Hasher) {
        h.combine(ObjectIdentifier(color))
    }
}
