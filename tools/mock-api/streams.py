"""Encoders for the three wire formats (OpenAI SSE, Anthropic SSE, Ollama NDJSON) and the interpreter that
plays a scenario into a response."""

import asyncio
import json
import socket
import struct
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Optional

from aiohttp import web

from providers import Provider, error_body
from state import RequestRecord, State

ANTHROPIC_STOP = {"stop": "end_turn", "tool_calls": "tool_use", "length": "max_tokens"}


def sse(data: dict, event: Optional[str] = None) -> bytes:
    head = f"event: {event}\n" if event else ""
    return f"{head}data: {json.dumps(data, separators=(',', ':'))}\n\n".encode()


def fragments(text: str, parts: int) -> list:
    """Splits `text` into at most `parts` non-empty pieces."""
    if parts <= 1 or len(text) <= 1:
        return [text]
    parts = min(parts, len(text))
    size = -(-len(text) // parts)
    return [text[i:i + size] for i in range(0, len(text), size)]


def arguments_text(arguments) -> str:
    if arguments is None:
        return "{}"
    return arguments if isinstance(arguments, str) else json.dumps(arguments, separators=(",", ":"))


# ---------------------------------------------------------------------------------------------------------
# OpenAI-style chunks
# ---------------------------------------------------------------------------------------------------------


class OpenAIEncoder:
    def __init__(self, provider: Provider, model: str, include_usage: bool):
        self.p = provider
        self.model = model
        self.include_usage = include_usage
        self.id = f"chatcmpl-{uuid.uuid4().hex[:24]}"
        self.created = int(time.time())
        self.tool_index = 0

    def _chunk(self, delta: dict, finish: Optional[str] = None, usage: Optional[dict] = None,
               choices: bool = True, extra: Optional[dict] = None) -> bytes:
        obj = {"id": self.id, "object": "chat.completion.chunk", "created": self.created, "model": self.model,
               "choices": [{"index": 0, "delta": delta, "finish_reason": finish}] if choices else []}
        if usage is not None:
            obj["usage"] = usage
        elif self.include_usage and self.p.name in ("openai", "deepseek"):
            obj["usage"] = None  # these two put `usage: null` on every other chunk
        if extra:
            obj.update(extra)
        return sse(obj)

    def usage_payload(self, usage: dict) -> dict:
        prompt = usage["input"] + usage["cached"]
        payload = {
            "prompt_tokens": prompt, "completion_tokens": usage["output"], "total_tokens": prompt + usage["output"],
            "prompt_tokens_details": {"cached_tokens": usage["cached"]},
        }
        if self.p.name == "deepseek":
            payload["prompt_cache_hit_tokens"] = usage["cached"]
            payload["prompt_cache_miss_tokens"] = usage["input"]
            payload["completion_tokens_details"] = {"reasoning_tokens": 0}
        if self.p.name == "openrouter":
            payload["cost"] = 0.0001
            payload["is_byok"] = False
        return payload

    def start(self) -> list:
        return [self._chunk({"role": "assistant", "content": ""})]

    def text(self, text: str) -> list:
        return [self._chunk({"content": text})]

    def thinking(self, text: str) -> list:
        return [self._chunk({self.p.thinking_field: text})]

    def tool_call(self, call_id: str, name: str, arguments, split: int) -> list:
        index = self.tool_index
        self.tool_index += 1
        args = arguments_text(arguments)
        head = {"index": index, "id": call_id, "type": "function", "function": {"name": name}}
        if self.p.tool_style == "whole":
            head["function"]["arguments"] = args
            return [self._chunk({"tool_calls": [head]})]
        head["function"]["arguments"] = ""
        chunks = [self._chunk({"tool_calls": [head]})]
        for piece in fragments(args, split):
            chunks.append(self._chunk({"tool_calls": [{"index": index, "function": {"arguments": piece}}]}))
        return chunks

    def keepalive(self) -> list:
        return [b": keep-alive\n\n"]

    def error(self, message: str, error_type: Optional[str]) -> list:
        return [sse(error_body(self.p, 500, message, error_type))]

    def finish(self, reason: str, usage: dict) -> list:
        payload = self.usage_payload(usage)
        style = self.p.usage_style
        if style == "final":
            chunks = [self._chunk({"content": ""}, finish=reason, usage=payload)]
        else:
            chunks = [self._chunk({}, finish=reason)]
            if self.include_usage or self.p.name == "openrouter":
                extra = None
                if style == "timings":
                    extra = {"timings": {"prompt_n": usage["input"], "predicted_n": usage["output"],
                                         "predicted_per_second": 42.0}}
                chunks.append(self._chunk({}, usage=payload, choices=False, extra=extra))
        chunks.append(b"data: [DONE]\n\n")
        return chunks


# ---------------------------------------------------------------------------------------------------------
# Anthropic typed events
# ---------------------------------------------------------------------------------------------------------


class AnthropicEncoder:
    def __init__(self, provider: Provider, model: str, usage: dict):
        self.p = provider
        self.model = model
        self.usage = usage
        self.id = f"msg_{uuid.uuid4().hex[:24]}"
        self.index = -1
        self.open_kind: Optional[str] = None

    def _event(self, data: dict) -> bytes:
        return sse(data, event=data["type"])

    def start(self) -> list:
        message = {
            "id": self.id, "type": "message", "role": "assistant", "model": self.model, "content": [],
            "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": self.usage["input"], "cache_creation_input_tokens": 0,
                      "cache_read_input_tokens": self.usage["cached"], "output_tokens": 1},
        }
        return [self._event({"type": "message_start", "message": message}), self._event({"type": "ping"})]

    def _close(self) -> list:
        if self.open_kind is None:
            return []
        chunks = []
        if self.open_kind == "thinking":
            chunks.append(self._event({"type": "content_block_delta", "index": self.index,
                                       "delta": {"type": "signature_delta", "signature": "mock-signature"}}))
        chunks.append(self._event({"type": "content_block_stop", "index": self.index}))
        self.open_kind = None
        return chunks

    def _open(self, kind: str, block: dict) -> list:
        chunks = self._close()
        self.index += 1
        self.open_kind = kind
        chunks.append(self._event({"type": "content_block_start", "index": self.index, "content_block": block}))
        return chunks

    def text(self, text: str) -> list:
        chunks = [] if self.open_kind == "text" else self._open("text", {"type": "text", "text": ""})
        chunks.append(self._event({"type": "content_block_delta", "index": self.index,
                                   "delta": {"type": "text_delta", "text": text}}))
        return chunks

    def thinking(self, text: str) -> list:
        chunks = [] if self.open_kind == "thinking" else self._open(
            "thinking", {"type": "thinking", "thinking": "", "signature": ""})
        chunks.append(self._event({"type": "content_block_delta", "index": self.index,
                                   "delta": {"type": "thinking_delta", "thinking": text}}))
        return chunks

    def tool_call(self, call_id: str, name: str, arguments, split: int) -> list:
        chunks = self._open("tool_use", {"type": "tool_use", "id": call_id, "name": name, "input": {}})
        for piece in fragments(arguments_text(arguments), split):
            chunks.append(self._event({"type": "content_block_delta", "index": self.index,
                                       "delta": {"type": "input_json_delta", "partial_json": piece}}))
        return chunks + self._close()

    def keepalive(self) -> list:
        return [self._event({"type": "ping"})]

    def error(self, message: str, error_type: Optional[str]) -> list:
        return [self._event({"type": "error", "error": {"type": error_type or "overloaded_error",
                                                         "message": message}})]

    def finish(self, reason: str, usage: dict) -> list:
        chunks = self._close()
        chunks.append(self._event({
            "type": "message_delta",
            "delta": {"stop_reason": ANTHROPIC_STOP.get(reason, reason), "stop_sequence": None},
            "usage": {"output_tokens": usage["output"]},
        }))
        chunks.append(self._event({"type": "message_stop"}))
        return chunks


