// Tests for visibility.ts — run via `node --test` against the esbuild-bundled
// output (see build.mjs `test` step). Uses a fake IntersectionObserver since
// there is no DOM in Node.
import { test } from "node:test";
import assert from "node:assert/strict";

class FakeIntersectionObserver {
    static instances: FakeIntersectionObserver[] = [];
    callback: IntersectionObserverCallback;
    options: IntersectionObserverInit | undefined;
    observed = new Set<Element>();

    constructor(cb: IntersectionObserverCallback, options?: IntersectionObserverInit) {
        this.callback = cb;
        this.options = options;
        FakeIntersectionObserver.instances.push(this);
    }
    observe(el: Element) {
        this.observed.add(el);
    }
    unobserve(el: Element) {
        this.observed.delete(el);
    }
    disconnect() {
        this.observed.clear();
    }
    /** Simulate the browser delivering intersection entries. */
    fire(entries: Array<{ target: Element; isIntersecting: boolean }>) {
        this.callback(entries as unknown as IntersectionObserverEntry[], this as unknown as IntersectionObserver);
    }
}

(globalThis as any).document = { querySelector: () => null };
(globalThis as any).IntersectionObserver = FakeIntersectionObserver;

import { observeVisibility } from "../src/visibility";

test("all subscriptions share a single observer instance", () => {
    const before = FakeIntersectionObserver.instances.length;
    const a = {} as Element;
    const b = {} as Element;
    observeVisibility(a, () => {});
    observeVisibility(b, () => {});
    assert.equal(FakeIntersectionObserver.instances.length, before + 1);
    const obs = FakeIntersectionObserver.instances.at(-1)!;
    assert.ok(obs.observed.has(a));
    assert.ok(obs.observed.has(b));
});

test("entries dispatch to the per-element callback", () => {
    const el = {} as Element;
    const other = {} as Element;
    const seen: boolean[] = [];
    observeVisibility(el, (v) => seen.push(v));
    observeVisibility(other, () => {});
    const obs = FakeIntersectionObserver.instances.at(-1)!;
    obs.fire([
        { target: el, isIntersecting: false },
        { target: other, isIntersecting: true },
    ]);
    assert.deepEqual(seen, [false]);
    obs.fire([{ target: el, isIntersecting: true }]);
    assert.deepEqual(seen, [false, true]);
});

test("unsubscribe stops callbacks and unobserves the element", () => {
    const el = {} as Element;
    const seen: boolean[] = [];
    const unsub = observeVisibility(el, (v) => seen.push(v));
    const obs = FakeIntersectionObserver.instances.at(-1)!;
    unsub();
    assert.ok(!obs.observed.has(el));
    obs.fire([{ target: el, isIntersecting: true }]);
    assert.deepEqual(seen, []);
});
