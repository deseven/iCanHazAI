import Foundation

/// Highlight results shared by the whole app. Explicit languages are highlighted synchronously
/// (the renderer calls this off the main thread or for a handful of visible rows); auto-detection
/// is async and cancellable, and its outcome is cached so a re-render never repeats it.
final class SyntaxHighlighter: @unchecked Sendable {
    static let shared = SyntaxHighlighter()

    struct Result: Sendable {
        /// nil: detection found nothing, the code stays unhighlighted.
        let language: SyntaxLanguage?
        let spans: [SyntaxSpan]
    }

    static func isDetectable(_ code: String) -> Bool {
        code.utf16.count <= SyntaxEngine.maxHighlightLength && code.contains(where: { !$0.isWhitespace })
    }

    /// `language == nil` keys the auto-detected result of a source.
    private struct Key: Hashable {
        let language: SyntaxLanguage?
        let code: String
    }

    private let lock = NSLock()
    private var entries: [Key: Result] = [:]
    private var order: [Key] = []
    private var cost = 0
    private let costLimit = 2_000_000
    private let countLimit = 400

    func cached(_ code: String, language: SyntaxLanguage?) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Key(language: language, code: code)]
    }

    private func store(_ result: Result, _ code: String, language: SyntaxLanguage?) {
        let key = Key(language: language, code: code)
        lock.lock()
        defer { lock.unlock() }
        if entries.updateValue(result, forKey: key) == nil {
            order.append(key)
            cost += code.utf16.count
        }
        while cost > costLimit || order.count > countLimit, !order.isEmpty {
            let old = order.removeFirst()
            if entries.removeValue(forKey: old) != nil { cost -= old.code.utf16.count }
        }
    }

    func highlight(_ code: String, as language: SyntaxLanguage) -> Result {
        if let hit = cached(code, language: language) { return hit }
        let result = Result(language: language, spans: SyntaxEngine.highlight(code, language: language) ?? [])
        store(result, code, language: language)
        return result
    }

    /// Runs on the cooperative pool, not the caller's actor. Returns nil if cancelled midway
    /// (nothing is cached then).
    func detect(_ code: String) async -> Result? {
        if let hit = cached(code, language: nil) { return hit }
        guard let language = LanguageDetector.detect(code, isCancelled: { Task.isCancelled }) else {
            if Task.isCancelled { return nil }
            let none = Result(language: nil, spans: [])
            store(none, code, language: nil)
            return none
        }
        if Task.isCancelled { return nil }
        let result = Result(language: language, spans: SyntaxEngine.highlight(code, language: language) ?? [])
        store(result, code, language: nil)
        return result
    }
}
