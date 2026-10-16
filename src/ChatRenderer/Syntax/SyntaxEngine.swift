import Foundation
import SwiftTreeSitter

/// Tree-sitter plumbing: parsing, highlight queries and parse-quality scoring.
/// Everything here is safe to call from any thread.
enum SyntaxEngine {
    /// Longer sources are shown unhighlighted: highlighting runs in the render path.
    static let maxHighlightLength = 50_000

    private final class Runtime: @unchecked Sendable {
        let language: Language
        let query: Query?
        init(language: Language, query: Query?) {
            self.language = language
            self.query = query
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var runtimes: [SyntaxLanguage: Runtime] = [:]

    /// Grammar and compiled highlight query, built once per language.
    private static func runtime(for language: SyntaxLanguage) -> Runtime? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = runtimes[language] { return cached }
        guard let grammar = language.grammar else { return nil }
        let runtime = Runtime(language: grammar, query: loadQuery(for: language, grammar: grammar))
        runtimes[language] = runtime
        return runtime
    }

    private static func loadQuery(for language: SyntaxLanguage, grammar: Language) -> Query? {
        guard let directory = SyntaxLanguage.queryDirectory else { return nil }
        guard
            let text = try? String(
                contentsOf: directory.appendingPathComponent("\(language.queryFile).scm"), encoding: .utf8)
        else { return nil }
        return try? Query(language: grammar, data: Data(text.utf8))
    }

    /// Whether the grammar loaded and its highlight query compiled.
    static func isAvailable(_ language: SyntaxLanguage) -> Bool {
        language.lightweight != nil || runtime(for: language)?.query != nil
    }

    private static func parse(_ code: String, with runtime: Runtime, timeout: TimeInterval) -> MutableTree? {
        let parser = Parser()
        guard (try? parser.setLanguage(runtime.language)) != nil else { return nil }
        parser.timeout = timeout
        return parser.parse(code)
    }

    // MARK: Highlighting

    static func highlight(_ code: String, language: SyntaxLanguage, timeout: TimeInterval = 1) -> [SyntaxSpan]? {
        guard code.utf16.count <= maxHighlightLength, !code.isEmpty else { return nil }
        if let lightweight = language.lightweight { return lightweight.highlight(code) }
        guard let runtime = runtime(for: language), let query = runtime.query,
            let tree = parse(code, with: runtime, timeout: timeout)
        else { return nil }

        let text = NSString(string: code)
        let length = text.length
        let context = Predicate.Context(textProvider: { range, _ in
            NSMaxRange(range) <= length ? text.substring(with: range) : nil
        })

        struct Paint {
            let range: NSRange
            let value: UInt8
            let pattern: Int
        }
        var paints: [Paint] = []
        for match in query.execute(in: tree).resolve(with: context) {
            for capture in match.captures {
                let value: UInt8
                switch SyntaxToken.classify(capture.nameComponents) {
                case .ignore: continue
                case .plain: value = 0
                case .token(let token): value = token.rawValue
                }
                let range = NSIntersectionRange(capture.range, NSRange(location: 0, length: length))
                guard range.length > 0 else { continue }
                paints.append(Paint(range: range, value: value, pattern: capture.patternIndex))
            }
        }

        // Painted last wins: the narrowest range (an interpolation inside a string, a name inside
        // a broad capture), then the later pattern: queries open with generic captures such as
        // `(identifier) @variable` and refine them below.
        paints.sort {
            $0.range.length != $1.range.length ? $0.range.length > $1.range.length : $0.pattern < $1.pattern
        }
        var canvas = [UInt8](repeating: 0, count: length)
        for paint in paints {
            for i in paint.range.location..<NSMaxRange(paint.range) { canvas[i] = paint.value }
        }

        var spans: [SyntaxSpan] = []
        var i = 0
        while i < length {
            let value = canvas[i]
            var j = i + 1
            while j < length, canvas[j] == value { j += 1 }
            if value != 0, let token = SyntaxToken(rawValue: value) {
                spans.append(SyntaxSpan(range: NSRange(location: i, length: j - i), token: token))
            }
            i = j
        }
        return spans
    }

    // MARK: Parse scoring

    /// The share of `code` covered by syntax errors (0 = parsed cleanly), or nil if the language
    /// can't be used.
    static func errorRatio(_ code: String, language: SyntaxLanguage, timeout: TimeInterval = 0.3) -> Double? {
        guard !code.isEmpty, let runtime = runtime(for: language),
            let tree = parse(code, with: runtime, timeout: timeout), let root = tree.rootNode
        else { return nil }
        guard root.hasError else { return 0 }
        var bad = 0
        countErrors(in: root, depth: 0, into: &bad)
        return min(1, Double(bad) / Double(code.utf16.count))
    }

    private static func countErrors(in node: Node, depth: Int, into bad: inout Int) {
        if node.isMissing {
            bad += 1
            return
        }
        if node.nodeType == "ERROR" {
            bad += max(node.range.length, 1)
            return
        }
        guard node.hasError else { return }
        // Pathologically deep trees are counted as failures instead of risking the stack.
        guard depth < 200 else {
            bad += node.range.length
            return
        }
        for i in 0..<node.childCount {
            if let child = node.child(at: i) { countErrors(in: child, depth: depth + 1, into: &bad) }
        }
    }
}
