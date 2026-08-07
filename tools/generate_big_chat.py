#!/usr/bin/env python3
"""Generate a very large chat file for performance testing the chat renderer.

Writes a chat JSON (same format the app persists) into the Chats directory,
assembled from realistic building blocks: markdown-heavy assistant messages,
thinking blocks, tool calls (incl. diffs and shell commands) and tool results.

Usage: python3 tools/generate_big_chat.py [rounds]  (default: 600 rounds,
each round = user + assistant + one tool message per tool call)
"""

import json
import os
import random
import sys
import time
import uuid
from datetime import datetime

CHATS_DIR = os.path.expanduser("~/iCanHazAI/Chats")
# Apple Cocoa reference date: seconds between 1970-01-01 and 2001-01-01.
COCOA_EPOCH_OFFSET = 978307200

random.seed(42)

# ── Building blocks ─────────────────────────────────────────────────────

USER_PROMPTS = [
    "can you refactor the parser to handle nested expressions?",
    "run the test suite and summarize the failures",
    "find all usages of `computeHash` and show them",
    "write a small utility that batches these requests",
    "explain how the caching layer works, with examples",
    "there's a bug where empty input crashes the CLI — investigate",
    "add a --verbose flag to the deploy script",
    "compare the two sorting implementations for performance",
    "generate a report of code coverage by module",
    "clean up the temporary files in the sandbox",
]

THINKING_BLOCKS = [
    "The user wants me to look into this. Let me start by exploring the "
    "directory structure to understand what we're working with. I'll use "
    "read-only tools first: ls, find_file, find_text.\n\nLet me make "
    "independent calls in parallel to save time.",
    "This is a multi-step task. First I need to understand the current "
    "state of the code, then figure out the minimal change.\n\nI should "
    "be careful not to break the existing tests. Let me check the test "
    "files before touching anything.",
    "Interesting — the error message suggests the issue is in the parsing "
    "layer, not the transport. Let me verify by reading the relevant "
    "source files.\n\nI'll grep for the function name first.",
    "Let me think about edge cases here: empty input, very long lines, "
    "unicode content, and concurrent modification. The naive "
    "implementation handles none of these.\n\nI'll write a defensive "
    "version and test each case.",
]

CODE_SNIPPETS = {
    "python": '''def batch_requests(items, size=50):
    """Split items into batches of at most `size`."""
    for i in range(0, len(items), size):
        yield items[i:i + size]


async def fetch_all(session, urls):
    results = []
    for batch in batch_requests(urls):
        coros = [session.get(u) for u in batch]
        results.extend(await asyncio.gather(*coros))
    return results''',
    "swift": '''struct Cache<Key: Hashable, Value> {
    private var storage: [Key: (Value, Date)] = [:]
    private let ttl: TimeInterval

    func get(_ key: Key) -> Value? {
        guard let (value, date) = storage[key] else { return nil }
        return Date().timeIntervalSince(date) < ttl ? value : nil
    }

    mutating func set(_ key: Key, _ value: Value) {
        storage[key] = (value, Date())
    }
}''',
    "javascript": '''function debounce(fn, delay) {
  let timer = null;
  return function (...args) {
    clearTimeout(timer);
    timer = setTimeout(() => fn.apply(this, args), delay);
  };
}

const onScroll = debounce(() => {
  const el = scrollerRef.current;
  if (el.scrollTop < 60) loadOlder();
}, 150);''',
    "rust": '''impl<T: Clone> RingBuffer<T> {
    fn push(&mut self, item: T) {
        self.buf[self.head] = item;
        self.head = (self.head + 1) % self.buf.len();
        if self.len < self.buf.len() {
            self.len += 1;
        }
    }

    fn iter(&self) -> impl Iterator<Item = &T> {
        (0..self.len).map(move |i| &self.buf[(self.tail + i) % self.buf.len()])
    }
}''',
    "sql": '''SELECT m.id, m.role, COUNT(tc.id) AS tool_calls
FROM messages m
LEFT JOIN tool_calls tc ON tc.message_id = m.id
WHERE m.chat_id = :chat_id
  AND m.created_at > datetime('now', '-7 days')
GROUP BY m.id
HAVING tool_calls > 0
ORDER BY m.created_at DESC
LIMIT 100;''',
}

