// esbuild-based build for the chat web view.
// Produces a single self-contained bundle (app.js + app.css) plus index.html
// in ../dist/web, ready to be copied into the app bundle's Resources.
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
const options = {
  entryPoints: [join(root, "src", "main.tsx")],
  bundle: true,
  format: "iife",
  target: "safari17",
  platform: "browser",
  jsx: "automatic",
  jsxImportSource: "preact",
  minify: !watch,
  sourcemap: watch ? "inline" : false,
  outfile: join(outDir, "app.js"),
  loader: {
    ".css": "css",
    ".woff2": "dataurl",
    ".woff": "dataurl",
    ".ttf": "dataurl",
  },
  define: {
    "process.env.NODE_ENV": watch ? '"development"' : '"production"',
  },
  logLevel: "info",
};

if (watch) {
  const ctx = await esbuild.context(options);
  await ctx.watch();
  console.log("Watching for changes...");
} else {
  await esbuild.build(options);
  // Copy the HTML entry point alongside the bundle.
  await copyFile(join(root, "src", "index.html"), join(outDir, "index.html"));
  console.log("Build complete ->", outDir);
}
