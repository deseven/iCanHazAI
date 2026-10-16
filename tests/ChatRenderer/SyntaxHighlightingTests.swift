import AppKit
import Testing

@testable import iCanHazAI

extension AllAppTests {

    @Suite("Syntax highlighting")
    struct SyntaxHighlightingTests {

        // MARK: Languages

        @Test("every language has a loadable grammar, a compiling highlight query and hints")
        func languagesAreAvailable() {
            for language in SyntaxLanguage.allCases {
                #expect(SyntaxEngine.isAvailable(language), "\(language) has no grammar or query")
                if language.lightweight == nil {
                    #expect(!(LanguageHints.all[language] ?? []).isEmpty, "\(language) has no detection hints")
                } else {
                    #expect((LanguageHints.all[language] ?? []).isEmpty, "\(language) must not be auto-detected")
                }
            }
        }

        @Test("fence markers resolve through aliases and common decorations")
        func markers() {
            #expect(SyntaxLanguage.from(marker: "python") == .python)
            #expect(SyntaxLanguage.from(marker: "PY") == .python)
            #expect(SyntaxLanguage.from(marker: "c++") == .c)
            #expect(SyntaxLanguage.from(marker: "c#") == .java)
            #expect(SyntaxLanguage.from(marker: "kotlin") == .java)
            #expect(SyntaxLanguage.from(marker: "sql") == .sql)
            #expect(SyntaxLanguage.from(marker: "PostgreSQL") == .sql)
            #expect(SyntaxLanguage.from(marker: "matlab") == .matlab)
            #expect(SyntaxLanguage.from(marker: "perl") == .perl)
            #expect(SyntaxLanguage.from(marker: "r") == .r)
            #expect(SyntaxLanguage.from(marker: "{.r}") == .r)
            #expect(SyntaxLanguage.from(marker: "sh") == .bash)
            #expect(SyntaxLanguage.from(marker: "yml") == .yaml)
            #expect(SyntaxLanguage.from(marker: "jsonc") == .json)
            #expect(SyntaxLanguage.from(marker: "language-go") == .go)
            #expect(SyntaxLanguage.from(marker: "{.rust}") == .rust)
            #expect(SyntaxLanguage.from(marker: "ts:app.ts") == .javascript)
            #expect(SyntaxLanguage.from(marker: "tsx") == .javascript)
            #expect(SyntaxLanguage.from(marker: "swift title=\"a.swift\"") == .swift)
            #expect(SyntaxLanguage.from(marker: "diff") == nil)
            #expect(SyntaxLanguage.from(marker: "mermaid") == nil)
            #expect(SyntaxLanguage.from(marker: "") == nil)
        }

