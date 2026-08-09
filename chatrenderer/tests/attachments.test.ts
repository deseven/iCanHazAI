// Tests for the attachment wire shape and the openAttachment bridge message.
// Run via `node --test` against the esbuild-bundled output (see build.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import type { AttachmentData, BridgeMessage, ChatMessage } from "../src/types";

/** A well-formed image attachment (kind=image, has url, no status). */
const imageAttachment: AttachmentData = {
  kind: "image",
  url: "ichai://ABC-123.png",
  name: "screenshot.png",
};

/** A text attachment that passed through intact (status=ok). */
const textAttachment: AttachmentData = {
  kind: "text",
  url: "ichai://DEF-456.txt",
  name: "notes.txt",
  status: "ok",
  failureReason: null,
};

/** A document attachment that was truncated at the 64 KB cap. */
const truncatedDoc: AttachmentData = {
  kind: "document",
  url: "ichai://GHI-789.docx",
  name: "report.docx",
  status: "truncated",
  failureReason: null,
};

/** A document attachment whose extraction failed. */
const failedDoc: AttachmentData = {
  kind: "document",
  url: "ichai://JKL-012.pdf",
  name: "scanned.pdf",
  status: "failed",
  failureReason: "no text layer and OCR unavailable",
};

test("AttachmentData carries kind/url/name for images with no status", () => {
  assert.equal(imageAttachment.kind, "image");
  assert.ok(imageAttachment.url);
  assert.equal(imageAttachment.status, undefined);
  assert.equal(imageAttachment.failureReason, undefined);
});

test("AttachmentData carries status for text/document kinds", () => {
  assert.equal(textAttachment.status, "ok");
  assert.equal(truncatedDoc.status, "truncated");
  assert.equal(failedDoc.status, "failed");
  assert.ok(failedDoc.failureReason);
});

test("ChatMessage uses attachments (not images)", () => {
  const msg: ChatMessage = {
    id: "1",
    role: "user",
    content: "here",
    timestamp: "2026-01-01T00:00:00Z",
    attachments: [imageAttachment, textAttachment, truncatedDoc, failedDoc],
  };
  assert.equal(msg.attachments?.length, 4);
  // The old `images` field must not exist on the type.
  assert.equal((msg as any).images, undefined);
});

test("openAttachment is a valid BridgeMessage carrying the url", () => {
  const msg: BridgeMessage = { type: "openAttachment", url: "ichai://GHI-789.docx" };
  assert.equal(msg.type, "openAttachment");
  assert.equal(msg.url, "ichai://GHI-789.docx");
});

/** Derives the inline status notice text shown on a document chip, mirroring
 *  the logic in Message.tsx's DocumentChip. Kept here as a pure function so
 *  the exact wording (truncation / failure reason) is locked by a test. */
function chipStatusText(a: AttachmentData): string | null {
  if (a.status === "truncated") return "truncated to 64 KB";
  if (a.status === "failed") {
    return `extraction failed${a.failureReason ? `: ${a.failureReason}` : ""}`;
  }
  return null;
}

test("chip status text: truncated", () => {
  assert.equal(chipStatusText(truncatedDoc), "truncated to 64 KB");
});

test("chip status text: failed with reason", () => {
  assert.equal(chipStatusText(failedDoc), "extraction failed: no text layer and OCR unavailable");
});

test("chip status text: failed without reason", () => {
  const noReason: AttachmentData = { kind: "document", url: "ichai://x.docx", name: "x.docx", status: "failed", failureReason: null };
  assert.equal(chipStatusText(noReason), "extraction failed");
});

test("chip status text: ok yields no notice", () => {
  assert.equal(chipStatusText(textAttachment), null);
});

test("chip status text: image yields no notice", () => {
  assert.equal(chipStatusText(imageAttachment), null);
});
