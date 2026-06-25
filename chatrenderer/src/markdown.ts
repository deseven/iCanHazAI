// Markdown rendering with markdown-it-ts + highlight.js.
// A single shared instance is configured once and reused for every message.
// markdown-it-ts is a TypeScript-first rewrite with streaming/incremental
// parsing support, which keeps streaming message re-renders cheap.
//
// We import highlight.js/lib/core and register only a curated set of common
// languages. This keeps the bundle small (~100KB vs ~1MB for the full build)
// while covering the languages users actually paste into a chat.
//
// Supported extensions beyond CommonMark:
//  - GFM tables & strikethrough (built into markdown-it-ts by default)
//  - LaTeX math via KaTeX (@vscode/markdown-it-katex)
//  - Mermaid diagrams (custom fence rule; rendered client-side via mermaid.run)
import MarkdownIt from "markdown-it-ts";
import type { Token } from "markdown-it-ts";
import katexPlugin from "@vscode/markdown-it-katex";
import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import c from "highlight.js/lib/languages/c";
import cpp from "highlight.js/lib/languages/cpp";
import csharp from "highlight.js/lib/languages/csharp";
import css from "highlight.js/lib/languages/css";
import diff from "highlight.js/lib/languages/diff";
import go from "highlight.js/lib/languages/go";
import xml from "highlight.js/lib/languages/xml";
import java from "highlight.js/lib/languages/java";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import kotlin from "highlight.js/lib/languages/kotlin";
import lua from "highlight.js/lib/languages/lua";
import markdown from "highlight.js/lib/languages/markdown";
import objectivec from "highlight.js/lib/languages/objectivec";
import perl from "highlight.js/lib/languages/perl";
import php from "highlight.js/lib/languages/php";
import python from "highlight.js/lib/languages/python";
import ruby from "highlight.js/lib/languages/ruby";
import rust from "highlight.js/lib/languages/rust";
import scala from "highlight.js/lib/languages/scala";
import shell from "highlight.js/lib/languages/shell";
import sql from "highlight.js/lib/languages/sql";
import swift from "highlight.js/lib/languages/swift";
import typescript from "highlight.js/lib/languages/typescript";
import yaml from "highlight.js/lib/languages/yaml";

// Register the curated language set. Aliases cover common fenced-code labels.
const languages: Array<[string, (hljs: any) => any]> = [
  ["bash", bash],
  ["sh", bash],
  ["c", c],
  ["h", c],
  ["cpp", cpp],
  ["c++", cpp],
  ["cc", cpp],
  ["hpp", cpp],
  ["csharp", csharp],
  ["cs", csharp],
  ["css", css],
  ["diff", diff],
  ["patch", diff],
  ["go", go],
  ["golang", go],
  ["html", xml],
  ["xml", xml],
  ["svg", xml],
  ["java", java],
  ["javascript", javascript],
  ["js", javascript],
  ["jsx", javascript],
  ["json", json],
  ["jsonc", json],
  ["kotlin", kotlin],
  ["kt", kotlin],
  ["lua", lua],
  ["markdown", markdown],
  ["md", markdown],
  ["objectivec", objectivec],
  ["objc", objectivec],
  ["obj-c", objectivec],
  ["perl", perl],
  ["pl", perl],
  ["php", php],
  ["python", python],
  ["py", python],
  ["ruby", ruby],
  ["rb", ruby],
  ["rust", rust],
  ["rs", rust],
  ["scala", scala],
  ["shell", shell],
  ["console", shell],
  ["terminal", shell],
  ["sql", sql],
  ["swift", swift],
  ["typescript", typescript],
  ["ts", typescript],
  ["tsx", typescript],
  ["yaml", yaml],
  ["yml", yaml],
];
for (const [name, lang] of languages) {
  hljs.registerLanguage(name, lang);
}

const md = new MarkdownIt({
  // Allow raw HTML so KaTeX-rendered output and mermaid containers can be
  // injected. The content originates from the host (trusted model output),
  // not arbitrary user input on the web.
  html: true,
  breaks: false,
  linkify: true,
  typographer: true,
  highlight(str: string, lang?: string): string {
    // Mermaid diagrams are rendered client-side: emit a container that the
    // renderer scans for after each render pass (see renderMermaidIn).
    if (lang === "mermaid") {
      return (
        '<div class="mermaid" data-mermaid="' +
        encodeURIComponent(str) +
        '"></div>'
      );
    }
    if (lang && hljs.getLanguage(lang)) {
      try {
        return (
          '<pre class="hljs"><code>' +
          hljs.highlight(str, { language: lang, ignoreIllegals: true }).value +
          "</code></pre>"
        );
      } catch {
        // fall through to plain escape
      }
    }
    return '<pre class="hljs"><code>' + md.utils.escapeHtml(str) + "</code></pre>";
  },
});

