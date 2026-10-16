// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreGraphics

/// Geometry shared by every node of the tree overview (fixed card size and spacing).
struct TreeLayoutOptions: Equatable, Sendable {
    var nodeWidth: CGFloat
    var nodeHeight: CGFloat
    /// Horizontal gap between sibling subtrees.
    var siblingSpacing: CGFloat
    /// Vertical gap between a parent's bottom and its children's top.
    var levelSpacing: CGFloat
}

/// Tidy-tree layout of the chat tree overview.
///
/// Implements the Buchheim–Jünger–Lepert algorithm ("Improving Walker's
/// Algorithm to Run in Linear Time", 2002). Nodes are stored flat in pre-order:
/// index 0 is the root, and every node's children come after it.
struct TreeLayout: Sendable {
    struct Node: Sendable {
        let data: TreeNodeData
        /// Left edge of the card; the leftmost card sits at 0.
        let x: CGFloat
        /// Top edge of the card; the root sits at 0.
        let y: CGFloat
        let parent: Int?
        /// Indices of the branch heads of this node's split, in order.
        let children: [Int]
    }

    struct Edge: Equatable, Sendable {
        let from: Int
        let to: Int
    }

    let options: TreeLayoutOptions
    let nodes: [Node]
    let edges: [Edge]
    /// Bounds of all cards, without any padding.
    let width: CGFloat
    let height: CGFloat

    init(root: TreeNodeData, options: TreeLayoutOptions) {
        var data: [TreeNodeData] = []
        var parents: [Int?] = []
        var children: [[Int]] = []
        Self.flatten(root, parent: nil, data: &data, parents: &parents, children: &children)

        var solver = Solver(parents: parents, children: children)
        solver.run()

        var minX = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var maxDepth = 0
        for i in data.indices {
            minX = min(minX, solver.x[i])
            maxX = max(maxX, solver.x[i])
            maxDepth = max(maxDepth, solver.depth[i])
        }
        let unitX = options.nodeWidth + options.siblingSpacing
        let unitY = options.nodeHeight + options.levelSpacing

        self.options = options
        self.nodes = data.indices.map { i in
            Node(
                data: data[i],
                x: (solver.x[i] - minX) * unitX,
                y: CGFloat(solver.depth[i]) * unitY,
                parent: parents[i],
                children: children[i])
        }
        self.edges = data.indices.flatMap { i in children[i].map { Edge(from: i, to: $0) } }
        self.width = (maxX - minX) * unitX + options.nodeWidth
        self.height = CGFloat(maxDepth + 1) * unitY - options.levelSpacing
    }

    var root: Node { nodes[0] }

    @discardableResult
    private static func flatten(
        _ node: TreeNodeData,
        parent: Int?,
        data: inout [TreeNodeData],
        parents: inout [Int?],
        children: inout [[Int]]
    ) -> Int {
        let index = data.count
        data.append(node)
        parents.append(parent)
        children.append([])
        var childIndices: [Int] = []
        for branch in node.split?.branches ?? [] {
            childIndices.append(flatten(branch, parent: index, data: &data, parents: &parents, children: &children))
        }
        children[index] = childIndices
        return index
    }
}

/// The algorithm's workspace, indexed like `TreeLayout.nodes`. `-1` stands for
/// "no node".
private struct Solver {
    /// Sibling separation in preliminary units (scaled to pixels afterwards).
    static let distance: CGFloat = 1

    let parent: [Int]
    let children: [[Int]]
    /// Position among the siblings.
    let index: [Int]

    /// Preliminary x, relative to the parent's `mod`.
    var prelim: [CGFloat]
    /// Shift applied to the whole subtree below the node.
    var mod: [CGFloat]
    var change: [CGFloat]
    var shift: [CGFloat]
    /// Link to the next node of a subtree contour that has no children.
    var thread: [Int]
    var ancestor: [Int]

    /// Results: center x in sibling units and depth in levels.
    var x: [CGFloat]
    var depth: [Int]

    init(parents: [Int?], children: [[Int]]) {
        let n = children.count
        self.children = children
        self.parent = parents.map { $0 ?? -1 }
        var index = [Int](repeating: 0, count: n)
        for siblings in children {
            for (i, child) in siblings.enumerated() { index[child] = i }
        }
        self.index = index
        prelim = [CGFloat](repeating: 0, count: n)
        mod = prelim
        change = prelim
        shift = prelim
        x = prelim
        thread = [Int](repeating: -1, count: n)
        ancestor = Array(0..<n)
        depth = [Int](repeating: 0, count: n)
    }

    mutating func run() {
        firstWalk(0)
        secondWalk(0, mod: -prelim[0], depth: 0)
    }

