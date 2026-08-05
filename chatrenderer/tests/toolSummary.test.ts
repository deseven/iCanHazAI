// Tests for toolSummary.ts — run via `node --test` against the esbuild-bundled
// output (see build.mjs `test` step). Uses Node's built-in test runner.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  summarizeToolCall,
  summarizeToolResult,
  extractPatchPaths,
} from "../src/toolSummary";

// ── summarizeToolCall: internal tools ───────────────────────────────────

test("read_file: path is the bare primary value", () => {
  const s = summarizeToolCall("read_file", JSON.stringify({ path: "src/main.swift" }));
  assert.deepEqual(s, [{ key: null, value: "src/main.swift" }]);
});

test("read_file: offset/limit shown as secondary key: value", () => {
  const s = summarizeToolCall(
    "read_file",
    JSON.stringify({ path: "a.txt", offset: 10, limit: 50 }),
  );
  assert.deepEqual(s, [
    { key: null, value: "a.txt" },
    { key: "offset", value: "10" },
    { key: "limit", value: "50" },
  ]);
});

test("shell: command is primary, cwd/timeout secondary", () => {
  const s = summarizeToolCall(
    "shell",
    JSON.stringify({ command: "ls -la", cwd: "/tmp", timeout: 30 }),
  );
  assert.deepEqual(s, [
    { key: null, value: "ls -la" },
    { key: "cwd", value: "/tmp" },
    { key: "timeout", value: "30" },
  ]);
});

test("shell: multi-line command collapses newlines into ⏎", () => {
  const s = summarizeToolCall("shell", JSON.stringify({ command: "cd /tmp\nls -la" }));
  assert.deepEqual(s, [{ key: null, value: "cd /tmp⏎ls -la" }]);
});

test("mv: renders src → dst", () => {
  const s = summarizeToolCall("mv", JSON.stringify({ src: "a.txt", dst: "b.txt" }));
  assert.deepEqual(s, [{ key: null, value: "a.txt → b.txt" }]);
});

test("git: args array joined with spaces", () => {
  const s = summarizeToolCall("git", JSON.stringify({ args: ["status", "--short"] }));
  assert.deepEqual(s, [{ key: null, value: "status --short" }]);
});

test("apply_patch: lists affected paths", () => {
  const patch = [
    "*** Begin Patch",
    "*** Add File: hello.txt",
    "+hi",
    "*** Update File: src/app.py",
    "@@",
    " ctx",
    "*** Delete File: obsolete.txt",
    "*** End Patch",
  ].join("\n");
  const s = summarizeToolCall("apply_patch", JSON.stringify({ patch }));
  assert.deepEqual(s, [
    { key: null, value: "hello.txt, src/app.py, obsolete.txt" },
  ]);
});

test("apply_patch: Move to folds into old → new", () => {
  const patch = [
    "*** Begin Patch",
    "*** Update File: src/app.py",
    "*** Move to: src/main.py",
    "@@",
    " ctx",
    "*** End Patch",
  ].join("\n");
  const s = summarizeToolCall("apply_patch", JSON.stringify({ patch }));
  assert.deepEqual(s, [{ key: null, value: "src/app.py → src/main.py" }]);
});

test("no-arg tools produce an empty summary", () => {
  assert.deepEqual(summarizeToolCall("datetime", "{}"), []);
  assert.deepEqual(summarizeToolCall("list_roles", "{}"), []);
});

test("configurator tools: id/name is primary", () => {
  assert.deepEqual(
    summarizeToolCall("delete_role", JSON.stringify({ name: "Old" })),
    [{ key: null, value: "Old" }],
  );
  assert.deepEqual(
    summarizeToolCall("check_connection", JSON.stringify({ id: "openai/gpt-4o" })),
    [{ key: null, value: "openai/gpt-4o" }],
  );
});

// ── summarizeToolCall: unknown tools ────────────────────────────────────

test("unknown tool: required args first (alphabetical), then optional", () => {
  const args = JSON.stringify({ zebra: 1, apple: 2, mango: 3, kiwi: 4 });
  const s = summarizeToolCall("mcp__srv__tool", args, ["zebra", "apple"]);
  assert.deepEqual(
    s.map((e) => e.key),
    ["apple", "zebra", "kiwi", "mango"],
  );
});

