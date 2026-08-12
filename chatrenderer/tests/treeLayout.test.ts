// Tests for the tidy-tree layout (treeLayout.ts).
// Run via `node --test` against the esbuild-bundled output (see build.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import type { TreeNode } from "../src/types";
import { layoutTree, type TreeLayoutOptions } from "../src/treeLayout";

const OPTS: TreeLayoutOptions = {
    nodeWidth: 220,
    nodeHeight: 84,
    siblingSpacing: 28,
    levelSpacing: 56,
};

function node(id: string, branches?: TreeNode[], opts: Partial<TreeNode> = {}): TreeNode {
    return {
        id,
        role: "assistant",
        snippet: "snippet",
        messageCount: 1,
        isActive: false,
        ...(branches ? { split: { branches } } : {}),
        ...opts,
    };
}

function byId(layout: ReturnType<typeof layoutTree>, id: string) {
    const n = layout.nodes.find((n) => n.data.id === id);
    assert.ok(n, `expected node ${id} to be laid out`);
    return n!;
}

const center = (n: { x: number }) => n.x + OPTS.nodeWidth / 2;

// MARK: - Structure & counts

test("single node: no edges, sized to one card", () => {
    const layout = layoutTree(node("root"), OPTS);
    assert.equal(layout.nodes.length, 1);
    assert.equal(layout.edges.length, 0);
    assert.equal(layout.width, OPTS.nodeWidth);
    assert.equal(layout.height, OPTS.nodeHeight);
});

test("edges connect every parent to its children", () => {
    // root → [a, b]; a → [a1]
    const layout = layoutTree(node("root", [node("a", [node("a1")]), node("b")]), OPTS);
    assert.equal(layout.nodes.length, 4);
    assert.equal(layout.edges.length, 3);
    const pairs = layout.edges.map((e) => `${e.from.data.id}->${e.to.data.id}`).sort();
    assert.deepEqual(pairs, ["a->a1", "root->a", "root->b"]);
});

test("a node's children are exactly its split's branches", () => {
    const layout = layoutTree(node("root", [node("a"), node("b"), node("c")]), OPTS);
    assert.equal(layout.root.children.length, 3);
    assert.deepEqual(
        layout.root.children.map((c) => c.data.id),
        ["a", "b", "c"],
    );
});

// MARK: - Depth / rows

test("depth maps to distinct rows one level apart", () => {
    const layout = layoutTree(node("root", [node("a", [node("a1")])]), OPTS);
    const root = byId(layout, "root");
    const a = byId(layout, "a");
    const a1 = byId(layout, "a1");
    const rowGap = OPTS.nodeHeight + OPTS.levelSpacing;
    assert.equal(root.y, 0);
    assert.equal(a.y, rowGap);
    assert.equal(a1.y, rowGap * 2);
});

// MARK: - Tidy-tree properties

test("siblings are separated by at least one spacing unit, in order", () => {
    const layout = layoutTree(node("root", [node("a"), node("b"), node("c")]), OPTS);
    const xs = ["a", "b", "c"].map((id) => byId(layout, id).x).sort((p, q) => p - q);
    for (let i = 1; i < xs.length; i++) {
        assert.ok(
            xs[i] - xs[i - 1] >= OPTS.nodeWidth + OPTS.siblingSpacing - 1e-6,
            `siblings ${i - 1} and ${i} overlap: ${xs[i - 1]} .. ${xs[i]}`,
        );
    }
    // Order preserved: a left of b left of c.
    assert.ok(center(byId(layout, "a")) < center(byId(layout, "b")));
    assert.ok(center(byId(layout, "b")) < center(byId(layout, "c")));
});

test("a parent is centered over its children", () => {
    const layout = layoutTree(node("root", [node("a"), node("b")]), OPTS);
    const rootCenter = center(byId(layout, "root"));
    const a = center(byId(layout, "a"));
    const b = center(byId(layout, "b"));
    const childMid = (a + b) / 2;
    assert.ok(Math.abs(rootCenter - childMid) < 1e-6, `root center ${rootCenter} != child midpoint ${childMid}`);
});

test("parent of three children centers over the middle child", () => {
    const layout = layoutTree(node("root", [node("a"), node("b"), node("c")]), OPTS);
    assert.ok(Math.abs(center(byId(layout, "root")) - center(byId(layout, "b"))) < 1e-6);
});

test("separate subtrees never overlap horizontally", () => {
    // Two branches, each with a deep chain; the chains must not collide.
    const chain = (prefix: string) => node(`${prefix}0`, [node(`${prefix}1`, [node(`${prefix}2`)])]);
    const layout = layoutTree(node("root", [chain("l"), chain("r")]), OPTS);
    // At every depth, the left subtree's nodes sit strictly left of the right's.
    for (const depth of [1, 2, 3]) {
        const atDepth = layout.nodes.filter((n) => n.y === depth * (OPTS.nodeHeight + OPTS.levelSpacing));
        const xs = atDepth.map((n) => n.x).sort((p, q) => p - q);
        for (let i = 1; i < xs.length; i++) {
            assert.ok(
                xs[i] - xs[i - 1] >= OPTS.nodeWidth + OPTS.siblingSpacing - 1e-6,
                `depth ${depth} overlap: ${xs[i - 1]} .. ${xs[i]}`,
            );
        }
    }
});

test("no node is placed at a negative x (bounds start at 0)", () => {
    const layout = layoutTree(
        node("root", [node("a", [node("a1"), node("a2")]), node("b", [node("b1"), node("b2")])]),
        OPTS,
    );
    for (const n of layout.nodes) {
        assert.ok(n.x >= -1e-6, `node ${n.data.id} has negative x ${n.x}`);
        assert.ok(n.y >= -1e-6, `node ${n.data.id} has negative y ${n.y}`);
    }
    // The leftmost node's left edge is flush with 0.
    const minX = Math.min(...layout.nodes.map((n) => n.x));
    assert.ok(Math.abs(minX) < 1e-6);
});

test("reported width/height bound every card", () => {
    const layout = layoutTree(node("root", [node("a", [node("a1"), node("a2")]), node("b")]), OPTS);
    for (const n of layout.nodes) {
        assert.ok(n.x + OPTS.nodeWidth <= layout.width + 1e-6, `${n.data.id} overflows width`);
        assert.ok(n.y + OPTS.nodeHeight <= layout.height + 1e-6, `${n.data.id} overflows height`);
    }
});

test("a deep linear chain stays a straight centered column", () => {
    const layout = layoutTree(node("root", [node("a", [node("a1", [node("a2")])])]), OPTS);
    const centers = ["root", "a", "a1", "a2"].map((id) => center(byId(layout, id)));
    for (const c of centers) {
        assert.ok(Math.abs(c - centers[0]) < 1e-6, `column not straight: ${centers}`);
    }
});