// LaTeX math support via KaTeX. Handles $...$ (inline) and $$...$$ (block).
// Cast: the plugin targets the markdown-it API; markdown-it-ts's plugin type
// is stricter on options, but the runtime contract is compatible.
md.use(katexPlugin as any);

// Open links in a new window (the host app intercepts external navigation anyway,
// but this is a sensible default for a chat view).
const defaultLinkOpen = md.renderer.rules.link_open;

md.renderer.rules.link_open = function (
  tokens: Token[],
  idx: number,
  options,
  env,
  self
) {
  const token = tokens[idx];
  const targetIndex = token.attrIndex("target");
  if (targetIndex < 0) {
    token.attrPush(["target", "_blank"]);
    token.attrPush(["rel", "noopener noreferrer"]);
  } else {
    token.attrs![targetIndex][1] = "_blank";
  }
  if (defaultLinkOpen) {
    return defaultLinkOpen(tokens, idx, options, env, self);
  }
  return self.renderToken(tokens, idx, options);
};

/**
 * Render markdown source to HTML. Raw HTML is enabled (html:true) so KaTeX
 * output and mermaid containers pass through. Returns an empty string for
 * empty/whitespace-only input so the caller can skip rendering an empty block.
 *
 * GFM task lists (`[ ]` / `[x]`) are post-processed since markdown-it-ts
 * does not ship a built-in task-list rule.
 */
export function renderMarkdown(src: string): string {
  const trimmed = src.trim();
  if (!trimmed) return "";
  let html = md.render(src);
  // Convert GFM task list items: <li>[ ] text</li> / <li>[x] text</li>
  html = html.replace(
    /<li>\s*\[([ xX])\]\s*/g,
    (_m, check: string) => {
      const checked = check === "x" || check === "X";
      return (
        '<li class="task-list-item">' +
        '<input type="checkbox" class="task-list-checkbox" disabled' +
        (checked ? " checked" : "") +
        "> "
      );
    }
  );
  return html;
}

/**
 * Render the trailing partial line of a streaming message as inline markdown.
 * Used for the in-progress line so it updates cheaply without re-rendering
 * completed blocks.
 */
export function renderInline(src: string): string {
  return md.renderInline(src);
}

// ── Mermaid post-render ──────────────────────────────────────────────
//
// Mermaid diagrams cannot be rendered synchronously inside the markdown-it
// highlight callback (mermaid 11 is async and operates on the DOM). Instead
// the highlight rule emits `<div class="mermaid" data-mermaid="...">` and we
// scan the rendered container after it is inserted into the DOM, calling
// mermaid.run() on any unprocessed elements.

let mermaidReady: Promise<typeof import("mermaid")> | null = null;

async function loadMermaid() {
  if (!mermaidReady) {
    mermaidReady = import("mermaid").then((m) => {
      m.default.initialize({
        startOnLoad: false,
        theme: document.documentElement.getAttribute("data-theme") === "light"
          ? "default"
          : "dark",
        securityLevel: "strict",
      });
      return m;
    });
  }
  return mermaidReady;
}

/** Re-theme mermaid when the app theme changes. */
export async function setMermaidTheme(theme: "light" | "dark") {
  const m = await loadMermaid();
  m.default.initialize({
    startOnLoad: false,
    theme: theme === "light" ? "default" : "dark",
    securityLevel: "strict",
  });
}

/**
 * Find unrendered `.mermaid` elements inside `root` and render them.
 * Called by the message component after its HTML is committed to the DOM.
 */
export async function renderMermaidIn(root: HTMLElement) {
  const nodes = root.querySelectorAll<HTMLElement>(
    ".mermaid:not([data-mermaid-done])"
  );
  if (nodes.length === 0) return;
  const m = await loadMermaid();
  for (const node of nodes) {
    const src = node.getAttribute("data-mermaid");
    if (!src) continue;
    node.setAttribute("data-mermaid-done", "1");
    try {
      const { svg } = await m.default.render(
        "mermaid-" + Math.random().toString(36).slice(2),
        decodeURIComponent(src)
      );
      node.innerHTML = svg;
    } catch (err) {
      node.classList.add("mermaid-error");
      node.textContent =
        "Mermaid error: " + (err instanceof Error ? err.message : String(err));
    }
  }
}