        @Test("close relatives borrow a grammar for colors but are never auto-detected")
        func borrowedGrammars() {
            let kotlin = tokens("fun main() {\n    val s = \"hi\" // note\n}\n", .java)
            #expect(kotlin.contains { $0.0 == "\"hi\"" && $0.1 == .string })
            #expect(kotlin.contains { $0.0 == "// note" && $0.1 == .comment })

            let cpp = tokens("namespace a {\nint f() { return 1; } // one\n}\n", .c)
            #expect(cpp.contains { $0.0 == "return" && $0.1 == .keyword })
            #expect(cpp.contains { $0.0 == "// one" && $0.1 == .comment })

            let ts = tokens("export async function f(id: number) {\n  return `x${id}`; // t\n}\n", .javascript)
            #expect(ts.contains { $0.0 == "return" && $0.1 == .keyword })
            #expect(ts.contains { $0.0 == "// t" && $0.1 == .comment })

            let names = SyntaxLanguage.allCases.map(\.displayName)
            for borrowed in ["kotlin", "c#", "c++", "typescript"] { #expect(!names.contains(borrowed)) }
        }

        @Test("SQL, MATLAB, Perl and R are colored without a grammar, and never auto-detected")
        func lightweightLanguages() {
            let sql = tokens(
                "SELECT name, COUNT(*) AS n -- total\nFROM users WHERE id = 42 AND s = 'it''s' /* x */;", .sql)
            #expect(sql.contains { $0.0 == "SELECT" && $0.1 == .keyword })
            #expect(sql.contains { $0.0 == "COUNT" && $0.1 == .function })
            #expect(sql.contains { $0.0 == "-- total" && $0.1 == .comment })
            #expect(sql.contains { $0.0 == "42" && $0.1 == .constant })
            #expect(sql.contains { $0.0 == "'it''s'" && $0.1 == .string })
            #expect(sql.contains { $0.0 == "/* x */" && $0.1 == .comment })
            #expect(!sql.contains { $0.0 == "name" || $0.0 == "users" })
            #expect(tokens("select 1 from t", .sql).contains { $0.0 == "from" && $0.1 == .keyword })
            #expect(
                tokens("CREATE TABLE t (id INT, v VARCHAR(20))", .sql).contains { $0.0 == "VARCHAR" && $0.1 == .type })

            let matlab = tokens(
                "function y = f(x)\n  y = x' * 2; % twice\n  s = 'a''b';\nend\n%{\nblock\n%}\n", .matlab)
            #expect(matlab.contains { $0.0 == "function" && $0.1 == .keyword })
            #expect(matlab.contains { $0.0 == "% twice" && $0.1 == .comment })
            #expect(matlab.contains { $0.0 == "'a''b'" && $0.1 == .string })
            #expect(matlab.contains { $0.0 == "%{\nblock\n%}" && $0.1 == .comment })
            #expect(!matlab.contains { $0.1 == .string && $0.0.contains("* 2") })

            let perl = tokens("my $x = shift; # c\nsub greet { print \"hi $x\\n\"; }\npackage Foo::Bar;\n", .perl)
            #expect(perl.contains { $0.0 == "my" && $0.1 == .keyword })
            #expect(perl.contains { $0.0 == "shift" && $0.1 == .function })
            #expect(perl.contains { $0.0 == "# c" && $0.1 == .comment })
            #expect(perl.contains { $0.0 == "greet" && $0.1 == .function })
            #expect(perl.contains { $0.0 == "Foo::Bar" && $0.1 == .type })
            #expect(perl.contains { $0.0.hasPrefix("\"hi") && $0.1 == .string })
            #expect(!perl.contains { $0.0 == "x" || $0.0 == "$x" })

            let r = tokens("f <- function(x, na.rm = TRUE) {\n  if (is.na(x)) NULL else mean(x) # avg\n}\n", .r)
            #expect(r.contains { $0.0 == "function" && $0.1 == .keyword })
            #expect(r.contains { $0.0 == "TRUE" && $0.1 == .constant })
            #expect(r.contains { $0.0 == "is.na" && $0.1 == .function })
            #expect(r.contains { $0.0 == "# avg" && $0.1 == .comment })
            #expect(!r.contains { $0.0 == "na" || $0.0 == "na.rm" })

            #expect(LanguageDetector.detect("SELECT id, name FROM users WHERE id = 1;") == nil)
            for code in [
                "my $x = 1;\nprint $x;\n", "x <- c(1, 2, 3)\nmean(x)\n", "SELECT a FROM b;",
                "Dim x As Integer\nx = 1\n", "program p\n  implicit none\nend program p\n",
                "begin\n  writeln('hi');\nend.\n",
            ] {
                let detected = LanguageDetector.detect(code)
                #expect(detected?.lightweight == nil, "\(code) was detected as \(String(describing: detected))")
                #expect(LanguageDetector.candidates(in: code).allSatisfy { $0.language.lightweight == nil })
            }
        }