# ---------------------------------------------------------------------------------------------------------
# Ollama native: newline-delimited JSON, no `data:` prefix and no [DONE]
# ---------------------------------------------------------------------------------------------------------


def ndjson(data: dict) -> bytes:
    return json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"


class OllamaEncoder:
    content_type = "application/x-ndjson"

    def __init__(self, provider: Provider, model: str):
        self.p = provider
        self.model = model
        self.tool_index = 0

    def _event(self, message: dict, done: bool = False, extra: Optional[dict] = None) -> bytes:
        now = datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
        obj = {"model": self.model, "created_at": now, "message": {"role": "assistant", **message}, "done": done}
        if extra:
            obj.update(extra)
        return ndjson(obj)

    def start(self) -> list:
        return []  # no preamble: the first event is the first token

    def text(self, text: str) -> list:
        return [self._event({"content": text})]

    def thinking(self, text: str) -> list:
        return [self._event({"content": "", "thinking": text})]

    def tool_call(self, call_id: Optional[str], name: str, arguments, split: int) -> list:
        """A tool call arrives whole, with object arguments. It has no id unless the scenario names one."""
        if isinstance(arguments, str):
            arguments = json.loads(arguments or "{}")
        call: dict[str, Any] = {"function": {"index": self.tool_index, "name": name, "arguments": arguments or {}}}
        if call_id:
            call["id"] = call_id
        self.tool_index += 1
        return [self._event({"content": "", "tool_calls": [call]})]

    def keepalive(self) -> list:
        return [b"\n"]  # the real server sends none; a client has to skip blank lines anyway

    def error(self, message: str, error_type: Optional[str]) -> list:
        return [ndjson({"error": message})]

    def finish(self, reason: str, usage: dict) -> list:
        prompt = usage["input"] + usage["cached"]  # `prompt_eval_count` includes the cached tokens
        metrics = {
            # A tool call ends with `stop`: there is no `tool_calls` reason.
            "done_reason": "length" if reason == "length" else "stop",
            "total_duration": 174560334, "load_duration": 101397084,
            "prompt_eval_count": prompt, "prompt_eval_duration": 13074791,
            "eval_count": usage["output"], "eval_duration": 52479709,
        }
        if usage["cached"]:
            metrics["prompt_eval_cached_count"] = usage["cached"]  # absent on servers that don't report it
        return [self._event({"content": ""}, done=True, extra=metrics)]


