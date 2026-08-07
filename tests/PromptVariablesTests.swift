import Foundation
import Testing
@testable import iCanHazAI

// Unit tests for the prompt variable helper ([`PromptVariables`](src/Chat/PromptVariables.swift)):
// substitution, escaping, unknown-variable detection, and the dynamic values
// (rendering capabilities, user name, date).
extension AllAppTests {
    @Suite("Prompt variables")
    struct PromptVariablesTests {

        // MARK: - Substitution

        @Test("substitute replaces known variables")
        func substituteKnown() {
            let text = "Hello {user}, today is {date}."
            let out = PromptVariables.substitute(text: text, values: ["user": "alice", "date": "Mon"])
            #expect(out == "Hello alice, today is Mon.")
        }

        @Test("substitute leaves unknown variables verbatim")
        func substituteUnknown() {
            let out = PromptVariables.substitute(text: "Hi {stranger}", values: ["user": "alice"])
            #expect(out == "Hi {stranger}")
        }

        @Test("substitute turns an escaped brace into a literal brace")
        func substituteEscaped() {
            // \{user} should NOT be substituted — it becomes a literal {user}.
            let out = PromptVariables.substitute(text: "literal: \\{user} real: {user}", values: ["user": "alice"])
            #expect(out == "literal: {user} real: alice")
        }

        @Test("substitute leaves non-identifier braces untouched (JSON/code)")
        func substituteNonIdentifier() {
            let json = #"{"model": "gpt-4o", "n": {}}"#
            let out = PromptVariables.substitute(text: json, values: ["user": "alice"])
            #expect(out == json)
        }

        @Test("substitute handles a variable adjacent to text and repeated use")
        func substituteRepeated() {
            let out = PromptVariables.substitute(text: "{user}{user}-{date}", values: ["user": "x", "date": "d"])
            #expect(out == "xx-d")
        }

        @Test("substitute with no variables returns the text unchanged")
        func substituteNone() {
            let text = "No variables here, just {1} and {a b} and { }."
            let out = PromptVariables.substitute(text: text, values: ["user": "alice"])
            #expect(out == text)
        }

        @Test("substitute resolves load_first_available via the resolver")
        func substituteLoadFirstAvailable() {
            let out = PromptVariables.substitute(
                text: "A {load_first_available:x.md,y.md} B",
                values: [:]
            ) { args in
                #expect(args == "x.md,y.md")
                return "(y.md)\nhello\n"
            }
            #expect(out == "A (y.md)\nhello\n B")
        }

        @Test("substitute leaves load_first_available verbatim without a resolver")
        func substituteLoadFirstAvailableNoResolver() {
            let text = "A {load_first_available:x.md} B"
            #expect(PromptVariables.substitute(text: text, values: [:]) == text)
        }

        @Test("substitute escapes load_first_available like any other variable")
        func substituteLoadFirstAvailableEscaped() {
            let out = PromptVariables.substitute(text: "\\{load_first_available:x.md}", values: [:]) { _ in "boom" }
            #expect(out == "{load_first_available:x.md}")
        }

        @Test("substitute leaves arguments on plain variables verbatim")
        func substitutePlainVariableWithArgs() {
            let text = "{user:foo}"
            #expect(PromptVariables.substitute(text: text, values: ["user": "alice"]) == text)
        }

        // MARK: - Validation

        @Test("unknownVariables finds unknown identifier-shaped references")
        func unknownFinds() {
            #expect(PromptVariables.unknownVariables(in: "Hi {foo} and {bar}") == ["foo", "bar"])
        }

        @Test("unknownVariables ignores known variables")
        func unknownIgnoresKnown() {
            #expect(PromptVariables.unknownVariables(in: "{user} {date} {output_rendering}").isEmpty)
        }

        @Test("unknownVariables ignores escaped braces")
        func unknownIgnoresEscaped() {
            // \{foo} is escaped → not a variable, even though foo is identifier-shaped.
            #expect(PromptVariables.unknownVariables(in: "literal \\{foo} and {user}").isEmpty)
        }

        @Test("unknownVariables ignores non-identifier braces")
        func unknownIgnoresNonIdentifier() {
            #expect(PromptVariables.unknownVariables(in: #"{"a": 1} { } {1a} {a b}"#).isEmpty)
        }

        @Test("unknownVariables dedupes and preserves first-seen order")
        func unknownDedupes() {
            #expect(PromptVariables.unknownVariables(in: "{foo} {bar} {foo} {baz}") == ["foo", "bar", "baz"])
        }

        @Test("unknownVariables accepts load_first_available with a file list")
        func unknownLoadFirstAvailableValid() {
            #expect(PromptVariables.unknownVariables(in: "{load_first_available:AGENTS.md,CLAUDE.md,.roorules}").isEmpty)
            #expect(PromptVariables.unknownVariables(in: "{load_first_available: /abs/path , rel.md }").isEmpty)
        }

