// Debug overlay for the chat renderer.
//
// When the page is loaded with the `withDebug` query flag (e.g.
// `index.html?withMermaid&withKatex&withDebug`), a collapsible debug panel is
// shown at the very top of the view. All debug output flows through a single
// `debugLog(topic, message)` formatter that prepends a timestamp and autoscrolls
// the panel to the bottom on new content.
//
// When `withDebug` is absent, `debugLog` is a no-op so general code never needs
// to guard calls with conditionals — the formatter itself checks the flag.

/** Whether debug mode is enabled (the `withDebug` query param is present). */
export const debugEnabled: boolean = new URLSearchParams(location.search).has(
  "withDebug"
);

const DEBUG_OVERLAY_ID = "__debug_overlay__";

/**
 * Appends a timestamped debug line to the on-screen debug overlay (if present)
 * and to the browser console. No-op when debug mode is disabled, so callers can
 * invoke it unconditionally without polluting production builds.
 *
 * @param topic   Short label for the source of the message (e.g. "load",
 *                "streaming", "markdown").
 * @param message The human-readable message (or object) to log.
 */
export function debugLog(topic: string, message: unknown): void {
  if (!debugEnabled) return;

  const ts = new Date().toISOString().split("T")[1] ?? "";
  const text =
    typeof message === "string" ? message : JSON.stringify(message);
  const line = `[${ts}] [${topic}] ${text}`;


  const overlay = document.getElementById(DEBUG_OVERLAY_ID);
  if (overlay) {
    overlay.textContent += line + "\n";
    overlay.scrollTop = overlay.scrollHeight;
  }
}

/**
 * Wires up the debug overlay DOM: creates the collapsible panel (collapsed by
 * default) and injects it at the very top of the document body. No-op when
 * debug mode is disabled.
 *
 * Called once at app boot (before rendering) so early log lines are captured.
 */
export function setupDebugOverlay(): void {
  if (!debugEnabled) return;

  let overlay = document.getElementById(DEBUG_OVERLAY_ID) as HTMLPreElement | null;
  if (!overlay) {
    overlay = document.createElement("pre");
    overlay.id = DEBUG_OVERLAY_ID;
    document.body.insertBefore(overlay, document.body.firstChild);
  }

  const wrapper = document.createElement("div");
  wrapper.id = "__debug_wrapper__";
  wrapper.className = "debug-wrapper";

  const header = document.createElement("button");
  header.type = "button";
  header.className = "debug-header";
  header.setAttribute("aria-expanded", "false");
  header.textContent = "▸ Debug";

  const content = document.createElement("div");
  content.className = "debug-content debug-collapsed";

  overlay.remove();
  content.appendChild(overlay);
  overlay.style.display = "block";

  header.addEventListener("click", () => {
    const collapsed = content.classList.toggle("debug-collapsed");
    header.setAttribute("aria-expanded", collapsed ? "false" : "true");
    header.textContent = (collapsed ? "▸" : "▾") + " Debug";
    if (!collapsed) {
      overlay.scrollTop = overlay.scrollHeight;
    }
  });

  wrapper.appendChild(header);
  wrapper.appendChild(content);
  document.body.insertBefore(wrapper, document.body.firstChild);
}
