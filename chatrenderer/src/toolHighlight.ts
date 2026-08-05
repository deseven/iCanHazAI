// Per-tool syntax highlighting hints for tool-call display. Pure mapping, no
// Preact/DOM dependencies so it can be unit-tested in Node directly.
//
// Some tools carry structured text in their arguments or results — e.g. the
// internal Configurator tools take whole config files as a `content` argument
// and return raw file contents. This module maps (tool, argument key) and
// tool-result pairs to highlight.js language names so the UI can syntax-
// highlight them instead of showing plain text. Tools without an entry fall
// back to the generic unhighlighted view.

/** highlight.js language for a tool call's argument, by argument key. */
const ARG_LANGS: Record<string, Record<string, string>> = {
  write_connection: { content: "jsonc" },
  write_mcp: { content: "toml" },
  write_role: { content: "toml" },
  write_config: { content: "toml" },
  write_prompt: { content: "markdown" },
  check_mcp_stdio: { command: "bash" },
};

/** highlight.js language for a tool result's whole content. */
const RESULT_LANGS: Record<string, string> = {
  read_connection: "jsonc",
  read_mcp: "toml",
  read_role: "toml",
  read_config: "toml",
  read_prompt: "markdown",
};

/** Language for tool `tool`'s argument `key`, or null for plain text. */
export function toolArgLang(tool: string, key: string): string | null {
  return ARG_LANGS[tool]?.[key] ?? null;
}

/** Language for tool `tool`'s result content, or null for plain text. */
export function toolResultLang(tool: string): string | null {
  return RESULT_LANGS[tool] ?? null;
}
