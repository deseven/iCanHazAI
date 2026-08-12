// Tests for toolHighlight.ts — run via `node --test` against the
// esbuild-bundled output (see build.mjs `test` step).
import { test } from "node:test";
import assert from "node:assert/strict";
import { toolArgLang, toolResultLang } from "../src/toolHighlight";

test("write tools map content to their config languages", () => {
    assert.equal(toolArgLang("write_connection", "content"), "jsonc");
    assert.equal(toolArgLang("write_mcp", "content"), "toml");
    assert.equal(toolArgLang("write_role", "content"), "toml");
    assert.equal(toolArgLang("write_config", "content"), "toml");
    assert.equal(toolArgLang("write_prompt", "content"), "markdown");
});

test("check_mcp_stdio highlights the command as bash", () => {
    assert.equal(toolArgLang("check_mcp_stdio", "command"), "bash");
});

test("non-content arguments have no language hint", () => {
    assert.equal(toolArgLang("write_config", "name"), null);
    assert.equal(toolArgLang("write_connection", "id"), null);
    assert.equal(toolArgLang("check_mcp_http", "endpoint"), null);
});

test("read tools map results to their file languages", () => {
    assert.equal(toolResultLang("read_connection"), "jsonc");
    assert.equal(toolResultLang("read_mcp"), "toml");
    assert.equal(toolResultLang("read_role"), "toml");
    assert.equal(toolResultLang("read_config"), "toml");
    assert.equal(toolResultLang("read_prompt"), "markdown");
});

test("unknown tools and tools with plain output have no hints", () => {
    assert.equal(toolArgLang("read_file", "content"), null);
    assert.equal(toolResultLang("read_log"), null);
    assert.equal(toolResultLang("list_roles"), null);
    assert.equal(toolResultLang("some_external_tool"), null);
    assert.equal(toolArgLang("some_external_tool", "content"), null);
});
