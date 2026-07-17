// Pure argument-parsing for tool-call display. No Preact/DOM dependencies so
// it can be unit-tested in Node directly.
//
// Tool-call arguments arrive as a raw JSON string (the model's output). This
// module turns that string into a list of display entries — one per top-level
// key — with values pre-formatted for human reading. Strings keep their
// newlines; objects/arrays are pretty-printed. Returns null when the string
// isn't valid JSON or isn't a JSON object, so callers can fall back to a
// plain-text view.

export interface ToolArgEntry {
  key: string;
  /** Pre-formatted value. May contain newlines for multi-line values. */
  value: string;
  /** True when the value spans multiple lines (string with newlines, or
   *  structured JSON that pretty-prints to more than one line). */
  multiline: boolean;
}

function formatValue(value: unknown): { value: string; multiline: boolean } {
  if (typeof value === "string") {
    return { value, multiline: value.includes("\n") };
  }
  if (value === null) {
    return { value: "null", multiline: false };
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return { value: String(value), multiline: false };
  }
  // Objects and arrays: pretty-printed JSON. Empty containers stringify to a
  // single line ("{}" / "[]"), so multiline tracks that accurately.
  const json = JSON.stringify(value, null, 2);
  return { value: json, multiline: json.includes("\n") };
}

/** True when the arguments string is effectively empty: blank, or `{}`.
 *  Used to hide the whole arguments block in the UI. */
export function isEmptyArgs(args: string): boolean {
  const trimmed = args.trim();
  if (trimmed.length === 0) return true;
  return trimmed === "{}";
}

/** Parse a tool-call arguments JSON string into display entries.
 *  Returns null when the string is not valid JSON or not a JSON object —
 *  callers should fall back to a plain-text view in that case. */
export function parseToolArgs(args: string): ToolArgEntry[] | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(args);
  } catch {
    return null;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }
  return Object.entries(parsed as Record<string, unknown>).map(([key, val]) => ({
    key,
    ...formatValue(val),
  }));
}
