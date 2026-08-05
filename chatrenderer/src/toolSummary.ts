// Collapsed tool-call summaries. Pure functions (no Preact/DOM) so they can
// be unit-tested in Node directly.
//
// The collapsed tool block shows two single-line summaries, each truncated
// with an ellipsis by CSS:
//  1. tool name + the call's most important arguments
//     (`summarizeToolCall`), and
//  2. the call's status + a one-line description (`summarizeToolResult`).
//
// For internal tools we know which arguments matter (path for read_file, the
// command for shell, the affected paths for apply_patch, ...). For everything
// else we fall back to `key: value` pairs ordered required-first (the host
// stamps the schema's `required` list onto each ToolCall), then optional;
// without that list the JSON key order is preserved.

import { parseToolArgs } from "./toolArgs";
import type { ToolArgEntry } from "./toolArgs";

/** One piece of the collapsed argument summary. `key: null` marks a tool's
 *  primary argument, rendered as a bare value (e.g. the path for read_file);
 *  everything else renders as `key: value`. */
export interface ToolSummaryEntry {
  key: string | null;
  /** Single-line value (newlines already collapsed to ⏎). */
  value: string;
}

/** Collapse newlines so a value fits the single-line summary. Whitespace
 *  around the break is dropped; the break itself becomes a visible marker. */
function oneLine(s: string): string {
  return s.replace(/\s*\n+\s*/g, "⏎").trim();
}

/** Display string for a scalar argument value; null for objects/arrays. */
function scalar(v: unknown): string | null {
  if (typeof v === "string") return oneLine(v);
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  return null;
}

/** Display string for any argument value: scalars verbatim, arrays of
 *  scalars joined, anything else compact JSON. */
function anyValue(v: unknown): string {
  const s = scalar(v);
  if (s !== null) return s;
  if (Array.isArray(v) && v.every((x) => scalar(x) !== null)) {
    return v.map((x) => scalar(x)!).join(" ");
  }
  return JSON.stringify(v);
}

// ── Internal tools ──────────────────────────────────────────────────────

interface KnownToolSpec {
  /** Arg keys rendered bare (no `key:` prefix), in order. */
  primary: string[];
  /** Arg keys rendered as `key: value` after the primary ones, in order. */
  secondary?: string[];
}

/** Per-tool argument importance for internal (built-in + configurator) tools.
 *  Tools with no meaningful arguments map to an empty `primary` list. */
const KNOWN_TOOLS: Record<string, KnownToolSpec> = {
  // Built-in: Filesystem
  read_file: { primary: ["path"], secondary: ["offset", "limit"] },
  write_file: { primary: ["path"] },
  ls: { primary: ["path"], secondary: ["recursive"] },
  find_file: { primary: ["pattern"], secondary: ["path"] },
  find_text: { primary: ["regex"], secondary: ["path", "file_pattern"] },
  mkdir: { primary: ["path"] },
  rm: { primary: ["path"], secondary: ["recursive"] },
  stat: { primary: ["path"] },
  pwd: { primary: [] },
  // Built-in: Shell
  shell: { primary: ["command"], secondary: ["cwd", "timeout"] },
  applescript: { primary: ["script"] },
  // Built-in: Utils
  calc: { primary: ["expression"] },
  hash: { primary: ["input"], secondary: ["algorithm"] },
  base64_encode: { primary: ["input"] },
  base64_decode: { primary: ["input"] },
  sleep: { primary: ["seconds"] },
  datetime: { primary: [] },
  uuid: { primary: [] },
  // Configurator
  read_connection: { primary: ["id"] },
  write_connection: { primary: ["id"] },
  delete_connection: { primary: ["id"] },
  check_connection: { primary: ["id"] },
  read_mcp: { primary: ["name"] },
  write_mcp: { primary: ["name"] },
  delete_mcp: { primary: ["name"] },
  read_role: { primary: ["name"] },
  write_role: { primary: ["name"] },
  delete_role: { primary: ["name"] },
  read_prompt: { primary: ["name"] },
  write_prompt: { primary: ["name"] },
  delete_prompt: { primary: ["name"] },
  write_config: { primary: ["content"] },
  check_mcp_stdio: { primary: ["command"] },
  check_mcp_http: { primary: ["endpoint"] },
  list_connections: { primary: [] },
  list_mcps: { primary: [] },
  list_roles: { primary: [] },
  list_prompts: { primary: [] },
  read_config: { primary: [] },
  read_log: { primary: [] },
};

