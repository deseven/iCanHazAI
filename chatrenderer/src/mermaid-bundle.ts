// Separate entry point for the Mermaid bundle.
//
// This is built as its own JS file (see build.mjs) so the Mermaid library is
// only downloaded/parsed when the user has enabled Mermaid in preferences. The
// core chat bundle never imports Mermaid directly.
//
// The bundle is loaded via a dynamically-injected <script> tag (WKWebView
// doesn't support dynamic import() with file:// URLs), so the default export
// is attached to `window.__mermaid` for the core bundle to pick up.
import mermaid from "mermaid";

(window as any).__mermaid = mermaid;