test("unknown tool: required args not present in the call are ignored", () => {
  const args = JSON.stringify({ beta: 1, alpha: 2 });
  const s = summarizeToolCall("some_tool", args, ["alpha", "missing"]);
  assert.deepEqual(
    s.map((e) => e.key),
    ["alpha", "beta"],
  );
});

test("unknown tool: without requiredArgs the JSON key order is preserved", () => {
  const args = JSON.stringify({ zebra: 1, apple: 2, mango: 3 });
  const s = summarizeToolCall("some_tool", args);
  assert.deepEqual(
    s.map((e) => e.key),
    ["zebra", "apple", "mango"],
  );
});

test("unknown tool: entries render as key: value", () => {
  const s = summarizeToolCall("some_tool", JSON.stringify({ query: "cats" }));
  assert.deepEqual(s, [{ key: "query", value: "cats" }]);
});

test("unknown tool: array of scalars joins inline", () => {
  const s = summarizeToolCall("some_tool", JSON.stringify({ ids: [1, 2, 3] }));
  assert.deepEqual(s, [{ key: "ids", value: "1 2 3" }]);
});

test("malformed arguments fall back to the raw single-line string", () => {
  const s = summarizeToolCall("some_tool", "{broken json");
  assert.deepEqual(s, [{ key: null, value: "{broken json" }]);
});

test("empty arguments produce an empty summary", () => {
  assert.deepEqual(summarizeToolCall("some_tool", ""), []);
  assert.deepEqual(summarizeToolCall("some_tool", "{}"), []);
});

// ── extractPatchPaths ───────────────────────────────────────────────────

test("extractPatchPaths: empty patch yields no paths", () => {
  assert.deepEqual(extractPatchPaths(""), []);
  assert.deepEqual(extractPatchPaths("*** Begin Patch\n*** End Patch"), []);
});

// ── summarizeToolResult ─────────────────────────────────────────────────

test("pending approval beats everything", () => {
  const s = summarizeToolResult("some_tool", undefined, false, true);
  assert.deepEqual(s, { kind: "pending", label: "approval", description: "" });
});

test("running without a result yet", () => {
  const s = summarizeToolResult("some_tool", undefined, true, false);
  assert.deepEqual(s, { kind: "running", label: "running", description: "" });
});

test("streaming result shows the first line so far", () => {
  const s = summarizeToolResult(
    "some_tool",
    { content: "line one\nline two", isError: false, isStreaming: true },
    true,
    false,
  );
  assert.deepEqual(s, { kind: "running", label: "running", description: "line one" });
});

test("no result and not running/pending → null", () => {
  assert.equal(summarizeToolResult("some_tool", undefined, false, false), null);
});

test("done: first non-empty line of the output", () => {
  const s = summarizeToolResult(
    "some_tool",
    { content: "\n\n  first line  \nsecond", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "done", label: "done", description: "first line" });
});

test("error: first line of the error text", () => {
  const s = summarizeToolResult(
    "some_tool",
    { content: "file not found: a.txt\ndetails", isError: true },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "error", label: "error", description: "file not found: a.txt" });
});

// ── summarizeToolResult: per-tool done descriptions ─────────────────────

test("read_file: counts the numbered output lines", () => {
  const content = " 1 | first\n 2 | second\n10 | tenth";
  const s = summarizeToolResult("read_file", { content, isError: false }, false, false);
  assert.deepEqual(s, { kind: "done", label: "done", description: "Read 3 lines." });
});

test("read_file: truncation marker is not counted", () => {
  const content = "1 | only\n... (truncated at 2000 lines)";
  const s = summarizeToolResult("read_file", { content, isError: false }, false, false);
  assert.deepEqual(s, { kind: "done", label: "done", description: "Read 1 line." });
});

test("read_file: non-text output falls back to the first line", () => {
  const s = summarizeToolResult(
    "read_file",
    { content: "[image: image/png]", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "done", label: "done", description: "[image: image/png]" });
});

test("ls: counts the listed entries", () => {
  const s = summarizeToolResult(
    "ls",
    { content: "src/\nPackage.swift\nREADME.md", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "done", label: "done", description: "Listed 3 items." });
});

test("ls: empty directory", () => {
  const s = summarizeToolResult("ls", { content: "", isError: false }, false, false);
  assert.deepEqual(s, { kind: "done", label: "done", description: "Listed 0 items." });
});

