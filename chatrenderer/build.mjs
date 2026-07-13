// esbuild-based build for the chat web view.
// Produces:
//  - app.js / app.css  : the core chat renderer (no Mermaid/KaTeX)
//  - katex-bundle.js    : KaTeX plugin + CSS (loaded only when KaTeX is enabled)
//  - mermaid-bundle.js  : Mermaid library (loaded only when Mermaid is enabled)
// plus index.html in ../dist/web, ready to be copied into the app bundle's Resources.
import * as esbuild from "esbuild";
import { mkdir, rm, copyFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = dirname(fileURLToPath(import.meta.url));
const outDir = join(root, "dist");

const watch = process.argv.includes("--watch");

await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });

/** @type {esbuild.BuildOptions} */
const commonOptions = {
  bundle: true,
  format: "iife",
  target: "safari17",
  platform: "browser",
  jsx: "automatic",
  jsxImportSource: "preact",
  minify: !watch,
  sourcemap: watch ? "inline" : false,
  loader: {
    ".css": "css",
    // KaTeX ships every font in three formats. Inlining them as data URLs
    // bloats the CSS to ~1.4 MB. Instead emit woff2 as a separate (lazily
    // fetched) file and drop woff/ttf entirely — WKWebView on macOS 15
    // supports woff2, so the other formats are dead weight.
    ".woff2": "file",
    ".woff": "empty",
    ".ttf": "empty",
  },
  assetNames: "[name]-[hash]",
  define: {
    "process.env.NODE_ENV": watch ? '"development"' : '"production"',
  },
  logLevel: "info",
};

// Core bundle: the chat renderer. Mermaid and KaTeX are loaded at runtime via
// dynamically-injected <script> tags (not dynamic import()), so the core
// bundle never references them and they are fully excluded when disabled.
const coreOptions = {
  ...commonOptions,
  entryPoints: [join(root, "src", "main.tsx")],
  outfile: join(outDir, "app.js"),
};

// KaTeX bundle: the markdown-it KaTeX plugin + KaTeX CSS.
const katexOptions = {
  ...commonOptions,
  entryPoints: [join(root, "src", "katex-bundle.ts")],
  outfile: join(outDir, "katex-bundle.js"),
};

// Mermaid bundle: the Mermaid library.
const mermaidOptions = {
  ...commonOptions,
  entryPoints: [join(root, "src", "mermaid-bundle.ts")],
  outfile: join(outDir, "mermaid-bundle.js"),
};

if (watch) {
  const ctxCore = await esbuild.context(coreOptions);
  const ctxKatex = await esbuild.context(katexOptions);
  const ctxMermaid = await esbuild.context(mermaidOptions);
  await Promise.all([ctxCore.watch(), ctxKatex.watch(), ctxMermaid.watch()]);
  console.log("Watching for changes...");
} else {
  await esbuild.build(coreOptions);
  await esbuild.build(katexOptions);
  await esbuild.build(mermaidOptions);
  // Copy the HTML entry point alongside the bundle.
  await copyFile(join(root, "src", "index.html"), join(outDir, "index.html"));
  console.log("Build complete ->", outDir);
}
