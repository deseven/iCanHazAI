// Tests for the tree overview gotoMessage bridge message.
// Run via `node --test` against the esbuild-bundled output (see build.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import type { BridgeMessage } from "../src/types";

test("gotoMessage is a valid BridgeMessage carrying the messageId", () => {
    const msg: BridgeMessage = { type: "gotoMessage", messageId: "abc-123" };
    assert.equal(msg.type, "gotoMessage");
    assert.equal((msg as any).messageId, "abc-123");
});

test("gotoMessage BridgeMessage has the correct type tag", () => {
    const msg: BridgeMessage = { type: "gotoMessage", messageId: "xyz" };
    assert.equal(msg.type, "gotoMessage");
    const keys = Object.keys(msg);
    assert.deepEqual(keys.sort(), ["messageId", "type"]);
});
