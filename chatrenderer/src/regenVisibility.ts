// Pure visibility logic for the Regen button, extracted from Message.tsx so it
// can be unit-tested without pulling in Preact/DOM dependencies.
import type { ChatMessage, ChatSnapshotFeatures } from "./types";

/** Whether the Regen button should be shown on a message.
 *  - Only on assistant messages.
 *  - Not on the first message (empty prefix — nothing to rebuild a request
 *    from; the engine no-ops in that case).
 *  - Only when the role's `with_response_regen` feature flag is on.
 *  - Not while the chat is streaming. */
export function canRegenerate(
  message: ChatMessage,
  isFirstMessage: boolean,
  features: ChatSnapshotFeatures | undefined,
  isStreaming: boolean,
): boolean {
  if (message.role !== "assistant") return false;
  if (isFirstMessage) return false;
  if (!(features?.responseRegen ?? false)) return false;
  if (isStreaming) return false;
  return true;
}
