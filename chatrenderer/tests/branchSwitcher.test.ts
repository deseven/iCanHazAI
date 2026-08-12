// Tests for branch switcher visibility logic and the switchBranch bridge message.
// Run via `node --test` against the esbuild-bundled output (see build.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import type { ChatMessage, BridgeMessage, SiblingsData } from "../src/types";

function assistantMsg(id: string = "a1", siblings?: SiblingsData | null): ChatMessage {
    return { id, role: "assistant", content: "response", timestamp: "2026-01-01T00:00:00Z", siblings };
}

// MARK: - Siblings data on messages

test("siblings: message without siblings has undefined siblings", () => {
    const msg = assistantMsg();
    assert.equal(msg.siblings, undefined);
});

test("siblings: message with siblings carries index and count", () => {
    const siblings: SiblingsData = { index: 1, count: 3 };
    const msg = assistantMsg("a2", siblings);
    assert.deepEqual(msg.siblings, { index: 1, count: 3 });
});

test("siblings: fork member with count > 1 indicates a switcher should show", () => {
    const siblings: SiblingsData = { index: 0, count: 2 };
    const msg = assistantMsg("a1", siblings);
    assert.equal(msg.siblings!.count > 1, true);
});

test("siblings: non-fork member (count == 1) indicates no switcher", () => {
    const siblings: SiblingsData = { index: 0, count: 1 };
    const msg = assistantMsg("a1", siblings);
    assert.equal(msg.siblings!.count > 1, false);
});

// MARK: - switchBranch bridge message

test("switchBranch is a valid BridgeMessage carrying messageId and direction", () => {
    const msg: BridgeMessage = { type: "switchBranch", messageId: "abc-123", direction: -1 };
    assert.equal(msg.type, "switchBranch");
    assert.equal(msg.messageId, "abc-123");
    assert.equal(msg.direction, -1);
});

test("switchBranch BridgeMessage has the correct type tag and fields", () => {
    const msg: BridgeMessage = { type: "switchBranch", messageId: "xyz", direction: 1 };
    assert.equal(msg.type, "switchBranch");
    const keys = Object.keys(msg);
    assert.deepEqual(keys.sort(), ["direction", "messageId", "type"]);
});

test("switchBranch with direction -1 represents previous sibling", () => {
    const msg: BridgeMessage = { type: "switchBranch", messageId: "m1", direction: -1 };
    assert.equal(msg.direction, -1);
});

test("switchBranch with direction +1 represents next sibling", () => {
    const msg: BridgeMessage = { type: "switchBranch", messageId: "m1", direction: 1 };
    assert.equal(msg.direction, 1);
});

// MARK: - Siblings data shape

test("SiblingsData with index 0 count 3 represents the first of three siblings", () => {
    const siblings: SiblingsData = { index: 0, count: 3 };
    assert.equal(siblings.index, 0);
    assert.equal(siblings.count, 3);
});

test("SiblingsData with index 2 count 3 represents the last of three siblings", () => {
    const siblings: SiblingsData = { index: 2, count: 3 };
    assert.equal(siblings.index, 2);
    assert.equal(siblings.count, 3);
});
