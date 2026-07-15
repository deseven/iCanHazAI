// A single chat message row.
//
// For finished messages we render the full content as block markdown.
// For the message currently being streamed, we split at the last newline:
// the complete part (up to the last `\n`) is rendered as block markdown, and
// the partial trailing line is rendered as inline markdown. This avoids
// re-laying-out every table/code-block on every incoming token — block
// markdown only re-renders when a newline arrives (a block completes), and the
// partial line updates cheaply as inline.
import { useMemo, useState, useRef, useEffect, useLayoutEffect, useCallback } from "preact/hooks";
import { memo } from "preact/compat";
import { createPortal } from "preact/compat";
import type { ChatMessage, MessageImage } from "../types";
import { renderMarkdown, renderInline, renderMermaidIn, restoreCachedMermaid, endsWithUnclosedMermaid } from "../markdown";
import { sendToHost } from "../bridge";
import { debugLog } from "../debug";
import { Copy, SquarePen, Trash2, Brain, User, Bot, Settings, AlertTriangle, RotateCcw, ChevronRight, ChevronDown, Wrench, Terminal } from "lucide-preact";
import type { ToolCallData, ToolResultData } from "../types";

interface Props {
  message: ChatMessage;
  isStreaming: boolean;
  /** The chat's role name (e.g. "Developer"). Used as the title of assistant
   *  messages instead of the generic "Assistant". Null when no role is set. */
  roleName: string | null;
  /** The role's accent color as an "#RRGGBB" hex string, used to color the
   *  assistant message title. Null when no role is set. */
  roleAccent: string | null;
  /** Whether Thinking blocks should be expanded by default (host preference). */
  defaultThinkingOpen: boolean;
  /** Whether Tool Use blocks should be expanded by default (host preference). */
  defaultToolOpen: boolean;
}

function roleLabel(role: string, roleName: string | null): string {
  switch (role) {
    case "system":
      return "System";
    case "user":
      return "You";
    case "assistant":
      // Prefer the chat's actual role name (e.g. "Developer") over the
      // generic "Assistant" when one is set.
      return roleName ?? "Assistant";
    case "tool":
      return "Tool";
    default:
      return role;
  }
}

function AvatarIcon({ role }: { role: string }) {
  switch (role) {
    case "system":
      return <Settings size={24} />;
    case "user":
      return <User size={24} />;
    case "assistant":
      return <Bot size={24} />;
    case "tool":
      return <Terminal size={24} />;
    default:
      return null;
  }
}

/** Pretty-print a JSON arguments string; falls back to the raw string. */
function prettyPrintArgs(args: string): string {
  try {
    return JSON.stringify(JSON.parse(args), null, 2);
  } catch {
    return args;
  }
}

/** Strip the `mcp__{server}__` namespace prefix for display. */
function shortToolName(name: string): string {
  if (name.startsWith("mcp__")) {
    const rest = name.slice("mcp__".length);
    const idx = rest.indexOf("__");
    if (idx >= 0) return rest.slice(idx + 2);
  }
  return name;
}

