// Shared types between the Swift host and the web renderer.
// These mirror the Swift `ChatMessage` / `MessageRole` models.

export type MessageRole = "system" | "user" | "assistant";

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
}

export interface ChatSnapshot {
  /** Stable chat identifier (filename). Changes when the user switches chats. */
  chatId: string;
  messages: ChatMessage[];
  /** Whether a stream is currently in flight for this chat. */
  isStreaming: boolean;
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
  | { type: "requestOlder"; chatId: string };
