import AppKit
import Testing

@testable import iCanHazAI

extension AllAppTests {

    @MainActor
    @Suite("Chat search")
    struct ChatSearchTests {

        @Test("matching ignores case and diacritics and doesn't overlap")
        func ranges() {
            #expect(ChatSearch.ranges(of: "cafe", in: "Café CAFE cafe").map(\.location) == [0, 5, 10])
            #expect(
                ChatSearch.ranges(of: "aa", in: "aaaaa") == [
                    NSRange(location: 0, length: 2), NSRange(location: 2, length: 2),
                ])
            #expect(ChatSearch.ranges(of: "", in: "abc").isEmpty)
            #expect(ChatSearch.ranges(of: "x", in: "abc").isEmpty)
        }

        @Test("only the body of user and assistant messages is searchable")
        func searchable() {
            let f = ChatRendererFixtures.self
            #expect(ChatSearch.isSearchable(f.message("a", role: .assistant, content: "needle")))
            #expect(ChatSearch.isSearchable(f.message("u", role: .user, content: "needle")))
            #expect(!ChatSearch.isSearchable(f.message("t", role: .tool, content: "needle")))
            #expect(!ChatSearch.isSearchable(f.message("s", role: .system, content: "needle")))
            #expect(!ChatSearch.isSearchable(f.message("e", content: "", thinking: "needle", error: "needle")))
        }

        @Test("matches are found in the rendered text, not the markdown source")
        func renderedText() {
            let text = ChatSearch.renderedText("a **nee**dle and [link](https://x.test/needle)", theme: Theme())
            #expect(ChatSearch.ranges(of: "needle", in: text).count == 1)
            #expect(!text.contains("https"))
        }

        @Test("stepping wraps around in both directions")
        func stepping() async {
            let index = ChatSearchIndex()
            _ = index.setQuery("ab")
            let inputs = [SearchRowInput(id: "r1", content: "ab ab"), SearchRowInput(id: "r2", content: "xx ab")]
            let ok = await index.refresh(
                inputs: inputs, theme: Theme(), rowIndex: ["r1": 0, "r2": 1], anchor: (0, 0))
            #expect(ok)
            #expect(index.matches.count == 3)
            #expect(index.current == 0)
            index.step(-1)
            #expect(index.current == 2)
            index.step(1)
            #expect(index.current == 0)
            #expect(
                index.highlight(forRow: "r1")
                    == SearchHighlight(ranges: index.matches.prefix(2).map(\.range), current: 0))
            #expect(index.highlight(forRow: "r2")?.current == nil)
        }

        @Test("the current match is the first one at or after the anchor")
        func anchor() async {
            let index = ChatSearchIndex()
            _ = index.setQuery("ab")
            let inputs = [SearchRowInput(id: "r1", content: "ab"), SearchRowInput(id: "r2", content: "ab ab")]
            let rowIndex = ["r1": 0, "r2": 1]
            _ = await index.refresh(inputs: inputs, theme: Theme(), rowIndex: rowIndex, anchor: (1, 1))
            #expect(index.current == 2)
            _ = await index.refresh(inputs: inputs, theme: Theme(), rowIndex: rowIndex, anchor: (1, 4))
            #expect(index.current == 0)
        }

        // MARK: In the list

        @MainActor
        private struct Harness {
            let window: NSWindow
            let list: ChatListView

            init(width: CGFloat = 900, height: CGFloat = 800) {
                window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                list = ChatListView(frame: NSRect(x: 0, y: 0, width: width, height: height))
                window.contentView = list
                list.layoutSubtreeIfNeeded()
            }

            func waitForStatus(_ ok: (ChatSearchStatus) -> Bool) async -> Bool {
                var waited = 0.0
                while !ok(list.testSearchStatus), waited < 10 {
                    try? await Task.sleep(for: .milliseconds(30))
                    waited += 0.03
                }
                return ok(list.testSearchStatus)
            }
        }

        private func chat() -> [ChatRowModel] {
            var rows = ChatRendererFixtures.chat(300)
            rows[100] = ChatRendererFixtures.message("a-100", content: "the zebra is here")
            rows[250] = ChatRendererFixtures.message("a-250", content: "another ZEBRA there")
            rows[40] = ChatRendererFixtures.message("a-40", content: "no match", thinking: "zebra", error: "zebra")
            rows[41] = ChatRendererFixtures.message("t-41", role: .tool, content: "zebra")
            return rows
        }

        @Test("a query finds matches in message bodies only and scrolls to the first one")
        func queryInList() async {
            let h = Harness()
            h.list.setMessages(chat())
            h.list.setSearchQuery("zebra")
            #expect(await h.waitForStatus { $0.count == 2 })
            #expect(h.list.testSearchStatus.current == 0)
            #expect(h.list.testSearchMatches.map(\.rowID) == ["a-100", "a-250"])
            #expect(h.list.testCurrentMatchVisible)
            #expect(h.list.testViewHighlight["a-100"]?.current == 0)
        }

        @Test("next and previous move through matches and wrap")
        func navigation() async {
            let h = Harness()
            h.list.setMessages(chat())
            h.list.setSearchQuery("zebra")
            _ = await h.waitForStatus { $0.count == 2 }
            h.list.stepSearch(1)
            #expect(h.list.testSearchStatus.current == 1)
            #expect(h.list.testCurrentMatchVisible)
            #expect(h.list.testViewHighlight["a-250"]?.current == 0)
            h.list.stepSearch(1)
            #expect(h.list.testSearchStatus.current == 0)
            #expect(h.list.testCurrentMatchVisible)
            h.list.stepSearch(-1)
            #expect(h.list.testSearchStatus.current == 1)
        }

        @Test("an empty query and a query without matches report nothing to show")
        func noMatches() async {
            let h = Harness()
            h.list.setMessages(chat())
            h.list.setSearchQuery("zebra")
            _ = await h.waitForStatus { $0.count == 2 }
            h.list.setSearchQuery("")
            #expect(h.list.testSearchStatus == ChatSearchStatus())
            #expect(h.list.testViewHighlight.isEmpty)
            h.list.setSearchQuery("qqqqq")
            #expect(await h.waitForStatus { $0.count == 0 })
            #expect(h.list.testSearchStatus.current == nil)
        }

        @Test("matches follow the content when a message changes")
        func contentChanges() async {
            let h = Harness()
            h.list.setMessages(chat())
            h.list.setSearchQuery("zebra")
            _ = await h.waitForStatus { $0.count == 2 }
            h.list.update(ChatRendererFixtures.message("a-100", content: "zebra zebra zebra"))
            #expect(await h.waitForStatus { $0.count == 4 })
            h.list.delete(id: "a-250")
            #expect(await h.waitForStatus { $0.count == 3 })
        }
    }
}
