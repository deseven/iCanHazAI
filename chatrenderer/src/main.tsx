// The chat renderer app.
//
// Renders a list of messages as markdown. Handles:
//  - streaming: the last assistant message updates live; we only re-render
//    the completed portion (up to the last newline) as block markdown and the
//    trailing partial line as inline markdown — cheap and flicker-free.
//  - autoscroll: while streaming, if the user is near the bottom we keep the
//    view pinned to the bottom. If the user scrolls up, we stop auto-following
//    so they can read freely (messenger-style).
//  - infinite scroll: when the user scrolls near the top, we notify the host
//    so it can load older messages (the host owns the full history).
//  - incremental updates: the host can send targeted updateMessage /
//    addMessage / deleteMessage commands so we don't re-render the whole list
//    on every token or edit.
import { render } from "preact";
import { useEffect, useRef, useState, useCallback } from "preact/hooks";
import { ChevronDown, ChevronLeft, ChevronRight, X } from "lucide-preact";
import type { ChatSnapshot, HostMessage } from "./types";
import { setHostSubscriber, sendToHost } from "./bridge";
import { MessageItem } from "./components/Message";
import { setMermaidTheme, featuresReady } from "./markdown";
import { debugLog } from "./debug";
import { expandThinking, expandToolUse } from "./chatBehaviour";
import { runSearch, nextMatch, prevMatch, clearSearch } from "./search";
import "./styles.css";
// highlight.js token colors are defined directly in styles.css, scoped by
// [data-theme="dark"] / [data-theme="light"] (atom-one-dark / atom-one-light).

const APP_ROOT = document.getElementById("app")!;