        @Test("unknownVariables rejects load_first_available without files")
        func unknownLoadFirstAvailableInvalid() {
            #expect(PromptVariables.unknownVariables(in: "{load_first_available}") == ["load_first_available"])
            #expect(PromptVariables.unknownVariables(in: "{load_first_available:}") == ["load_first_available"])
            #expect(PromptVariables.unknownVariables(in: "{load_first_available: , }") == ["load_first_available"])
        }

        @Test("unknownVariables rejects arguments on plain variables")
        func unknownPlainVariableWithArgs() {
            #expect(PromptVariables.unknownVariables(in: "{user:foo}") == ["user"])
        }

        @Test("unknownVariablesMessage shows the correct form for load_first_available")
        func messageLoadFirstAvailable() {
            #expect(PromptVariables.unknownVariablesMessage(["load_first_available"])
                == "unknown prompt variable {load_first_available:file1,file2,...}")
        }

        @Test("knownVariablesList includes load_first_available")
        func knownListIncludesLoadFirstAvailable() {
            #expect(PromptVariables.knownVariablesList.contains("{load_first_available:file1,file2,...}"))
        }

        @Test("unknownVariablesMessage is singular/plural")
        func messagePluralization() {
            #expect(PromptVariables.unknownVariablesMessage(["foo"]) == "unknown prompt variable {foo}")
            #expect(PromptVariables.unknownVariablesMessage(["foo", "bar"]) == "unknown prompt variables {foo}, {bar}")
        }

        // MARK: - Dynamic values

        @Test("renderingCapabilities advertises enabled features and hides disabled ones")
        func renderingCapabilities() {
            let both = PromptVariables.renderingCapabilities(mermaid: true, katex: true)
            #expect(both.contains("KaTeX"))
            #expect(both.contains("Mermaid"))
            #expect(!both.contains("NOT supported"))

            let neither = PromptVariables.renderingCapabilities(mermaid: false, katex: false)
            #expect(neither.contains("LaTeX math is NOT supported"))
            #expect(neither.contains("Mermaid diagrams are NOT supported"))
        }

        @Test("currentDate is formatted as 'EEE MMM d yyyy'")
        func currentDateFormatted() {
            let date = PromptVariables.currentDate()
            // e.g. "Thu Jun 16 2026" — three-letter weekday, three-letter month,
            // day without leading zero, four-digit year.
            let pattern = #"^\w{3} \w{3} \d{1,2} \d{4}$"#
            #expect(date.range(of: pattern, options: .regularExpression) != nil)
        }

        @Test("currentUserName is the home directory's last path component")
        func currentUserNameValue() {
            let expected = (NSHomeDirectory() as NSString).lastPathComponent
            #expect(!expected.isEmpty)
            #expect(PromptVariables.currentUserName() == expected)
        }

        @Test("currentDirectory is empty without a workdir-capable group")
        func currentDirectoryNoGroup() {
            #expect(PromptVariables.currentDirectory(workdirCapable: false, isolated: false, directory: nil) == "")
            #expect(PromptVariables.currentDirectory(workdirCapable: false, isolated: true, directory: "/tmp") == "")
        }

        @Test("currentDirectory is / when isolated")
        func currentDirectoryIsolated() {
            #expect(PromptVariables.currentDirectory(workdirCapable: true, isolated: true, directory: nil) == "Current directory: /")
            #expect(PromptVariables.currentDirectory(workdirCapable: true, isolated: true, directory: "/some/path") == "Current directory: /")
        }

        @Test("currentDirectory is ~ when no directory is set")
        func currentDirectoryUnset() {
            #expect(PromptVariables.currentDirectory(workdirCapable: true, isolated: false, directory: nil) == "Current directory: ~")
            #expect(PromptVariables.currentDirectory(workdirCapable: true, isolated: false, directory: "") == "Current directory: ~")
        }

        @Test("currentDirectory is the path when set")
        func currentDirectorySet() {
            #expect(PromptVariables.currentDirectory(workdirCapable: true, isolated: false, directory: "/some/path") == "Current directory: /some/path")
        }

