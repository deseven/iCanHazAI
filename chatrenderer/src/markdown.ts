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
import hljs from "highlight.js/lib/core";
import { debugLog, setupDebugOverlay } from "./debug";
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

// Feature flags passed by the native host via URL query parameters. Flags are
// presence-based: `?withMermaid&withKatex&withDebug` enables all features. When
// a feature is disabled its (large) bundle is never loaded and the
// corresponding markdown-it plugin / fence rule is not registered.
interface ChatFeatures {
  mermaid: boolean;
  katex: boolean;
}
function readFeatures(): ChatFeatures {
  const params = new URLSearchParams(location.search);
  const f = {
    mermaid: params.has("withMermaid"),
    katex: params.has("withKatex"),
  };
  debugLog("markdown", "features: " + JSON.stringify(f) + " search: " + location.search);
  return f;
}
const features: ChatFeatures = readFeatures();

const md = new MarkdownIt({
  // Allow raw HTML so KaTeX-rendered output and mermaid containers can be
  // injected. The content originates from the host (trusted model output),
  // not arbitrary user input on the web.
  html: true,
  breaks: false,
  linkify: true,
  typographer: true,
  highlight(str: string, lang?: string): string {
    if (features.mermaid && lang === "mermaid") {
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
// Only loaded when the katex feature flag is enabled. The bundle is loaded via
// a dynamically-injected <script> tag (WKWebView doesn't support dynamic
// import() with file:// URLs) so the KaTeX bundle is excluded entirely when
// disabled. The bundle attaches its export to `window.__katexPlugin`.
// Cast: the plugin targets the markdown-it API; markdown-it-ts's plugin type
// is stricter on options, but the runtime contract is compatible.
let katexReady: Promise<void> | null = null;
function loadKatex(): Promise<void> {
  if (!katexReady) {
    debugLog("katex", "Loading KaTeX bundle via <script> tag...");
    katexReady = loadScript("./katex-bundle.js")
      .then(() => {
        debugLog("katex", "bundle loaded, registering plugin");
        const w = window as any;
        if (w.__katexPlugin) {
          md.use(w.__katexPlugin as any);
          debugLog("katex", "plugin registered");
        } else {
          debugLog("katex", "ERROR: plugin not found on window after script load");
        }
      })
      .catch((err) => {
        debugLog("katex", "load failed: " + (err instanceof Error ? err.message : String(err)));
        reportFeatureError(
          "KaTeX",
          err instanceof Error ? err.message : String(err)
        );
      });
  }
  return katexReady;
}
if (features.katex) {
  debugLog("katex", "feature enabled, starting load");
  loadKatex();
} else {
  debugLog("katex", "feature disabled");
}

/**
 * Resolves once all enabled optional feature bundles have finished loading.
 * The app awaits this before rendering so the first render already has all
 * plugins registered (e.g. KaTeX). When no features are enabled, resolves
 * immediately.
 */
export const featuresReady: Promise<void> = Promise.all([
  features.katex ? loadKatex() : Promise.resolve(),
]).then(() => {
  debugLog("markdown", "all features ready");
});

/** Reports a feature-loading error so it's visible to the user. */
function reportFeatureError(feature: string, message: string): void {
  debugLog("markdown", `ERROR: Failed to load ${feature}: ${message}`);
}

/**
 * Loads a JS bundle by injecting a <script> tag. Resolves on load, rejects on
 * error. More reliable than dynamic import() in WKWebView with file:// URLs.
 */
function loadScript(src: string): Promise<void> {
  debugLog("script", `Loading: ${src}`);
  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = src;
    script.onload = () => {
      debugLog("script", `Loaded: ${src}`);
      resolve();
    };
    script.onerror = () => {
      debugLog("script", `Failed to load: ${src}`);
      reject(new Error(`Failed to load ${src}`));
    };
    document.head.appendChild(script);
  });
}

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

let mermaidReady: Promise<void> | null = null;

function loadMermaid(): Promise<void> {
  if (!mermaidReady) {
    debugLog("mermaid", "Loading bundle via <script> tag...");
    mermaidReady = loadScript("./mermaid-bundle.js")
      .then(() => {
        debugLog("mermaid", "bundle loaded, initializing");
        const w = window as any;
        if (w.__mermaid) {
          w.__mermaid.initialize({
            startOnLoad: false,
            theme: document.documentElement.getAttribute("data-theme") === "light"
              ? "default"
              : "dark",
            securityLevel: "strict",
          });
          debugLog("mermaid", "initialized");
        } else {
          debugLog("mermaid", "ERROR: not found on window after script load");
        }
      })
      .catch((err) => {
        debugLog("mermaid", "load failed: " + (err instanceof Error ? err.message : String(err)));
        reportFeatureError(
          "Mermaid",
          err instanceof Error ? err.message : String(err)
        );
      });
  }
  return mermaidReady;
}

/** Re-theme mermaid when the app theme changes. No-op if mermaid is disabled. */
export async function setMermaidTheme(theme: "light" | "dark") {
  if (!features.mermaid) return;
  await loadMermaid();
  const m = (window as any).__mermaid;
  if (m) {
    m.initialize({
      startOnLoad: false,
      theme: theme === "light" ? "default" : "dark",
      securityLevel: "strict",
    });
  }
}

/**
 * Find unrendered `.mermaid` elements inside `root` and render them.
 * Called by the message component after its HTML is committed to the DOM.
 * No-op if mermaid is disabled (no `.mermaid` containers are emitted).
 */
export async function renderMermaidIn(root: HTMLElement) {
  if (!features.mermaid) return;
  const nodes = root.querySelectorAll<HTMLElement>(
    ".mermaid:not([data-mermaid-done])"
  );
  if (nodes.length === 0) return;
  debugLog("mermaid", `rendering ${nodes.length} diagram(s)`);
  await loadMermaid();
  const m = (window as any).__mermaid;
  if (!m) return;
  for (const node of nodes) {
    const src = node.getAttribute("data-mermaid");
    if (!src) continue;
    node.setAttribute("data-mermaid-done", "1");
    try {
      const { svg } = await m.render(
        "mermaid-" + Math.random().toString(36).slice(2),
        decodeURIComponent(src)
      );
      node.innerHTML = svg;
    } catch (err) {
      node.classList.add("mermaid-error");
      node.textContent =
        "Mermaid error: " + (err instanceof Error ? err.message : String(err));
      debugLog("mermaid", "render error: " + (err instanceof Error ? err.message : String(err)));
    }
  }
}

// Set up the debug overlay as early as possible so log lines emitted during
// module init (feature loading, etc.) are captured. No-op when withDebug is
// absent.
setupDebugOverlay();
