// Bridge between the web renderer and the native Swift host.
//
// Swift -> JS:  the host calls `window.chatHost.postMessage(msg)` (registered as
//               a `WKScriptMessageHandler` named "chat"). We expose a typed
//               `onHostMessage` subscriber.
//
// JS -> Swift:  we call `window.webkit.messageHandlers.bridge.postMessage(msg)`
//               (a `WKScriptMessageHandler` named "bridge").

import type { HostMessage, BridgeMessage } from "./types";

type HostSubscriber = (msg: HostMessage) => void;

let subscriber: HostSubscriber | null = null;

/**
 * Register the single host-message subscriber. Called once at app boot.
 * The native side invokes `window.chatHost.postMessage(jsonString)`.
 */
export function setHostSubscriber(fn: HostSubscriber): void {
  subscriber = fn;
}

/**
 * Send a message to the native host. Silently no-ops if the host bridge
 * isn't present (e.g. when running standalone in a browser for dev).
 */
export function sendToHost(msg: BridgeMessage): void {
  const bridge = (window as any).webkit?.messageHandlers?.bridge;
  if (bridge) {
    bridge.postMessage(msg);
  } else if (typeof window !== "undefined") {
    // Dev fallback: log so we can see actions in the browser console.
    console.log("[bridge -> host]", msg);
  }
}

// Expose `chatHost` on the window object. The native WKWebView calls
// `window.chatHost.postMessage(jsonString)`; we parse and dispatch here.
// We attach it as a non-enumerable property so it doesn't leak into Preact
// state or iteration.
declare global {
  interface Window {
    chatHost: {
      postMessage: (raw: string) => void;
    };
  }
}

Object.defineProperty(window, "chatHost", {
  value: {
    postMessage(raw: string) {
      let msg: HostMessage;
      try {
        msg = JSON.parse(raw) as HostMessage;
      } catch (e) {
        console.error("[chatHost] failed to parse host message", e, raw);
        return;
      }
      subscriber?.(msg);
    },
  },
  writable: false,
  enumerable: false,
  configurable: false,
});
