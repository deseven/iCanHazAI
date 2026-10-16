import AppKit
import Testing

@testable import iCanHazAI

extension AllAppTests {

    @Suite("Chat row model")
    struct ChatRowModelTests {

        private func assistant(_ id: String = "a1") -> ChatRowModel {
            ChatRendererFixtures.message(id, content: "response")
        }

        private func user(_ id: String = "u1") -> ChatRowModel {
            ChatRendererFixtures.message(id, role: .user, content: "question")
        }

        private let regen = ChatRowFeatures(responseRegen: true)
        private let noRegen = ChatRowFeatures(responseRegen: false)
        private let trees = ChatRowFeatures(responseRegen: true, chatTrees: true)

        // MARK: Regenerate visibility

        @Test("regenerate: offered on a non-first assistant message with the feature on")
        func regenerateOffered() {
            #expect(assistant().canRegenerate(isFirst: false, features: regen, streaming: false))
            #expect(assistant().canRegenerate(isFirst: false, features: trees, streaming: false))
        }

        @Test("regenerate: never on user messages, the first message, or while streaming")
        func regenerateHidden() {
            #expect(!user().canRegenerate(isFirst: false, features: regen, streaming: false))
            #expect(!assistant().canRegenerate(isFirst: true, features: regen, streaming: false))
            #expect(!assistant().canRegenerate(isFirst: true, features: trees, streaming: false))
            #expect(!assistant().canRegenerate(isFirst: false, features: regen, streaming: true))
        }

        @Test("regenerate: needs the role feature")
        func regenerateFeature() {
            #expect(!assistant().canRegenerate(isFirst: false, features: noRegen, streaming: false))
            #expect(!assistant().canRegenerate(isFirst: false, features: ChatRowFeatures(), streaming: false))
        }

        // MARK: Branch switcher

        @Test("the branch switcher shows only for fork members")
        func branchSwitcher() {
            var m = assistant()
            #expect(!m.hasSiblings)
            m.siblings = .init(index: 0, count: 1)
            #expect(!m.hasSiblings)
            m.siblings = .init(index: 1, count: 3)
            #expect(m.hasSiblings)
        }

        // MARK: Pending / streaming

        @Test("a streaming assistant message with nothing in it is pending")
        func pending() {
            let empty = ChatRendererFixtures.message("a")
            #expect(empty.isPending(streaming: true))
            #expect(!empty.isPending(streaming: false))

            #expect(!ChatRendererFixtures.message("a", content: "hi").isPending(streaming: true))
            #expect(!ChatRendererFixtures.message("a", thinking: "hmm").isPending(streaming: true))
            #expect(!ChatRendererFixtures.message("a", error: "boom").isPending(streaming: true))
            #expect(!ChatRendererFixtures.message("a", role: .user).isPending(streaming: true))
            // Whitespace doesn't count as content.
            #expect(ChatRendererFixtures.message("a", content: " \n ").isPending(streaming: true))

            var withCall = empty
            withCall.toolCalls = [.init(id: "c", name: "t", arguments: "{}")]
            #expect(!withCall.isPending(streaming: true))
        }

        @Test("rows depend on the streaming flag only for pending spinners and unfinished calls")
        func dependsOnStreaming() {
            #expect(ChatRendererFixtures.message("a").dependsOnStreaming)
            #expect(!ChatRendererFixtures.message("a", content: "hi").dependsOnStreaming)
            #expect(!ChatRendererFixtures.message("u", role: .user).dependsOnStreaming)

            var m = ChatRendererFixtures.message("a", content: "hi")
            m.toolCalls = [.init(id: "c", name: "t", arguments: "{}")]
            #expect(m.dependsOnStreaming)
            m.toolResults = [.init(callID: "c", content: "ok", isError: false)]
            #expect(!m.dependsOnStreaming)
        }

        // MARK: Attachments

        @Test("document chips explain truncation and failures")
        func chipStatusText() {
            func info(_ status: AttachmentStatus, reason: String? = nil) -> ChatRowModel.AttachmentInfo {
                .init(kind: .document, filename: "f", originalName: "f", status: status, failureReason: reason)
            }
            #expect(info(.truncated).statusText == "truncated to 64 KB")
            #expect(
                info(.failed, reason: "no text layer and OCR unavailable").statusText
                    == "extraction failed: no text layer and OCR unavailable")
            #expect(info(.failed).statusText == "extraction failed")
            #expect(info(.failed, reason: "").statusText == "extraction failed")
            #expect(info(.ok).statusText == nil)
        }

