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
import type { RefObject } from "preact";
import { memo } from "preact/compat";
import { createPortal } from "preact/compat";
import type { ChatMessage, AttachmentData, SiblingsData } from "../types";
import { canRegenerate } from "../regenVisibility";
import {
    renderMarkdown,
    renderInline,
    renderMermaidIn,
    restoreCachedMermaid,
    endsWithUnclosedMermaid,
    renderDiff,
    highlightCode,
} from "../markdown";
import { sendToHost } from "../bridge";
import { observeVisibility } from "../visibility";
import { debugLog } from "../debug";
import { parseToolArgs, isEmptyArgs } from "../toolArgs";
import type { ToolArgEntry } from "../toolArgs";
import { toolArgLang, toolResultLang } from "../toolHighlight";
import { transientToolStatus, localToolStatus } from "../toolSummary";
import {
    Copy,
    SquarePen,
    Trash2,
    Brain,
    User,
    Bot,
    Settings,
    AlertTriangle,
    RotateCcw,
    ChevronRight,
    ChevronLeft,
    ChevronDown,
    Wrench,
    Terminal,
    FileText,
} from "lucide-preact";
import type { ToolCallData, ToolResultData, ToolResultImageData } from "../types";

interface Props {
    message: ChatMessage;
    isStreaming: boolean;
    /** The chat's role name (e.g. "Developer"). Used as the title of assistant
     *  messages instead of the generic "Assistant". Null when no role is set. */
    roleName: string | null;
    /** The role's accent color as an "#RRGGBB" hex string, used to color the
     *  assistant message title. Null when no role is set. */
    roleAccent: string | null;
    /** Feature flags gating renderer UI capabilities (regen button, trees).
     *  Absent when the host hasn't sent features (treated as all-false). */
    features?: import("../types").ChatSnapshotFeatures;
    /** Whether this message is the first in the chat. The Regen button is
     *  hidden on the first message (empty prefix — nothing to rebuild a
     *  request from). */
    isFirstMessage: boolean;
    /** Sibling index and count for branch switching. Present only for messages
     *  that are fork members (count > 1). */
    siblings?: SiblingsData | null;
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

/** Render parsed tool-call arguments as a human-readable key/value list.
 *  When `tool` is given, values whose (tool, key) pair has a language hint in
 *  toolHighlight (e.g. TOML for the Configurator's write_config `content`)
 *  are syntax-highlighted instead of shown as plain text. */
function ToolArgEntries({ entries, tool }: { entries: ToolArgEntry[]; tool?: string }) {
    const highlighted = useMemo(() => {
        if (!tool) return null;
        const map = new Map<string, string>();
        for (const e of entries) {
            const lang = toolArgLang(tool, e.key);
            if (!lang) continue;
            const html = highlightCode(e.value, lang);
            if (html !== null) map.set(e.key, html);
        }
        return map;
    }, [entries, tool]);
    return (
        <dl class="tool-args">
            {entries.map((e) => {
                const html = highlighted?.get(e.key);
                return (
                    <div class="tool-arg" key={e.key}>
                        <dt class="tool-arg-key">{e.key}</dt>
                        {html !== undefined ? (
                            <dd
                                class={`hljs tool-arg-value${e.multiline ? " tool-arg-value-multiline" : ""}`}
                                dangerouslySetInnerHTML={{ __html: html }}
                            />
                        ) : (
                            <dd class={`tool-arg-value${e.multiline ? " tool-arg-value-multiline" : ""}`}>{e.value}</dd>
                        )}
                    </div>
                );
            })}
        </dl>
    );
}

/** Render tool-call arguments as a human-readable key/value list.
 *  Falls back to a plain <pre> with the raw string when the arguments aren't
 *  a valid JSON object (e.g. malformed JSON, a JSON array, or a scalar). */
function ToolArgsView({ args, tool }: { args: string; tool?: string }) {
    const entries = useMemo(() => parseToolArgs(args), [args]);
    if (entries === null) {
        return <pre class="tool-call-args">{args}</pre>;
    }
    return <ToolArgEntries entries={entries} tool={tool} />;
}

/** Render a tool result's content. When `lang` is set (a toolHighlight hint
 *  for this tool's result, e.g. JSONC for read_connection) the whole content
 *  is syntax-highlighted as one block. Otherwise a result that is a JSON
 *  object gets the same key/value treatment as call arguments; anything else
 *  stays a raw <pre>. The leading-"{" precondition avoids running JSON.parse
 *  over plainly-textual output.
 *
 *  When the result carries a processed image (from `read_file` on an image),
 *  the output is split into two labeled sections: the image itself (sent to
 *  vision-capable models) and the classification+OCR fallback text (sent to
 *  vision-incapable models), so the user can see exactly what each kind of
 *  model receives. */
function ToolResultContent({
    content,
    lang,
    image,
    callID,
}: {
    content: string;
    lang?: string | null;
    image?: ToolResultImageData | null;
    callID: string;
}) {
    const highlighted = useMemo(() => (lang ? highlightCode(content, lang) : null), [content, lang]);
    const entries = useMemo(() => {
        if (lang) return null;
        if (!content.trimStart().startsWith("{")) return null;
        return parseToolArgs(content);
    }, [content, lang]);
    const imageUrl = image ? `ichai://toolresult/${callID}` : null;

    // Image result: split into two labeled sections so the user can tell what
    // each kind of model receives — the image (vision-capable) and the fallback
    // text (vision-incapable). The `content` is the fallback text (same as
    // `image.fallback`); it's always plain text, never JSON or highlighted.
    if (imageUrl && image) {
        return (
            <>
                <div class="tool-result-section">
                    <div class="tool-call-label">
                        Image
                        <span class="tool-result-label-hint">vision-capable models</span>
                    </div>
                    <div class="tool-result-image">
                        <img src={imageUrl} alt={image.fallback ?? "tool result image"} loading="lazy" />
                    </div>
                </div>
                <div class="tool-result-section">
                    <div class="tool-call-label">
                        Fallback
                        <span class="tool-result-label-hint">vision-incapable models</span>
                    </div>
                    <pre class="tool-call-args">{content}</pre>
                </div>
            </>
        );
    }

    return (
        <>
            {highlighted !== null ? (
                <pre class="hljs tool-call-args" dangerouslySetInnerHTML={{ __html: highlighted }} />
            ) : entries === null ? (
                <pre class="tool-call-args">{content}</pre>
            ) : (
                <ToolArgEntries entries={entries} />
            )}
        </>
    );
}

/** Renderer for the internal `shell` tool: the `command` argument gets its
 *  own bash-highlighted block (like the diff view). Any remaining arguments
 *  (cwd, timeout) are shown as a muted suffix in the block's title, keeping
 *  the focus on the command itself. Falls back to the generic arguments view
 *  when the arguments don't parse to an object with a `command` key. */
function ShellToolCall({ args }: { args: string }) {
    const parsed = useMemo(() => {
        const entries = parseToolArgs(args);
        if (!entries) return null;
        const command = entries.find((e) => e.key === "command");
        if (!command) return null;
        return {
            command: command.value,
            rest: entries.filter((e) => e.key !== "command"),
        };
    }, [args]);

    const commandHtml = useMemo(() => {
        if (!parsed) return null;
        const highlighted = highlightCode(parsed.command, "bash");
        return highlighted === null ? null : `<pre class="hljs tool-command"><code>${highlighted}</code></pre>`;
    }, [parsed]);

    if (!parsed) {
        if (isEmptyArgs(args)) return null;
        return (
            <div class="tool-call">
                <div class="tool-call-label">Arguments</div>
                <ToolArgsView args={args} />
            </div>
        );
    }
    return (
        <div class="tool-call">
            <div class="tool-call-label">
                Command
                {parsed.rest.length > 0 && (
                    <span class="tool-command-extra">{parsed.rest.map((e) => `${e.key}: ${e.value}`).join(" · ")}</span>
                )}
            </div>
            {commandHtml ? (
                <div class="tool-command-container" dangerouslySetInnerHTML={{ __html: commandHtml }} />
            ) : (
                <pre class="tool-call-args">{parsed.command}</pre>
            )}
        </div>
    );
}

/** Render a pre-computed unified diff (from the host) as a colorized code
 *  block via highlight.js's `diff` language. The host builds the diff for
 *  `write_file` calls so the renderer can show what changed instead of raw
 *  JSON arguments. */
function ToolDiffView({ diff }: { diff: string }) {
    const html = useMemo(() => renderDiff(diff), [diff]);
    if (!html) return null;
    return <div class="tool-diff-container" dangerouslySetInnerHTML={{ __html: html }} />;
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

/** Tracks whether an element is visible in the chat viewport. All elements
 *  share a single IntersectionObserver (see visibility.ts). */
function useVisibility<T extends HTMLElement>() {
    const ref = useRef<T>(null);
    const [visible, setVisible] = useState(true);
    useEffect(() => {
        const el = ref.current;
        if (!el) return;
        return observeVisibility(el, setVisible);
    }, []);
    return [ref, visible] as const;
}

/** Tracks a collapsible block so a bottom "collapse" link can be shown when
 *  the expanded block's top scrolls out of view while its bottom is still on
 *  screen (i.e. the block is taller than the viewport). Attach `rootRef` to
 *  the block element and `toggleRef` to its header. */
function useBottomCollapse(open: boolean) {
    const [rootRef, blockVisible] = useVisibility<HTMLDivElement>();
    const [toggleRef, toggleVisible] = useVisibility<HTMLButtonElement>();
    return {
        rootRef,
        toggleRef,
        showCollapse: open && !toggleVisible && blockVisible,
    };
}

/** A small "collapse" link shown at the bottom right of a tall expanded block.
 *  After collapsing, scrolls back to the block's top — collapsing shrinks the
 *  content above the current scroll position, which would otherwise yank the
 *  viewport. */
function CollapseLink({ blockRef, onCollapse }: { blockRef: RefObject<HTMLDivElement>; onCollapse: () => void }) {
    return (
        <div class="collapse-bottom">
            <button
                type="button"
                class="collapse-bottom-btn"
                onClick={() => {
                    onCollapse();
                    requestAnimationFrame(() => {
                        blockRef.current?.scrollIntoView({ block: "start" });
                    });
                }}
            >
                collapse
            </button>
        </div>
    );
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
    const { rootRef: blockRef, toggleRef, showCollapse } = useBottomCollapse(open);
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
    const onAllowForChat = () => {
        // Same as Allow, plus the host remembers this tool as auto-approved for
        // the current chat.
        setOpen(defaultOpen);
        sendToHost({ type: "allowToolCallForChat", callId: call.id });
    };
    const onDeny = () => {
        // The host presents a reason sheet; the block stays open meanwhile.
        sendToHost({ type: "denyToolCall", callId: call.id });
    };

    // Collapsed header summaries: line 1 is the call's key arguments, line 2
    // the status + one-line description. Both are computed by the host and
    // persisted in the chat data; only transient states (pending approval,
    // still running) are derived locally — they can never be persisted. Both
    // lines truncate with an ellipsis in CSS.
    const summary = call.summary ?? "";
    const status = result?.summary ?? transientToolStatus(result, running, pending) ?? localToolStatus(result);

    // Per-tool syntax-highlighting hints (toolHighlight.ts) apply only to
    // host-stamped internal tools, so an external MCP tool that happens to
    // share a bare name (e.g. "read_config") doesn't get false highlighting.
    const toolName = shortToolName(call.name);
    const highlightTool = call.internalTool === true ? toolName : undefined;
    // Error/denied/cancelled results are plain messages, never tool output —
    // leave them unhighlighted.
    const resultLang =
        highlightTool && result && !result.isError && !result.isDenied && !result.isCancelled
            ? toolResultLang(highlightTool)
            : null;

    return (
        <div class={`tool-block${pending ? " tool-block-pending" : ""}`} ref={blockRef}>
            <button class="tool-toggle" ref={toggleRef} onClick={() => setOpen((v) => !v)}>
                <span class="tool-line">
                    <Wrench size={14} class="tool-icon" />
                    <span class="tool-name">{toolName}</span>
                    {open
                        ? // Expanded: the arguments and result are visible below, so the
                          // header carries just the name and the status badge.
                          status && (
                              <>
                                  {status.kind === "running" && <span class="tool-spinner" aria-hidden="true" />}
                                  <span class={`tool-badge tool-badge-${status.kind === "done" ? "ok" : status.kind}`}>
                                      {status.label}
                                  </span>
                              </>
                          )
                        : summary && <span class="tool-summary">{summary}</span>}
                    <span class="tool-chevron">{open ? <ChevronDown size={14} /> : <ChevronRight size={14} />}</span>
                </span>
                {!open && status && (
                    <span class="tool-line tool-status-line">
                        {status.kind === "running" && <span class="tool-spinner" aria-hidden="true" />}
                        <span class={`tool-badge tool-badge-${status.kind === "done" ? "ok" : status.kind}`}>
                            {status.label}
                        </span>
                        {status.description && (
                            <span class={`tool-status-desc${status.kind === "error" ? " tool-status-desc-error" : ""}`}>
                                {status.description}
                            </span>
                        )}
                    </span>
                )}
            </button>
            {open && (
                <div class="tool-content">
                    {call.diff ? (
                        <div class="tool-call">
                            <div class="tool-call-label">Diff</div>
                            <ToolDiffView diff={call.diff} />
                        </div>
                    ) : call.name === "shell" ? (
                        <ShellToolCall args={call.arguments} />
                    ) : !isEmptyArgs(call.arguments) ? (
                        <div class="tool-call">
                            <div class="tool-call-label">Arguments</div>
                            <ToolArgsView args={call.arguments} tool={highlightTool} />
                        </div>
                    ) : null}
                    {result && (
                        <div
                            class={`tool-result${result.isError && !result.isDenied && !result.isCancelled ? " tool-result-error" : ""}`}
                        >
                            <div class="tool-call-label">{result.isStreaming ? "Result (streaming…)" : "Result"}</div>
                            <ToolResultContent
                                content={result.content}
                                lang={resultLang}
                                image={result.image}
                                callID={result.callID}
                            />
                        </div>
                    )}
                    {pending && (
                        <div class="tool-approval">
                            <div class="tool-approval-label">This tool call needs your approval.</div>
                            <div class="tool-approval-actions">
                                <button type="button" class="tool-approval-btn tool-approval-allow" onClick={onAllow}>
                                    Allow once
                                </button>
                                <button
                                    type="button"
                                    class="tool-approval-btn tool-approval-allow-chat"
                                    onClick={onAllowForChat}
                                >
                                    Allow for this chat
                                </button>
                                <button type="button" class="tool-approval-btn tool-approval-deny" onClick={onDeny}>
                                    Deny
                                </button>
                            </div>
                        </div>
                    )}
                    {showCollapse && <CollapseLink blockRef={blockRef} onCollapse={() => setOpen(false)} />}
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
 *  fixed 256×256 squares with the image centered (object-fit: cover). Clicking
 *  a square opens a full-image overlay; clicking the image or outside closes it. */
function ImageGallery({ images }: { images: AttachmentData[] }) {
    const [zoomed, setZoomed] = useState<AttachmentData | null>(null);

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
                    <img src={img.url!} alt={img.name ?? "image"} loading="lazy" />
                </button>
            ))}
            {zoomed &&
                createPortal(
                    <div class="msg-image-zoom-overlay" onClick={closeZoom}>
                        <img class="msg-image-zoomed" src={zoomed.url!} alt={zoomed.name ?? "image"} />
                    </div>,
                    document.body,
                )}
        </div>
    );
}

/** A clickable chip for a text/document attachment. Shows the filename and a
 *  small inline notice for truncation/extraction-failure status. Clicking sends
 *  an `openAttachment` bridge message so the host opens the original in the
 *  system default app. */
function DocumentChip({ attachment }: { attachment: AttachmentData }) {
    const statusText =
        attachment.status === "truncated"
            ? "truncated to 64 KB"
            : attachment.status === "failed"
              ? `extraction failed${attachment.failureReason ? `: ${attachment.failureReason}` : ""}`
              : null;
    return (
        <button
            class="msg-attachment-chip"
            type="button"
            title={attachment.url ? `Open ${attachment.name ?? "file"}` : (attachment.name ?? "file")}
            onClick={() => {
                if (attachment.url) {
                    sendToHost({ type: "openAttachment", url: attachment.url });
                }
            }}
        >
            <FileText size={14} class="msg-attachment-chip-icon" />
            <span class="msg-attachment-chip-name">{attachment.name ?? "document"}</span>
            {statusText && (
                <span
                    class={`msg-attachment-chip-status${attachment.status === "failed" ? " msg-attachment-chip-status-failed" : ""}`}
                >
                    {statusText}
                </span>
            )}
        </button>
    );
}

/** Renders a message's attachments: images inline (click-to-zoom), text and
 *  document attachments as clickable chips with status notices. The extracted
 *  text body is never sent to the renderer — only metadata crosses the bridge. */
function AttachmentGallery({ attachments }: { attachments: AttachmentData[] }) {
    const images = attachments.filter((a) => a.kind === "image" && a.url);
    const docs = attachments.filter((a) => a.kind !== "image");
    return (
        <>
            {images.length > 0 && <ImageGallery images={images} />}
            {docs.length > 0 && (
                <div class="msg-attachments">
                    {docs.map((a) => (
                        <DocumentChip key={a.url ?? a.name} attachment={a} />
                    ))}
                </div>
            )}
        </>
    );
}

export const MessageItem = memo(function MessageItem({
    message,
    isStreaming,
    roleName,
    roleAccent,
    features,
    isFirstMessage,
    siblings,
    defaultThinkingOpen,
    defaultToolOpen,
}: Props) {
    const [hovering, setHovering] = useState(false);
    const [thinkingOpen, setThinkingOpen] = useState(defaultThinkingOpen);
    const {
        rootRef: thinkingBlockRef,
        toggleRef: thinkingToggleRef,
        showCollapse: showThinkingCollapse,
    } = useBottomCollapse(thinkingOpen);
    const bodyRef = useRef<HTMLDivElement>(null);
    // Track whether the message header (top) is visible in the viewport. When
    // the message is taller than the viewport and the top scrolls out of view
    // while the bottom remains visible, we surface the action buttons at the
    // bottom so they remain reachable.
    const [headerRef, topVisible] = useVisibility<HTMLDivElement>();
    const [rootRef, msgVisible] = useVisibility<HTMLDivElement>();

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

    // When the top is scrolled out of view but the message is still on screen,
    // show the action buttons at the bottom (always visible, not hover-gated).
    const showBottomActions = !topVisible && msgVisible;

    const hasThinking = !!message.thinking && message.thinking.trim().length > 0;
    const hasError = !!message.error && message.error.trim().length > 0;
    const hasContent = !!message.content && message.content.trim().length > 0;
    const hasAttachments = !!message.attachments && message.attachments.length > 0;
    const hasToolCalls = !!message.toolCalls && message.toolCalls.length > 0;
    // The request was sent but nothing (thinking, content, tool calls) has
    // arrived yet — show a spinner instead of a blank message.
    const isPending =
        isStreaming && message.role === "assistant" && !hasThinking && !hasContent && !hasToolCalls && !hasError;

    const hoverDetail = [
        formatTimestamp(message.timestamp),
        message.role === "assistant" && message.connectionName ? `via ${message.connectionName}` : null,
    ]
        .filter(Boolean)
        .join(" · ");

    const showRegen = canRegenerate(message, isFirstMessage, features, isStreaming);
    const hasSiblings = !!siblings && siblings.count > 1;
    const switchBranch = (dir: number) => sendToHost({ type: "switchBranch", messageId: message.id, direction: dir });
    const BranchSwitcher = hasSiblings ? (
        <span class="msg-branch-switcher">
            <button
                class="msg-action-btn msg-branch-btn"
                title="Previous sibling"
                disabled={isStreaming}
                onClick={() => switchBranch(-1)}
            >
                <ChevronLeft size={14} />
            </button>
            <span class="msg-branch-count">
                {siblings!.index + 1}/{siblings!.count}
            </span>
            <button
                class="msg-action-btn msg-branch-btn"
                title="Next sibling"
                disabled={isStreaming}
                onClick={() => switchBranch(1)}
            >
                <ChevronRight size={14} />
            </button>
        </span>
    ) : null;

    return (
        <div
            class={`msg msg-${message.role}`}
            data-message-id={message.id}
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
                    {hovering && (
                        <span class="msg-detail" title={hoverDetail}>
                            {hoverDetail}
                        </span>
                    )}
                    <span
                        class="msg-actions"
                        style={{
                            opacity: hovering ? 1 : 0,
                            // Hidden, not just transparent: invisible buttons must not be
                            // clickable or keyboard-focusable.
                            visibility: hovering ? "visible" : "hidden",
                        }}
                    >
                        <button
                            class="msg-action-btn"
                            title="Copy"
                            onClick={() => sendToHost({ type: "copy", messageId: message.id })}
                        >
                            <Copy size={14} />
                        </button>
                        {showRegen && (
                            <button
                                class="msg-action-btn"
                                title="Regenerate"
                                onClick={() => sendToHost({ type: "regenerate", messageId: message.id })}
                            >
                                <RotateCcw size={14} />
                            </button>
                        )}
                        {BranchSwitcher}
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

                {isPending && (
                    <div class="msg-pending" aria-label="Waiting for response">
                        <span class="msg-pending-spinner" aria-hidden="true" />
                    </div>
                )}

                {hasThinking && (
                    <div class="thinking-block" ref={thinkingBlockRef}>
                        <button
                            class="thinking-toggle"
                            ref={thinkingToggleRef}
                            onClick={() => setThinkingOpen((v) => !v)}
                        >
                            <Brain size={14} />
                            <span>Thinking</span>
                            {isStreaming && !hasContent && !hasToolCalls && (
                                <span class="thinking-spinner" aria-hidden="true" />
                            )}
                            {thinkingOpen ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                        </button>
                        {thinkingOpen && <div class="thinking-content">{message.thinking}</div>}
                        {showThinkingCollapse && (
                            <CollapseLink blockRef={thinkingBlockRef} onCollapse={() => setThinkingOpen(false)} />
                        )}
                    </div>
                )}

                {hasAttachments && <AttachmentGallery attachments={message.attachments!} />}

                {hasContent && (
                    <div class="msg-content">
                        {rendered.blockHtml && (
                            <div class="markdown" dangerouslySetInnerHTML={{ __html: rendered.blockHtml }} />
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
                {message.toolCalls &&
                    message.toolCalls.length > 0 &&
                    message.toolCalls.map((call) => {
                        const result = message.toolResults?.find((r) => r.callID === call.id);
                        debugLog(
                            "tool",
                            `render ToolBlock call=${call.name} hasResult=${!!result} isStreaming=${isStreaming}`,
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
                    })}
                {message.role === "tool" &&
                    message.toolResults &&
                    message.toolResults.length > 0 &&
                    !message.toolCalls &&
                    message.toolResults.map((r) => (
                        <div class="tool-block" key={r.callID}>
                            <div class="tool-result-only">
                                <pre
                                    class={`tool-call-args${r.isError && !r.isDenied && !r.isCancelled ? " tool-result-error-text" : ""}`}
                                >
                                    {r.content}
                                </pre>
                            </div>
                        </div>
                    ))}

                {hasError && (
                    <div class="error-block">
                        <div class="error-text">
                            <AlertTriangle size={14} />
                            {message.error}
                        </div>
                        <button class="retry-btn" onClick={() => sendToHost({ type: "retry" })}>
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
                        {showRegen && (
                            <button
                                class="msg-action-btn"
                                title="Regenerate"
                                onClick={() => sendToHost({ type: "regenerate", messageId: message.id })}
                            >
                                <RotateCcw size={14} />
                            </button>
                        )}
                        {BranchSwitcher}
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