function ChatApp() {
  const [snapshot, setSnapshot] = useState<ChatSnapshot | null>(null);
  const [theme, setTheme] = useState<"light" | "dark">("dark");
  // Whether we're waiting for the first snapshot from the host. Shows a
  // spinner until content arrives.
  const [loading, setLoading] = useState(true);

  // ── In-chat search ──────────────────────────────────────────────────
  /** Whether the search bar is open. */
  const [searchOpen, setSearchOpen] = useState(false);
  /** Current search query. */
  const [searchQuery, setSearchQuery] = useState("");
  /** Total matches / active (1-based) match index for display. */
  const [searchTotal, setSearchTotal] = useState(0);
  const [searchActive, setSearchActive] = useState(0);
  /** Ref to the search input so we can focus it on open. */
  const searchInputRef = useRef<HTMLInputElement>(null);
  /** Debounce timer for the 200ms search delay. */
  const searchTimerRef = useRef<number | null>(null);
  /** Bump counter to re-run search after incremental message updates. */
  const [searchTick, setSearchTick] = useState(0);

  // Scroll bookkeeping.
  const scrollerRef = useRef<HTMLDivElement>(null);
  /** Whether the user is currently near the bottom (within threshold px). */
  const atBottomRef = useRef(true);
  /** Whether we are programmatically scrolling to the bottom. */
  const autoScrollingRef = useRef(false);
  /** The chat id we're currently rendering, for infinite-scroll dedup. */
  const loadedChatIdRef = useRef<string | null>(null);
  /** Whether an older-messages request is in flight (prevents duplicate fetches). */
  const loadingOlderRef = useRef(false);
  /** Bump counter to trigger the autoscroll effect after incremental updates. */
  const [tick, setTick] = useState(0);
  /** Whether the scroll-to-bottom button should be visible. */
  const [showScrollButton, setShowScrollButton] = useState(false);
  /** Distance from bottom (px) beyond which the button appears. */
  const SCROLL_BUTTON_THRESHOLD = 300;

  // ── Host message handling ───────────────────────────────────────────
  useEffect(() => {
    setHostSubscriber((msg: HostMessage) => {
      switch (msg.type) {
        case "snapshot": {
          const prev = loadedChatIdRef.current;
          const isFirstLoad = prev === null;
          const isNewChat = !isFirstLoad && prev !== msg.snapshot.chatId;
          loadedChatIdRef.current = msg.snapshot.chatId;
          debugLog(
            "load",
            `snapshot chatId=${msg.snapshot.chatId} msgs=${msg.snapshot.messages.length} streaming=${msg.snapshot.isStreaming}` +
              (isFirstLoad ? " (initial)" : isNewChat ? " (chat switch)" : "")
          );
          setSnapshot(msg.snapshot);
          setLoading(false);
          // When switching chats, jump to the bottom and reset follow state.
          if (isFirstLoad || isNewChat) {
            atBottomRef.current = true;
            requestAnimationFrame(() => scrollToBottom(true));
          }
          break;
        }
        case "streaming":
          debugLog("streaming", `chatId=${msg.chatId} isStreaming=${msg.isStreaming}`);
          setSnapshot((s) =>
            s && s.chatId === msg.chatId ? { ...s, isStreaming: msg.isStreaming } : s
          );
          setTick((t) => t + 1);
          break;
        case "theme":
          debugLog("theme", msg.theme);
          setTheme(msg.theme);
          break;
        case "scrollToBottom":
          debugLog("scroll", "scrollToBottom requested");
          requestAnimationFrame(() => scrollToBottom(true));
          break;
        case "startSearch":
          // Toggle the search bar: open if closed, close if already open.
          setSearchOpen((open) => {
            if (open) {
              closeSearch();
              return false;
            }
            return true;
          });
          break;
        case "updateMessage":
          debugLog(
            "edit",
            `updateMessage id=${msg.message.id} role=${msg.message.role} len=${msg.message.content.length}` +
              (msg.message.toolCalls?.length
                ? ` toolCalls=${msg.message.toolCalls.length}`
                : "") +
              (msg.message.toolResults?.length
                ? ` toolResults=${msg.message.toolResults.length}`
                : "")
          );
          setSnapshot((s) => {
            if (!s || s.chatId !== msg.chatId) return s;
            const messages = s.messages.map((m) =>
              m.id === msg.message.id ? msg.message : m
            );
            return { ...s, messages };
          });
          setTick((t) => t + 1);
          setSearchTick((t) => t + 1);
          break;
        case "addMessage":
          debugLog(
            "add",
            `addMessage id=${msg.message.id} role=${msg.message.role} index=${msg.index} len=${msg.message.content.length}`
          );
          setSnapshot((s) => {
            if (!s || s.chatId !== msg.chatId) return s;
            const messages = [...s.messages];
            const idx = Math.min(msg.index, messages.length);
            messages.splice(idx, 0, msg.message);
            return { ...s, messages };
          });
          setTick((t) => t + 1);
          setSearchTick((t) => t + 1);
          break;
        case "deleteMessage":
          debugLog("delete", `deleteMessage id=${msg.messageId}`);
          setSnapshot((s) => {
            if (!s || s.chatId !== msg.chatId) return s;
            const messages = s.messages.filter((m) => m.id !== msg.messageId);
            return { ...s, messages };
          });
          setTick((t) => t + 1);
          setSearchTick((t) => t + 1);
          break;
      }
    });
    debugLog("init", "renderer ready, signaling host");
    // Signal that the renderer is ready to receive snapshots.
    sendToHost({ type: "ready" });
  }, []);

  // Apply theme to <html> so CSS variables resolve, and re-theme mermaid.
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    setMermaidTheme(theme);
  }, [theme]);

  // ── Autoscroll during streaming ─────────────────────────────────────
  // Whenever the snapshot or tick changes (new chunk or incremental update),
  // if the user is near the bottom, keep the view pinned. We use a double-rAF
  // to ensure the DOM has been painted before scrolling.
  useEffect(() => {
    if (!snapshot) return;
    if (atBottomRef.current) {
      requestAnimationFrame(() => {
        requestAnimationFrame(() => scrollToBottom(false));
      });
    }
  }, [snapshot, tick]);

  // ── Scroll handling ─────────────────────────────────────────────────
  const onScroll = useCallback(() => {
    const el = scrollerRef.current;
    if (!el) return;

    // If this scroll event was triggered by our own programmatic scroll-to-bottom,
    // don't treat it as user input.
    if (autoScrollingRef.current) return;

    const distanceFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
    const wasAtBottom = atBottomRef.current;
    const nowAtBottom = distanceFromBottom < 40;
    atBottomRef.current = nowAtBottom;

    setShowScrollButton(distanceFromBottom >= SCROLL_BUTTON_THRESHOLD);

    // Notify the host when the bottom state changes (used to suppress the
    // unread marker).
    if (wasAtBottom !== nowAtBottom) {
      sendToHost({ type: "scrollState", atBottom: nowAtBottom });
    }

    // Infinite scroll: near the top → request older messages.
    if (el.scrollTop < 60 && snapshot && !loadingOlderRef.current) {
      loadingOlderRef.current = true;
      debugLog("scroll", `requestOlder chatId=${snapshot.chatId} (near top)`);
      sendToHost({ type: "requestOlder", chatId: snapshot.chatId });
    }
  }, [snapshot]);

  // Reset the "loading older" flag whenever the message count grows (the host
  // delivered older messages) or the chat changes.
  useEffect(() => {
    loadingOlderRef.current = false;
  }, [snapshot?.messages.length, snapshot?.chatId]);

  // ── Helpers ─────────────────────────────────────────────────────────
  function scrollToBottom(force: boolean) {
    const el = scrollerRef.current;
    if (!el) return;
    if (!force && !atBottomRef.current) return;
    autoScrollingRef.current = true;
    el.scrollTop = el.scrollHeight;
    atBottomRef.current = true;
    setShowScrollButton(false);
    // Clear the flag after the scroll settles.
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        autoScrollingRef.current = false;
      });
    });
  }

  // ── Search helpers ───────────────────────────────────────────────────
  /** Close the search bar and clear all highlights. */
  function closeSearch() {
    if (searchTimerRef.current != null) {
      clearTimeout(searchTimerRef.current);
      searchTimerRef.current = null;
    }
    clearSearch();
    setSearchQuery("");
    setSearchTotal(0);
    setSearchActive(0);
  }

  /** Run the search immediately and update display state. */
  function doSearchNow(q: string) {
    const st = runSearch(q);
    setSearchTotal(st.total);
    setSearchActive(st.total > 0 ? st.active + 1 : 0);
  }

  /** Schedule a search 200ms after the last input (debounced). */
  function scheduleSearch(q: string) {
    if (searchTimerRef.current != null) clearTimeout(searchTimerRef.current);
    searchTimerRef.current = window.setTimeout(() => {
      searchTimerRef.current = null;
      doSearchNow(q);
    }, 200);
  }

  // Focus the input when the search bar opens; clear when it closes.
  useEffect(() => {
    if (searchOpen) {
      requestAnimationFrame(() => searchInputRef.current?.focus());
    } else {
      closeSearch();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchOpen]);

  // Re-run the current search after incremental message updates so new/edited
  // content is reflected in the results.
  useEffect(() => {
    if (!searchOpen) return;
    if (searchQuery.trim()) doSearchNow(searchQuery);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchTick, snapshot?.messages.length]);

  // Global Escape closes the search when the input is focused.
  useEffect(() => {
    if (!searchOpen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        setSearchOpen(false);
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [searchOpen]);

  const messages = snapshot?.messages ?? [];
  const isStreaming = snapshot?.isStreaming ?? false;
  const streamingId =
    isStreaming && messages.length > 0
      ? messages[messages.length - 1].id
      : null;

  return (
    <div class="chat-viewport">
      {searchOpen && (
        <div class="search-bar">
          <input
            ref={searchInputRef}
            class="search-input"
            type="text"
            placeholder="Find in chat"
            value={searchQuery}
            spellcheck={false}
            autocomplete="off"
            onInput={(e) => {
              const v = (e.target as HTMLInputElement).value;
              setSearchQuery(v);
              scheduleSearch(v);
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                if (searchTotal === 0) return;
                // Shift+Enter goes to the previous match, Enter to the next.
                const st = e.shiftKey ? prevMatch() : nextMatch();
                setSearchActive(st.total > 0 ? st.active + 1 : 0);
              }
            }}
          />
          <span class="search-count">
            {searchTotal > 0
              ? `${searchActive} / ${searchTotal}`
              : searchQuery.trim()
                ? "0 / 0"
                : ""}
          </span>
          <button
            type="button"
            class="search-nav-btn"
            title="Previous"
            disabled={searchTotal < 2}
            onClick={() => {
              const st = prevMatch();
              setSearchActive(st.total > 0 ? st.active + 1 : 0);
            }}
          >
            <ChevronLeft size={16} />
          </button>
          <button
            type="button"
            class="search-nav-btn"
            title="Next"
            disabled={searchTotal < 2}
            onClick={() => {
              const st = nextMatch();
              setSearchActive(st.total > 0 ? st.active + 1 : 0);
            }}
          >
            <ChevronRight size={16} />
          </button>
          <button
            type="button"
            class="search-close-btn"
            title="Close"
            onClick={() => setSearchOpen(false)}
          >
            <X size={16} />
          </button>
        </div>
      )}
      <div class="chat-scroller" ref={scrollerRef} onScroll={onScroll}>
        <div class="chat-list">
          {/* Sentinel for infinite scroll; also acts as top padding. */}
          <div class="scroll-sentinel-top" />
          {loading ? (
            <div class="loading-state">
              <div class="spinner" />
            </div>
          ) : messages.length === 0 ? (
            <div class="empty-state">No messages yet</div>
          ) : (
            messages.map((m) => (
              <MessageItem
                key={m.id}
                message={m}
                isStreaming={m.id === streamingId}
                defaultThinkingOpen={expandThinking}
                defaultToolOpen={expandToolUse}
              />
            ))
          )}
          {/* Bottom sentinel; the scroller pins to here. */}
          <div class="scroll-sentinel-bottom" />
        </div>
      </div>
      {showScrollButton && (
        <button
          type="button"
          class="scroll-to-bottom-btn"
          title="Scroll to bottom"
          aria-label="Scroll to bottom"
          onClick={() => scrollToBottom(true)}
        >
          <ChevronDown size={22} />
        </button>
      )}
    </div>
  );
}

// Wait for any enabled optional feature bundles (e.g. KaTeX) to finish
// loading before rendering, so the first render already has all plugins
// registered. When no features are enabled this resolves immediately.
featuresReady.then(() => {
  debugLog("init", "features ready, mounting ChatApp");
  render(<ChatApp />, APP_ROOT);
});
