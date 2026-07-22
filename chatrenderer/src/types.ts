// Shared types between the Swift host and the web renderer.
// These mirror the Swift `ChatMessage` / `MessageRole` models.

export type MessageRole = "system" | "user" | "assistant" | "tool";

/** An image attached to a message, loaded via the custom `ichai://` scheme. */
export interface MessageImage {
  /** The `ichai://{UUID}.{ext}` URL to use as the `src`. */
  url: string;
  /** Original filename for alt text / display. */
  name?: string | null;
}

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
  /** Images attached to the message (user messages only). */
  images?: MessageImage[] | null;
  /** For assistant messages: tool calls issued by the model. */
  toolCalls?: ToolCallData[] | null;
  /** For `tool`-role messages: the result of a tool call. */
  toolResults?: ToolResultData[] | null;
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
  | { type: "updateMessage"; chatId: string; message: ChatMessage }
  | { type: "addMessage"; chatId: string; message: ChatMessage; index: number }
  | { type: "deleteMessage"; chatId: string; messageId: string };

/**
 * Messages flowing JS -> Swift via `window.webkit.messageHandlers.bridge.postMessage(...)`.
 * Used for user actions that the native app must handle (edit, delete, copy, ...).
 */
export type BridgeMessage =
  | { type: "copy"; messageId: string }
  | { type: "edit"; messageId: string }
  | { type: "delete"; messageId: string }
  | { type: "retry" }
  | { type: "scrollState"; atBottom: boolean }
  | { type: "ready" }
  | { type: "requestOlder"; chatId: string }
  | { type: "allowToolCall"; callId: string }
  | { type: "allowToolCallForChat"; callId: string }
  | { type: "denyToolCall"; callId: string };
