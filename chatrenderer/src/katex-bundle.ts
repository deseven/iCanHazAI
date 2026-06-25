// Separate entry point for the KaTeX bundle.
//
// This is built as its own JS file (see build.mjs) so the KaTeX library and
// its CSS are only downloaded/parsed when the user has enabled KaTeX in
// preferences. The core chat bundle never imports KaTeX directly.
//
// The bundle is loaded via a dynamically-injected <script> tag (WKWebView
// doesn't support dynamic import() with file:// URLs), so the default export
// is attached to `window.__katexPlugin` for the core bundle to pick up.
import katexPlugin from "@vscode/markdown-it-katex";
import "katex/dist/katex.min.css";

(window as any).__katexPlugin = katexPlugin;
