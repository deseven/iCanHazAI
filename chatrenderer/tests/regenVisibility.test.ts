// Tests for regen visibility logic and the regenerate bridge message.
// Run via `node --test` against the esbuild-bundled output (see build.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import type { ChatMessage, BridgeMessage, ChatSnapshotFeatures } from "../src/types";
import { canRegenerate } from "../src/regenVisibility";

function assistantMsg(id: string = "a1"): ChatMessage {
    return { id, role: "assistant", content: "response", timestamp: "2026-01-01T00:00:00Z" };
}

function userMsg(id: string = "u1"): ChatMessage {
    return { id, role: "user", content: "question", timestamp: "2026-01-01T00:00:00Z" };
}

const regenFeatures: ChatSnapshotFeatures = { responseRegen: true };
const noFeatures: ChatSnapshotFeatures = { responseRegen: false };
const treeFeatures: ChatSnapshotFeatures = { responseRegen: true, chatTrees: true };

// MARK: - canRegenerate

test("canRegenerate: true for a non-first assistant message with regen enabled", () => {
    assert.equal(canRegenerate(assistantMsg(), false, regenFeatures, false), true);
});

test("canRegenerate: false for a user message", () => {
    assert.equal(canRegenerate(userMsg(), false, regenFeatures, false), false);
});

test("canRegenerate: false for the first message in the chat", () => {
    assert.equal(canRegenerate(assistantMsg(), true, regenFeatures, false), false);
});

test("canRegenerate: false when responseRegen is not enabled", () => {
    assert.equal(canRegenerate(assistantMsg(), false, noFeatures, false), false);
});

test("canRegenerate: false when features are undefined", () => {
    assert.equal(canRegenerate(assistantMsg(), false, undefined, false), false);
});

test("canRegenerate: false while streaming", () => {
    assert.equal(canRegenerate(assistantMsg(), false, regenFeatures, true), false);
});

test("canRegenerate: true with chatTrees features (which include regen)", () => {
    assert.equal(canRegenerate(assistantMsg(), false, treeFeatures, false), true);
});

test("canRegenerate: false for first message even with all features on and not streaming", () => {
    assert.equal(canRegenerate(assistantMsg(), true, treeFeatures, false), false);
});

// MARK: - regenerate bridge message

test("regenerate is a valid BridgeMessage carrying the messageId", () => {
    const msg: BridgeMessage = { type: "regenerate", messageId: "abc-123" };
    assert.equal(msg.type, "regenerate");
    assert.equal(msg.messageId, "abc-123");
});

test("regenerate BridgeMessage has the correct type tag", () => {
    const msg: BridgeMessage = { type: "regenerate", messageId: "xyz" };
    assert.equal(msg.type, "regenerate");
    // Ensure no other fields are present.
    const keys = Object.keys(msg);
    assert.deepEqual(keys.sort(), ["messageId", "type"]);
});