    private func nextLeft(_ v: Int) -> Int {
        children[v].first ?? thread[v]
    }

    private func nextRight(_ v: Int) -> Int {
        children[v].last ?? thread[v]
    }

    private func leftSibling(_ v: Int) -> Int? {
        let p = parent[v]
        guard p >= 0, index[v] > 0 else { return nil }
        return children[p][index[v] - 1]
    }

    /// Post-order: preliminary x plus the mod/ancestor/thread bookkeeping that
    /// resolves conflicts between subtrees.
    private mutating func firstWalk(_ v: Int) {
        let kids = children[v]
        guard let firstChild = kids.first, let lastChild = kids.last else {
            prelim[v] = leftSibling(v).map { prelim[$0] + Self.distance } ?? 0
            return
        }

        var defaultAncestor = firstChild
        for child in kids {
            firstWalk(child)
            defaultAncestor = apportion(child, defaultAncestor)
        }
        executeShifts(v)

        let midpoint = (prelim[firstChild] + prelim[lastChild]) / 2
        if let left = leftSibling(v) {
            prelim[v] = prelim[left] + Self.distance
            mod[v] = prelim[v] - midpoint
        } else {
            prelim[v] = midpoint
        }
    }

    /// Resolves spacing conflicts between the subtree of `w` and the subtrees of
    /// its earlier siblings by shifting `w`'s subtree right. Returns the default
    /// ancestor for the next sibling.
    private mutating func apportion(_ w: Int, _ defaultAncestor: Int) -> Int {
        guard let left = leftSibling(w) else { return defaultAncestor }

        var vInnerRight = w
        var vOuterRight = w
        var vInnerLeft = left
        var vOuterLeft = children[parent[w]][0]
        var sInnerRight = mod[vInnerRight]
        var sOuterRight = mod[vOuterRight]
        var sInnerLeft = mod[vInnerLeft]
        var sOuterLeft = mod[vOuterLeft]

        while nextRight(vInnerLeft) >= 0 && nextLeft(vInnerRight) >= 0 {
            vInnerLeft = nextRight(vInnerLeft)
            vInnerRight = nextLeft(vInnerRight)
            vOuterLeft = nextLeft(vOuterLeft)
            vOuterRight = nextRight(vOuterRight)
            ancestor[vOuterRight] = w
            let required = prelim[vInnerLeft] + sInnerLeft - (prelim[vInnerRight] + sInnerRight) + Self.distance
            if required > 0 {
                let anc = ancestor[vInnerLeft]
                moveSubtree(parent[anc] == parent[w] ? anc : defaultAncestor, w, required)
                sInnerRight += required
                sOuterRight += required
            }
            sInnerLeft += mod[vInnerLeft]
            sInnerRight += mod[vInnerRight]
            sOuterLeft += mod[vOuterLeft]
            sOuterRight += mod[vOuterRight]
        }

        // One contour is deeper than the other: continue it through a thread.
        if nextRight(vInnerLeft) >= 0 && nextRight(vOuterRight) < 0 {
            thread[vOuterRight] = nextRight(vInnerLeft)
            mod[vOuterRight] += sInnerLeft - sOuterRight
        }
        if nextLeft(vInnerRight) >= 0 && nextLeft(vOuterLeft) < 0 {
            thread[vOuterLeft] = nextLeft(vInnerRight)
            mod[vOuterLeft] += sInnerRight - sOuterLeft
        }
        return index[w] > 0 && nextRight(vInnerLeft) >= 0 ? ancestor[vOuterRight] : defaultAncestor
    }

    /// Moves `wr` (and its subtree) right by `amount`, spreading the move over
    /// the siblings between `wl` and `wr` so spacing stays even.
    private mutating func moveSubtree(_ wl: Int, _ wr: Int, _ amount: CGFloat) {
        let subtrees = CGFloat(index[wr] - index[wl])
        change[wr] -= amount / subtrees
        shift[wr] += amount
        change[wl] += amount / subtrees
        prelim[wr] += amount
        mod[wr] += amount
    }

    private mutating func executeShifts(_ v: Int) {
        var shiftSum: CGFloat = 0
        var changeSum: CGFloat = 0
        for child in children[v].reversed() {
            prelim[child] += shiftSum
            mod[child] += shiftSum
            changeSum += change[child]
            shiftSum += shift[child] + changeSum
        }
    }

    /// Pre-order: final x is the preliminary x plus the accumulated mods.
    private mutating func secondWalk(_ v: Int, mod accumulated: CGFloat, depth level: Int) {
        x[v] = prelim[v] + accumulated
        depth[v] = level
        for child in children[v] {
            secondWalk(child, mod: accumulated + mod[v], depth: level + 1)
        }
    }
}
