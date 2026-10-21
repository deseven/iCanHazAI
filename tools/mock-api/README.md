# Mock provider API

A local server that speaks the APIs of DeepSeek, OpenAI, Anthropic, OpenRouter, Ollama (its native API and its OpenAI layer) and llama.cpp (as documented in `dev-docs/`), for the smoke tests (`./build.sh smoke`). It can also be pointed at by hand, e.g. as a custom provider of type Ollama with the endpoint `http://127.0.0.1:<port>/ollama`, or of type OpenAI-compatible with `http://127.0.0.1:<port>/ollama/v1`.

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt   # build.sh smoke does this itself
.venv/bin/python server.py --port 0       # prints "LISTENING http://127.0.0.1:<port>"
```

Streaming only (`stream: true`; Ollama streams unless told not to). Requests are validated strictly (auth headers, required fields, tool call pairing, Anthropic `max_tokens` against the model limit, no `system` role for Anthropic, object tool-call arguments and `tool_name` pairing for Ollama, …) and rejected with the provider's own error shape.

## Routes

The layout mirrors each provider's real base URL under a prefix.

| Prefix | Chat | Models |
| --- | --- | --- |
| `/deepseek` | `POST /chat/completions` | `GET /models` |
| `/openai` | `POST /v1/chat/completions` | `GET /v1/models` |
| `/anthropic` | `POST /v1/messages` | `GET /v1/models` (cursor paginated) |
| `/openrouter` | `POST /api/v1/chat/completions` | `GET /api/v1/models` (`q`, `limit`, `offset`), `GET /api/v1/key` |
| `/ollama` | `POST /api/chat` (native, NDJSON) · `POST /v1/chat/completions` (OpenAI layer) | `GET /api/tags`, `POST /api/show`, `GET /api/ps` (native) · `GET /v1/models` (OpenAI layer) |
| `/llama-cpp` | `POST /v1/chat/completions` | `GET /v1/models`, `GET /props` (outside `/v1`) |
| `/litellm` | | `GET /model_prices_and_context_window.json` (the LiteLLM excerpt the app reads) |

The API key `bad-key` is rejected with 401 everywhere. Without a queued scenario a chat request gets an echo reply (flagged `scripted: false` in the log). Unknown URLs answer 404 and are logged under the channel `unknown`.

Both Ollama APIs and both llama.cpp modes are one channel each (`ollama`, `llama-cpp`): the scenario queue and the request log don't care which API was used.

## Control API (`/__mock`)

| Call | Meaning |
| --- | --- |
| `POST /reset` | Clear scenarios, request log, gates and config |
| `POST /scenarios` `{"channel", "steps": [...]}` | Queue a scenario for the next chat request of the channel (`deepseek`, `openai`, `anthropic`, `openrouter`, `ollama`, `llama-cpp`) |
| `GET /requests[?channel=]` | The request log: headers (lowercased), parsed body, `state`, `status`, `scripted`, `waiting_gate`, `client_disconnected`, `mock_error` |
| `POST /gates/{name}/release` | Release a gate; releasing before it is reached works too |
| `POST /config` `{"channel", ...}` | Per-channel overrides, see below |
| `GET /status` | Pending scenarios, unscripted requests, mock-side rejections |

`/config` keys: `page_size`, `models`, `models_status`, `reject_keys` (any channel); for `ollama`: `loaded` (what `/api/ps` reports, `[{name, context_length}]`), `show_failures` (model names whose `/api/show` fails with 500), `ps_status`; for `llama-cpp`: `router` (list the router's models with a `status` and validate the chat `model`), `props` (merged over the `/props` defaults), `props_by_model` (merged for `/props?model=`), `props_status`. `models` for `ollama` uses the `/api/tags` shape plus a private `show` entry (see `catalog.py`).

## Steps

See the docstring of `scenario.py`: `text`, `thinking`, `tool_call`, `usage`, `finish`, `open`, `gate`, `delay`, `keepalive`, `sse_error`, `http_error`, `drop` (reset), `close` (clean close mid-stream), `hold`. An empty step list is a valid scenario: an empty stream that just finishes.

```sh
curl -XPOST $MOCK/__mock/scenarios -d '{"channel":"deepseek","steps":[
  {"type":"thinking","text":"Let me think"},{"type":"text","text":"Hel"},{"type":"gate","name":"mid"},
  {"type":"text","text":"lo"},{"type":"usage","input":12,"output":4}]}'
curl -XPOST $MOCK/__mock/gates/mid/release
```

## Provider quirks reproduced

- DeepSeek: `reasoning_content`, usage in the final chunk, `usage: null` on the others.
- OpenAI: usage in a separate trailing chunk; no reasoning text.
- Anthropic: typed events (`message_start`, `content_block_*`, `message_delta`, `message_stop`), thinking blocks with signatures, `input_json_delta` tool calls, pagination, `tool_use`/`tool_result` pairing checks.
- OpenRouter: `reasoning` deltas, `cost` in usage, public `/models`, `/key` check.
- Ollama, native: NDJSON (no `data:` prefix, no `[DONE]`), `message.thinking`, tool calls whole with object arguments and no id, usage on the `done: true` event (`prompt_eval_count` includes the cached tokens, `prompt_eval_cached_count` only when there are some), `{"error": "…"}` errors also mid-stream, per-model `/api/show` (capabilities, thinking levels, `model_info`, Modelfile `parameters`), `/api/ps` with the loaded context, an embedding-only model in the listing.
- Ollama, OpenAI layer: no auth, whole tool call in a single delta, `reasoning` deltas, thin model list.
- llama.cpp: `reasoning_content`, `timings` next to usage, `meta.n_ctx` in `/v1/models`, `/props` with `chat_template_caps`, router mode (`status` on each model, `meta` only when loaded, the chat `model` validated); a single-model server ignores the requested model name.
