import AppKit
import Testing

@testable import iCanHazAI

extension AllAppTests {

    @Suite("Tool block bodies")
    struct ToolBodyTests {

        private let theme = Theme()

        private func texts(_ segments: [LazyBody.Segment]) -> [RenderedText] {
            segments.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
        }

        private func body(_ m: ChatRowModel) -> [LazyBody.Segment] {
            let r = RenderedMessage.render(m, theme: theme)
            for block in r.blocks {
                if case .collapsible(let c) = block { return c.body.segments }
            }
            return []
        }

        private func message(
            name: String = "some_tool", arguments: String, diff: String? = nil, result: ChatRowModel.ToolResult? = nil
        ) -> ChatRowModel {
            var m = ChatRendererFixtures.message("m")
            m.toolCalls = [.init(id: "c1", name: name, arguments: arguments, summary: nil, diff: diff)]
            if let result { m.toolResults = [result] }
            return m
        }

        @Test("diff lines are classified by prefix; file names before the first hunk are headers")
        func diffClassification() {
            typealias K = DiffLineKind
            #expect(K.classify("@@ -1,2 +1,2 @@", inHeader: false) == .hunk)
            #expect(K.classify("--- a/file", inHeader: true) == .header)
            #expect(K.classify("+++ b/file", inHeader: true) == .header)
            #expect(K.classify("--- removed dashes", inHeader: false) == .removed)
            #expect(K.classify("+++ added pluses", inHeader: false) == .added)
            #expect(K.classify("+new", inHeader: false) == .added)
            #expect(K.classify("-old", inHeader: false) == .removed)
            #expect(K.classify(" same", inHeader: false) == .context)
            #expect(K.classify("", inHeader: false) == .context)
        }

