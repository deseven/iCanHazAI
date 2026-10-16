import Foundation

/// Guesses the language of an unlabeled code block in three stages:
/// 1. cheap definitive signals (shebang, `<?php`, a doctype, strictly valid JSON),
/// 2. weighted regex hints that narrow the field to a few candidates (a language
///    with no positive evidence is never considered: grammars like bash or YAML
///    happily "parse" plain prose without errors),
/// 3. tree-sitter parse-scoring of the candidates, best hints first; a clean parse wins at once,
///    otherwise the lowest error ratio wins if it's low enough.
enum LanguageDetector {
    /// Minimum hint score for a language to be tried at all.
    static let minimumScore = 2
    /// Largest share of the sample the parser may fail on for a language to be accepted.
    static let maximumErrorRatio = 0.08
    /// Detection looks at the head of long blocks only.
    static let sampleLength = 6000

    static func detect(_ code: String, isCancelled: () -> Bool = { false }) -> SyntaxLanguage? {
        let sample = sample(of: code)
        if let definitive = definitiveSignal(sample) { return definitive }

        var best: (language: SyntaxLanguage, ratio: Double)?
        for (language, _) in candidates(in: sample) {
            if isCancelled() { return nil }

            guard let ratio = SyntaxEngine.errorRatio(sample, language: language) else { continue }
            if ratio == 0 { return language }
            if best == nil || ratio < best!.ratio { best = (language, ratio) }
        }
        if let best, best.ratio <= maximumErrorRatio { return best.language }
        return nil
    }

    /// The head of `code`, cut at a line boundary so the parser doesn't see a torn last line.
    static func sample(of code: String) -> String {
        guard code.utf16.count > sampleLength else { return code }
        let head = String(code.prefix(sampleLength))
        guard let cut = head.lastIndex(of: "\n") else { return head }
        return String(head[..<cut])
    }

    // MARK: Stage 1

    static func definitiveSignal(_ code: String) -> SyntaxLanguage? {
        let trimmed = code.drop(while: \.isWhitespace)
        guard let first = trimmed.first else { return nil }
        let firstLine = trimmed.prefix(while: { $0 != "\n" })

        if firstLine.hasPrefix("#!") {
            let line = firstLine.lowercased()
            if line.contains("python") { return .python }
            if line.contains("node") || line.contains("deno") || line.contains("bun") { return .javascript }
            if line.contains("ruby") { return .ruby }
            if line.contains("php") { return .php }
            if line.contains("lua") { return .lua }
            if line.range(of: #"\b(ba|z|da|k)?sh\b"#, options: .regularExpression) != nil { return .bash }
            return nil
        }
        let head = trimmed.prefix(64).lowercased()
        if head.hasPrefix("<?php") { return .php }
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return .html }
        if first == "{" || first == "[",
            (try? JSONSerialization.jsonObject(with: Data(code.utf8), options: [.fragmentsAllowed])) != nil
        {
            return .json
        }
        return nil
    }

    // MARK: Stage 2