        @Test("Visual Basic, Fortran and Pascal are colored without a grammar")
        func moreLightweightLanguages() {
            #expect(SyntaxLanguage.from(marker: "vb.net") == .vb)
            #expect(SyntaxLanguage.from(marker: "vba") == .vb)
            #expect(SyntaxLanguage.from(marker: "f90") == .fortran)
            #expect(SyntaxLanguage.from(marker: "delphi") == .pascal)
            #expect(SyntaxLanguage.from(marker: "pas") == .pascal)

            let vb = tokens(
                "Public Function Add(a As Integer) As Integer ' sum\n    Return a & \"x\"\"y\"\nEnd Function\nIf x Is Nothing Then\n",
                .vb)
            #expect(vb.contains { $0.0 == "Public" && $0.1 == .keyword })
            #expect(vb.contains { $0.0 == "Add" && $0.1 == .function })
            #expect(vb.contains { $0.0 == "Integer" && $0.1 == .type })
            #expect(vb.contains { $0.0 == "' sum" && $0.1 == .comment })
            #expect(vb.contains { $0.0 == "\"x\"\"y\"" && $0.1 == .string })
            #expect(vb.contains { $0.0 == "Nothing" && $0.1 == .constant })
            // `End Function` must not turn the next line's first word into a function name.
            #expect(vb.contains { $0.0 == "If" && $0.1 == .keyword })
            #expect(!vb.contains { $0.0 == "x" && $0.1 == .function })

            let fortran = tokens(
                "program p\n  integer :: i ! count\n  if (i .gt. 1.and.x) print *, 'hi', 1.5e-3, .true.\nend program p\n",
                .fortran)
            #expect(fortran.contains { $0.0 == "program" && $0.1 == .keyword })
            #expect(fortran.contains { $0.0 == "integer" && $0.1 == .type })
            #expect(fortran.contains { $0.0 == "! count" && $0.1 == .comment })
            #expect(fortran.contains { $0.0 == ".gt." && $0.1 == .keyword })
            #expect(fortran.contains { $0.0 == ".and." && $0.1 == .keyword })
            #expect(fortran.contains { $0.0 == "1" && $0.1 == .constant })
            #expect(fortran.contains { $0.0 == ".true." && $0.1 == .constant })
            #expect(fortran.contains { $0.0 == "1.5e-3" && $0.1 == .constant })
            #expect(fortran.contains { $0.0 == "'hi'" && $0.1 == .string })

            let pascal = tokens(
                "program Hello;\n{ note }\n(* other *)\nvar s: string; // tail\nbegin\n  s := 'it''s';\nend.\n",
                .pascal)
            #expect(pascal.contains { $0.0 == "program" && $0.1 == .keyword })
            #expect(pascal.contains { $0.0 == "Hello" && $0.1 == .type })
            #expect(pascal.contains { $0.0 == "{ note }" && $0.1 == .comment })
            #expect(pascal.contains { $0.0 == "(* other *)" && $0.1 == .comment })
            #expect(pascal.contains { $0.0 == "// tail" && $0.1 == .comment })
            #expect(pascal.contains { $0.0 == "string" && $0.1 == .type })
            #expect(pascal.contains { $0.0 == "'it''s'" && $0.1 == .string })
            #expect(pascal.contains { $0.0 == "begin" && $0.1 == .keyword })
        }

        @Test("lightweight spans are sorted, non-overlapping, inside the source and UTF-16 aligned")
        func lightweightSpans() throws {
            let code = "SELECT '😀😀' AS x -- é\nFROM t /* unterminated"
            let spans = try #require(SyntaxEngine.highlight(code, language: .sql))
            var end = 0
            for span in spans {
                #expect(span.range.location >= end)
                #expect(span.range.length > 0)
                end = NSMaxRange(span.range)
            }
            #expect(end <= (code as NSString).length)
            #expect(tokens(code, .sql).contains { $0.0 == "'😀😀'" && $0.1 == .string })
            #expect(tokens(code, .sql).contains { $0.0 == "/* unterminated" && $0.1 == .comment })
        }

