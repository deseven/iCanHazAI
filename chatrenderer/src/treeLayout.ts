// Tidy-tree layout for the chat tree overview.
//
// Implements the Buchheim–Jünger–Lepert algorithm ("Improving Walker's
// Algorithm to Run in Linear Time", 2002) — the same published method
// d3-hierarchy's `tree()` uses. This is a clean-room implementation written
// from the algorithm, not derived from any tree library's code.
//
// The input is the host's nested `TreeNode` projection (each node's children
// are its `split.branches`). The output is an absolute (x, y) per node plus
// the list of parent→child edges, ready to render.
import type { TreeNode } from "./types";

/** Geometry shared by every node (fixed card size + spacing). */
export interface TreeLayoutOptions {
  nodeWidth: number;
  nodeHeight: number;
  /** Horizontal gap between sibling subtrees. */
  siblingSpacing: number;
  /** Vertical gap between a parent's bottom and its children's top. */
  levelSpacing: number;
}

/** A laid-out node: its source data plus absolute top-left coordinates. */
export interface LayoutNode {
  data: TreeNode;
  /** Absolute x of the card's left edge. */
  x: number;
  /** Absolute y of the card's top edge. */
  y: number;
  /** The laid-out children (branch heads of this node's split). */
  children: LayoutNode[];
}

/** A parent→child connection between two laid-out nodes. */
export interface LayoutEdge {
  from: LayoutNode;
  to: LayoutNode;
}

export interface TreeLayout {
  root: LayoutNode;
  nodes: LayoutNode[];
  edges: LayoutEdge[];
  /** Total drawing bounds (before any pan/zoom). */
  width: number;
  height: number;
}

/** Internal workspace node carrying the layout temporaries. */
interface Work {
  data: TreeNode;
  children: Work[];
  parent: Work | null;
  /** Preliminary x (subtree-local), before ancestor shifts are applied. */
  prelim: number;
  /** Accumulated shift to apply to this node's subtree. */
  mod: number;
  /** Thread link to the next node of the subtree contour (for apportion). */
  thread: Work | null;
  /** The ancestor to use when resolving apportion conflicts. */
  ancestor: Work;
  /** Index among siblings (0-based). */
  index: number;
  change: number;
  shift: number;
  /** Final absolute coordinates, filled by the second walk. */
  x: number;
  y: number;
}

const DISTANCE = 1; // sibling separation in prelim units (scaled later)

/**
 * Lay out the tree. Returns absolute coordinates with the root's top-left at
 * (0, 0); the caller adds padding and lets the container scroll.
 */
export function layoutTree(root: TreeNode, opts: TreeLayoutOptions): TreeLayout {
  const workRoot = buildWork(root, null, 0);
  firstWalk(workRoot);
  secondWalk(workRoot, -workRoot.prelim, 0);

  // w.x/w.y are in tree units (center-x in sibling units, depth in levels).
  // Measure the bounds, then convert to pixels with the left edge at 0.
  let minX = Infinity;
  let maxX = -Infinity;
  let maxDepth = 0;
  for (const w of allWork(workRoot)) {
    minX = Math.min(minX, w.x);
    maxX = Math.max(maxX, w.x);
    maxDepth = Math.max(maxDepth, w.y);
  }
  const unitX = opts.nodeWidth + opts.siblingSpacing;
  const unitY = opts.nodeHeight + opts.levelSpacing;
  const toLayout = (w: Work): LayoutNode => ({
    data: w.data,
    // Center-x → left edge; normalize so the leftmost center maps to nodeWidth/2.
    x: (w.x - minX) * unitX,
    y: w.y * unitY,
    children: [],
  });

  // Build the LayoutNode tree (matching the Work structure), wiring children
  // by reference, then flatten into nodes + edges for the renderer.
  const buildLayout = (w: Work): LayoutNode => {
    const ln = toLayout(w);
    ln.children = w.children.map(buildLayout);
    return ln;
  };
  const layoutRoot = buildLayout(workRoot);

  const flatNodes: LayoutNode[] = [];
  const flatEdges: LayoutEdge[] = [];
  const walkLayout = (ln: LayoutNode) => {
    flatNodes.push(ln);
    for (const c of ln.children) {
      flatEdges.push({ from: ln, to: c });
      walkLayout(c);
    }
  };
  walkLayout(layoutRoot);

  const width = (maxX - minX) * unitX + opts.nodeWidth;
  const height = (maxDepth + 1) * unitY - opts.levelSpacing;
  return { root: layoutRoot, nodes: flatNodes, edges: flatEdges, width, height };
}

// MARK: - Internals

function buildWork(data: TreeNode, parent: Work | null, index: number): Work {
  const w: Work = {
    data,
    children: [],
    parent,
    prelim: 0,
    mod: 0,
    thread: null,
    ancestor: null as unknown as Work,
    index,
    change: 0,
    shift: 0,
    x: 0,
    y: 0,
  };
  w.ancestor = w;
  w.children = (data.split?.branches ?? []).map((b, i) => buildWork(b, w, i));
  return w;
}

function* allWork(w: Work): Generator<Work> {
  yield w;
  for (const c of w.children) yield* allWork(c);
}

function nextLeft(w: Work): Work {
  return w.children.length > 0 ? w.children[0] : (w.thread as Work);
}

