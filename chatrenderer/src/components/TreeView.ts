// Renders a laid-out chat tree as an SVG canvas with HTML node cards.
//
// Cards are absolutely-positioned <div>s stacked above an <svg> holding the
// orthogonal edges — deliberately *not* SVG <foreignObject>, which Safari
// mis-paints under transforms. We use no pan/zoom transform at all: the
// wrapper is sized to the layout and the container scrolls, so cards render
// crisply at 100% scale.
import type { TreeNode } from "../types";
import {
  layoutTree,
  type LayoutEdge,
  type LayoutNode,
  type TreeLayout,
} from "../treeLayout";

const SVG_NS = "http://www.w3.org/2000/svg";

const NODE_WIDTH = 220;
const NODE_HEIGHT = 84;
const SIBLING_SPACING = 28;
const LEVEL_SPACING = 56;
const PADDING = 40;
/** Corner radius of the orthogonal edge elbows. */
const EDGE_RADIUS = 8;

export interface TreeViewOptions {
  /** Called with the message id when a node card is clicked. */
  onNodeClick?: (id: string) => void;
}

/** Escape user content for safe insertion into an HTML string. */
function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&#34;");
}

/** Badge background colors per role, matching the app's accent variables. */
const BADGE_COLORS: Record<string, string> = {
  user: "var(--accent-user-bg, rgba(0,122,255,0.12))",
  assistant: "var(--accent-bg, rgba(175,82,222,0.12))",
  tool: "var(--bg-surface-hover, rgba(120,120,120,0.12))",
  system: "var(--accent-system-bg, rgba(255,159,10,0.12))",
};

export class TreeView {
  private container: HTMLElement;
  private wrapper: HTMLDivElement | null = null;
  private opts: TreeViewOptions;

  constructor(container: HTMLElement, opts: TreeViewOptions = {}) {
    this.container = container;
    this.opts = opts;
  }

  /** Lay out and render the tree, replacing any previous content. */
  render(root: TreeNode): void {
    this.destroy();
    const layout = layoutTree(root, {
      nodeWidth: NODE_WIDTH,
      nodeHeight: NODE_HEIGHT,
      siblingSpacing: SIBLING_SPACING,
      levelSpacing: LEVEL_SPACING,
    });

    const wrapper = document.createElement("div");
    wrapper.style.position = "relative";
    wrapper.style.width = `${layout.width + PADDING * 2}px`;
    wrapper.style.height = `${layout.height + PADDING * 2}px`;

    wrapper.appendChild(this.buildEdges(layout));
    for (const node of layout.nodes) {
      wrapper.appendChild(this.buildCard(node));
    }

    this.container.appendChild(wrapper);
    this.wrapper = wrapper;
  }

  /** Remove the rendered tree. */
  destroy(): void {
    this.wrapper?.remove();
    this.wrapper = null;
  }

  // MARK: - Edges

  private buildEdges(layout: TreeLayout): SVGSVGElement {
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("class", "tree-view-svg");
    svg.setAttribute("width", String(layout.width + PADDING * 2));
    svg.setAttribute("height", String(layout.height + PADDING * 2));
    svg.style.position = "absolute";
    svg.style.left = "0";
    svg.style.top = "0";
    for (const edge of layout.edges) {
      svg.appendChild(this.buildEdge(edge));
    }
    return svg;
  }

  private buildEdge(edge: LayoutEdge): SVGPathElement {
    const path = document.createElementNS(SVG_NS, "path");
    path.setAttribute("d", edgePath(edge));
    path.setAttribute("class", this.isActiveEdge(edge) ? "tree-edge tree-edge-active" : "tree-edge");
    return path;
  }

  /** An edge is on the active path when both endpoints are active. */
  private isActiveEdge(edge: LayoutEdge): boolean {
    return edge.from.data.isActive && edge.to.data.isActive;
  }

  // MARK: - Cards

  private buildCard(node: LayoutNode): HTMLElement {
    const data = node.data;
    const holder = document.createElement("div");
    holder.style.position = "absolute";
    holder.style.left = `${PADDING + node.x}px`;
    holder.style.top = `${PADDING + node.y}px`;
    holder.style.width = `${NODE_WIDTH}px`;
    holder.style.minHeight = `${NODE_HEIGHT}px`;
    holder.innerHTML = cardHTML(data);
    const card = holder.firstElementChild as HTMLElement;
    card.style.background = "var(--bg-surface)";
    card.style.border = "1px solid var(--border)";
    card.style.borderRadius = "8px";
    holder.addEventListener("click", () => this.opts.onNodeClick?.(data.id));
    return holder;
  }
}

/** Rounded orthogonal path from the parent's bottom-center to the child's
 *  top-center: down to the mid-level, across, then down again. */
function edgePath(edge: LayoutEdge): string {
  const x1 = PADDING + edge.from.x + NODE_WIDTH / 2;
  const y1 = PADDING + edge.from.y + NODE_HEIGHT;
  const x2 = PADDING + edge.to.x + NODE_WIDTH / 2;
  const y2 = PADDING + edge.to.y;

  // Degenerate: perfectly vertical (single centered child).
  if (Math.abs(x2 - x1) < 0.01) {
    return `M ${x1} ${y1} L ${x2} ${y2}`;
  }

  const midY = (y1 + y2) / 2;
  const r = Math.min(EDGE_RADIUS, Math.abs(x2 - x1) / 2, Math.max(0, midY - y1));
  const sx = Math.sign(x2 - x1);
  return (
    `M ${x1} ${y1} ` +
    `L ${x1} ${midY - r} ` +
    `Q ${x1} ${midY} ${x1 + r * sx} ${midY} ` +
    `L ${x2 - r * sx} ${midY} ` +
    `Q ${x2} ${midY} ${x2} ${midY + r} ` +
    `L ${x2} ${y2}`
  );
}

/** The HTML for a node card. Safari-safe: plain flow layout, no
 *  position/opacity/transform (cards are already positioned by the wrapper). */
function cardHTML(data: TreeNode): string {
  const roleClass = `tree-card-role-${esc(data.role)}`;
  const activeClass = data.isActive ? " tree-card-active-path" : "";
  const badge =
    data.messageCount > 1
      ? `<span class="tree-card-badge" style="background:${esc(
          BADGE_COLORS[data.role] ?? BADGE_COLORS.tool,
        )}">${data.messageCount} messages</span>`
      : "";
  return (
    `<div class="tree-card${activeClass}">` +
    `<div class="tree-card-head">` +
    `<span class="tree-card-role ${roleClass}">${esc(data.role)}</span>` +
    badge +
    `</div>` +
    `<div class="tree-card-snippet">${esc(data.snippet)}</div>` +
    `</div>`
  );
}