        @Test("attachments fall back to a generic display name")
        func displayName() {
            #expect(ChatRowModel.AttachmentInfo(kind: .image, filename: "f", originalName: nil).displayName == "image")
            #expect(
                ChatRowModel.AttachmentInfo(kind: .text, filename: "f", originalName: nil).displayName == "document")
            #expect(
                ChatRowModel.AttachmentInfo(kind: .text, filename: "f", originalName: "notes.txt").displayName
                    == "notes.txt")
        }

        // MARK: Tool presentation

        @Test("MCP tool names lose their namespace prefix")
        func shortName() {
            #expect(ToolPresentation.shortName("mcp__sheets__read_range") == "read_range")
            #expect(ToolPresentation.shortName("mcp__sheets__a__b") == "a__b")
            #expect(ToolPresentation.shortName("mcp__nope") == "mcp__nope")
            #expect(ToolPresentation.shortName("shell") == "shell")
        }

        @Test("pending approval beats everything")
        func statusPending() {
            let s = ToolPresentation.transientStatus(for: nil, running: false, pending: true)
            #expect(s == .init(kind: .pending, label: "approval", description: ""))
            let streaming = ChatRowModel.ToolResult(callID: "c", content: "partial", isError: false, isStreaming: true)
            #expect(ToolPresentation.transientStatus(for: streaming, running: true, pending: true) == s)
        }

        @Test("running shows the first line of a streaming result")
        func statusRunning() {
            #expect(
                ToolPresentation.transientStatus(for: nil, running: true, pending: false)
                    == .init(kind: .running, label: "running", description: ""))
            let streaming = ChatRowModel.ToolResult(
                callID: "c", content: "\n line one\nline two", isError: false, isStreaming: true)
            #expect(
                ToolPresentation.transientStatus(for: streaming, running: true, pending: false)
                    == .init(kind: .running, label: "running", description: "line one"))
            #expect(ToolPresentation.transientStatus(for: nil, running: false, pending: false) == nil)
        }

        @Test("final results have no transient status; the persisted summary is used")
        func statusFinal() {
            let ok = ChatRowModel.ToolResult(callID: "c", content: "out", isError: false)
            let failed = ChatRowModel.ToolResult(callID: "c", content: "boom", isError: true)
            let denied = ChatRowModel.ToolResult(callID: "c", content: "no", isError: true, isDenied: true)
            for r in [ok, failed, denied] {
                #expect(ToolPresentation.transientStatus(for: r, running: false, pending: false) == nil)
                #expect(ToolPresentation.status(for: r, running: false, pending: false) == nil)
            }
            var persisted = ok
            persisted.summary = .init(kind: .done, label: "done", description: "Read 3 lines.")
            #expect(ToolPresentation.status(for: persisted, running: false, pending: false) == persisted.summary)
        }

        @Test("cancelled results without a summary still get their badge")
        func statusCancelled() {
            let cancelled = ChatRowModel.ToolResult(callID: "c", content: "…", isError: true, isCancelled: true)
            #expect(
                ToolPresentation.status(for: cancelled, running: false, pending: false)
                    == .init(kind: .cancelled, label: "cancelled", description: ""))
            #expect(ToolPresentation.localStatus(for: nil) == nil)
            var streaming = cancelled
            streaming.isStreaming = true
            #expect(ToolPresentation.localStatus(for: streaming) == nil)
        }

        // MARK: Arguments

        @Test("argument entries keep key order and format values")
        func argumentEntries() throws {
            let entries = try #require(
                ToolSummary.argumentEntries(#"{"zebra":"z","apple":42,"on":true,"off":false,"none":null,"pi":3.14}"#))
            #expect(entries.map(\.key) == ["zebra", "apple", "on", "off", "none", "pi"])
            #expect(entries.map(\.value) == ["z", "42", "true", "false", "null", "3.14"])
            #expect(entries.allSatisfy { !$0.multiline })
        }

        @Test("multi-line strings and nested values are multi-line, empty containers are not")
        func argumentEntriesMultiline() throws {
            let entries = try #require(
                ToolSummary.argumentEntries(
                    #"{"text":"a\nb","obj":{"a":1,"b":2},"list":[1,2,3],"emptyList":[],"emptyObj":{}}"#))
            let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
            #expect(byKey["text"]?.value == "a\nb")
            #expect(byKey["text"]?.multiline == true)
            #expect(byKey["obj"]?.multiline == true)
            #expect(byKey["list"]?.multiline == true)
            #expect(byKey["emptyList"]?.value == "[]")
            #expect(byKey["emptyList"]?.multiline == false)
            #expect(byKey["emptyObj"]?.value == "{}")
            #expect(byKey["emptyObj"]?.multiline == false)
        }

        @Test("only JSON objects have argument entries")
        func argumentEntriesInvalid() {
            #expect(ToolSummary.argumentEntries("{}") == [])
            for bad in ["not json", "{broken", "", "[1,2]", "\"str\"", "42", "true", "null"] {
                #expect(ToolSummary.argumentEntries(bad) == nil)
            }
        }

        @Test("empty arguments are blank or an empty object")
        func emptyArgs() {
            for empty in ["", "   \n\t ", "{}", "  {}  "] { #expect(ToolSummary.isEmptyArgs(empty)) }
            for full in [#"{"path":"a"}"#, "null", "[]"] { #expect(!ToolSummary.isEmptyArgs(full)) }
        }

        // MARK: Links

        @Test("only web and mail links are opened")
        func openableLinks() {
            #expect(MarkdownTextView.canOpen(URL(string: "https://example.com")!))
            #expect(MarkdownTextView.canOpen(URL(string: "HTTP://example.com")!))
            #expect(MarkdownTextView.canOpen(URL(string: "mailto:a@b.c")!))
            #expect(!MarkdownTextView.canOpen(URL(string: "ichai://file.png")!))
            #expect(!MarkdownTextView.canOpen(URL(string: "/relative/path")!))
            #expect(!MarkdownTextView.canOpen(URL(string: "file:///etc/passwd")!))
        }
    }
}