        @Test("current_directory is a known variable")
        func currentDirectoryKnown() {
            #expect(PromptVariables.unknownVariables(in: "dir: {current_directory}").isEmpty)
        }
    }

    @Suite("Load first available cache")
    struct LoadFirstAvailableCacheTests {

        /// A scratch directory per test, removed on exit.
        private func withTempDir(_ body: (URL) throws -> Void) throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("lfa-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try body(dir)
        }

        @discardableResult
        private func write(_ name: String, _ contents: String, in dir: URL) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        private func setMtime(_ date: Date, of url: URL) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        @Test("picks the first existing file and formats it as (name) + contents")
        func picksFirstExisting() throws {
            try withTempDir { dir in
                try write("info.txt", "hello world\n", in: dir)
                let cache = LoadFirstAvailableCache()
                let out = cache.resolve(args: "missing.md,info.txt", baseDirectory: dir.path)
                #expect(out == "(info.txt)\nhello world\n")
            }
        }

        @Test("prefers the earlier file when several exist")
        func prefersEarlier() throws {
            try withTempDir { dir in
                try write("a.md", "first", in: dir)
                try write("b.md", "second", in: dir)
                let cache = LoadFirstAvailableCache()
                #expect(cache.resolve(args: "a.md,b.md", baseDirectory: dir.path) == "(a.md)\nfirst\n")
            }
        }

        @Test("supports absolute paths and ensures a trailing newline")
        func absolutePath() throws {
            try withTempDir { dir in
                let url = try write("abs.txt", "no newline at end", in: dir)
                let cache = LoadFirstAvailableCache()
                let out = cache.resolve(args: "nope.md,\(url.path)", baseDirectory: dir.path)
                #expect(out == "(\(url.path))\nno newline at end\n")
            }
        }

        @Test("returns an empty string when nothing exists")
        func nothingExists() throws {
            try withTempDir { dir in
                let cache = LoadFirstAvailableCache()
                #expect(cache.resolve(args: "a.md,b.md", baseDirectory: dir.path) == "")
            }
        }

        @Test("skips binary and non-file candidates")
        func skipsNonText() throws {
            try withTempDir { dir in
                try Data([0x68, 0x69, 0x00, 0x21]).write(to: dir.appendingPathComponent("bin.md"))
                try FileManager.default.createDirectory(at: dir.appendingPathComponent("dir.md"), withIntermediateDirectories: false)
                try write("ok.md", "text", in: dir)
                let cache = LoadFirstAvailableCache()
                #expect(cache.resolve(args: "bin.md,dir.md,ok.md", baseDirectory: dir.path) == "(ok.md)\ntext\n")
            }
        }

        @Test("re-reads the picked file when its modification date changes")
        func reReadsOnChange() throws {
            try withTempDir { dir in
                let url = try write("a.md", "v1", in: dir)
                let cache = LoadFirstAvailableCache()
                #expect(cache.resolve(args: "a.md", baseDirectory: dir.path) == "(a.md)\nv1\n")
                try write("a.md", "v2", in: dir)
                try setMtime(Date().addingTimeInterval(120), of: url)
                #expect(cache.resolve(args: "a.md", baseDirectory: dir.path) == "(a.md)\nv2\n")
            }
        }

        @Test("keeps cached contents while the file is unchanged")
        func keepsCache() throws {
            try withTempDir { dir in
                let url = try write("a.md", "original", in: dir)
                let fixed = Date(timeIntervalSince1970: 1_700_000_000)
                try setMtime(fixed, of: url)
                let cache = LoadFirstAvailableCache()
                #expect(cache.resolve(args: "a.md", baseDirectory: dir.path) == "(a.md)\noriginal\n")
                // Rewrite the bytes but keep the same mtime: the cache wins.
                try "sneaky".write(to: url, atomically: false, encoding: .utf8)
                try setMtime(fixed, of: url)
                #expect(cache.resolve(args: "a.md", baseDirectory: dir.path) == "(a.md)\noriginal\n")
            }
        }

        @Test("a higher-priority file appearing later takes over")
        func higherPriorityTakesOver() throws {
            try withTempDir { dir in
                try write("b.md", "fallback", in: dir)
                let cache = LoadFirstAvailableCache()
                #expect(cache.resolve(args: "a.md,b.md", baseDirectory: dir.path) == "(b.md)\nfallback\n")
                try write("a.md", "important", in: dir)
                #expect(cache.resolve(args: "a.md,b.md", baseDirectory: dir.path) == "(a.md)\nimportant\n")
            }
        }

        @Test("falls back when the picked file disappears")
        func fallsBackOnDelete() throws {
            try withTempDir { dir in
                let a = try write("a.md", "primary", in: dir)
                try write("b.md", "backup", in: dir)
                let cache = LoadFirstAvailableCache()
                #expect(cache.resolve(args: "a.md,b.md", baseDirectory: dir.path) == "(a.md)\nprimary\n")
                try FileManager.default.removeItem(at: a)
                #expect(cache.resolve(args: "a.md,b.md", baseDirectory: dir.path) == "(b.md)\nbackup\n")
            }
        }

        @Test("caches per base directory")
        func perBaseDirectory() throws {
            try withTempDir { dir1 in
                try withTempDir { dir2 in
                    try write("a.md", "one", in: dir1)
                    try write("a.md", "two", in: dir2)
                    let cache = LoadFirstAvailableCache()
                    #expect(cache.resolve(args: "a.md", baseDirectory: dir1.path) == "(a.md)\none\n")
                    #expect(cache.resolve(args: "a.md", baseDirectory: dir2.path) == "(a.md)\ntwo\n")
                }
            }
        }
    }
}
