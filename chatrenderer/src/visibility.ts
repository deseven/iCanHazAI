// Shared visibility tracking.
//
// Message rows, thinking blocks and tool blocks all want to know when they
// (or their header) intersect the chat viewport. A dedicated
// IntersectionObserver per element scales poorly — a long chat would mean
// hundreds of observer instances — so everything funnels through a single
// observer with per-element callbacks.

export type VisibilityCallback = (isIntersecting: boolean) => void;

const callbacks = new Map<Element, VisibilityCallback>();
let observer: IntersectionObserver | null = null;

function ensureObserver(): IntersectionObserver | null {
    if (observer) return observer;
    // Guarded for tests (no DOM) — observing becomes a no-op there.
    if (typeof IntersectionObserver === "undefined" || typeof document === "undefined") {
        return null;
    }
    observer = new IntersectionObserver(
        (entries) => {
            for (const e of entries) callbacks.get(e.target)?.(e.isIntersecting);
        },
        // Root at the chat scroller so "visible" means visible in the chat
        // viewport, not the window.
        { root: document.querySelector(".chat-scroller"), threshold: 0 },
    );
    return observer;
}

/**
 * Observe `el`, invoking `cb` whenever its viewport visibility changes.
 * Returns an unsubscribe function.
 */
export function observeVisibility(el: Element, cb: VisibilityCallback): () => void {
    const obs = ensureObserver();
    if (!obs) return () => {};
    callbacks.set(el, cb);
    obs.observe(el);
    return () => {
        callbacks.delete(el);
        obs.unobserve(el);
    };
}