function nextRight(w: Work): Work {
  return w.children.length > 0
    ? w.children[w.children.length - 1]
    : (w.thread as Work);
}

/**
 * First walk (post-order): compute preliminary x and the mod/ancestor/thread
 * bookkeeping used to resolve subtree conflicts.
 */
function firstWalk(w: Work): void {
  if (w.children.length === 0) {
    // Leaf: place just right of its left sibling (or at 0 if first).
    w.prelim = w.index > 0 ? leftSibling(w)!.prelim + DISTANCE : 0;
    return;
  }

  // Default ancestor for resolving conflicts between subtrees.
  let defaultAncestor = w.children[0];
  for (const child of w.children) {
    firstWalk(child);
    defaultAncestor = apportion(child, defaultAncestor);
  }
  executeShifts(w);

  // Center the parent over its children (or place right of the left sibling).
  const first = w.children[0];
  const last = w.children[w.children.length - 1];
  const midpoint = (first.prelim + last.prelim) / 2;
  if (w.index > 0) {
    const left = leftSibling(w)!;
    w.prelim = left.prelim + DISTANCE;
    w.mod = w.prelim - midpoint;
  } else {
    w.prelim = midpoint;
  }
}

/**
 * Resolve spacing conflicts between the subtree rooted at `w` and the
 * subtrees of its earlier siblings, shifting `w`'s subtree right as needed.
 * Returns the ancestor to use for the next sibling.
 */
function apportion(w: Work, defaultAncestor: Work): Work {
  const left = leftSibling(w);
  if (!left) return defaultAncestor;

  // Walk the right contour of the left subtree and the left contour of w's
  // subtree in parallel, computing the required shift at each level.
  let vInnerRight: Work = w;
  let vOuterRight: Work = w;
  let vInnerLeft: Work = left;
  let vOuterLeft: Work = w.parent!.children[0];
  let sInnerRight = vInnerRight.mod;
  let sOuterRight = vOuterRight.mod;
  let sInnerLeft = vInnerLeft.mod;
  let sOuterLeft = vOuterLeft.mod;

  while (nextRight(vInnerLeft) && nextLeft(vInnerRight)) {
    vInnerLeft = nextRight(vInnerLeft);
    vInnerRight = nextLeft(vInnerRight);
    vOuterLeft = nextLeft(vOuterLeft);
    vOuterRight = nextRight(vOuterRight);
    vOuterRight.ancestor = w;
    const shift =
      vInnerLeft.prelim + sInnerLeft - (vInnerRight.prelim + sInnerRight) + DISTANCE;
    if (shift > 0) {
      moveSubtree(findAncestor(vInnerLeft, w, defaultAncestor), w, shift);
      sInnerRight += shift;
      sOuterRight += shift;
    }
    sInnerLeft += vInnerLeft.mod;
    sInnerRight += vInnerRight.mod;
    sOuterLeft += vOuterLeft.mod;
    sOuterRight += vOuterRight.mod;
  }

  // Install threads where one contour is deeper than the other.
  if (nextRight(vInnerLeft) && !nextRight(vOuterRight)) {
    vOuterRight.thread = nextRight(vInnerLeft);
    vOuterRight.mod += sInnerLeft - sOuterRight;
  }
  if (nextLeft(vInnerRight) && !nextLeft(vOuterLeft)) {
    vOuterLeft.thread = nextLeft(vInnerRight);
    vOuterLeft.mod += sInnerRight - sOuterLeft;
  }
  return w.index > 0 && nextRight(vInnerLeft) ? vOuterRight.ancestor : defaultAncestor;
}

/** Find the ancestor of `wInnerLeft` whose subtree actually conflicts with
 *  `w`'s, falling back to `defaultAncestor` when it's outside w's parent. */
function findAncestor(wInnerLeft: Work, w: Work, defaultAncestor: Work): Work {
  const anc = wInnerLeft.ancestor;
  return anc.parent === w.parent ? anc : defaultAncestor;
}

/** Shift `wl`'s subtree right of `wr`'s by `shift`, distributing the move
 *  across the intermediate siblings so spacing stays even. */
function moveSubtree(wl: Work, wr: Work, shift: number): void {
  const subtrees = wr.index - wl.index;
  wr.change -= shift / subtrees;
  wr.shift += shift;
  wl.change += shift / subtrees;
  wr.prelim += shift;
  wr.mod += shift;
}

/** Apply the accumulated `change` shifts to children between siblings. */
function executeShifts(w: Work): void {
  let shift = 0;
  let change = 0;
  for (let i = w.children.length - 1; i >= 0; i--) {
    const child = w.children[i];
    child.prelim += shift;
    child.mod += shift;
    change += child.change;
    shift += child.shift + change;
  }
}

/**
 * Second walk (pre-order): add each node's accumulated `mod` to its prelim to
 * get the final x, and assign depth (y) in levels.
 */
function secondWalk(w: Work, mod: number, depth: number): void {
  w.x = w.prelim + mod;
  w.y = depth;
  for (const child of w.children) secondWalk(child, mod + w.mod, depth + 1);
}

function leftSibling(w: Work): Work | null {
  if (!w.parent || w.index === 0) return null;
  return w.parent.children[w.index - 1];
}