/** Extract the affected paths from an apply_patch patch text. A `Move to`
 *  renames the previously listed path into `old → new`. */
export function extractPatchPaths(patch: string): string[] {
  const paths: string[] = [];
  for (const line of patch.split("\n")) {
    let m = /^\*\*\* (?:Add|Delete|Update) File: (.+)$/.exec(line);
    if (m) {
      paths.push(m[1].trim());
      continue;
    }
    m = /^\*\*\* Move to: (.+)$/.exec(line);
    if (m && paths.length > 0) {
      paths[paths.length - 1] = `${paths[paths.length - 1]} → ${m[1].trim()}`;
    }
  }
  return paths;
}

/** Custom summaries for internal tools whose primary value isn't a plain
 *  argument lookup. Returns null when the expected arguments are missing, so
 *  the caller falls back to the generic spec-based rendering. */
function customKnownSummary(
  name: string,
  obj: Record<string, unknown>,
): ToolSummaryEntry[] | null {
  switch (name) {
    case "mv": {
      const src = scalar(obj.src);
      const dst = scalar(obj.dst);
      if (src === null || dst === null) return null;
      return [{ key: null, value: `${src} → ${dst}` }];
    }
    case "git": {
      if (!Array.isArray(obj.args)) return null;
      return [{ key: null, value: obj.args.map((a) => scalar(a) ?? JSON.stringify(a)).join(" ") }];
    }
    case "apply_patch": {
      if (typeof obj.patch !== "string") return null;
      const paths = extractPatchPaths(obj.patch);
      return paths.length > 0 ? [{ key: null, value: paths.join(", ") }] : null;
    }
    default:
      return null;
  }
}

const CUSTOM_KNOWN_TOOLS = new Set(["mv", "git", "apply_patch"]);

/** Summary for an internal tool, or null when the tool isn't known. */
function knownToolSummary(
  name: string,
  obj: Record<string, unknown>,
): ToolSummaryEntry[] | null {
  if (CUSTOM_KNOWN_TOOLS.has(name)) {
    const custom = customKnownSummary(name, obj);
    if (custom !== null) return custom;
    // Fall through to the generic table when the custom builder couldn't use
    // the arguments (e.g. mv without src/dst) — mv/git/apply_patch have no
    // table entry, so this returns null and the caller goes generic.
  }
  const spec = KNOWN_TOOLS[name];
  if (!spec) return null;
  const out: ToolSummaryEntry[] = [];
  for (const key of spec.primary) {
    if (key in obj) out.push({ key: null, value: anyValue(obj[key]) });
  }
  for (const key of spec.secondary ?? []) {
    if (key in obj) out.push({ key, value: anyValue(obj[key]) });
  }
  return out;
}

// ── Generic (unknown tools) ─────────────────────────────────────────────

/** Single-line value for a parsed argument entry. Multi-line structured
 *  values (arrays/objects) are compacted; multi-line strings get ⏎ marks. */
function inlineEntryValue(e: ToolArgEntry): string {
  if (!e.multiline) return e.value;
  try {
    const v: unknown = JSON.parse(e.value);
    if (Array.isArray(v) && v.every((x) => scalar(x) !== null)) {
      return v.map((x) => scalar(x)!).join(" ");
    }
  } catch {
    // Not JSON — a plain multi-line string.
  }
  return oneLine(e.value);
}

/** Fallback summary for tools we have no per-tool knowledge of: required
 *  arguments first (alphabetical), then optional ones (alphabetical). Without
 *  a `requiredArgs` list the JSON key order is preserved as-is. */
function genericSummary(
  entries: ToolArgEntry[],
  requiredArgs: string[] | null | undefined,
): ToolSummaryEntry[] {
  const mapped: ToolSummaryEntry[] = entries.map((e) => ({
    key: e.key,
    value: inlineEntryValue(e),
  }));
  if (!requiredArgs) return mapped;
  const required = new Set(requiredArgs);
  const byKey = (a: ToolSummaryEntry, b: ToolSummaryEntry) =>
    (a.key ?? "").localeCompare(b.key ?? "");
  const req = mapped.filter((e) => e.key !== null && required.has(e.key)).sort(byKey);
  const opt = mapped.filter((e) => e.key === null || !required.has(e.key)).sort(byKey);
  return [...req, ...opt];
}

// ── Public API ──────────────────────────────────────────────────────────