TABLE_MD = """| Module | Lines | Coverage | Status |
| ------ | ----: | -------: | :----: |
| parser | 1,204 | 94.2% | ✅ |
| transport | 862 | 88.7% | ✅ |
| cache | 415 | 71.3% | ⚠️ |
| cli | 230 | 52.1% | ❌ |
| utils | 178 | 97.9% | ✅ |"""

MERMAID_MD = """```mermaid
flowchart TD
    A[User input] --> B{Valid?}
    B -->|yes| C[Parse request]
    B -->|no| D[Show error]
    C --> E[Build prompt]
    E --> F[Stream response]
    F --> G[Render markdown]
    G --> H[Update UI]
```"""

TASK_LIST_MD = """- [x] reproduce the crash locally
- [x] add a regression test
- [x] fix the nil-coalescing bug in the parser
- [ ] profile memory usage under load
- [ ] update the changelog"""


def markdown_report(i: int) -> str:
    lang, code = random.choice(list(CODE_SNIPPETS.items()))
    return f"""Here's the consolidated report for round {i}.

## Findings

The investigation covered **{random.randint(3, 12)} modules** and surfaced a few issues worth fixing. The most important one is in `parser.py`, where unbalanced brackets aren't rejected early:

```{lang}
{code}
```

### Coverage by module

{TABLE_MD}

### Next steps

{TASK_LIST_MD}

> **Note:** the numbers above were collected with `--strict` enabled. Running without it inflates coverage by roughly 4–6 points because unreachable branches are counted as covered.

The full diff is available in the tool output above. Let me know if you want me to drill into any specific module — `cache` and `cli` are the obvious candidates given their coverage."""


def markdown_explainer(i: int) -> str:
    lang, code = random.choice(list(CODE_SNIPPETS.items()))
    return f"""Good question. The short answer: it's a write-through cache with TTL-based expiry. Here's the flow:

1. Every `set()` stamps the value with the current time.
2. `get()` compares the age against the TTL and returns `nil` for stale entries.
3. Expired entries are evicted lazily — there's no background sweeper, which keeps writes O(1).

```{lang}
{code}
```

The trade-off is that memory usage grows with the number of *distinct* keys, not the number of *live* ones. For this workload (~{random.randint(100, 5000)} keys) that's fine, but it's worth revisiting if the key space ever becomes unbounded.

{MERMAID_MD}

Inline math works too: the hit rate is $h = \\\\frac{{hits}}{{hits + misses}}$, and with a TTL of $t = 60s$ the expected staleness is bounded by $\\\\epsilon \\\\le t \\\\cdot r_{{write}}$."""


def markdown_short(i: int) -> str:
    return random.choice([
        f"Done — all {random.randint(10, 200)} tests pass. The failure you saw was a flaky timeout; I bumped the limit to 5s and it stabilized.",
        f"Found {random.randint(2, 40)} usages. Most are in the hot path, so I'd avoid changing the signature without a deprecation period.",
        "Fixed. The crash was an out-of-bounds slice when the input had a trailing delimiter with no payload. Added a regression test.",
        f"Refactored into {random.randint(2, 6)} smaller functions. Behavior is unchanged; the diff is in the tool output above.",
    ])


def assistant_content(i: int) -> str:
    r = random.random()
    if r < 0.35:
        return markdown_report(i)
    if r < 0.55:
        return markdown_explainer(i)
    return markdown_short(i)


# ── Tool calls ───────────────────────────────────────────────────────────

def make_diff() -> str:
    fname = random.choice(["parser.py", "cache.swift", "deploy.sh", "utils.ts"])
    old = random.randint(10, 90)
    lines = [f"--- a/{fname}", f"+++ b/{fname}", f"@@ -{old},4 +{old},5 @@"]
    lines.append(f" context line {random.randint(1000, 9999)}")
    for _ in range(random.randint(1, 4)):
        lines.append(f"-removed: value = {random.randint(0, 999)}")
    for _ in range(random.randint(1, 5)):
        lines.append(f"+added: value = compute({random.randint(0, 999)})")
    lines.append(f" context line {random.randint(1000, 9999)}")
    return "\n".join(lines)


