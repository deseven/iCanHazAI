import AppKit

enum SyntaxToken: UInt8, Sendable, CaseIterable {
    case comment = 1
    case keyword
    case string
    /// Numbers, booleans, escapes and builtin constants.
    case constant
    case function
    case type
    case property
    case tag
    case attribute

    /// How a tree-sitter capture name (`function.method.call` → `["function", "method", "call"]`)
    /// maps onto a token. Grammars name captures differently (nvim-treesitter, Helix and
    /// grammar-repo conventions are all in the wild), so only the leading components are looked at.
    enum Classification: Equatable {
        case token(SyntaxToken)
        /// Explicitly uncolored: overrides less specific captures on the same node.
        case plain
        /// Not a highlight at all (`@spell`, `@local.scope`, `@_helper`, …).
        case ignore
    }

    static func classify(_ components: [String]) -> Classification {
        guard let head = components.first else { return .ignore }
        if head.hasPrefix("_") { return .ignore }
        let second = components.count > 1 ? components[1] : nil
        switch head {
        case "comment": return .token(.comment)
        case "keyword", "conditional", "repeat", "include", "exception", "storage", "define", "preproc",
            "preprocessor":
            return .token(.keyword)
        case "string":
            return second == "escape" ? .token(.constant) : .token(.string)
        case "character":
            return second == "special" ? .token(.constant) : .token(.string)
        case "escape": return .token(.constant)
        case "number", "float", "integer", "boolean": return .token(.constant)
        case "constant": return .token(.constant)
        case "function", "method":
            return .token(.function)
        case "constructor", "type", "class", "interface", "enum", "struct", "namespace", "module":
            return .token(.type)
        case "property", "field", "member":
            return .token(.property)
        case "tag":
            return second == "attribute" ? .token(.attribute) : .token(.tag)
        case "attribute":
            return .token(.attribute)
        case "variable":
            switch second {
            case "builtin": return .token(.constant)
            case "member": return .token(.property)
            default: return .plain
            }
        case "operator", "punctuation", "parameter", "text", "markup", "none", "label":
            return .plain
        default:
            return .ignore
        }
    }
}

/// GitHub's Primer palette (github-vscode-theme, MIT), "Light Default" and "Dark Default".
/// The colors are dynamic, so an appearance change repaints without re-rendering anything.
enum SyntaxTheme {
    private static func color(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    // Style keys are the colors' object identities, so each token needs one stable instance.
    private static let comment = color(light: 0x6E7781, dark: 0x8B949E)
    private static let keyword = color(light: 0xCF222E, dark: 0xFF7B72)
    private static let string = color(light: 0x0A3069, dark: 0xA5D6FF)
    private static let constant = color(light: 0x0550AE, dark: 0x79C0FF)
    private static let function = color(light: 0x8250DF, dark: 0xD2A8FF)
    private static let type = color(light: 0x953800, dark: 0xFFA657)
    private static let property = color(light: 0x0550AE, dark: 0x79C0FF)
    private static let tag = color(light: 0x116329, dark: 0x7EE787)
    private static let attribute = color(light: 0x0550AE, dark: 0x79C0FF)

    static func color(for token: SyntaxToken) -> NSColor {
        switch token {
        case .comment: comment
        case .keyword: keyword
        case .string: string
        case .constant: constant
        case .function: function
        case .type: type
        case .property: property
        case .tag: tag
        case .attribute: attribute
        }
    }
}

/// A highlighted UTF-16 range of a code string. A highlight is a sorted list of non-overlapping spans.
struct SyntaxSpan: Equatable, Sendable {
    var range: NSRange
    var token: SyntaxToken
}
