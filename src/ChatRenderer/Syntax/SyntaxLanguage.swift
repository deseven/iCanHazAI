import Foundation

/// The languages that can be highlighted. Declaration order is the popularity order used to
/// break ties between equally plausible candidates during auto-detection.
///
/// Close relatives share a grammar (see `aliases`): every grammar costs megabytes of binary, and
/// colors don't need to be IDE-perfect. The last group has no grammar at all and is colored by
/// `LightweightSyntax`; it has no detection hints, so it's only ever picked by an explicit marker.
enum SyntaxLanguage: String, CaseIterable, Sendable {
    case python, javascript, java, c, go, rust, swift, php, ruby, bash
    case html, css, json, yaml, toml, lua
    case sql, matlab, perl, r, vb, fortran, pascal

    var displayName: String { rawValue }

    var aliases: [String] {
        switch self {
        case .python: ["python", "py", "python3", "py3"]
        // TypeScript only adds annotations on top of JavaScript.
        case .javascript:
            ["javascript", "js", "jsx", "node", "nodejs", "mjs", "cjs", "typescript", "ts", "tsx", "mts", "cts"]
        // Kotlin and C# borrow Java's grammar. Borrowers are only ever picked by an explicit
        // marker, never auto-detected.
        case .java: ["java", "kotlin", "kt", "kts", "csharp", "c#", "cs", "dotnet"]
        case .c: ["c", "h", "cpp", "c++", "cc", "cxx", "hpp", "hxx", "cplusplus"]
        case .go: ["go", "golang"]
        case .rust: ["rust", "rs"]
        case .swift: ["swift"]
        case .php: ["php"]
        case .ruby: ["ruby", "rb"]
        case .bash: ["bash", "sh", "shell", "zsh", "ksh", "shellscript"]
        case .html: ["html", "htm", "xhtml"]
        case .css: ["css"]
        case .json: ["json", "jsonc", "json5"]
        case .yaml: ["yaml", "yml"]
        case .toml: ["toml"]
        case .lua: ["lua"]
        case .sql: ["sql", "mysql", "postgresql", "postgres", "pgsql", "psql", "plsql", "sqlite", "tsql", "mariadb"]
        case .matlab: ["matlab", "octave"]
        case .perl: ["perl", "pl", "pm"]
        case .r: ["r", "rscript"]
        // VB6, VBA, VBScript and VB.NET are lexically near-identical.
        case .vb: ["vb", "vba", "vbs", "vbscript", "vb6", "vbnet", "vb.net", "visualbasic"]
        case .fortran: ["fortran", "f90", "f95", "f03", "f08", "f77", "f"]
        case .pascal: ["pascal", "pas", "delphi", "objectpascal", "freepascal", "lazarus"]
        }
    }

    private static let byAlias: [String: SyntaxLanguage] = {
        var map: [String: SyntaxLanguage] = [:]
        for language in allCases { for alias in language.aliases { map[alias] = language } }
        return map
    }()

    /// Resolves a fence info string (`python`, `py title="x.py"`, `{.rust}`, `language-go`, `ts:app.ts`).
    static func from(marker info: String) -> SyntaxLanguage? {
        var word = info.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        word = word.lowercased()
        if word.hasPrefix("language-") { word.removeFirst("language-".count) }
        word = word.trimmingCharacters(in: CharacterSet(charactersIn: "{}."))
        if let cut = word.firstIndex(where: { ":,={".contains($0) }) { word = String(word[..<cut]) }
        return byAlias[word]
    }
}
