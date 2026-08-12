// Shared types between the Swift host and the web renderer.
// These mirror the Swift `ChatMessage` / `MessageRole` models.

import type { ToolStatusSummary } from "./toolSummary";

export type MessageRole = "system" | "user" | "assistant" | "tool";

/** A tool call issued by the assistant. */
export interface ToolCallData {
    id: string;
    name: string;
    /** Raw JSON arguments string as returned by the model. */
    arguments: string;
    /** True while the host is waiting for the user to approve this call. When
     *  set, the block is forced open and Allow/Deny buttons are shown. */
    pendingApproval?: boolean;
    /** Optional pre-rendered unified diff for `write_file`/`apply_patch` calls.
     *  When present, the renderer shows this diff (via highlight.js's diff
     *  language) instead of the raw arguments. Nil for tools that don't produce
     *  diffs. */
    diff?: string | null;
    /** The tool schema's required argument names, stamped by the host when the
     *  call is finalized. Used to order the collapsed header's argument summary
     *  (required first) for tools the renderer has no built-in knowledge of.
     *  Absent for calls from before this field existed. */
    requiredArgs?: string[] | null;
    /** True for in-process internal (Configurator) tools, stamped by the host.
     *  Guards the per-tool syntax-highlighting hints in toolHighlight.ts so
     *  they can't misfire on an external MCP tool with the same bare name. */
    internalTool?: boolean;
    /** The collapsed one-line argument summary, pre-computed by the host and
     *  persisted in the chat data. Absent for calls from before the field
     *  existed — the renderer computes it locally then. */
    summary?: string | null;
}

/** The result of executing a tool call. */
export interface ToolResultData {
    callID: string;
    content: string;
    isError: boolean;
    /** True while the tool is still running and `content` is streaming in. */
    isStreaming?: boolean;
    /** True when the result is a user denial (not a tool failure). Shown as a
     *  "denied" badge instead of "error". */
    isDenied?: boolean;
    /** True when the result was synthesized on stop for a call that never
     *  executed. Shown as a "cancelled" badge instead of "error". */
    isCancelled?: boolean;
    /** The one-line status summary, pre-computed by the host and persisted in
     *  the chat data. Absent for results from before the field existed (and for
     *  transient streaming placeholders) — the renderer computes it locally
     *  then. */
    summary?: ToolStatusSummary | null;
    /** A processed image, present when `read_file` read an image. The renderer
     *  loads it via `ichai://toolresult/{callID}` (served from chat data, no
     *  disk file). The `fallback` text (classification + OCR) is shown
     *  alongside. Absent for all other results. */
    image?: ToolResultImageData | null;
}

/** A processed image carried on a tool result (from `read_file` on an image). */
export interface ToolResultImageData {
    /** The media type, e.g. "image/png". */
    mimeType: string;
    /** The classification+OCR fallback text. */
    fallback: string;
}

/** Sibling position within a fork group, for the branch switcher UI. */
export interface SiblingsData {
    /** 0-based index of this message within its sibling group. */
    index: number;
    /** Total number of siblings in the group (including this one). */
    count: number;
}

export interface ChatMessage {
    id: string;
    role: MessageRole;
    content: string;
    thinking?: string | null;
    error?: string | null;
    /** ISO 8601 timestamp. */
    timestamp: string;
    /** Display name of the connection that produced an assistant response. */
    connectionName?: string | null;
    /** Attachments on the message (user messages only). Images carry an
     *  `ichai://` URL the renderer loads via the custom scheme handler;
     *  text/documents carry metadata only (name, kind, status) — the extracted
     *  text body is never sent to the WebView. */
    attachments?: AttachmentData[] | null;
    /** For assistant messages: tool calls issued by the model. */
    toolCalls?: ToolCallData[] | null;
    /** For `tool`-role messages: the result of a tool call. */
    toolResults?: ToolResultData[] | null;
    /** Sibling index and count for branch switching. Present only for messages
     *  that are fork members (siblings.count > 1). Nil for linear chats and
     *  non-fork messages. */
    siblings?: SiblingsData | null;
}

/** A single attachment reference mirroring the Swift `AttachmentData`. */
export interface AttachmentData {
    /** The kind: "image", "text", or "document". */
    kind: string;
    /** For images: the `ichai://` URL the renderer uses as the `src`. For
     *  text/documents: an `ichai://` reference to the original file, used to
     *  open it in the system app on click. */
    url?: string | null;
    /** Original filename for display/alt text. */
    name?: string | null;
    /** Extraction status for text/document attachments: "ok", "truncated", or
     *  "failed". Nil for images. */
    status?: string | null;
    /** Short failure reason when status is "failed". Nil otherwise. */
    failureReason?: string | null;
}

/** Feature flags gating renderer UI capabilities, derived from the selected
 *  chat's role `[features]` table. Each flag gates a UI capability; all default
 *  to false when the role has no `[features]` table or omits the key. */
export interface ChatSnapshotFeatures {
    /** Whether the per-message Regen button is shown on assistant messages. */
    responseRegen?: boolean;
    /** Whether chat trees (non-destructive regen/edit branching) are enabled.
     *  Declared here so the wire shape doesn't change again; the tree UI itself
     *  arrives later. */
    chatTrees?: boolean;
}

