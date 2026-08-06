// Tests for toolSummary.ts — run via `node --test` against the esbuild-bundled
// output (see build.mjs `test` step). Uses Node's built-in test runner.
import { test } from "node:test";
import assert from "node:assert/strict";
import { transientToolStatus } from "../src/toolSummary";

// Final states (done/error/denied/cancelled) are computed by the host and
// persisted in the chat data — only the transient states are derived here.

test("pending approval beats everything", () => {
  const s = transientToolStatus(undefined, false, true);
  assert.deepEqual(s, { kind: "pending", label: "approval", description: "" });
});

test("pending beats a streaming result", () => {
  const s = transientToolStatus(
    { content: "partial", isError: false, isStreaming: true },
    true,
    true,
  );
  assert.deepEqual(s, { kind: "pending", label: "approval", description: "" });
});

test("running without a result yet", () => {
  const s = transientToolStatus(undefined, true, false);
  assert.deepEqual(s, { kind: "running", label: "running", description: "" });
});

test("streaming result shows the first line so far", () => {
  const s = transientToolStatus(
    { content: "line one\nline two", isError: false, isStreaming: true },
    true,
    false,
  );
  assert.deepEqual(s, { kind: "running", label: "running", description: "line one" });
});

test("no result and not running/pending → null", () => {
  assert.equal(transientToolStatus(undefined, false, false), null);
});

test("a final result has no transient status (the persisted summary is used)", () => {
  assert.equal(transientToolStatus({ content: "done output", isError: false }, false, false), null);
  assert.equal(transientToolStatus({ content: "boom", isError: true }, false, false), null);
  assert.equal(
    transientToolStatus({ content: "denied", isError: true, isDenied: true }, false, false),
    null,
  );
});
