import Foundation
import Testing

@testable import iCanHazAI

extension AllAppTests {

    @Suite("Tree layout")
    struct TreeLayoutTests {

        private let opts = TreeLayoutOptions(nodeWidth: 220, nodeHeight: 84, siblingSpacing: 28, levelSpacing: 56)
        private var unitX: CGFloat { opts.nodeWidth + opts.siblingSpacing }
        private var rowGap: CGFloat { opts.nodeHeight + opts.levelSpacing }

        private func node(_ id: String, _ branches: [TreeNodeData]? = nil) -> TreeNodeData {
            TreeNodeData(
                id: id, role: "assistant", snippet: "snippet", messageCount: 1, isActive: false,
                split: branches.map { TreeSplitData(branches: $0) })
        }

        private func layout(_ root: TreeNodeData) -> TreeLayout {
            TreeLayout(root: root, options: opts)
        }

        private func find(_ layout: TreeLayout, _ id: String) -> TreeLayout.Node {
            layout.nodes.first { $0.data.id == id }!
        }

        private func center(_ n: TreeLayout.Node) -> CGFloat { n.x + opts.nodeWidth / 2 }

        // MARK: - Structure

        @Test("single node: no edges, sized to one card")
        func singleNode() {
            let l = layout(node("root"))
            #expect(l.nodes.count == 1)
            #expect(l.edges.isEmpty)
            #expect(l.width == opts.nodeWidth)
            #expect(l.height == opts.nodeHeight)
        }

        @Test("edges connect every parent to its children")
        func edges() {
            let l = layout(node("root", [node("a", [node("a1")]), node("b")]))
            #expect(l.nodes.count == 4)
            let pairs = l.edges.map { "\(l.nodes[$0.from].data.id)->\(l.nodes[$0.to].data.id)" }.sorted()
            #expect(pairs == ["a->a1", "root->a", "root->b"])
        }

        @Test("children are the split's branches in order, and know their parent")
        func children() {
            let l = layout(node("root", [node("a"), node("b"), node("c")]))
            #expect(l.root.children.map { l.nodes[$0].data.id } == ["a", "b", "c"])
            #expect(l.root.parent == nil)
            for c in l.root.children { #expect(l.nodes[c].parent == 0) }
        }

        // MARK: - Geometry

        @Test("depth maps to rows one level apart")
        func depthRows() {
            let l = layout(node("root", [node("a", [node("a1")])]))
            #expect(find(l, "root").y == 0)
            #expect(find(l, "a").y == rowGap)
            #expect(find(l, "a1").y == rowGap * 2)
        }

        @Test("siblings keep their order and are at least one unit apart")
        func siblingsSeparated() {
            let l = layout(node("root", [node("a"), node("b"), node("c")]))
            let xs = ["a", "b", "c"].map { find(l, $0).x }
            #expect(xs == xs.sorted())
            for i in 1..<xs.count { #expect(xs[i] - xs[i - 1] >= unitX - 1e-6) }
        }

        @Test("a parent is centered over its children")
        func parentCentered() {
            let l = layout(node("root", [node("a"), node("b")]))
            let mid = (center(find(l, "a")) + center(find(l, "b"))) / 2
            #expect(abs(center(find(l, "root")) - mid) < 1e-6)
        }

        @Test("a parent of three children sits over the middle child")
        func parentOverMiddle() {
            let l = layout(node("root", [node("a"), node("b"), node("c")]))
            #expect(abs(center(find(l, "root")) - center(find(l, "b"))) < 1e-6)
        }

        @Test("separate subtrees never overlap horizontally")
        func subtreesDoNotOverlap() {
            func chain(_ p: String) -> TreeNodeData { node("\(p)0", [node("\(p)1", [node("\(p)2")])]) }
            let l = layout(node("root", [chain("l"), chain("r")]))
            for depth in 1...3 {
                let xs = l.nodes.filter { $0.y == CGFloat(depth) * rowGap }.map(\.x).sorted()
                for i in 1..<xs.count { #expect(xs[i] - xs[i - 1] >= unitX - 1e-6) }
            }
        }

        @Test("uneven subtrees stay apart at every level")
        func unevenSubtrees() {
            // A deep left subtree next to a shallow one, and a wide one after it.
            let root = node(
                "root",
                [
                    node("a", [node("a1", [node("a11"), node("a12")]), node("a2")]),
                    node("b"),
                    node("c", [node("c1"), node("c2"), node("c3")]),
                ])
            let l = layout(root)
            let levels = Dictionary(grouping: l.nodes, by: \.y)
            for (_, row) in levels {
                let xs = row.map(\.x).sorted()
                for i in 1..<max(xs.count, 1) { #expect(xs[i] - xs[i - 1] >= unitX - 1e-6) }
            }
            for n in l.nodes where !n.children.isEmpty {
                let first = center(l.nodes[n.children.first!])
                let last = center(l.nodes[n.children.last!])
                #expect(abs(center(n) - (first + last) / 2) < 1e-6)
            }
        }

        @Test("bounds start at 0 and contain every card")
        func bounds() {
            let l = layout(
                node("root", [node("a", [node("a1"), node("a2")]), node("b", [node("b1"), node("b2")])]))
            #expect(l.nodes.map(\.x).min()! == 0)
            #expect(l.nodes.map(\.y).min()! == 0)
            for n in l.nodes {
                #expect(n.x + opts.nodeWidth <= l.width + 1e-6)
                #expect(n.y + opts.nodeHeight <= l.height + 1e-6)
            }
        }

        @Test("a deep linear chain is a straight column")
        func straightColumn() {
            let l = layout(node("root", [node("a", [node("a1", [node("a2")])])]))
            let centers = ["root", "a", "a1", "a2"].map { center(find(l, $0)) }
            for c in centers { #expect(abs(c - centers[0]) < 1e-6) }
        }

        @Test("a tree built from a forked chat lays out its root and branches")
        func fromChat() {
            let user = Fixtures.message(role: .user, content: "q", timestamp: Date(timeIntervalSince1970: 1))
            let a1 = Fixtures.message(role: .assistant, content: "a1", timestamp: Date(timeIntervalSince1970: 2))
            let a2 = Fixtures.message(role: .assistant, content: "a2", timestamp: Date(timeIntervalSince1970: 3))
            let chat = Fixtures.chat(messages: [Fixtures.forking(user, branches: [[a1], [a2]], active: 1)])
            let content = TreeOverviewContent(chat: chat, scale: 1)
            #expect(content.layout?.nodes.count == 3)
            #expect(TreeOverviewContent(chat: Fixtures.chat(messages: []), scale: 1).layout == nil)
        }

        @Test("the interface scale scales the geometry")
        func scaled() {
            let chat = Fixtures.simpleChat()
            let one = TreeOverviewContent(chat: chat, scale: 1).layout!
            let two = TreeOverviewContent(chat: chat, scale: 2).layout!
            #expect(two.width == one.width * 2)
            #expect(two.height == one.height * 2)
        }
    }
}
