import Foundation
import Testing
@testable import iCanHazAI

// Unit tests for the prompt variable helper ([`PromptVariables`](src/PromptVariables.swift)):
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
    }
}