test("find_file: counts matches, ignoring the truncation marker", () => {
  const s = summarizeToolResult(
    "find_file",
    { content: "a.txt\nb.txt\n... (truncated at 200 results)", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "done", label: "done", description: "Found 2 items." });
});

test("find_text: counts match lines", () => {
  const s = summarizeToolResult(
    "find_text",
    { content: "src/a.swift:10:match one", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "done", label: "done", description: "Found 1 item." });
});

test("find_file: no matches", () => {
  const s = summarizeToolResult("find_file", { content: "", isError: false }, false, false);
  assert.deepEqual(s, { kind: "done", label: "done", description: "Found 0 items." });
});

test("shell: last line carries the exit code", () => {
  const s = summarizeToolResult(
    "shell",
    { content: "total 8\n-rw-r--r--  a.txt\n[exit code: 0]", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "done", label: "done", description: "[exit code: 0]" });
});

test("git: non-zero exit code still surfaces from the last line", () => {
  const s = summarizeToolResult(
    "git",
    { content: "error: pathspec 'x' did not match\n[exit code: 1]", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "done", label: "done", description: "[exit code: 1]" });
});

test("apply_patch: summarizes the per-file operation lines", () => {
  const content = "Added: a.txt\nUpdated: b.swift (2 hunks)\nUpdated: c.swift → d.swift (1 hunks)\nDeleted: e.txt";
  const s = summarizeToolResult("apply_patch", { content, isError: false }, false, false);
  assert.deepEqual(s, {
    kind: "done",
    label: "done",
    description: "Patched 4 files (1 added, 2 updated, 1 deleted).",
  });
});

test("apply_patch: single operation", () => {
  const s = summarizeToolResult(
    "apply_patch",
    { content: "Updated: src/app.py (3 hunks)", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, {
    kind: "done",
    label: "done",
    description: "Patched 1 file (1 updated).",
  });
});

// ── summarizeToolResult: configurator tools ─────────────────────────────

test("list_roles: counts the bullet entries", () => {
  const s = summarizeToolResult(
    "list_roles",
    { content: "- Assistant\n- Developer", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "done", label: "done", description: "Listed 2 items." });
});

test("list_connections: empty listing", () => {
  const s = summarizeToolResult(
    "list_connections",
    { content: "(none)", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "done", label: "done", description: "Listed 0 items." });
});

test("check_mcp_stdio: counts the discovered tools", () => {
  const s = summarizeToolResult(
    "check_mcp_stdio",
    { content: "- search — web search\n- fetch", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "done", label: "done", description: "Found 2 tools." });
});

test("check_mcp_http: server reported no tools", () => {
  const s = summarizeToolResult(
    "check_mcp_http",
    { content: "(no tools reported)", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "done", label: "done", description: "Found 0 tools." });
});

test("read_role: counts content lines, ignoring a trailing newline", () => {
  const s = summarizeToolResult(
    "read_role",
    { content: "[role]\nname = \"Dev\"\n", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "done", label: "done", description: "Read 2 lines." });
});

test("read_log: empty-log notice is shown verbatim", () => {
  const s = summarizeToolResult(
    "read_log",
    { content: "(application log is empty)", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, {
    kind: "done",
    label: "done",
    description: "(application log is empty)",
  });
});

test("write_role: confirmation sentence via the default first line", () => {
  const s = summarizeToolResult(
    "write_role",
    { content: "Role \"Dev\" saved. It will be applied automatically in a second.", isError: false },
    false,
    false,
  );
  assert.deepEqual(s, {
    kind: "done",
    label: "done",
    description: "Role \"Dev\" saved. It will be applied automatically in a second.",
  });
});

test("denied with a reason strips the boilerplate prefix", () => {
  const s = summarizeToolResult(
    "some_tool",
    {
      content: "User denied this tool call with the following reason: too risky",
      isError: true,
      isDenied: true,
    },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "denied", label: "denied", description: "too risky" });
});

test("denied without a reason has an empty description", () => {
  const s = summarizeToolResult(
    "some_tool",
    { content: "User denied this tool call", isError: true, isDenied: true },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "denied", label: "denied", description: "" });
});

test("cancelled has no description (content is boilerplate)", () => {
  const s = summarizeToolResult(
    "some_tool",
    {
      content: "Tool call was cancelled by the user before it was executed.",
      isError: true,
      isCancelled: true,
    },
    false,
    false,
  );
  assert.deepEqual(s, { kind: "cancelled", label: "cancelled", description: "" });
});
