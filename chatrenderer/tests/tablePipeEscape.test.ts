import { test } from "node:test";
import assert from "node:assert/strict";
import MarkdownIt from "markdown-it-ts";
import { escapeTableCodeSpanPipes, installTablePipeEscape } from "../src/tablePipeEscape";

function makeMd() {
    const md = new MarkdownIt({ html: true });
    installTablePipeEscape(md);
    return md;
}

function countCells(html: string, tag: string): number {
    return (html.match(new RegExp(`<${tag}[ >]`, "g")) ?? []).length;
}

test("renders pipe inside code span in a table cell", () => {
    const html = makeMd().render("| a | b |\n|---|---|\n| `x|y` | z |");
    assert.equal(countCells(html, "td"), 2);
    assert.ok(html.includes("<code>x|y</code>"), html);
});

test("renders the originally reported table", () => {
    const src = [
        "| Quirk | Hurts in a single env? | Why |",
        "|-------|------------------------|-----|",
        "| **Unreliable `grep` mode (BRE/ERE confusion)** | **Yes — badly** | This is the real one. On this host, `|` worked as alternation but `e{2}` didn't. Every pattern is a gamble. This is unacceptable in any environment. |",
    ].join("\n");
    const html = makeMd().render(src);
    assert.equal(countCells(html, "td"), 3);
    assert.ok(html.includes("<code>|</code>"), html);
    assert.ok(html.includes("unacceptable in any environment."), html);
});

test("does not touch code spans outside tables", () => {
    const html = makeMd().render("Use `a|b` for alternation.");
    assert.ok(html.includes("<code>a|b</code>"), html);
    assert.ok(!html.includes("\\"), html);
});

test("does not touch fenced code blocks containing table-like text", () => {
    const src = "```\n| a | b |\n|---|---|\n| `x|y` | z |\n```";
    const html = makeMd().render(src);
    assert.ok(!html.includes("<table"), html);
    assert.ok(html.includes("`x|y`"), html);
});

test("already-escaped pipes still render as a single pipe", () => {
    const html = makeMd().render("| a | b |\n|---|---|\n| `x\\|y` | z |");
    assert.equal(countCells(html, "td"), 2);
    assert.ok(html.includes("<code>x|y</code>"), html);
});

test("multi-backtick code spans are respected", () => {
    const html = makeMd().render("| a | b |\n|---|---|\n| ``x `|`| y`` | z |");
    assert.equal(countCells(html, "td"), 2);
});

test("unclosed backtick in a row is left alone", () => {
    // No closing backtick: the pipe still delimits (nothing we can do
    // unambiguously), but rendering must not break.
    const html = makeMd().render("| a | b |\n|---|---|\n| `x|y | z |");
    assert.ok(html.includes("<table"), html);
});

test("setext headings are not mistaken for tables", () => {
    const html = makeMd().render("Title\n-----\n\npara `a|b`");
    assert.ok(html.includes("<h2>"), html);
    assert.ok(html.includes("<code>a|b</code>"), html);
    assert.ok(!html.includes("\\"), html);
});

test("heading directly after a table is not treated as a row", () => {
    const html = makeMd().render("| a |\n|---|\n# H `x|y`");
    assert.ok(html.includes("<h1>"), html);
    assert.ok(html.includes("<code>x|y</code>"), html);
    assert.ok(!html.includes("\\"), html);
});

test("paragraph after a table without blank line keeps code spans intact", () => {
    // The library itself continues the table body on such lines, so escaping
    // there is consistent with what the parser would do anyway.
    const html = makeMd().render("| a |\n|---|\ntext `x|y`");
    assert.ok(!html.includes("\\"), html);
});

test("blockquoted tables are handled", () => {
    const html = makeMd().render("> | a | b |\n> |---|---|\n> | `x|y` | z |");
    assert.equal(countCells(html, "td"), 2);
    assert.ok(html.includes("<code>x|y</code>"), html);
});

test("multiple tables in one document", () => {
    const src = "| a |\n|---|\n| `x|y` |\n\n| b |\n|---|\n| `p|q` |";
    const html = makeMd().render(src);
    assert.equal(countCells(html, "table"), 2);
    assert.ok(html.includes("<code>x|y</code>"), html);
    assert.ok(html.includes("<code>p|q</code>"), html);
});

test("indented code blocks are not mistaken for tables", () => {
    const src = "para\n\n    | a |\n    |---|\n    | `x|y` |";
    const html = makeMd().render(src);
    assert.ok(!html.includes("<table"), html);
    assert.ok(!html.includes("\\"), html);
});

test("escapeTableCodeSpanPipes is idempotent", () => {
    const src = "| a | b |\n|---|---|\n| `x|y` | z |";
    const once = escapeTableCodeSpanPipes(src);
    assert.equal(escapeTableCodeSpanPipes(once), once);
});

test("source without pipes or backticks is returned unchanged", () => {
    const src = "# Title\n\nSome `code` here.";
    assert.equal(escapeTableCodeSpanPipes(src), src);
});
