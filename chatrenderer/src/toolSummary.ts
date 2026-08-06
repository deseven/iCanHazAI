// Transient tool-call status derivation for the collapsed tool block.
//
// Final states (done/error/denied/cancelled) are computed by the host and
// persisted in the chat data (`ToolResult.summary`); every surface — this
// renderer and the CLI — shows those verbatim. Only the live states are
// derived here, since they can never be persisted: pending approval and
// still-running calls.

export type ToolStatusKind =
  | "pending"
  | "running"
  | "done"
  | "error"
  | "denied"
  | "cancelled";

export interface ToolStatusSummary {
  kind: ToolStatusKind;
  /** Badge text shown before the description. */
  label: string;
  /** Single-line description. May be empty when there's nothing meaningful
   *  to say. */
  description: string;
}

export interface ToolResultLike {
  content: string;
  isError: boolean;
  isStreaming?: boolean;
  isDenied?: boolean;
  isCancelled?: boolean;
}

/** First non-empty line of a (possibly multi-line) text, trimmed. */
function firstLine(text: string): string {
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (t) return t;
  }
  return "";
}

/** The transient status of a tool call, or null when the call is in a final
 *  state — those come from the persisted `ToolResult.summary` instead. */
export function transientToolStatus(
  result: ToolResultLike | undefined,
  running: boolean,
  pending: boolean,
): ToolStatusSummary | null {
  if (pending) return { kind: "pending", label: "approval", description: "" };
  if (result?.isStreaming) {
    return { kind: "running", label: "running", description: firstLine(result.content) };
  }
  if (!result) {
    return running ? { kind: "running", label: "running", description: "" } : null;
  }
  return null;
}