/** Build the collapsed first-line argument summary for a tool call. */
export function summarizeToolCall(
  name: string,
  args: string,
  requiredArgs?: string[] | null,
): ToolSummaryEntry[] {
  let obj: unknown;
  try {
    obj = JSON.parse(args);
  } catch {
    obj = null;
  }
  if (obj === null || typeof obj !== "object" || Array.isArray(obj)) {
    // Not a JSON object (malformed or still streaming): show the raw string
    // if there's anything to show.
    const trimmed = args.trim();
    return trimmed ? [{ key: null, value: oneLine(trimmed) }] : [];
  }
  const known = knownToolSummary(name, obj as Record<string, unknown>);
  if (known !== null) return known;
  return genericSummary(parseToolArgs(args) ?? [], requiredArgs);
}

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
  /** Single-line description (error text, denial reason, first output line).
   *  May be empty when there's nothing meaningful to say. */
  description: string;
}

export interface ToolResultLike {
  content: string;
  isError: boolean;
  isStreaming?: boolean;
  isDenied?: boolean;
  isCancelled?: boolean;
}

// Mirrors `ToolApproval.denialMessage(for:)` on the host.
const DENIAL_PREFIX = "User denied this tool call with the following reason: ";
const DENIAL_GENERIC = "User denied this tool call";

/** First non-empty line of a (possibly multi-line) text, trimmed. */
function firstLine(text: string): string {
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (t) return t;
  }
  return "";
}

/** Last non-empty line of a (possibly multi-line) text, trimmed. */
function lastLine(text: string): string {
  const lines = text.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    const t = lines[i].trim();
    if (t) return t;
  }
  return "";
}

/** Count of non-empty lines, excluding truncation markers ("... (truncated…)"). */
function countResultLines(text: string): number {
  let n = 0;
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (t && !t.startsWith("...")) n++;
  }
  return n;
}

/** One-line description of a successful result, specialized for internal
 *  tools whose output is a structured list we can count or a log whose tail
 *  (the exit-code line) is the informative part. Falls back to the first
 *  output line for everything else. */
function doneDescription(name: string, content: string): string {
  switch (name) {
    case "read_file": {
      // Text output lines carry the "N | content" gutter; anything else
      // (image/binary notices) falls back to the first line.
      const n = content.split("\n").filter((l) => /^\s*\d+ \| /.test(l)).length;
      if (n > 0) return `Read ${n} ${n === 1 ? "line" : "lines"}.`;
      return firstLine(content);
    }
    case "ls": {
      const n = countResultLines(content);
      return `Listed ${n} ${n === 1 ? "item" : "items"}.`;
    }
    case "find_file":
    case "find_text": {
      const n = countResultLines(content);
      return `Found ${n} ${n === 1 ? "item" : "items"}.`;
    }
    case "apply_patch": {
      // The result is one "Added:/Updated:/Deleted: path" line per file op.
      let added = 0, updated = 0, deleted = 0;
      for (const line of content.split("\n")) {
        const t = line.trim();
        if (t.startsWith("Added:")) added++;
        else if (t.startsWith("Updated:")) updated++;
        else if (t.startsWith("Deleted:")) deleted++;
      }
      const total = added + updated + deleted;
      if (total === 0) return firstLine(content);
      const parts: string[] = [];
      if (added > 0) parts.push(`${added} added`);
      if (updated > 0) parts.push(`${updated} updated`);
      if (deleted > 0) parts.push(`${deleted} deleted`);
      return `Patched ${total} ${total === 1 ? "file" : "files"} (${parts.join(", ")}).`;
    }
    case "git":
    case "shell":
      // Output ends with the "[exit code: N]" line — that's the useful part.
      return lastLine(content);
    default:
      return firstLine(content);
  }
}

/** The denial reason without the boilerplate prefix; empty for a generic
 *  (reason-less) denial. */
function denialReason(content: string): string {
  if (content.startsWith(DENIAL_PREFIX)) {
    return content.slice(DENIAL_PREFIX.length).trim();
  }
  if (content.startsWith(DENIAL_GENERIC)) return "";
  return firstLine(content);
}

/** Build the collapsed second-line status summary. Returns null when there's
 *  no status to show (no result yet and the call isn't running/pending). */
export function summarizeToolResult(
  name: string,
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
  if (result.isDenied) {
    return { kind: "denied", label: "denied", description: denialReason(result.content) };
  }
  if (result.isCancelled) {
    // The content is a fixed boilerplate sentence — the badge says it all.
    return { kind: "cancelled", label: "cancelled", description: "" };
  }
  if (result.isError) {
    return { kind: "error", label: "error", description: firstLine(result.content) };
  }
  return { kind: "done", label: "done", description: doneDescription(name, result.content) };
}