/** A collapsible block showing a tool call and (optionally) its result. */
function ToolBlock({
  call,
  result,
  isStreaming,
  defaultOpen,
}: {
  call: ToolCallData;
  result?: ToolResultData;
  isStreaming: boolean;
  defaultOpen: boolean;
}) {
  // `running` covers two cases: no result yet (the call hasn't returned), or a
  // result whose `isStreaming` flag is set (the server is streaming progress).
  const running = (!result && isStreaming) || (result?.isStreaming ?? false);
  const pending = call.pendingApproval === true;
  const [open, setOpen] = useState(defaultOpen);
  // Force the block open whenever approval is requested so the user can see
  // the arguments and the Allow/Deny buttons.
  useEffect(() => {
    if (pending) setOpen(true);
  }, [pending]);
  // Once a denial is finalized the host has dismissed its reason sheet, so
  // collapse the block back to its default state (stays open only when the
  // renderer defaults to expanded tool use via `withExpandedToolUse`).
  useEffect(() => {
    if (result && !result.isStreaming && result.isDenied) setOpen(defaultOpen);
  }, [result?.isDenied, result?.isStreaming, defaultOpen]);

  const onAllow = () => {
    // Collapse (unless the renderer defaults to expanded tool use) and let the
    // host proceed with execution.
    setOpen(defaultOpen);
    sendToHost({ type: "allowToolCall", callId: call.id });
  };
  const onDeny = () => {
    // The host presents a reason sheet; the block stays open meanwhile.
    sendToHost({ type: "denyToolCall", callId: call.id });
  };

  return (
    <div class={`tool-block${pending ? " tool-block-pending" : ""}`}>
      <button class="tool-toggle" onClick={() => setOpen((v) => !v)}>
        <Wrench size={14} />
        <span class="tool-name">{shortToolName(call.name)}</span>
        {pending && <span class="tool-badge tool-badge-pending">approval</span>}
        {running && <span class="tool-spinner" aria-hidden="true" />}
        {result && !result.isStreaming && result.isDenied && (
          <span class="tool-badge tool-badge-denied">denied</span>
        )}
        {result && !result.isStreaming && !result.isDenied && result.isError && (
          <span class="tool-badge tool-badge-error">error</span>
        )}
        {result && !result.isStreaming && !result.isDenied && !result.isError && (
          <span class="tool-badge tool-badge-ok">done</span>
        )}
        {result?.isStreaming && <span class="tool-badge tool-badge-running">running</span>}
        {open ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
      </button>
      {open && (
        <div class="tool-content">
          <div class="tool-call">
            <div class="tool-call-label">Arguments</div>
            <pre class="tool-call-args">{prettyPrintArgs(call.arguments)}</pre>
          </div>
          {result && (
            <div class={`tool-result${result.isError && !result.isDenied ? " tool-result-error" : ""}`}>
              <div class="tool-call-label">
                {result.isStreaming ? "Result (streaming…)" : "Result"}
              </div>
              <pre class="tool-call-args">{result.content}</pre>
            </div>
          )}
          {pending && (
            <div class="tool-approval">
              <div class="tool-approval-label">This tool call needs your approval.</div>
              <div class="tool-approval-actions">
                <button
                  type="button"
                  class="tool-approval-btn tool-approval-allow"
                  onClick={onAllow}
                >
                  Allow
                </button>
                <button
                  type="button"
                  class="tool-approval-btn tool-approval-deny"
                  onClick={onDeny}
                >
                  Deny
                </button>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function formatTimestamp(iso: string): string {
  try {
    const d = new Date(iso);
    return d.toLocaleString(undefined, {
      dateStyle: "medium",
      timeStyle: "short",
    });
  } catch {
    return "";
  }
}

/** Split streaming content into a complete (block) part and a partial (inline) part. */
function splitStreaming(content: string): { block: string; partial: string } {
  const idx = content.lastIndexOf("\n");
  if (idx < 0) return { block: "", partial: content };
  return {
    block: content.slice(0, idx + 1),
    partial: content.slice(idx + 1),
  };
}

/** A gallery of image squares with click-to-zoom. Images are displayed as
 *  fixed 512×512 squares with the image centered (object-fit: cover). Clicking
 *  a square opens a full-image overlay; clicking outside closes it. */
function ImageGallery({ images }: { images: MessageImage[] }) {
  const [zoomed, setZoomed] = useState<MessageImage | null>(null);

  const closeZoom = useCallback(() => setZoomed(null), []);

  // Close on Escape.
  useEffect(() => {
    if (!zoomed) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setZoomed(null);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [zoomed]);

  return (
    <div class="msg-images">
      {images.map((img) => (
        <button
          key={img.url}
          class="msg-image-square"
          type="button"
          title={img.name ?? "image"}
          onClick={() => setZoomed(img)}
        >
          <img src={img.url} alt={img.name ?? "image"} loading="lazy" />
        </button>
      ))}
      {zoomed &&
        createPortal(
          <div class="msg-image-zoom-overlay" onClick={closeZoom}>
            <img
              class="msg-image-zoomed"
              src={zoomed.url}
              alt={zoomed.name ?? "image"}
              onClick={(e) => e.stopPropagation()}
            />
          </div>,
          document.body,
        )}
    </div>
  );
}

export const MessageItem = memo(function MessageItem({
  message,
  isStreaming,
  roleName,
  roleAccent,
  defaultThinkingOpen,
  defaultToolOpen,
}: Props) {
  const [hovering, setHovering] = useState(false);
  const [thinkingOpen, setThinkingOpen] = useState(defaultThinkingOpen);
  const [topVisible, setTopVisible] = useState(true);
  const [msgVisible, setMsgVisible] = useState(true);
  const bodyRef = useRef<HTMLDivElement>(null);
  const headerRef = useRef<HTMLDivElement>(null);
  const rootRef = useRef<HTMLDivElement>(null);

  // Render content. For streaming, memoize on the block/partial split so we
  // only re-render block HTML when a newline arrives.
  const rendered = useMemo(() => {
    if (isStreaming) {
      const { block, partial } = splitStreaming(message.content);
      return {
        blockHtml: block ? renderMarkdown(block) : "",
        partialHtml: partial ? renderInline(partial) : "",
        // While streaming, the last mermaid fence may still be open. Its
        // diagram is incomplete and must be skipped to avoid a render error.
        skipLastMermaid: endsWithUnclosedMermaid(block),
      };
    }
    return {
      blockHtml: renderMarkdown(message.content),
      partialHtml: "",
      skipLastMermaid: false,
    };
  }, [message.content, isStreaming]);

  // Streaming re-commits the block HTML on every newline, which recreates the
  // `.mermaid` divs empty. Restore cached SVGs synchronously (before paint) so
  // already-drawn diagrams don't flash empty on each chunk. The still-open
  // trailing diagram is skipped (it is incomplete and not in the cache anyway).
  useLayoutEffect(() => {
    if (!bodyRef.current) return;
    restoreCachedMermaid(bodyRef.current, rendered.skipLastMermaid);
  }, [rendered.blockHtml, rendered.skipLastMermaid]);

  // Render any uncached (newly completed) diagrams asynchronously. Also runs
  // once the message finishes. Cached diagrams are already restored above, so
  // this only invokes the expensive mermaid.render for genuinely new content.
  useEffect(() => {
    if (!bodyRef.current) return;
    renderMermaidIn(bodyRef.current, { skipLast: rendered.skipLastMermaid });
  }, [rendered.blockHtml, rendered.skipLastMermaid, isStreaming]);

  // Track whether the message header (top) is visible in the viewport. When
  // the message is taller than the viewport and the top scrolls out of view
  // while the bottom remains visible, we surface the action buttons at the
  // bottom so they remain reachable.
  useEffect(() => {
    const header = headerRef.current;
    const root = rootRef.current;
    if (!header || !root) return;
    const scroller = root.closest(".chat-scroller") as Element | null;
    const rootEl = scroller || null;

    const headerObs = new IntersectionObserver(
      (entries) => {
        for (const e of entries) setTopVisible(e.isIntersecting);
      },
      { root: rootEl, threshold: 0 }
    );
    headerObs.observe(header);

    const rootObs = new IntersectionObserver(
      (entries) => {
        for (const e of entries) setMsgVisible(e.isIntersecting);
      },
      { root: rootEl, threshold: 0 }
    );
    rootObs.observe(root);

    return () => {
      headerObs.disconnect();
      rootObs.disconnect();
    };
  }, []);

  // When the top is scrolled out of view but the message is still on screen,
  // show the action buttons at the bottom (always visible, not hover-gated).
  const showBottomActions = !topVisible && msgVisible;

  const hasThinking = !!message.thinking && message.thinking.trim().length > 0;
  const hasError = !!message.error && message.error.trim().length > 0;
  const hasContent = !!message.content && message.content.trim().length > 0;
  const hasImages = !!message.images && message.images.length > 0;
  const hasToolCalls = !!message.toolCalls && message.toolCalls.length > 0;

  const hoverDetail = [
    formatTimestamp(message.timestamp),
    message.role === "assistant" && message.connectionName
      ? `via ${message.connectionName}`
      : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <div
      class={`msg msg-${message.role}`}
      ref={rootRef}
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => setHovering(false)}
    >
      <div class="msg-avatar" aria-hidden="true">
        <AvatarIcon role={message.role} />
      </div>
      <div class="msg-body" ref={bodyRef}>
        <div class="msg-header" ref={headerRef}>
          <span
            class="msg-role"
            style={message.role === "assistant" && roleAccent ? { color: roleAccent } : undefined}
          >
            {roleLabel(message.role, roleName)}
          </span>
          {hovering && <span class="msg-detail">{hoverDetail}</span>}
          <span class="msg-actions" style={{ opacity: hovering ? 1 : 0 }}>
            <button
              class="msg-action-btn"
              title="Copy"
              onClick={() => sendToHost({ type: "copy", messageId: message.id })}
            >
              <Copy size={14} />
            </button>
            <button
              class="msg-action-btn"
              title="Edit"
              onClick={() => sendToHost({ type: "edit", messageId: message.id })}
            >
              <SquarePen size={14} />
            </button>
            <button
              class="msg-action-btn msg-action-danger"
              title="Delete"
              onClick={() => sendToHost({ type: "delete", messageId: message.id })}
            >
              <Trash2 size={14} />
            </button>
          </span>
        </div>

        {hasThinking && (
          <div class="thinking-block">
            <button
              class="thinking-toggle"
              onClick={() => setThinkingOpen((v) => !v)}
            >
              <Brain size={14} />
              <span>Thinking</span>
              {isStreaming && !hasContent && !hasToolCalls && <span class="thinking-spinner" aria-hidden="true" />}
              {thinkingOpen
                ? <ChevronDown size={14} />
                : <ChevronRight size={14} />}
            </button>
            {thinkingOpen && (
              <div class="thinking-content">{message.thinking}</div>
            )}
          </div>
        )}

        {hasImages && (
          <ImageGallery images={message.images!} />
        )}

        {hasContent && (
          <div class="msg-content">
            {rendered.blockHtml && (
              <div
                class="markdown"
                dangerouslySetInnerHTML={{ __html: rendered.blockHtml }}
              />
            )}
            {rendered.partialHtml && (
              <div
                class="markdown markdown-partial"
                dangerouslySetInnerHTML={{ __html: rendered.partialHtml }}
              />
            )}
            {isStreaming && <span class="streaming-cursor" />}
          </div>
        )}

        {/* Tool calls (assistant) or tool results (tool-role messages).
            Placed after content so the natural order is:
            thinking → response → tool call. */}
        {message.toolCalls && message.toolCalls.length > 0 && (
          message.toolCalls.map((call) => {
            const result = message.toolResults?.find((r) => r.callID === call.id);
            debugLog(
              "tool",
              `render ToolBlock call=${call.name} hasResult=${!!result} isStreaming=${isStreaming}`
            );
            return (
              <ToolBlock
                key={call.id}
                call={call}
                result={result}
                isStreaming={isStreaming}
                defaultOpen={defaultToolOpen}
              />
            );
          })
        )}
        {message.role === "tool" && message.toolResults && message.toolResults.length > 0 && !message.toolCalls && (
          message.toolResults.map((r) => (
            <div class="tool-block" key={r.callID}>
              <div class="tool-result-only">
                <pre class={`tool-call-args${r.isError && !r.isDenied ? " tool-result-error-text" : ""}`}>{r.content}</pre>
              </div>
            </div>
          ))
        )}

        {hasError && (
          <div class="error-block">
            <div class="error-text">
              <AlertTriangle size={14} />
              {message.error}
            </div>
            <button
              class="retry-btn"
              onClick={() => sendToHost({ type: "retry" })}
            >
              <RotateCcw size={12} />
              <span>Retry</span>
            </button>
          </div>
        )}

        {/* Bottom action bar: shown when the header has scrolled out of view
            but the message is still on screen. Space is always reserved so the
            layout doesn't jump when the bar appears. */}
        <div class={`msg-bottom-actions${showBottomActions ? " is-visible" : ""}`}>
          <span class="msg-actions">
            <button
              class="msg-action-btn"
              title="Copy"
              onClick={() => sendToHost({ type: "copy", messageId: message.id })}
            >
              <Copy size={14} />
            </button>
            <button
              class="msg-action-btn"
              title="Edit"
              onClick={() => sendToHost({ type: "edit", messageId: message.id })}
            >
              <SquarePen size={14} />
            </button>
            <button
              class="msg-action-btn msg-action-danger"
              title="Delete"
              onClick={() => sendToHost({ type: "delete", messageId: message.id })}
            >
              <Trash2 size={14} />
            </button>
          </span>
        </div>
      </div>
    </div>
  );
});
