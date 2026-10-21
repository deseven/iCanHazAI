"""Route handlers: the provider endpoints and the /__mock control API."""

import asyncio
import json
import time
from typing import Optional

from aiohttp import web

import catalog
from providers import LITELLM_PATH, PROVIDERS, Provider, error_body
from scenario import ScenarioError, validate_steps
from state import RequestRecord, State
from streams import Dropped, default_steps, play
from validate import Err, validate_anthropic, validate_openai

DEFAULT_REJECTED_KEYS = {"bad-key"}


def _record(state: State, channel: str, request: web.Request) -> RequestRecord:
    headers = {k.lower(): v for k, v in request.headers.items()}
    return state.new_request(channel, request.method, request.path, dict(request.query), headers)


def _reject(provider: Provider, record: RequestRecord, err: Err) -> web.Response:
    record.mock_error = err.message
    record.status = err.status
    record.state = "rejected"
    record.finished_at = time.time()
    return web.json_response(error_body(provider, err.status, err.message, err.error_type), status=err.status)


def check_auth(provider: Provider, request: web.Request, config: dict) -> Optional[Err]:
    rejected = set(config["reject_keys"]) if "reject_keys" in config else DEFAULT_REJECTED_KEYS
    if provider.auth == "x-api-key":
        key = request.headers.get("x-api-key", "")
        if not key or key in rejected:
            return Err(401, "invalid x-api-key", "authentication_error")
        if not request.headers.get("anthropic-version"):
            return Err(400, "anthropic-version: header is required", "invalid_request_error")
        return None
    header = request.headers.get("Authorization", "")
    key = header[7:].strip() if header.lower().startswith("bearer ") else ""
    if provider.auth == "bearer":
        if not key:
            return Err(401, "Missing or malformed Authorization header: expected 'Bearer <key>'.")
        if key in rejected:
            return Err(401, "Authentication Fails: the API key is invalid.")
    elif key and key in rejected:
        return Err(401, "Invalid API Key")
    return None


def chat_handler(provider: Provider, state: State):
    async def handler(request: web.Request) -> web.StreamResponse:
        record = _record(state, provider.name, request)
        raw = await request.read()
        try:
            body = json.loads(raw)
            record.body = body
        except ValueError:
            body = None
            record.body = raw.decode(errors="replace")
        config = state.config[provider.name]

        if err := check_auth(provider, request, config):
            return _reject(provider, record, err)
        validator = validate_anthropic if provider.wire == "anthropic" else validate_openai
        if err := validator(provider, body, config):
            return _reject(provider, record, err)
        if body.get("stream") is not True:
            return _reject(provider, record, Err(400, "The mock only serves streamed completions (stream: true)."))

        scenario = state.next_scenario(provider.name)
        record.scripted = scenario is not None
        record.scenario_id = scenario.id if scenario else None
        steps = scenario.steps if scenario else default_steps(body)
        try:
            return await play(request, state, record, provider, body, steps)
        except Dropped:
            return web.Response(status=500)
        except asyncio.CancelledError:
            record.client_disconnected = True
            record.state = "disconnected"
            raise
        except ConnectionError:
            record.client_disconnected = True
            record.state = "disconnected"
            return web.Response(status=499)
        finally:
            record.finished_at = time.time()

    return handler


def models_handler(provider: Provider, state: State):
    async def handler(request: web.Request) -> web.Response:
        record = _record(state, provider.name, request)
        config = state.config[provider.name]
        if provider.models_need_auth or "Authorization" in request.headers:
            if err := check_auth(provider, request, config):
                return _reject(provider, record, err)
        record.finished_at = time.time()
        if status := config.get("models_status"):
            record.status = status
            record.state = "done"
            return web.json_response(error_body(provider, status, "Mock models error"), status=status)
        record.status = 200
        record.state = "done"
        return web.json_response(catalog.listing(provider.name, config, request.query))

    return handler