        @Test("capture names map onto tokens by their leading components")
        func classification() {
            #expect(SyntaxToken.classify(["keyword", "return"]) == .token(.keyword))
            #expect(SyntaxToken.classify(["function", "method", "call"]) == .token(.function))
            #expect(SyntaxToken.classify(["string", "escape"]) == .token(.constant))
            #expect(SyntaxToken.classify(["variable"]) == .plain)
            #expect(SyntaxToken.classify(["variable", "builtin"]) == .token(.constant))
            #expect(SyntaxToken.classify(["spell"]) == .ignore)
            #expect(SyntaxToken.classify(["_helper"]) == .ignore)
        }

        // MARK: Highlighting

        private func tokens(_ code: String, _ language: SyntaxLanguage) -> [(String, SyntaxToken)] {
            let ns = code as NSString
            return (SyntaxEngine.highlight(code, language: language) ?? []).map {
                (ns.substring(with: $0.range), $0.token)
            }
        }

        @Test("spans are sorted, non-overlapping and inside the source")
        func spanInvariants() throws {
            let code = "def f(x):\n    # note\n    return \"a\" + str(x)\n"
            let spans = try #require(SyntaxEngine.highlight(code, language: .python))
            #expect(!spans.isEmpty)
            var end = 0
            for span in spans {
                #expect(span.range.location >= end)
                #expect(span.range.length > 0)
                end = NSMaxRange(span.range)
            }
            #expect(end <= (code as NSString).length)
        }

        @Test("keywords, strings, numbers and comments get their tokens")
        func basicTokens() {
            let py = tokens("def f():\n    return \"hi\"  # done\n", .python)
            #expect(py.contains { $0.0 == "def" && $0.1 == .keyword })
            #expect(py.contains { $0.0 == "\"hi\"" && $0.1 == .string })
            #expect(py.contains { $0.0 == "# done" && $0.1 == .comment })

            let swift = tokens("let answer = 42 // yes\n", .swift)
            #expect(swift.contains { $0.0 == "let" && $0.1 == .keyword })
            #expect(swift.contains { $0.0 == "42" && $0.1 == .constant })
            #expect(swift.contains { $0.0.hasPrefix("// yes") && $0.1 == .comment })
        }

        @Test("spans stay aligned with UTF-16 offsets after non-BMP characters")
        func utf16Offsets() {
            let t = tokens("x = \"😀😀\"  # é\ny = 1\n", .python)
            #expect(t.contains { $0.0 == "\"😀😀\"" && $0.1 == .string })
            #expect(t.contains { $0.0 == "# é" && $0.1 == .comment })
        }

        @Test("oversized sources are left unhighlighted")
        func sizeCap() {
            let code = String(repeating: "x = 1\n", count: SyntaxEngine.maxHighlightLength)
            #expect(SyntaxEngine.highlight(code, language: .python) == nil)
        }

        @Test("parse quality: clean code has no errors, foreign code has some")
        func errorRatio() throws {
            let python = "def f(x):\n    return x + 1\n"
            #expect(SyntaxEngine.errorRatio(python, language: .python) == 0)
            let wrong = try #require(SyntaxEngine.errorRatio(python, language: .rust))
            #expect(wrong > 0)
        }

        // MARK: Detection