    /// Languages with enough hint evidence, best first (ties follow popularity order).
    static func candidates(in code: String) -> [(language: SyntaxLanguage, score: Int)] {
        let range = NSRange(location: 0, length: (code as NSString).length)
        var scored: [(language: SyntaxLanguage, score: Int, order: Int)] = []
        for (order, language) in SyntaxLanguage.allCases.enumerated() {
            let score = LanguageHints.score(language, in: code, range: range)
            if score >= minimumScore { scored.append((language, score, order)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.map { ($0.language, $0.score) }
    }
}

final class Hint: @unchecked Sendable {
    let regex: NSRegularExpression
    let weight: Int
    let repeats: Bool

    /// With `repeats`, each match (up to three) adds the weight again.
    init(_ pattern: String, _ weight: Int, repeats: Bool = false, caseInsensitive: Bool = false) {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseInsensitive { options.insert(.caseInsensitive) }
        // Patterns are literals in this file; a typo must fail loudly (the tests compile them all).
        regex = try! NSRegularExpression(pattern: pattern, options: options)
        self.weight = weight
        self.repeats = repeats
    }

    func score(in code: String, range: NSRange) -> Int {
        guard repeats else {
            return regex.firstMatch(in: code, options: [], range: range) != nil ? weight : 0
        }
        let n = regex.numberOfMatches(in: code, options: [], range: range)
        return weight * min(n, 3)
    }
}

enum LanguageHints {
    static func score(_ language: SyntaxLanguage, in code: String, range: NSRange) -> Int {
        table[language, default: []].reduce(0) { $0 + $1.score(in: code, range: range) }
    }

    static var all: [SyntaxLanguage: [Hint]] { table }

    private static let jsHints: [Hint] = [
        Hint(#"\b(const|let|var)\s+\w+\s*="#, 1),
        Hint(#"=>"#, 1),
        Hint(#"\bfunction\b\s*\w*\s*\("#, 2),
        Hint(#"\bconsole\.(log|error|warn|info)\("#, 3),
        Hint(#"\brequire\(\s*['"]"#, 3),
        Hint(#"^\s*import\s.+\sfrom\s+['"]"#, 3),
        Hint(#"^\s*export\s+(default|const|function|class|async)\b"#, 2),
        Hint(#"\b(document|window)\.\w+"#, 2),
        Hint(#"[^=!]===|!=="#, 1),
        Hint(#"\bmodule\.exports\b"#, 3),
        Hint(#"\b(async|await)\b"#, 1),
    ]

    private static let cHints: [Hint] = [
        Hint(#"^\s*#include\s*<\w+\.h>"#, 3),
        Hint(#"^\s*#include\s*""#, 3),
        Hint(#"\bint\s+main\s*\("#, 3),
        Hint(#"\b(printf|scanf|malloc|calloc|free|sizeof|strlen|memcpy)\s*\("#, 2),
        Hint(#"^\s*#(define|ifdef|ifndef|endif|pragma|undef)\b"#, 2),
        Hint(#"\b(typedef|unsigned|struct\s+\w+\s*\{)"#, 1),
    ]

    private static let table: [SyntaxLanguage: [Hint]] = [
        .python: [
            Hint(#"^\s*def\s+\w+\s*\(.*\)\s*(->\s*[^:]+)?:\s*$"#, 3),
            Hint(#"^\s*class\s+\w+(\(.*\))?:\s*$"#, 3),
            Hint(#"^\s*(import\s+[\w.]+(\s+as\s+\w+)?|from\s+[\w.]+\s+import\s+.+)\s*$"#, 2),
            Hint(#"if\s+__name__\s*==\s*['"]__main__['"]"#, 4),
            Hint(#"^\s*(elif\b.*|except\b.*|finally|else|try)\s*:\s*$"#, 2),
            Hint(#"\bself\.\w+"#, 1),
            Hint(#"^\s*print\("#, 1),
            Hint(#"^\s*(for|while|if|with)\b.*:\s*$"#, 1),
            Hint(#"\b(None|True|False)\b"#, 1),
            Hint(#"\bf['"][^'"\n]*\{[^}\n]*\}"#, 2),
        ],
        .javascript: jsHints,
        .java: [
            Hint(#"\bpublic\s+(static\s+)?(final\s+)?(abstract\s+)?(class|interface|enum|record)\s+\w+"#, 3),
            Hint(#"public\s+static\s+void\s+main\s*\("#, 4),
            Hint(#"System\.(out|err)\.print"#, 4),
            Hint(#"^\s*import\s+(static\s+)?(java|javax|org|com)\.[\w.*]+;"#, 4),
            Hint(#"^\s*package\s+[\w.]+;"#, 3),
            Hint(#"@(Override|Autowired|Test|Entity|Service|Component)\b"#, 2),
            Hint(#"\b(private|protected|public)\s+(static\s+)?(final\s+)?[\w<>\[\],]+\s+\w+\s*(\(|=|;)"#, 1),
            Hint(#"\bString\[\]|\bnew\s+\w+(<.*>)?\("#, 1),
        ],
        .c: cHints,
        .go: [
            Hint(#"^\s*package\s+\w+\s*$"#, 4),
            Hint(#"^\s*import\s+(\(|")"#, 3),
            Hint(#"\bfunc\s+(\(\w+\s+\*?\w+\)\s+)?\w+\s*\("#, 3),
            Hint(#"\w\s*:=\s*"#, 2),
            Hint(#"\bfmt\.\w+\("#, 4),
            Hint(#"\bif\s+err\s*!=\s*nil\b"#, 4),
            Hint(#"^\s*type\s+\w+\s+(struct|interface)\s*\{"#, 4),
            Hint(#"\b(defer|go\s+func|chan)\b"#, 2),
        ],
        .rust: [
            Hint(#"\bfn\s+\w+\s*(<.*>)?\("#, 3),
            Hint(#"\blet\s+(mut\s+)?\w+(\s*:\s*[\w<>&\[\]']+)?\s*="#, 2),
            Hint(#"^\s*use\s+(std|crate|super|self)::"#, 4),
            Hint(#"\b(println|print|eprintln|vec|format|panic|assert|assert_eq|todo|unimplemented)!\s*[(\[{]"#, 4),
            Hint(#"\bimpl\b(<.*>)?\s+\w+"#, 3),
            Hint(#"^\s*(pub(\(\w+\))?\s+)?(struct|enum|trait|mod)\s+\w+"#, 2),
            Hint(#"->\s*(Result|Option|Self|Vec|String|&)"#, 2),
            Hint(#"^\s*#!?\[(derive|test|cfg|allow)\b"#, 4),
            Hint(#"\.unwrap\(\)|\.expect\(|&mut\s"#, 2),
        ],
        .swift: [
            Hint(#"^\s*import\s+(Foundation|SwiftUI|UIKit|AppKit|Combine|XCTest|Testing)\b"#, 4),
            Hint(#"\bfunc\s+\w+\s*(<[^>]*>)?\("#, 2),
            Hint(#"\b(guard|if)\s+let\b"#, 3),
            Hint(#"\b(let|var)\s+\w+\s*(:\s*[\w\[\]<>?:, ]+)?\s*="#, 1),
            Hint(#"\)\s*(async\s+)?(throws\s+)?->\s*[\w\[\]<>?]+\s*\{"#, 2),
            Hint(#"^\s*(public\s+|private\s+|final\s+)*(struct|class|enum|protocol|extension|actor)\s+\w+"#, 1),
            Hint(#"@(State|Published|main|objc|MainActor|Observable|Binding|Environment)\b"#, 3),
            Hint(#"\bnil\b.*\?\?|\?\?\s|\bself\.\w+|\[weak self\]"#, 1),
        ],
        .php: [
            Hint(#"<\?php"#, 5),
            Hint(#"\$this->"#, 3),
            Hint(#"\$\w+\s*="#, 2),
            Hint(#"\becho\s"#, 2),
            Hint(#"\bfunction\s+\w+\s*\(.*\)\s*(:\s*\??\w+)?\s*\{?"#, 1),
            Hint(#"^\s*(namespace|use)\s+[\w\\]+;"#, 2),
            Hint(#"\barray\s*\(|->\w+\("#, 1),
        ],
        .ruby: [
            Hint(#"^\s*def\s+\w+[?!=]?(\(.*\))?\s*$"#, 3),
            Hint(#"^\s*end\s*$"#, 2),
            Hint(#"\bputs\s"#, 2),
            Hint(#"^\s*require(_relative)?\s+['"]"#, 3),
            Hint(#"^\s*(class|module)\s+[A-Z]\w*(\s*<\s*[\w:]+)?\s*$"#, 3),
            Hint(#"\battr_(accessor|reader|writer)\b"#, 4),
            Hint(#"\bdo\s*(\|[^|]*\|)?\s*$"#, 2),
            Hint(#"\b(elsif|unless|nil)\b"#, 2),
            Hint(#"@\w+\s*=|\.each\b"#, 1),
        ],
        .bash: [
            Hint(
                #"^\s*(echo|cd|ls|mkdir|rm|cp|mv|cat|grep|sed|awk|export|source|sudo|apt(-get)?|brew|curl|wget|chmod|chown|git|docker|npm|pip3?|cargo|make|tar|kill|ssh|scp|touch|find|xargs|head|tail|sort|uniq|wc|set|trap|read|exit)\b"#,
                2),
            Hint(#"\$\{?\w+\}?"#, 1),
            Hint(#"^\s*(then|fi|done|esac|elif)\s*;?\s*$|;\s*(then|do)\s*$"#, 3),
            Hint(#"\[\[\s.*\s\]\]|\[\s+-[a-z]\s"#, 3),
            Hint(#"^\s*(function\s+\w+|\w+\s*\(\s*\))\s*\{"#, 2),
            Hint(#"2>&1|>\s*/dev/null|\|\s*\w+"#, 2),
            Hint(#"^\s*[A-Z_][A-Z0-9_]*=\S*"#, 1),
        ],
        .html: [
            Hint(#"<!DOCTYPE\s+html"#, 5, caseInsensitive: true),
            Hint(#"<html\b"#, 4, caseInsensitive: true),
            Hint(
                #"</?(div|span|p|a|ul|ol|li|body|head|h[1-6]|script|style|table|tr|td|form|input|button|img|section|nav|header|footer|meta|link|title|main)\b[^>]*>"#,
                3, repeats: true, caseInsensitive: true),
        ],
        .css: [
            Hint(#"@(media|import|keyframes|font-face|charset|supports)\b"#, 3),
            Hint(
                #"^\s*(margin|padding|display|color|background(-color)?|font(-size|-family|-weight)?|border(-radius)?|flex(-direction)?|grid|width|height|position|justify-content|align-items)\s*:"#,
                2, repeats: true),
            Hint(#"^\s*[.#]?[\w-][\w\s.#:>+~,\[\]=*-]*\{\s*$"#, 1),
        ],
        .json: [
            Hint(#"^\s*"[^"\n]+"\s*:\s*\S"#, 2, repeats: true),
            Hint(#"^\s*[\[{]\s*$"#, 1),
        ],
        .yaml: [
            Hint(#"^---\s*$"#, 3),
            Hint(#"^\s*-\s+[\w"'-]+:\s"#, 2),
            Hint(
                #"^\s*(?!(else|try|finally|default|case|do|begin|public|private)\b)[A-Za-z_][\w.-]*:(\s+[^{};,()\[\]]*)?$"#,
                1, repeats: true),
        ],
        .toml: [
            Hint(#"^\s*\[\[?[\w."-]+\]\]?\s*$"#, 3),
            Hint(#"^\s*[\w.-]+\s*=\s*("|'|\d|true\b|false\b|\[|\{)"#, 1, repeats: true),
        ],
        .lua: [
            Hint(#"\blocal\s+(function\s+)?\w+"#, 3),
            Hint(#"\bfunction\s+[\w.:]+\s*\("#, 2),
            Hint(#"\belseif\b"#, 3),
            Hint(#"\b(ipairs|pairs)\s*\("#, 3),
            Hint(#"~="#, 2),
            Hint(#"^\s*end\s*[,)]?\s*$"#, 1),
            Hint(#"\brequire\s*\(?\s*['"]"#, 1),
        ],
    ]
}
