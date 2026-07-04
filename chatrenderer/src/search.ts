// In-chat search.
//
// Searches only the rendered message *content* text — message headers, thinking
// blocks and tool-call blocks are excluded. We walk the text nodes inside
// `.msg-content .markdown` elements, wrap matches in `<mark class="search-mark">`,
// and keep an ordered list of match nodes so we can scroll/navigate between
// them. The active match gets `search-mark-active` (yellow); the rest get a
// subtler highlight.

export interface SearchState {
  query: string;
  /** 0-based index of the active (current) match. */
  active: number;
  /** Total number of matches found. */
  total: number;
}

/** CSS class applied to every match wrapper. */
const MARK_CLASS = "search-mark";
/** Additional class for the currently-active match. */
const ACTIVE_CLASS = "search-mark-active";
/** Wrapper element tag used to surround matched text. */
const MARK_TAG = "span";

/** Returns the message-content root elements to search within. */
function contentRoots(): HTMLElement[] {
  return Array.from(
    document.querySelectorAll<HTMLElement>(".msg-content .markdown"),
  );
}

/**
 * Escape a user query into a regex source matching it literally,
 * case-insensitively.
 */
function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

interface FoundMatch {
  /** The wrapper element we inserted. */
  mark: HTMLElement;
  /** The text node the match starts in (for scrolling). */
  node: Text;
}

let currentMatches: FoundMatch[] = [];
let currentQuery: string = "";
let activeIndex: number = -1;

/** Remove all existing highlight marks from the DOM and reset state. */
export function clearSearch(): void {
  for (const { mark } of currentMatches) {
    const parent = mark.parentNode;
    if (!parent) continue;
    // Replace the wrapper with its text content, normalizing adjacent text
    // nodes so subsequent searches can re-walk cleanly.
    while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
    parent.removeChild(mark);
    parent.normalize();
  }
  currentMatches = [];
  currentQuery = "";
  activeIndex = -1;
}

/**
 * Run a search for `query` across all message content. Returns the new state.
 * Re-running with the same query is a no-op (preserves the active match).
 * An empty query clears all marks.
 */
export function runSearch(query: string): SearchState {
  const trimmed = query.trim();
  if (trimmed === "") {
    clearSearch();
    return { query: "", active: -1, total: 0 };
  }
  if (trimmed === currentQuery && currentMatches.length > 0) {
    return state();
  }
  clearSearch();
  currentQuery = trimmed;

  const re = new RegExp(escapeRegExp(trimmed), "gi");
  const roots = contentRoots();

  for (const root of roots) {
    // Collect text nodes under the root, skipping already-marked spans and
    // non-text content (e.g. <svg> from mermaid).
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const parent = node.parentElement;
        if (!parent) return NodeFilter.FILTER_REJECT;
        // Skip our own mark wrappers (they don't exist yet on first pass, but
        // guard against re-entrancy) and skip script/style/svg.
        if (parent.closest(`.${MARK_CLASS}`)) return NodeFilter.FILTER_REJECT;
        const tag = parent.tagName.toLowerCase();
        if (tag === "script" || tag === "style" || tag === "svg") {
          return NodeFilter.FILTER_REJECT;
        }
        if (node.nodeValue == null || node.nodeValue.length === 0) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });

    const textNodes: Text[] = [];
    let n: Node | null;
    while ((n = walker.nextNode())) textNodes.push(n as Text);

    for (const textNode of textNodes) {
      const text = textNode.nodeValue ?? "";
      re.lastIndex = 0;
      let m: RegExpExecArray | null;
      let last = 0;
      const frag = document.createDocumentFragment();
      let matched = false;

      while ((m = re.exec(text)) !== null) {
        matched = true;
        const matchStart = m.index;
        const matchEnd = matchStart + m[0].length;
        // Text before the match.
        if (matchStart > last) {
          frag.appendChild(document.createTextNode(text.slice(last, matchStart)));
        }
        const mark = document.createElement(MARK_TAG);
        mark.className = MARK_CLASS;
        mark.textContent = m[0];
        frag.appendChild(mark);
        currentMatches.push({ mark, node: textNode });
        last = matchEnd;
        // Guard against zero-length matches (shouldn't happen with non-empty
        // literal patterns, but keeps the loop from spinning).
        if (m.index === re.lastIndex) re.lastIndex++;
      }

      if (matched) {
        if (last < text.length) {
          frag.appendChild(document.createTextNode(text.slice(last)));
        }
        textNode.parentNode?.replaceChild(frag, textNode);
      }
    }
  }

  if (currentMatches.length > 0) {
    setActive(0);
  }
  return state();
}

/** Build a `SearchState` snapshot from current state. */
function state(): SearchState {
  return {
    query: currentQuery,
    active: activeIndex,
    total: currentMatches.length,
  };
}

/** Mark `index` as the active match, scrolling it into view. */
export function setActive(index: number): SearchState {
  if (currentMatches.length === 0) {
    activeIndex = -1;
    return state();
  }
  // Wrap around.
  let i = index % currentMatches.length;
  if (i < 0) i += currentMatches.length;
  activeIndex = i;

  for (let k = 0; k < currentMatches.length; k++) {
    const { mark } = currentMatches[k];
    if (k === i) {
      mark.classList.add(ACTIVE_CLASS);
    } else {
      mark.classList.remove(ACTIVE_CLASS);
    }
  }

  const active = currentMatches[i];
  if (active) {
    active.mark.scrollIntoView({ block: "center", behavior: "auto" });
  }
  return state();
}

/** Move to the next match (wraps around). */
export function nextMatch(): SearchState {
  if (currentMatches.length === 0) return state();
  return setActive(activeIndex + 1);
}

/** Move to the previous match (wraps around). */
export function prevMatch(): SearchState {
  if (currentMatches.length === 0) return state();
  return setActive(activeIndex - 1);
}

/** Whether a search is currently active (non-empty query with marks). */
export function isSearching(): boolean {
  return currentQuery.length > 0;
}