def openrouter_key_handler(state: State):
    provider = PROVIDERS["openrouter"]

    async def handler(request: web.Request) -> web.Response:
        record = _record(state, provider.name, request)
        if err := check_auth(provider, request, state.config[provider.name]):
            return _reject(provider, record, err)
        record.status, record.state, record.finished_at = 200, "done", time.time()
        return web.json_response({"data": {"label": "sk-or-v1-mock", "limit": None, "usage": 0, "is_free_tier": False}})

    return handler


def litellm_handler(state: State):
    async def handler(request: web.Request) -> web.Response:
        record = _record(state, "litellm", request)
        record.status, record.state, record.finished_at = 200, "done", time.time()
        return web.json_response(catalog.LITELLM)

    return handler


def unknown_handler(state: State):
    async def handler(request: web.Request) -> web.Response:
        record = _record(state, "unknown", request)
        record.mock_error = f"no route for {request.method} {request.path}"
        record.status, record.state, record.finished_at = 404, "rejected", time.time()
        return web.json_response({"error": {"message": record.mock_error}}, status=404)

    return handler


# ---------------------------------------------------------------------------------------------------------
# Control API
# ---------------------------------------------------------------------------------------------------------


async def _json(request: web.Request) -> dict:
    try:
        body = await request.json()
    except ValueError:
        raise web.HTTPBadRequest(text="body must be JSON")
    if not isinstance(body, dict):
        raise web.HTTPBadRequest(text="body must be a JSON object")
    return body


def control_routes(state: State) -> list:
    async def health(_request):
        return web.json_response({"ok": True})

    async def reset(_request):
        state.reset()
        return web.json_response({"ok": True})

    async def enqueue(request):
        body = await _json(request)
        provider = PROVIDERS.get(body.get("channel"))
        if provider is None:
            raise web.HTTPBadRequest(text=f"unknown channel {body.get('channel')!r}; one of {sorted(PROVIDERS)}")
        steps = body.get("steps", [])
        try:
            validate_steps(provider, steps)
        except ScenarioError as error:
            raise web.HTTPBadRequest(text=str(error))
        return web.json_response({"id": state.enqueue(provider.name, steps).id})

    async def requests(request):
        channel = request.query.get("channel")
        items = [r.to_json() for r in state.requests if channel in (None, r.channel)]
        return web.json_response(items)

    async def release(request):
        state.release(request.match_info["name"])
        return web.json_response({"ok": True})

    async def configure(request):
        body = await _json(request)
        channel = body.pop("channel", None)
        if channel not in PROVIDERS:
            raise web.HTTPBadRequest(text=f"unknown channel {channel!r}")
        state.config[channel].update(body)
        return web.json_response({"ok": True})

    async def status(_request):
        return web.json_response({
            "pending_scenarios": state.pending(),
            "request_count": len(state.requests),
            "unscripted": [r.seq for r in state.requests
                           if r.path.endswith(("/chat/completions", "/messages")) and not r.scripted
                           and r.mock_error is None],
            "mock_errors": [{"seq": r.seq, "path": r.path, "error": r.mock_error}
                            for r in state.requests if r.mock_error],
            "gates": {name: event.is_set() for name, event in state.gates.items()},
        })

    return [
        web.get("/__mock/health", health),
        web.post("/__mock/reset", reset),
        web.post("/__mock/scenarios", enqueue),
        web.get("/__mock/requests", requests),
        web.post("/__mock/gates/{name}/release", release),
        web.post("/__mock/config", configure),
        web.get("/__mock/status", status),
    ]


def provider_routes(state: State) -> list:
    routes = []
    for provider in PROVIDERS.values():
        routes.append(web.post(provider.chat_path, chat_handler(provider, state)))
        routes.append(web.get(provider.models_path, models_handler(provider, state)))
    routes.append(web.get(f"{PROVIDERS['openrouter'].prefix}{PROVIDERS['openrouter'].base_path}/key",
                          openrouter_key_handler(state)))
    routes.append(web.get(LITELLM_PATH, litellm_handler(state)))
    return routes