        static let samples: [(SyntaxLanguage, String)] = [
            (
                .python,
                """
                import os

                def main(path):
                    for name in os.listdir(path):
                        print(name)

                if __name__ == "__main__":
                    main(".")
                """
            ),
            (
                .javascript,
                """
                const fs = require('fs');
                function read(path) {
                  return fs.readFileSync(path, 'utf8');
                }
                console.log(read('a.txt'));
                """
            ),
            (
                .java,
                """
                package com.example;

                public class Main {
                    public static void main(String[] args) {
                        System.out.println("hi");
                    }
                }
                """
            ),
            (
                .c,
                """
                #include <stdio.h>

                int main(void) {
                    printf("hello\\n");
                    return 0;
                }
                """
            ),
            (
                .go,
                """
                package main

                import "fmt"

                func main() {
                    if err := run(); err != nil {
                        fmt.Println(err)
                    }
                }
                """
            ),
            (
                .rust,
                """
                use std::collections::HashMap;

                fn main() {
                    let mut m: HashMap<String, i32> = HashMap::new();
                    m.insert("a".to_string(), 1);
                    println!("{:?}", m);
                }
                """
            ),
            (
                .swift,
                """
                import Foundation

                struct Point {
                    var x: Int
                    func doubled() -> Int {
                        guard let y = Optional(x) else { return 0 }
                        return y * 2
                    }
                }
                """
            ),
            (
                .php,
                """
                <?php
                class Foo {
                    public function bar($x) {
                        return $this->baz($x);
                    }
                }
                """
            ),
            (
                .ruby,
                """
                class Greeter
                  attr_reader :name

                  def initialize(name)
                    @name = name
                  end

                  def hi
                    puts "hi #{name}"
                  end
                end
                """
            ),
            (
                .bash,
                """
                #!/bin/bash
                set -e
                for f in *.txt; do
                  echo "$f"
                done
                """
            ),
            (
                .bash,
                """
                cd /tmp
                mkdir -p build
                export PATH="$HOME/bin:$PATH"
                git status | grep modified
                """
            ),
            (
                .html,
                """
                <!DOCTYPE html>
                <html>
                <body>
                  <p>hi</p>
                </body>
                </html>
                """
            ),
            (
                .css,
                """
                .card {
                  margin: 0 auto;
                  padding: 8px;
                  display: flex;
                }
                """
            ),
            (
                .json,
                """
                {
                  "name": "demo",
                  "version": 1,
                  "tags": ["a", "b"]
                }
                """
            ),
            (
                .yaml,
                """
                name: build
                on:
                  push:
                    branches: [main]
                jobs:
                  test:
                    runs-on: ubuntu-latest
                """
            ),
            (
                .toml,
                """
                [package]
                name = "demo"
                version = "0.1.0"

                [dependencies]
                serde = "1"
                """
            ),
            (
                .lua,
                """
                local function add(a, b)
                  return a + b
                end
                for i, v in ipairs({1, 2}) do
                  print(add(i, v))
                end
                """
            ),
        ]

        @Test("detection finds the language of typical snippets", arguments: SyntaxHighlightingTests.samples)
        func detects(language: SyntaxLanguage, code: String) {
            #expect(LanguageDetector.detect(code) == language)
        }

