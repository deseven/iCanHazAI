import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterLua
import TreeSitterPHP
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterYAML

/// Where the tree-sitter grammars and their highlight queries come from.
extension SyntaxLanguage {
    /// nil for the languages colored by `LightweightSyntax`.
    var grammar: Language? {
        let pointer: OpaquePointer? =
            switch self {
            case .python: tree_sitter_python()!
            case .javascript: tree_sitter_javascript()!
            case .java: tree_sitter_java()!
            case .c: tree_sitter_c()!
            case .go: tree_sitter_go()!
            case .rust: tree_sitter_rust()!
            case .swift: tree_sitter_swift()!
            case .php: tree_sitter_php()!
            case .ruby: tree_sitter_ruby()!
            case .bash: tree_sitter_bash()!
            case .html: tree_sitter_html()!
            case .css: tree_sitter_css()!
            case .json: tree_sitter_json()!
            case .yaml: tree_sitter_yaml()!
            case .toml: tree_sitter_toml()!
            case .lua: tree_sitter_lua()!
            case .sql, .matlab, .perl, .r, .vb, .fortran, .pascal: nil
            }
        return pointer.map { Language($0) }
    }

    /// The file of `res/syntax` holding the highlight query.
    var queryFile: String { rawValue }

    /// The bundled `Syntax` resource folder; sources and tests fall back to the repo's `res/syntax`.
    static let queryDirectory: URL? = {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Syntax"),
            fm.fileExists(atPath: bundled.path)
        {
            return bundled
        }
        // …/src/ChatRenderer/Syntax/SyntaxGrammars.swift → repo root
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let checkout = root.appendingPathComponent("res/syntax")
        return fm.fileExists(atPath: checkout.path) ? checkout : nil
    }()
}