# ---------------------------------------------------------------------------------------------------------
# Scenario interpreter
# ---------------------------------------------------------------------------------------------------------


def request_text_size(body: dict) -> int:
    return len(json.dumps(body.get("messages") or [], separators=(",", ":")))


def planned_usage(steps: list, body: dict) -> dict:
    explicit = next((s for s in reversed(steps) if s["type"] == "usage"), None)
    produced = sum(len(s.get("text", "")) for s in steps if s["type"] in ("text", "thinking"))
    produced += sum(len(arguments_text(s.get("arguments"))) for s in steps if s["type"] == "tool_call")
    usage = {"input": max(1, request_text_size(body) // 4), "output": max(1, produced // 4), "cached": 0}
    if explicit:
        usage.update({k: int(explicit[k]) for k in ("input", "output", "cached") if k in explicit})
    return usage


def default_steps(body: dict) -> list:
    """What an unscripted request gets: an echo of the last user text."""
    last = ""
    for message in reversed(body.get("messages") or []):
        if message.get("role") != "user":
            if message.get("role") == "tool":
                last = "(tool result received)"
                break
            continue
        content = message.get("content")
        if isinstance(content, list):
            last = " ".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
        else:
            last = str(content)
        break
    return [{"type": "text", "text": f"Mock reply to: {last[:200]}"}]


class Dropped(Exception):
    """A `drop` or `close` step ended the connection."""


async def play(request: web.Request, state: State, record: RequestRecord, provider: Provider, body: dict,
               steps: list) -> web.StreamResponse:
    """Plays `steps` as the response to `request` and returns the finished response. Raises ConnectionError /
    CancelledError when the client goes away and `Dropped` after a `drop` step; the caller records those."""
    model = body["model"]

    if steps and steps[0]["type"] == "http_error":
        step = steps[0]
        record.status = step["status"]
        record.state = "done"
        message = step.get("message") or f"Mock error {step['status']}"
        payload = error_body(provider, step["status"], message, step.get("error_type"))
        headers = {"retry-after": "0"} if step["status"] in (429, 503, 529) else {}
        return web.json_response(payload, status=step["status"], headers=headers)

    usage = planned_usage(steps, body)
    wanted = next((s["reason"] for s in reversed(steps) if s["type"] == "finish"), None)
    if provider.wire == "anthropic":
        encoder = AnthropicEncoder(provider, model, usage)
    elif provider.wire == "ollama":
        encoder = OllamaEncoder(provider, model)
    else:
        include = (body.get("stream_options") or {}).get("include_usage") is True
        encoder = OpenAIEncoder(provider, model, include)
    content_type = getattr(encoder, "content_type", "text/event-stream")

    response: Optional[web.StreamResponse] = None

    async def emit(chunks: list) -> web.StreamResponse:
        nonlocal response
        if response is None:
            response = web.StreamResponse(status=200, headers={
                "Content-Type": content_type, "Cache-Control": "no-cache"})
            await response.prepare(request)
            record.status = 200
            record.state = "streaming"
            for chunk in encoder.start():
                await response.write(chunk)
        for chunk in chunks:
            await response.write(chunk)
        return response

    had_tool_calls = False
    for step in steps:
        kind = step["type"]
        if kind == "text":
            await emit(encoder.text(step["text"]))
        elif kind == "thinking":
            await emit(encoder.thinking(step["text"]))
        elif kind == "tool_call":
            had_tool_calls = True
            call_id = step.get("id") or f"call_{uuid.uuid4().hex[:12]}"
            if provider.wire == "anthropic" and not step.get("id"):
                call_id = f"toolu_{uuid.uuid4().hex[:12]}"
            if provider.wire == "ollama":
                call_id = step.get("id")  # Ollama's tool calls carry no id of their own
            await emit(encoder.tool_call(call_id, step["name"], step.get("arguments"), int(step.get("split", 2))))
        elif kind == "open":
            await emit([])
        elif kind == "keepalive":
            await emit(encoder.keepalive())
        elif kind == "delay":
            await asyncio.sleep(step["ms"] / 1000)
        elif kind == "gate":
            previous = record.state
            record.waiting_gate = step["name"]
            record.state = "gate"
            await state.gate(step["name"]).wait()
            record.waiting_gate = None
            record.state = previous
        elif kind == "sse_error":
            stream = await emit(encoder.error(step["message"], step.get("error_type")))
            await stream.write_eof()
            record.state = "done"
            return stream
        elif kind == "drop":
            # A reset (RST), as a network failure looks like: the client sees an error.
            record.state = "done"
            if (transport := request.transport) is not None:
                sock = transport.get_extra_info("socket")
                if sock is not None:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                transport.abort()
            raise Dropped()
        elif kind == "close":
            # A clean close (FIN) in the middle of the stream, without the terminating chunk.
            record.state = "done"
            if (transport := request.transport) is not None:
                transport.close()
            raise Dropped()
        elif kind == "hold":
            record.state = "held"
            await asyncio.Event().wait()  # until the client disconnects (cancels this handler)

    reason = wanted or ("tool_calls" if had_tool_calls else "stop")
    stream = await emit(encoder.finish(reason, usage))
    await stream.write_eof()
    record.state = "done"
    return stream
