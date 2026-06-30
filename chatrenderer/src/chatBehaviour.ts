// Behaviour flags passed by the native host via URL query parameters.
//
// These are presence-based flags (like the feature flags in markdown.ts):
// `?withExpandedThinking&withExpandedToolUse` enables both. They control the
// default expanded/collapsed state of Thinking and Tool Use blocks in the
// renderer. The user can still collapse/expand individual blocks; this state
// is purely a render default and is never written back to the chat file.

/** Whether Thinking blocks should be expanded by default. */
export const expandThinking: boolean = new URLSearchParams(
  location.search,
).has("withExpandedThinking");

/** Whether Tool Use blocks should be expanded by default. */
export const expandToolUse: boolean = new URLSearchParams(
  location.search,
).has("withExpandedToolUse");
