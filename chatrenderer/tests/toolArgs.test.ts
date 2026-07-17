// Tests for toolArgs.ts — run via `node --test` against the esbuild-bundled
// output (see build.mjs `test` step). Uses Node's built-in test runner.
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseToolArgs, isEmptyArgs } from "../src/toolArgs";

test("parses a simple object with string values", () => {
  const args = JSON.stringify({ path: "TEST.md", content: "hello" });
  const result = parseToolArgs(args);
  assert.deepEqual(result, [
    { key: "path", value: "TEST.md", multiline: false },
    { key: "content", value: "hello", multiline: false },
  ]);
});

test("marks multi-line string values as multiline", () => {
  const args = JSON.stringify({
    path: "TEST.md",
    content: "Some text\n\nAnd more text\nAnd more",
  });
  const result = parseToolArgs(args);
  assert.notEqual(result, null, "should not be null");
  assert.equal(result!.length, 2);
  assert.equal(result![0].key, "path");
  assert.equal(result![0].multiline, false);
  assert.equal(result![1].key, "content");
  assert.equal(result![1].multiline, true);
  assert.equal(result![1].value, "Some text\n\nAnd more text\nAnd more");
});

test("preserves newlines in string values verbatim", () => {
  const args = JSON.stringify({ content: "line1\nline2\nline3" });
  const result = parseToolArgs(args);
  assert.equal(result![0].value, "line1\nline2\nline3");
});

test("handles numbers and booleans", () => {
  const args = JSON.stringify({ count: 42, enabled: true, ratio: 3.14 });
  const result = parseToolArgs(args);
  assert.deepEqual(result, [
    { key: "count", value: "42", multiline: false },
    { key: "enabled", value: "true", multiline: false },
    { key: "ratio", value: "3.14", multiline: false },
  ]);
});

test("handles null values", () => {
  const args = JSON.stringify({ value: null });
  const result = parseToolArgs(args);
  assert.deepEqual(result, [
    { key: "value", value: "null", multiline: false },
  ]);
});

test("pretty-prints nested objects as multi-line JSON", () => {
  const args = JSON.stringify({ options: { a: 1, b: 2 } });
  const result = parseToolArgs(args);
  assert.equal(result![0].key, "options");
  assert.equal(result![0].multiline, true);
  assert.equal(
    result![0].value,
    JSON.stringify({ a: 1, b: 2 }, null, 2),
  );
});

test("pretty-prints arrays as multi-line JSON", () => {
  const args = JSON.stringify({ items: [1, 2, 3] });
  const result = parseToolArgs(args);
  assert.equal(result![0].multiline, true);
  assert.equal(result![0].value, JSON.stringify([1, 2, 3], null, 2));
});

test("empty object returns empty array (not null)", () => {
  const result = parseToolArgs("{}");
  assert.deepEqual(result, []);
});

test("returns null for invalid JSON", () => {
  assert.equal(parseToolArgs("not json"), null);
  assert.equal(parseToolArgs("{broken"), null);
  assert.equal(parseToolArgs(""), null);
});

test("returns null for JSON arrays", () => {
  assert.equal(parseToolArgs("[1, 2, 3]"), null);
});

test("returns null for JSON scalars", () => {
  assert.equal(parseToolArgs('"just a string"'), null);
  assert.equal(parseToolArgs("42"), null);
  assert.equal(parseToolArgs("true"), null);
  assert.equal(parseToolArgs("null"), null);
});

test("preserves key order from the source object", () => {
  const args = JSON.stringify({ zebra: 1, apple: 2, mango: 3 });
  const result = parseToolArgs(args);
  assert.deepEqual(
    result!.map((e) => e.key),
    ["zebra", "apple", "mango"],
  );
});

test("empty array value is single-line", () => {
  const args = JSON.stringify({ items: [] });
  const result = parseToolArgs(args);
  assert.equal(result![0].value, "[]");
  assert.equal(result![0].multiline, false);
});

test("empty object value is single-line", () => {
  const args = JSON.stringify({ config: {} });
  const result = parseToolArgs(args);
  assert.equal(result![0].value, "{}");
  assert.equal(result![0].multiline, false);
});

test("isEmptyArgs: empty string", () => {
  assert.equal(isEmptyArgs(""), true);
});

test("isEmptyArgs: whitespace-only string", () => {
  assert.equal(isEmptyArgs("   \n\t  "), true);
});

test("isEmptyArgs: empty object", () => {
  assert.equal(isEmptyArgs("{}"), true);
  assert.equal(isEmptyArgs("  {}  "), true);
});

test("isEmptyArgs: non-empty arguments", () => {
  assert.equal(isEmptyArgs('{"path":"TEST.md"}'), false);
  assert.equal(isEmptyArgs("null"), false);
  assert.equal(isEmptyArgs("[]"), false);
});