        @Test("prose and plain output are not mistaken for code")
        func rejectsProse() {
            #expect(
                LanguageDetector.detect(
                    """
                    This is just a paragraph of text.
                    It talks about things: apples, pears.
                    Nothing here is code at all, really.
                    The end.
                    """) == nil)
            #expect(
                LanguageDetector.detect(
                    """
                    total 8
                    drwxr-xr-x  3 me  staff   96 Oct 16 12:00 build
                    -rw-r--r--  1 me  staff  120 Oct 16 12:00 notes
                    """) == nil)
        }

        @Test("a shebang or doctype decides without any parsing")
        func definitive() {
            #expect(LanguageDetector.definitiveSignal("#!/usr/bin/env python3\nprint(1)") == .python)
            #expect(LanguageDetector.definitiveSignal("#!/bin/zsh\nls") == .bash)
            #expect(LanguageDetector.definitiveSignal("<?php echo 1;") == .php)
            #expect(LanguageDetector.definitiveSignal("<!doctype html><p>") == .html)
            #expect(LanguageDetector.definitiveSignal("[1, 2, 3]") == .json)
            #expect(LanguageDetector.definitiveSignal("[section]\nkey = 1") == nil)
        }

        @Test("a cancelled detection gives up")
        func cancelled() {
            let (_, code) = Self.samples[0]
            #expect(LanguageDetector.detect(code, isCancelled: { true }) == nil)
        }

        @Test("blank or oversized unlabeled code is not worth detecting")
        func detectable() {
            #expect(!SyntaxHighlighter.isDetectable(""))
            #expect(!SyntaxHighlighter.isDetectable(" \n\n "))
            #expect(SyntaxHighlighter.isDetectable("a"))
            #expect(SyntaxHighlighter.isDetectable("a\nb\nc\nd"))
            #expect(!SyntaxHighlighter.isDetectable(String(repeating: "a", count: SyntaxEngine.maxHighlightLength + 1)))
        }

        @Test("short hello-world snippets are detected")
        func shortSnippets() {
            #expect(LanguageDetector.detect("def greet(name):\n    print(f\"Hello, {name}!\")") == .python)
            #expect(
                LanguageDetector.detect("function greet(name) {\n  console.log(`Hello, ${name}!`);\n}") == .javascript)

            #expect(LanguageDetector.detect("<?php\necho \"Hello, World!\";\n?>") == .php)
            #expect(LanguageDetector.detect("fn main() {\n    println!(\"Hello, World!\");\n}") == .rust)
        }

        @Test("detection results are cached, including 'nothing found'")
        func cache() async throws {
            let code = "just\nsome\nplain\nwords here\n(unique \(UUID()))"
            #expect(SyntaxHighlighter.shared.cached(code, language: nil) == nil)
            let result = try #require(await SyntaxHighlighter.shared.detect(code))
            #expect(result.language == nil)
            #expect(SyntaxHighlighter.shared.cached(code, language: nil) != nil)
        }

        // MARK: Renderer

        private let theme = Theme()

        private func render(_ markdown: String) -> RenderedText {
            MarkdownRenderer.render(markdown, theme: theme)
        }

        private func color(at index: Int, in text: RenderedText) -> NSColor? {
            text.string.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
        }

        @Test("a labeled block is highlighted while building; the text is unchanged")
        func labeledBlock() throws {
            let text = render("```python\ndef f():\n    return 1\n```")
            #expect(text.string.string == "def f():\u{2028}    return 1")
            let keyword = try #require(color(at: 0, in: text))
            #expect(keyword === SyntaxTheme.color(for: .keyword))
            let marker = try #require(text.codeBlocks.first)
            #expect(marker.code == "def f():\n    return 1")
            #expect(!marker.needsDetection)
            #expect(marker.label == "python")
        }

        @Test("an unsupported label stays plain and is never detected")
        func unsupportedLabel() throws {
            let text = render("```diff\n- a\n+ b\n+ c\n+ d\n```")
            let marker = try #require(text.codeBlocks.first)
            #expect(!marker.needsDetection)
            #expect(marker.label == "diff")
            #expect(color(at: 0, in: text) == NSColor.labelColor)
        }

        @Test("unlabeled code waits for detection, blank code does not")
        func unlabeledBlock() throws {
            let long = render("```\na\nb\nc\nd\n```")
            let marker = try #require(long.codeBlocks.first)
            #expect(marker.needsDetection)
            #expect(marker.label == "code")

            let blank = try #require(render("```\n \n```").codeBlocks.first)
            #expect(!blank.needsDetection)
        }

        @Test("a cached detection is applied right away, with its label")
        func cachedDetection() async throws {
            let code = "def f(x):\n    y = x + 1\n    return y\n\nprint(f(1))"
            let first = render("```\n\(code)\n```")
            let firstMarker = try #require(first.codeBlocks.first)
            #expect(firstMarker.needsDetection)

            let detected = try #require(await SyntaxHighlighter.shared.detect(code))
            #expect(detected.language == .python)

            let second = render("```\n\(code)\n```")
            let marker = try #require(second.codeBlocks.first)
            #expect(!marker.needsDetection)
            #expect(marker.label == "python")
            #expect(color(at: 0, in: second) === SyntaxTheme.color(for: .keyword))
        }

        // MARK: View

        @MainActor
        private func shownView(_ markdown: String, width: CGFloat = 400) -> (MarkdownTextView, RenderedText) {
            let text = render(markdown)
            let view = MarkdownTextView()
            view.theme = theme
            view.frame = NSRect(x: 0, y: 0, width: width, height: text.height(forWidth: width))
            view.setRenderedIfNeeded(text, width: width)
            return (view, text)
        }

        @Test("each code block gets a copy button in the top right of its header")
        @MainActor
        func copyButtons() throws {
            let (view, _) = shownView("```py\nx = 1\n```\n\ntext\n\n```\nsecond\n```")
            let buttons = view.subviews.compactMap { $0 as? CodeCopyButton }.filter { !$0.isHidden }
            #expect(buttons.count == 2)
            let first = try #require(buttons.first)
            #expect(first.frame.maxX < view.bounds.width)
            #expect(first.frame.maxX > view.bounds.width - 30)
            // The first block's box starts at the top of the view; its header is `topInset` tall.
            #expect(first.frame.minY >= 0)
            #expect(first.frame.maxY <= view.topInset)
            #expect(buttons[1].frame.minY > first.frame.maxY)
        }

        @Test("the copy button puts the block's source on the pasteboard")
        @MainActor
        func copyAction() throws {
            let (view, _) = shownView("```swift\nlet a = 1\nlet b = 2\n```")
            let button = try #require(view.subviews.compactMap { $0 as? CodeCopyButton }.first)
            let pasteboard = NSPasteboard.general
            let saved = pasteboard.string(forType: .string)
            defer {
                pasteboard.clearContents()
                if let saved { pasteboard.setString(saved, forType: .string) }
            }
            button.performClick(nil)
            #expect(pasteboard.string(forType: .string) == "let a = 1\nlet b = 2")
        }

        @Test("a view reused for text without code hides its copy buttons")
        @MainActor
        func copyButtonsHidden() {
            let (view, _) = shownView("```\ncode\n```")
            let plain = render("just text")
            view.setRenderedIfNeeded(plain, width: 400)
            let visible = view.subviews.compactMap { $0 as? CodeCopyButton }.filter { !$0.isHidden }
            #expect(visible.isEmpty)
        }

        @Test("unlabeled code is colored in the background, without touching the text")
        @MainActor
        func backgroundDetection() async throws {
            let code =
                "fn area(w: u32, h: u32) -> u32 {\n    let a = w * h; // unique \(UUID())\n    a\n}\nfn main() {}"
            let (view, text) = shownView("```\n\(code)\n```")
            let storage = try #require(view.textStorage)
            let before = storage.string
            #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.labelColor)

            for _ in 0..<100 {
                if (storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                    === SyntaxTheme.color(for: .keyword)
                {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(
                (storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                    === SyntaxTheme.color(for: .keyword))
            #expect(storage.string == before)
            let marker = try #require(text.codeBlocks.first)
            #expect(marker.label == "rust")
        }

        @Test("replacing the text cancels a pending detection")
        @MainActor
        func detectionCancelled() async throws {
            let code =
                "fn area(w: u32, h: u32) -> u32 {\n    let a = w * h; // unique \(UUID())\n    a\n}\nfn main() {}"
            let (view, _) = shownView("```\n\(code)\n```")
            view.setRenderedIfNeeded(render("replacement"), width: 400)
            try await Task.sleep(for: .milliseconds(600))
            let storage = try #require(view.textStorage)
            #expect(storage.string == "replacement")
            #expect(SyntaxHighlighter.shared.cached(code, language: nil) == nil)
        }

        @Test("every code block reserves its header row and is listed for the copy button")
        func codeBlocksAreListed() {
            let text = render("```\ncode\n```\n\ntext\n\n```py\nx = 1\n```")
            #expect(text.codeBlocks.count == 2)
            #expect(text.topInset == theme.codePadV + theme.codeLabelHeight)
            #expect(render("no code").codeBlocks.isEmpty)
        }
    }
}