        @Test("a diff is shown monospaced with colored additions and removals")
        func diffBody() throws {
            let diff = "--- a.txt\n+++ a.txt\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n"
            let segments = body(message(name: "write_file", arguments: #"{"path":"a.txt"}"#, diff: diff))
            let text = try #require(texts(segments).first)
            let s = text.string
            #expect(s.string == "Diff\n--- a.txt\n+++ a.txt\n@@ -1,2 +1,2 @@\n keep\n-old\n+new")

            func color(of marker: String) -> NSColor? {
                let r = (s.string as NSString).range(of: marker)
                return s.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor
            }
            #expect(color(of: "+new") == .systemGreen)
            #expect(color(of: "-old") == .systemRed)
            #expect(color(of: "@@") == .secondaryLabelColor)
            #expect(color(of: "--- a.txt") == .secondaryLabelColor)
            #expect(color(of: " keep") == .labelColor)
            let font = s.attribute(.font, at: (s.string as NSString).range(of: "+new").location, effectiveRange: nil)
            #expect((font as? NSFont)?.isFixedPitch == true)
        }

        @Test("arguments render as key lines followed by monospaced values")
        func argumentsBody() throws {
            let segments = body(message(arguments: #"{"path":"a.txt","content":"one\ntwo"}"#))
            let text = try #require(texts(segments).first)
            #expect(text.string.string == "Arguments\npath\na.txt\ncontent\none\u{2028}two")
            let ns = text.string.string as NSString
            let value = text.string.attribute(.font, at: ns.range(of: "a.txt").location, effectiveRange: nil) as? NSFont
            let key = text.string.attribute(.font, at: ns.range(of: "path").location, effectiveRange: nil) as? NSFont
            #expect(value?.isFixedPitch == true)
            #expect(key?.isFixedPitch == false)
        }

        @Test("arguments that aren't a JSON object fall back to raw text; empty arguments show nothing")
        func rawArguments() throws {
            let raw = try #require(texts(body(message(arguments: "{broken"))).first)
            #expect(raw.string.string == "Arguments\n{broken")
            #expect(body(message(arguments: "{}")).isEmpty)
            #expect(body(message(arguments: "")).isEmpty)
        }

        @Test("shell shows its command, with the other arguments as a hint")
        func shellBody() throws {
            let segments = body(message(name: "shell", arguments: #"{"command":"ls -la","cwd":"/tmp","timeout":30}"#))
            let text = try #require(texts(segments).first)
            #expect(text.string.string == "Command  cwd: /tmp · timeout: 30\nls -la")
        }

        @Test("shell without a command falls back to the generic arguments")
        func shellWithoutCommand() throws {
            let segments = body(message(name: "shell", arguments: #"{"cwd":"/tmp"}"#))
            let text = try #require(texts(segments).first)
            #expect(text.string.string == "Arguments\ncwd\n/tmp")
        }

        @Test("results: plain output stays raw, JSON objects become key/value lists, errors are red")
        func resultBodies() throws {
            let plain = body(
                message(arguments: "{}", result: .init(callID: "c1", content: "line 1\nline 2\n", isError: false)))
            #expect(texts(plain).first?.string.string == "Result\nline 1\nline 2")

            let json = body(
                message(arguments: "{}", result: .init(callID: "c1", content: #"{"ok": true, "n": 2}"#, isError: false))
            )
            #expect(texts(json).first?.string.string == "Result\nok\ntrue\nn\n2")

            let failed = body(message(arguments: "{}", result: .init(callID: "c1", content: "boom", isError: true)))
            let s = try #require(texts(failed).first).string
            let at = (s.string as NSString).range(of: "boom").location
            #expect(s.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor == .systemRed)

            let denied = body(
                message(arguments: "{}", result: .init(callID: "c1", content: "denied", isError: true, isDenied: true)))
            let d = try #require(texts(denied).first).string
            let dAt = (d.string as NSString).range(of: "denied").location
            #expect(d.attribute(.foregroundColor, at: dAt, effectiveRange: nil) as? NSColor == .labelColor)
        }

        @Test("a streaming result is labeled as such")
        func streamingResult() {
            let segments = body(
                message(
                    arguments: "{}", result: .init(callID: "c1", content: "so far", isError: false, isStreaming: true)))
            #expect(texts(segments).first?.string.string == "Result (streaming…)\nso far")
        }

        @Test("an image result is split into an image and its fallback text")
        func imageResult() throws {
            let image = ToolResultImage(data: "AAAA", mimeType: "image/png", fallback: "a cat")
            let segments = body(
                message(
                    arguments: #"{"path":"cat.png"}"#,
                    result: .init(callID: "c1", content: "a cat on a sofa", isError: false, image: image)))
            #expect(segments.count == 3)
            guard case .text(let before) = segments[0], case .image(let key, _) = segments[1],
                case .text(let after) = segments[2]
            else {
                Issue.record("expected text, image, text")
                return
            }
            #expect(before.string.string == "Arguments\npath\ncat.png\nImage  vision-capable models")
            #expect(key == "toolresult/c1")
            #expect(after.string.string == "Fallback  vision-incapable models\na cat on a sofa")
        }

        @Test("bodies are built lazily and only once")
        func lazyBody() {
            nonisolated(unsafe) var builds = 0
            let lazy = LazyBody {
                builds += 1
                return []
            }
            #expect(builds == 0)
            _ = lazy.segments
            _ = lazy.segments
            #expect(builds == 1)
        }

        @Test("thinking is plain secondary text, not markdown")
        func thinkingBody() throws {
            let m = ChatRendererFixtures.message("m", thinking: "**not bold** and `not code`")
            let text = try #require(texts(body(m)).first)
            #expect(text.string.string == "**not bold** and `not code`")
            #expect(
                text.string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        }

        @Test("the thinking spinner shows only while nothing else has arrived")
        func thinkingSpinner() {
            func spinner(_ m: ChatRowModel, streaming: Bool) -> Bool {
                let r = RenderedMessage.render(m, theme: theme, streaming: streaming)
                for block in r.blocks {
                    if case .collapsible(let c) = block { return c.showsSpinner }
                }
                return false
            }
            let thinking = ChatRendererFixtures.message("m", thinking: "hmm")
            #expect(spinner(thinking, streaming: true))
            #expect(!spinner(thinking, streaming: false))
            var answered = thinking
            answered.content = "answer"
            #expect(!spinner(answered, streaming: true))
        }

        @Test("running status comes from a missing result while streaming")
        func runningStatus() {
            let m = message(arguments: "{}")
            func status(streaming: Bool) -> ToolSummary.Status.Kind? {
                let r = RenderedMessage.render(m, theme: theme, streaming: streaming)
                for block in r.blocks {
                    if case .collapsible(let c) = block { return c.status?.kind }
                }
                return nil
            }
            #expect(status(streaming: true) == .running)
            #expect(status(streaming: false) == nil)
        }
    }
}