export interface ChatSnapshot {
    /** Stable chat identifier (filename). Changes when the user switches chats. */
    chatId: string;
    messages: ChatMessage[];
    /** Whether a stream is currently in flight for this chat. */
    isStreaming: boolean;
    /** The chat's role name (e.g. "Developer"), shown as the title of assistant
     *  messages. Nil/undefined when no role is set; the renderer falls back to
     *  "Assistant" in that case. */
    roleName?: string | null;
    /** The role's accent color as an "#RRGGBB" hex string, resolved against the
     *  host's current appearance. Used to color the assistant message title.
     *  Appearance-dependent — the host re-pushes a fresh snapshot on theme
     *  change so this tracks light/dark mode. */
    roleAccent?: string | null;
    /** Feature flags gating renderer UI capabilities (regen button, trees).
     *  Derived from the selected chat's role at snapshot time. Absent when the
     *  host hasn't sent features (treated as all-false by the renderer). */
    features?: ChatSnapshotFeatures;
}

/** A node in the tree overview projection: the conversation root, or one
 *  branch-head of a split. The projection mirrors the chat's tree structure
 *  directly — each node is a drawn card, and its `split` (when present) holds
 *  the alternative continuations, each headed by its own node. Everything
 *  between drawn nodes collapses into the node's `messageCount` (shown as a
 *  "{n} messages" badge). */
export interface TreeNode {
    /** The message id this node represents (used for goto-on-click). */
    id: string;
    /** The message role ("user", "assistant", "tool", "system"). */
    role: MessageRole;
    /** A short snippet of the message content (≤100 chars), for the node card. */
    snippet: string;
    /** Number of messages in this branch segment: from this node up to (and
     *  including) the next split's owner, or to the end of the branch. */
    messageCount: number;
    /** Whether this node lies on the active path (root → active leaf). */
    isActive: boolean;
    /** The split this node's segment ends in. Absent → the segment runs to a
     *  leaf (the end of the branch). */
    split?: TreeSplit;
}

/** A fork point: the alternative continuations after a node's segment, each
 *  headed by its own node. Exactly one branch is active (has `isActive`). */
export interface TreeSplit {
    /** The branch heads, in order. */
    branches: TreeNode[];
}

/**
 * Messages flowing Swift -> JS via `window.chatHost.postMessage(...)`.
 * Tagged union so the renderer can switch on `type`.
 *
 * The protocol supports both full snapshots (for chat switches) and
 * incremental updates (for streaming, editing, adding, deleting individual
 * messages). Incremental updates let the web view do targeted DOM patches
 * instead of re-rendering the entire message list.
 */
export type HostMessage =
    | { type: "snapshot"; snapshot: ChatSnapshot }
    | { type: "streaming"; chatId: string; isStreaming: boolean }
    | { type: "theme"; theme: "light" | "dark" }
    | { type: "scrollToBottom" }
    | { type: "startSearch" }
    /** Blank the view and show the spinner; a chat switch is in progress and a
     *  fresh snapshot follows. */
    | { type: "unload" }
    | { type: "updateMessage"; chatId: string; message: ChatMessage }
    | { type: "addMessage"; chatId: string; message: ChatMessage; index: number }
    | { type: "deleteMessage"; chatId: string; messageId: string }
    /** Open (or update) the tree overview mode with the given root. A null/absent
     *  root closes the overview (nothing to show). */
    | { type: "treeOverview"; root?: TreeNode | null }
    /** Close the tree overview mode. */
    | { type: "exitTreeOverview" }
    /** Scroll the (re-rendered) chat to bring `messageId` into view, with a
     *  brief highlight flash. Sent after a branch switch triggered from the
     *  overview so the user lands on the jumped-to message. */
    | { type: "scrollToMessage"; messageId: string };

/**
 * Messages flowing JS -> Swift via `window.webkit.messageHandlers.bridge.postMessage(...)`.
 * Used for user actions that the native app must handle (edit, delete, copy, ...).
 */
export type BridgeMessage =
    | { type: "copy"; messageId: string }
    | { type: "edit"; messageId: string }
    | { type: "delete"; messageId: string }
    | { type: "retry" }
    /** Regenerate the assistant response at `messageId` (an assistant message).
     *  The host truncates everything after it and re-runs the request. */
    | { type: "regenerate"; messageId: string }
    | { type: "scrollState"; atBottom: boolean }
    | { type: "ready" }
    /** The first snapshot of `chatId` has been committed to the DOM (and had a
     *  frame to paint); the host dismisses its chat-switch overlay on this. */
    | { type: "loaded"; chatId: string }
    | { type: "requestOlder"; chatId: string }
    | { type: "allowToolCall"; callId: string }
    | { type: "allowToolCallForChat"; callId: string }
    | { type: "denyToolCall"; callId: string }
    /** Open a document/text attachment's original file in the system default
     *  app. `url` is the `ichai://` reference the host resolves to the file. */
    | { type: "openAttachment"; url: string }
    /** Switch the active branch at the message's fork point. `direction` is
     *  -1 (previous sibling) or +1 (next sibling); the host resolves the
     *  target sibling and calls `setActiveBranch`. */
    | { type: "switchBranch"; messageId: string; direction: number }
    /** Jump to a message from the tree overview. The host resolves the path to
     *  the node, calls `setActiveBranch` for each fork on the way (no-op when
     *  already on-path), closes the overview, pushes the resulting snapshot,
     *  then sends `scrollToMessage`. */
    | { type: "gotoMessage"; messageId: string };