def make_tool_call(i: int, n: int):
    """Returns (toolCall dict, resultContent, resultSummary)."""
    kind = random.random()
    cid = f"call_{i:03d}_{n}_{uuid.uuid4().hex[:22]}"
    base = {"id": cid, "pendingApproval": False}

    if kind < 0.18:  # write_file with a diff
        fname = f"src/module_{random.randint(1, 20)}.py"
        args = json.dumps({"path": fname, "content": "\n".join(
            f"line {j}: value = {random.randint(0, 9999)}" for j in range(random.randint(5, 40)))})
        return (
            {**base, "name": "write_file", "arguments": args,
             "requiredArgs": ["path", "content"],
             "summary": fname, "diff": make_diff(), "internalTool": True},
            f"Wrote {fname} ({random.randint(1, 9)} KB).",
            {"kind": "done", "label": "done", "description": f"Wrote {fname}."},
        )
    if kind < 0.36:  # shell
        cmd = random.choice([
            "python3 -m pytest tests/ -x -q",
            "grep -rn 'computeHash' src/ | head -50",
            "find . -name '*.tmp' -mtime +7 -delete",
            "git diff --stat HEAD~5",
            "wc -l src/**/*.py | sort -n | tail -20",
        ])
        output = "\n".join(
            random.choice([
                f"tests/test_module_{random.randint(1, 30)}.py PASSED",
                f"src/file_{random.randint(1, 50)}.py:{random.randint(1, 500)}: result = computeHash(data)",
                f"{random.randint(10, 999)} src/module_{random.randint(1, 20)}.py",
                f" ok {random.random():.3f}s",
            ]) for _ in range(random.randint(3, 25)))
        return (
            {**base, "name": "shell", "arguments": json.dumps({"command": cmd}),
             "requiredArgs": ["command"], "summary": cmd, "internalTool": True},
            output,
            {"kind": "done", "label": "done", "description": output.splitlines()[0][:80]},
        )
    if kind < 0.52:  # find_text
        pattern = random.choice(["computeHash", "TODO", "deprecated", "unsafe", "FIXME"])
        matches = "\n".join(
            f"src/dir_{random.randint(1, 8)}/file_{random.randint(1, 40)}.py:{random.randint(1, 400)}: "
            f"context around {pattern} here"
            for _ in range(random.randint(2, 15)))
        return (
            {**base, "name": "find_text",
             "arguments": json.dumps({"pattern": pattern, "path": "src/"}),
             "requiredArgs": ["pattern"],
             "summary": f'"{pattern}" in src/', "internalTool": True},
            matches,
            {"kind": "done", "label": "done",
             "description": f"{matches.count(chr(10)) + 1} matches."},
        )
    if kind < 0.64:  # read_file with JSON-ish result
        payload = json.dumps({
            "name": f"module_{random.randint(1, 20)}",
            "version": f"{random.randint(0, 4)}.{random.randint(0, 20)}.{random.randint(0, 9)}",
            "enabled": random.choice([True, False]),
            "limits": {"rate": random.randint(10, 1000), "burst": random.randint(1, 50)},
            "tags": random.sample(["core", "experimental", "legacy", "fast", "safe"], 3),
        }, indent=2)
        return (
            {**base, "name": "read_file",
             "arguments": json.dumps({"path": f"config/module_{random.randint(1, 20)}.json"}),
             "requiredArgs": ["path"], "summary": "config file", "internalTool": True},
            payload,
            {"kind": "done", "label": "done", "description": "Read config."},
        )
    if kind < 0.76:  # ls
        path = random.choice([".", "src/", "tests/", "config/", "sandbox/"])
        listing = "\n".join(sorted(random.sample([
            "README.md", "main.py", "utils.py", "parser.py", "cache.swift",
            "deploy.sh", "config.json", "data.csv", "notes.txt", "Makefile",
            "Dockerfile", "test_utils.py", "benchmarks/", "docs/", "assets/",
        ], random.randint(4, 12))))
        return (
            {**base, "name": "ls", "arguments": json.dumps({"path": path}),
             "requiredArgs": ["path"], "summary": path, "internalTool": True},
            listing,
            {"kind": "done", "label": "done",
             "description": f"Listed {listing.count(chr(10)) + 1} items."},
        )
    if kind < 0.88:  # calc / hash / datetime-style small calls
        name = random.choice(["calc", "hash", "uuid", "base64"])
        if name == "calc":
            expr = f"({random.randint(1, 99)} + {random.randint(1, 99)}) * {random.randint(2, 9)}"
            args, out = json.dumps({"expression": expr}), str(eval(expr))
            req, summ = ["expression"], expr
        elif name == "hash":
            data = f"payload-{random.randint(0, 99999)}"
            args = json.dumps({"algorithm": "sha256", "data": data})
            out = uuid.uuid5(uuid.NAMESPACE_DNS, data).hex + uuid.uuid4().hex[:32]
            req, summ = ["algorithm", "data"], f"sha256 of {len(data)} bytes"
        elif name == "uuid":
            args, out = "{}", str(uuid.uuid4()).upper()
            req, summ = [], ""
        else:
            data = f"encode me {random.randint(0, 999)}"
            import base64 as b64mod
            args = json.dumps({"data": data, "direction": "encode"})
            out = b64mod.b64encode(data.encode()).decode()
            req, summ = ["data"], "encode"
        return (
            {**base, "name": name, "arguments": args, "requiredArgs": req,
             "summary": summ, "internalTool": True},
            out,
            {"kind": "done", "label": "done", "description": out[:80]},
        )
    # MCP-style external tool
    args = json.dumps({"query": random.choice(["status", "metrics", "health"]),
                       "limit": random.randint(1, 100)})
    out = json.dumps({"ok": True, "elapsed_ms": random.randint(1, 900),
                      "rows": random.randint(0, 500)})
    return (
        {**base, "name": "mcp__monitoring__query", "arguments": args,
         "requiredArgs": ["query"], "summary": "monitoring query"},
        out,
        {"kind": "done", "label": "done", "description": "Query succeeded."},
    )


# ── Assembly ─────────────────────────────────────────────────────────────

def main() -> None:
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 600
    ts = time.time() - COCOA_EPOCH_OFFSET - rounds * 30  # start in the past

    def tick() -> float:
        nonlocal ts
        ts += random.uniform(0.4, 4.0)
        return ts

    messages = []
    for i in range(rounds):
        messages.append({
            "id": str(uuid.uuid4()).upper(),
            "role": "user",
            "content": random.choice(USER_PROMPTS),
            "timestamp": tick(),
        })

        n_calls = random.choices([0, 1, 2, 3, 4], weights=[2, 5, 4, 2, 1])[0]
        calls, results = [], []
        for n in range(n_calls):
            call, result_content, result_summary = make_tool_call(i, n)
            calls.append(call)
            results.append((call["id"], result_content, result_summary))

        assistant = {
            "id": str(uuid.uuid4()).upper(),
            "role": "assistant",
            "connectionName": "test-connection/gpt-synthetic-9000",
            "content": assistant_content(i),
            "thinking": random.choice(THINKING_BLOCKS) if random.random() < 0.5 else None,
            "timestamp": tick(),
            "tokenUsage": {"tokensUsed": random.randint(500, 12000)},
        }
        if calls:
            assistant["toolCalls"] = calls
        # Drop None values (e.g. thinking when absent).
        assistant = {k: v for k, v in assistant.items() if v is not None}
        messages.append(assistant)

        for call_id, content, summary in results:
            messages.append({
                "id": str(uuid.uuid4()).upper(),
                "role": "tool",
                "content": "",
                "timestamp": tick(),
                "toolResults": [{
                    "callID": call_id,
                    "content": content,
                    "isCancelled": False,
                    "isDenied": False,
                    "isError": False,
                    "isStreaming": False,
                    "tool_call_result_summary": summary,
                }],
            })

    chat = {
        "id": str(uuid.uuid4()).upper(),
        "connection": "test/synthetic",
        "role": "Developer",
        "title": f"Synthetic perf chat ({rounds} rounds)",
        "workingDirectory": "/tmp/synthetic",
        "messages": messages,
    }

    os.makedirs(CHATS_DIR, exist_ok=True)
    name = datetime.now().strftime("%Y-%m-%d %H-%M-%S")
    path = os.path.join(CHATS_DIR, f"{name}.json")
    suffix = 1
    while os.path.exists(path):
        path = os.path.join(CHATS_DIR, f"{name}-{suffix}.json")
        suffix += 1

    with open(path, "w") as f:
        json.dump(chat, f, indent=2, sort_keys=True)

    size = os.path.getsize(path)
    n_tool = sum(1 for m in messages if m["role"] == "tool")
    n_calls = sum(len(m.get("toolCalls", [])) for m in messages)
    print(f"Wrote {path}")
    print(f"{size / 1024 / 1024:.1f} MB, {len(messages)} messages "
          f"({n_tool} tool messages, {n_calls} tool calls)")


if __name__ == "__main__":
    main()
